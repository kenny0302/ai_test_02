#!/usr/bin/env python3
"""
LLM Worker - Text Summarization Worker
Consumes tasks from RabbitMQ, performs LLM summarization (mock), and saves results
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
LLM_QUEUE = os.getenv('LLM_QUEUE', 'llm-queue')
MAX_RETRIES = 3

# LLM Service Configuration
MOCK_LLM_SERVICE = os.getenv('MOCK_LLM_SERVICE', 'true').lower() in ('true', '1', 'yes')
OPENAI_API_KEY = os.getenv('OPENAI_API_KEY', '')
OPENAI_MODEL = os.getenv('OPENAI_MODEL', 'gpt-4')

# Check OpenAI API configuration (using REST API instead of SDK to avoid conflicts)
if not MOCK_LLM_SERVICE:
    if OPENAI_API_KEY:
        logger.info(f"✅ Real LLM Service enabled (OpenAI GPT via REST API)")
        logger.info(f"🤖 Model: {OPENAI_MODEL}")
    else:
        logger.warning("⚠️  MOCK_LLM_SERVICE=false but no OPENAI_API_KEY provided")
        logger.warning("Falling back to mock LLM service")
        MOCK_LLM_SERVICE = True
else:
    logger.info("ℹ️  LLM Service: MOCK mode enabled")

# Mock summaries
MOCK_SUMMARIES = [
    {
        'summary': "This audio discusses the AI processing platform's demo capabilities, highlighting the end-to-end "
                   "workflow from speech-to-text conversion to automated summarization. The system is designed to "
                   "replace mock implementations with production-grade STT services.",
        'key_points': [
            'AI processing platform demonstration',
            'End-to-end speech-to-text and summarization workflow',
            'Production-ready architecture design'
        ]
    },
    {
        'summary': "The transcription covers the platform's scalability features, including high-volume request handling, "
                   "automatic scaling, and fault tolerance mechanisms. The architecture incorporates message queues, "
                   "Redis caching, and PostgreSQL for robust data management.",
        'key_points': [
            'High-volume concurrent request processing',
            'Automatic scaling and fault tolerance',
            'Multi-layered architecture with queuing, caching, and persistence'
        ]
    },
    {
        'summary': "This segment explains the multi-stage AI processing pipeline: audio upload and storage, STT transcription, "
                   "LLM summarization, and result persistence with caching for optimal performance.",
        'key_points': [
            'Multi-stage processing pipeline',
            'Object storage for audio files',
            'Result caching for performance optimization'
        ]
    }
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


def get_stt_result(task_id):
    """Get STT result from database"""
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """SELECT transcription, confidence, language
                   FROM stt_results
                   WHERE task_id = %s
                   ORDER BY created_at DESC
                   LIMIT 1""",
                (task_id,)
            )
            result = cur.fetchone()
            if not result:
                raise ValueError(f"No STT result found for task {task_id}")
            return dict(result)
    finally:
        conn.close()


def update_task_status(task_id, status, error_message=None):
    """Update task status in database"""
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            if status == 'completed':
                cur.execute(
                    """UPDATE tasks
                       SET status = %s, completed_at = NOW(), updated_at = NOW()
                       WHERE id = %s""",
                    (status, task_id)
                )
            elif error_message:
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


def save_llm_result(task_id, summary, model_name, tokens_used, processing_time_ms):
    """Save LLM result to database"""
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """INSERT INTO llm_summaries (task_id, summary, model_name, tokens_used, processing_time_ms)
                   VALUES (%s, %s, %s, %s, %s)
                   RETURNING id""",
                (task_id, summary, model_name, tokens_used, processing_time_ms)
            )
            result_id = cur.fetchone()['id']
            conn.commit()
            logger.info(f"LLM result saved with ID {result_id}")
            return result_id
    except Exception as e:
        logger.error(f"Failed to save LLM result: {e}")
        conn.rollback()
        raise
    finally:
        conn.close()


def real_llm_processing(transcription):
    """
    Real LLM processing using OpenAI GPT API via HTTP REST
    Uses requests library to avoid SDK dependency conflicts

    Args:
        transcription: The text to summarize

    Returns:
        dict: LLM result with summary, model_name, tokens_used, processing_time_ms
    """
    import requests
    import json

    start_time = time.time()

    try:
        logger.info(f"🤖 Starting OpenAI LLM summarization (model: {OPENAI_MODEL})")
        logger.info(f"📝 Input length: {len(transcription)} characters")

        # OpenAI Chat Completions API endpoint
        url = "https://api.openai.com/v1/chat/completions"

        headers = {
            "Authorization": f"Bearer {OPENAI_API_KEY}",
            "Content-Type": "application/json"
        }

        payload = {
            "model": OPENAI_MODEL,
            "messages": [
                {
                    "role": "system",
                    "content": "You are a helpful assistant that creates concise summaries of transcribed audio. "
                               "Provide a clear summary followed by 3-5 key points in bullet format."
                },
                {
                    "role": "user",
                    "content": f"Please summarize the following transcription:\n\n{transcription}"
                }
            ],
            "temperature": 0.7,
            "max_tokens": 500
        }

        # Make HTTP POST request
        response = requests.post(url, headers=headers, json=payload, timeout=120)
        response.raise_for_status()

        processing_time = time.time() - start_time

        # Parse JSON response
        result = response.json()
        summary = result['choices'][0]['message']['content']
        tokens_used = result['usage']['total_tokens']
        model_used = result['model']

        logger.info(f"✅ OpenAI LLM completed in {processing_time:.2f}s")
        logger.info(f"📊 Tokens used: {tokens_used}")
        logger.info(f"🤖 Model: {model_used}")
        logger.info(f"📄 Summary length: {len(summary)} characters")

        return {
            'summary': summary,
            'model_name': model_used,
            'tokens_used': tokens_used,
            'processing_time_ms': int(processing_time * 1000)
        }

    except requests.exceptions.RequestException as e:
        processing_time = time.time() - start_time
        logger.error(f"❌ OpenAI LLM API HTTP error: {e}")
        if hasattr(e.response, 'text'):
            logger.error(f"Response: {e.response.text}")
        raise
    except Exception as e:
        processing_time = time.time() - start_time
        logger.error(f"❌ OpenAI LLM API error: {e}")
        raise


def mock_llm_processing(transcription):
    """
    Mock LLM processing
    Simulates LLM processing without calling external APIs
    """
    # Simulate processing time (3-7 seconds)
    processing_time = random.uniform(3, 7)
    time.sleep(processing_time)

    # Generate mock summary
    mock_result = random.choice(MOCK_SUMMARIES)

    # Calculate mock tokens
    tokens_used = len(transcription.split()) * 2  # Rough estimate

    logger.info(f"🎭 Mock LLM processing completed in {processing_time:.2f}s")

    # Create enhanced summary
    summary = f"{mock_result['summary']}\n\n**Key Points:**\n"
    for i, point in enumerate(mock_result['key_points'], 1):
        summary += f"{i}. {point}\n"

    return {
        'summary': summary,
        'model_name': 'mock-llm-v1',
        'tokens_used': tokens_used,
        'processing_time_ms': int(processing_time * 1000)
    }


def perform_llm_processing(transcription):
    """
    Unified LLM processing entry point
    Routes to real or mock LLM based on configuration

    Args:
        transcription: The text to summarize

    Returns:
        dict: LLM result with summary, model_name, tokens_used, processing_time_ms
    """
    if MOCK_LLM_SERVICE:
        # Use mock LLM
        return mock_llm_processing(transcription)
    else:
        # Use real LLM
        return real_llm_processing(transcription)


def process_message(ch, method, properties, body):
    """Process incoming message from LLM queue"""
    task_id = None

    try:
        # Parse message
        message = json.loads(body)
        task_id = message['task_id']

        logger.info(f"Processing task {task_id}")

        # Update task status to processing
        update_task_status(task_id, 'processing_llm')

        # Get STT result
        stt_result = get_stt_result(task_id)
        transcription = stt_result['transcription']

        logger.info(f"Retrieved transcription: {len(transcription)} characters")

        # Perform LLM processing (mock or real based on config)
        llm_result = perform_llm_processing(transcription)

        # Save LLM result to database
        save_llm_result(
            task_id,
            llm_result['summary'],
            llm_result['model_name'],
            llm_result['tokens_used'],
            llm_result['processing_time_ms']
        )

        # Update task status to completed
        update_task_status(task_id, 'completed')

        # Acknowledge message
        ch.basic_ack(delivery_tag=method.delivery_tag)

        logger.info(f"✅ Task {task_id} LLM processing completed successfully")

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
    logger.info("🚀 LLM Worker starting...")

    # Wait for services to be ready
    time.sleep(15)  # Wait a bit longer than STT worker

    # Connect to RabbitMQ
    while True:
        try:
            # Parse RabbitMQ URL
            params = pika.URLParameters(RABBITMQ_URL)
            connection = pika.BlockingConnection(params)
            channel = connection.channel()

            # Declare queue
            channel.queue_declare(queue=LLM_QUEUE, durable=True)

            # Set QoS - process one message at a time
            channel.basic_qos(prefetch_count=1)

            # Start consuming
            channel.basic_consume(
                queue=LLM_QUEUE,
                on_message_callback=process_message
            )

            logger.info(f"👂 LLM Worker listening on queue: {LLM_QUEUE}")
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
