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


def mock_llm_processing(transcription):
    """
    Mock LLM processing
    In production, this would call actual LLM API (GPT-4, Claude, Llama, etc.)
    """
    # Simulate processing time (3-7 seconds)
    processing_time = random.uniform(3, 7)
    time.sleep(processing_time)

    # Generate mock summary
    mock_result = random.choice(MOCK_SUMMARIES)

    # Calculate mock tokens
    tokens_used = len(transcription.split()) * 2  # Rough estimate

    logger.info(f"Mock LLM processing completed in {processing_time:.2f}s")

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


def process_message(ch, method, properties, body):
    """Process incoming message from LLM queue"""
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

        # Perform LLM processing (mock)
        llm_result = mock_llm_processing(transcription)

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
