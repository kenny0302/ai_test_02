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
import pika
import psycopg2
from psycopg2.extras import RealDictCursor

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


def mock_stt_processing(audio_url):
    """
    Mock STT processing
    In production, this would call actual STT API (Whisper, Google STT, etc.)
    """
    # Simulate processing time (2-5 seconds)
    processing_time = random.uniform(2, 5)
    time.sleep(processing_time)

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
    try:
        # Parse message
        message = json.loads(body)
        task_id = message['task_id']
        audio_url = message.get('audio_url', '')

        logger.info(f"Processing task {task_id} - Audio URL: {audio_url}")

        # Update task status to processing
        update_task_status(task_id, 'processing_stt')

        # Perform STT processing (mock)
        stt_result = mock_stt_processing(audio_url)

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
        logger.error(f"❌ Error processing message: {e}")

        try:
            # Try to update task status to failed
            if 'task_id' in locals():
                update_task_status(task_id, 'failed', str(e))
        except:
            pass

        # Reject message and requeue
        ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)


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
