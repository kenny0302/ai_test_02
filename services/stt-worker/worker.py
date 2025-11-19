#!/usr/bin/env python3
"""
STT Worker - Speech-to-Text Processing Worker
Consumes tasks from RabbitMQ, performs STT (mock), and publishes to LLM queue
"""

import os
import json
import time
import logging
import random
from datetime import datetime
from urllib.parse import urlparse
import pika
import psycopg2
from psycopg2.extras import RealDictCursor
import boto3
from botocore.client import Config

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuration
DATABASE_URL = os.getenv('DATABASE_URL')
RABBITMQ_URL = os.getenv('RABBITMQ_URL', 'amqp://admin:admin123@rabbitmq:5672')
STT_QUEUE = os.getenv('STT_QUEUE', 'stt-queue')
LLM_QUEUE = 'llm-queue'
MAX_RETRIES = 3

# MinIO/S3 Configuration
ENABLE_MINIO = os.getenv('ENABLE_MINIO', 'false').lower() in ('true', '1', 'yes')
S3_ENDPOINT = os.getenv('S3_ENDPOINT', 'http://minio:9000')
S3_REGION = os.getenv('S3_REGION', 'us-east-1')
MINIO_ROOT_USER = os.getenv('MINIO_ROOT_USER', 'admin')
MINIO_ROOT_PASSWORD = os.getenv('MINIO_ROOT_PASSWORD', 'admin123456')

# STT Service Configuration
MOCK_STT_SERVICE = os.getenv('MOCK_STT_SERVICE', 'true').lower() in ('true', '1', 'yes')
OPENAI_API_KEY = os.getenv('OPENAI_API_KEY', '')
# For Whisper STT, always use whisper-1 model
OPENAI_STT_MODEL = 'whisper-1'

# Initialize S3 client only if MinIO is enabled
s3_client = None
if ENABLE_MINIO:
    try:
        s3_client = boto3.client(
            's3',
            endpoint_url=S3_ENDPOINT,
            aws_access_key_id=MINIO_ROOT_USER,
            aws_secret_access_key=MINIO_ROOT_PASSWORD,
            region_name=S3_REGION,
            config=Config(signature_version='s3v4')
        )
        logger.info(f"✅ MinIO S3 client initialized (endpoint: {S3_ENDPOINT})")
    except Exception as e:
        logger.warning(f"⚠️  Failed to initialize MinIO S3 client: {e}")
        logger.warning("Falling back to mock-only mode")
else:
    logger.info("ℹ️  MinIO disabled - running in mock-only mode")

# Check OpenAI API configuration (using REST API instead of SDK to avoid conflicts)
if not MOCK_STT_SERVICE:
    if OPENAI_API_KEY:
        logger.info(f"✅ Real STT Service enabled (OpenAI Whisper via REST API)")
        logger.info(f"🎙️  Model: {OPENAI_STT_MODEL}")
    else:
        logger.warning("⚠️  MOCK_STT_SERVICE=false but no OPENAI_API_KEY provided")
        logger.warning("Falling back to mock STT service")
        MOCK_STT_SERVICE = True
else:
    logger.info("ℹ️  STT Service: MOCK mode enabled")

# Mock transcriptions
MOCK_TRANSCRIPTIONS = [
    "Welcome to our AI processing platform demo. This is a mock transcription of your audio file. "
    "The system demonstrates end-to-end processing from speech-to-text to summarization. "
    "In a production environment, this would be replaced with actual STT API calls to services like "
    "OpenAI Whisper, Google Cloud Speech-to-Text, or AWS Transcribe.",

    "This is another example transcription. Our platform is designed to handle high-volume concurrent requests "
    "with automatic scaling and fault tolerance. The architecture includes message queues for asynchronous processing, "
    "Redis caching for performance, and PostgreSQL for reliable data storage.",

    "The AI processing pipeline consists of multiple stages. First, the audio file is uploaded and stored in object storage. "
    "Then, the STT worker transcribes the audio to text. Next, the LLM worker generates a summary of the transcription. "
    "Finally, the results are stored in the database and cached for quick retrieval."
]


def get_db_connection():
    """Create database connection"""
    try:
        conn = psycopg2.connect(DATABASE_URL, cursor_factory=RealDictCursor)
        return conn
    except Exception as e:
        logger.error(f"Database connection failed: {e}")
        raise


def get_retry_count(task_id):
    """Get current retry count for a task"""
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT retry_count FROM tasks WHERE id = %s",
                (task_id,)
            )
            result = cur.fetchone()
            return result['retry_count'] if result else 0
    except Exception as e:
        logger.error(f"Failed to get retry count: {e}")
        return 0
    finally:
        conn.close()


def increment_retry_count(task_id):
    """Increment retry count for a task"""
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """UPDATE tasks
                   SET retry_count = retry_count + 1, updated_at = NOW()
                   WHERE id = %s
                   RETURNING retry_count""",
                (task_id,)
            )
            result = cur.fetchone()
            conn.commit()
            new_count = result['retry_count'] if result else 0
            logger.info(f"Task {task_id} retry count incremented to {new_count}")
            return new_count
    except Exception as e:
        logger.error(f"Failed to increment retry count: {e}")
        conn.rollback()
        raise
    finally:
        conn.close()


def update_task_status(task_id, status, error_message=None):
    """Update task status in database"""
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            if error_message:
                cur.execute(
                    """UPDATE tasks
                       SET status = %s, error_message = %s, updated_at = NOW()
                       WHERE id = %s""",
                    (status, error_message, task_id)
                )
            else:
                cur.execute(
                    """UPDATE tasks
                       SET status = %s, updated_at = NOW()
                       WHERE id = %s""",
                    (status, task_id)
                )
            conn.commit()
            logger.info(f"Task {task_id} status updated to {status}")
    except Exception as e:
        logger.error(f"Failed to update task status: {e}")
        conn.rollback()
        raise
    finally:
        conn.close()


def save_stt_result(task_id, transcription, confidence, language, processing_time_ms):
    """Save STT result to database"""
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """INSERT INTO stt_results (task_id, transcription, confidence, language, processing_time_ms)
                   VALUES (%s, %s, %s, %s, %s)
                   RETURNING id""",
                (task_id, transcription, confidence, language, processing_time_ms)
            )
            result_id = cur.fetchone()['id']
            conn.commit()
            logger.info(f"STT result saved with ID {result_id}")
            return result_id
    except Exception as e:
        logger.error(f"Failed to save STT result: {e}")
        conn.rollback()
        raise
    finally:
        conn.close()


def download_audio_from_minio(audio_url):
    """
    Download audio file from MinIO
    Returns: file path of downloaded audio, or None if download failed
    """
    # Check if MinIO is enabled
    if not ENABLE_MINIO or s3_client is None:
        logger.info("ℹ️  MinIO is disabled, skipping download")
        return None

    try:
        # Parse the audio URL to extract bucket and key
        # Expected format: http://minio:9000/audio-files/audio/timestamp-filename.mp3
        parsed_url = urlparse(audio_url)

        # Check if it's a MinIO URL
        if 'minio' not in parsed_url.netloc and 'localhost:9000' not in parsed_url.netloc:
            logger.warning(f"URL is not a MinIO URL: {audio_url}")
            return None

        # Extract path parts: /audio-files/audio/timestamp-filename.mp3
        path_parts = parsed_url.path.lstrip('/').split('/', 1)
        if len(path_parts) < 2:
            logger.error(f"Invalid MinIO URL format: {audio_url}")
            return None

        bucket_name = path_parts[0]  # audio-files
        object_key = path_parts[1]   # audio/timestamp-filename.mp3

        logger.info(f"Downloading from MinIO - Bucket: {bucket_name}, Key: {object_key}")

        # Create temporary file path
        local_file_path = f"/tmp/{object_key.replace('/', '_')}"

        # Download file from MinIO
        s3_client.download_file(bucket_name, object_key, local_file_path)

        logger.info(f"✅ Downloaded audio file to {local_file_path}")
        return local_file_path

    except Exception as e:
        logger.error(f"❌ Failed to download audio from MinIO: {e}")
        return None


def real_stt_processing(audio_file_path):
    """
    Real STT processing using OpenAI Whisper API via HTTP REST
    Uses requests library to avoid SDK dependency conflicts

    Args:
        audio_file_path: Local path to audio file

    Returns:
        dict: STT result with transcription, confidence, language, processing_time_ms
    """
    import requests

    start_time = time.time()

    try:
        logger.info(f"🎙️  Starting OpenAI Whisper transcription: {audio_file_path}")

        # OpenAI Whisper API endpoint
        url = "https://api.openai.com/v1/audio/transcriptions"

        headers = {
            "Authorization": f"Bearer {OPENAI_API_KEY}"
        }

        # Read audio file
        with open(audio_file_path, 'rb') as audio_file:
            files = {
                'file': (os.path.basename(audio_file_path), audio_file, 'audio/wav')
            }
            data = {
                'model': OPENAI_STT_MODEL,
                'response_format': 'verbose_json'
            }

            # Make HTTP POST request
            response = requests.post(url, headers=headers, files=files, data=data, timeout=120)
            response.raise_for_status()

        processing_time = time.time() - start_time

        # Parse JSON response
        result = response.json()
        transcription = result.get('text', '')
        language = result.get('language', 'unknown')

        # OpenAI Whisper doesn't provide confidence scores in the standard API
        # We'll estimate based on duration and processing success
        confidence = 0.95  # High confidence for successful API calls

        logger.info(f"✅ OpenAI Whisper completed in {processing_time:.2f}s")
        logger.info(f"📝 Transcription length: {len(transcription)} characters")
        logger.info(f"🌍 Detected language: {language}")

        return {
            'transcription': transcription,
            'confidence': confidence,
            'language': language,
            'processing_time_ms': int(processing_time * 1000)
        }

    except requests.exceptions.RequestException as e:
        processing_time = time.time() - start_time
        logger.error(f"❌ OpenAI Whisper API HTTP error: {e}")
        if hasattr(e.response, 'text'):
            logger.error(f"Response: {e.response.text}")
        raise
    except Exception as e:
        processing_time = time.time() - start_time
        logger.error(f"❌ OpenAI Whisper API error: {e}")
        raise


def mock_stt_processing(audio_url, audio_file_path=None):
    """
    Mock STT processing
    Simulates STT processing without calling external APIs

    Args:
        audio_url: URL of the audio file
        audio_file_path: Local path to downloaded audio file (if available)
    """
    # Simulate processing time (2-5 seconds)
    processing_time = random.uniform(2, 5)
    time.sleep(processing_time)

    # Log whether we have the actual file
    if audio_file_path:
        logger.info(f"🎭 Mock processing downloaded audio file: {audio_file_path}")
    else:
        logger.info(f"🎭 Mock processing with URL only: {audio_url}")

    # Generate mock transcription
    transcription = random.choice(MOCK_TRANSCRIPTIONS)
    confidence = random.uniform(0.85, 0.99)
    language = "en"

    logger.info(f"Mock STT processing completed in {processing_time:.2f}s")

    return {
        'transcription': transcription,
        'confidence': confidence,
        'language': language,
        'processing_time_ms': int(processing_time * 1000)
    }


def perform_stt_processing(audio_url, audio_file_path=None):
    """
    Unified STT processing entry point
    Routes to real or mock STT based on configuration

    Args:
        audio_url: URL of the audio file
        audio_file_path: Local path to downloaded audio file (if available)

    Returns:
        dict: STT result with transcription, confidence, language, processing_time_ms
    """
    if MOCK_STT_SERVICE:
        # Use mock STT
        return mock_stt_processing(audio_url, audio_file_path)
    else:
        # Use real STT (requires audio file)
        if not audio_file_path:
            logger.warning("⚠️  Real STT requires audio file, but none provided. Downloading...")
            audio_file_path = download_audio_from_minio(audio_url)

            if not audio_file_path:
                logger.error("❌ Cannot perform real STT without audio file. Falling back to mock.")
                return mock_stt_processing(audio_url, audio_file_path)

        return real_stt_processing(audio_file_path)


def publish_to_llm_queue(channel, task_id):
    """Publish task to LLM queue"""
    try:
        message = {
            'task_id': task_id,
            'timestamp': datetime.now().isoformat()
        }

        channel.basic_publish(
            exchange='',
            routing_key=LLM_QUEUE,
            body=json.dumps(message),
            properties=pika.BasicProperties(
                delivery_mode=2,  # Make message persistent
                content_type='application/json'
            )
        )

        logger.info(f"Task {task_id} published to LLM queue")
    except Exception as e:
        logger.error(f"Failed to publish to LLM queue: {e}")
        raise


def process_message(ch, method, properties, body):
    """Process incoming message from STT queue"""
    task_id = None
    audio_file_path = None

    try:
        # Parse message
        message = json.loads(body)
        task_id = message['task_id']
        audio_url = message.get('audio_url', '')

        logger.info(f"Processing task {task_id} - Audio URL: {audio_url}")

        # Update task status to processing
        update_task_status(task_id, 'processing_stt')

        # Try to download audio file from MinIO if it's a MinIO URL
        if audio_url and ('minio' in audio_url or 'localhost:9000' in audio_url):
            audio_file_path = download_audio_from_minio(audio_url)
            if audio_file_path:
                logger.info(f"✅ Audio file downloaded successfully: {audio_file_path}")
            else:
                logger.warning("⚠️  Failed to download audio, proceeding with mock processing")
        else:
            logger.info("ℹ️  Non-MinIO URL or mock URL, skipping download")

        # Perform STT processing (mock or real based on config)
        stt_result = perform_stt_processing(audio_url, audio_file_path)

        # Clean up downloaded file
        if audio_file_path:
            try:
                import os as os_module
                if os_module.path.exists(audio_file_path):
                    os_module.remove(audio_file_path)
                    logger.info(f"🗑️  Cleaned up temporary file: {audio_file_path}")
            except Exception as cleanup_error:
                logger.warning(f"Failed to clean up temporary file: {cleanup_error}")

        # Save STT result to database
        save_stt_result(
            task_id,
            stt_result['transcription'],
            stt_result['confidence'],
            stt_result['language'],
            stt_result['processing_time_ms']
        )

        # Update task status
        update_task_status(task_id, 'stt_completed')

        # Publish to LLM queue
        publish_to_llm_queue(ch, task_id)

        # Acknowledge message
        ch.basic_ack(delivery_tag=method.delivery_tag)

        logger.info(f"✅ Task {task_id} STT processing completed successfully")

    except Exception as e:
        logger.error(f"❌ Error processing task {task_id}: {e}")

        if task_id:
            try:
                # Get current retry count
                retry_count = get_retry_count(task_id)
                logger.info(f"Task {task_id} retry count: {retry_count}/{MAX_RETRIES}")

                if retry_count >= MAX_RETRIES:
                    # Max retries reached - permanently fail the task
                    update_task_status(task_id, 'failed', f"Max retries ({MAX_RETRIES}) exceeded: {str(e)}")

                    # Acknowledge message to remove from queue
                    ch.basic_ack(delivery_tag=method.delivery_tag)

                    logger.error(f"❌ Task {task_id} permanently failed after {retry_count} retries")
                else:
                    # Increment retry count
                    new_count = increment_retry_count(task_id)

                    # Calculate exponential backoff delay (for logging)
                    delay = min(2 ** retry_count, 300)  # Max 5 minutes

                    # Requeue the message for retry
                    ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)

                    logger.warning(f"⚠️  Task {task_id} will be retried (attempt {new_count}/{MAX_RETRIES})")
                    logger.info(f"Suggested backoff delay: {delay} seconds")

            except Exception as retry_error:
                logger.error(f"Error handling retry logic: {retry_error}")
                # In case of error, requeue anyway
                ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
        else:
            # If we don't have task_id, we can't properly handle retry
            # Reject and requeue once
            ch.basic_nack(delivery_tag=method.delivery_tag, requeue=False)


def main():
    """Main worker loop"""
    logger.info("🚀 STT Worker starting...")

    # Wait for services to be ready
    time.sleep(10)

    # Connect to RabbitMQ
    while True:
        try:
            # Parse RabbitMQ URL
            params = pika.URLParameters(RABBITMQ_URL)
            connection = pika.BlockingConnection(params)
            channel = connection.channel()

            # Declare queue
            channel.queue_declare(queue=STT_QUEUE, durable=True)

            # Set QoS - process one message at a time
            channel.basic_qos(prefetch_count=1)

            # Start consuming
            channel.basic_consume(
                queue=STT_QUEUE,
                on_message_callback=process_message
            )

            logger.info(f"👂 STT Worker listening on queue: {STT_QUEUE}")
            logger.info("⏳ Waiting for messages. To exit press CTRL+C")

            channel.start_consuming()

        except KeyboardInterrupt:
            logger.info("Worker stopped by user")
            break
        except Exception as e:
            logger.error(f"Worker error: {e}")
            logger.info("Reconnecting in 5 seconds...")
            time.sleep(5)


if __name__ == '__main__':
    main()
