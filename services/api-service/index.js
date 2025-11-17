const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const rateLimit = require('express-rate-limit');
const { body, validationResult } = require('express-validator');
const { Pool } = require('pg');
const { createClient } = require('redis');
const amqp = require('amqplib');
const client = require('prom-client');
const winston = require('winston');

// Initialize Express app
const app = express();
const PORT = process.env.PORT || 8080;

// Logger configuration
const logger = winston.createLogger({
  level: 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.json()
  ),
  transports: [
    new winston.transports.Console({
      format: winston.format.combine(
        winston.format.colorize(),
        winston.format.simple()
      )
    })
  ]
});

// Prometheus metrics
const register = new client.Registry();
client.collectDefaultMetrics({ register });

const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  registers: [register]
});

const taskCounter = new client.Counter({
  name: 'tasks_total',
  help: 'Total number of tasks',
  labelNames: ['status'],
  registers: [register]
});

// Database connection
const db = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 20,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 2000,
});

// Redis connection
let redisClient;
(async () => {
  redisClient = createClient({
    url: process.env.REDIS_URL
  });

  redisClient.on('error', (err) => logger.error('Redis Client Error', err));
  redisClient.on('connect', () => logger.info('Redis connected'));

  await redisClient.connect();
})();

// RabbitMQ connection
let rabbitChannel;
(async () => {
  try {
    const rabbitConn = await amqp.connect(process.env.RABBITMQ_URL);
    rabbitChannel = await rabbitConn.createChannel();

    // Declare queues
    await rabbitChannel.assertQueue('stt-queue', { durable: true });
    await rabbitChannel.assertQueue('llm-queue', { durable: true });
    await rabbitChannel.assertQueue('dlq-queue', { durable: true });

    logger.info('RabbitMQ connected and queues declared');
  } catch (error) {
    logger.error('RabbitMQ connection error:', error);
    process.exit(1);
  }
})();

// Middleware
app.use(helmet());
app.use(cors());
app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(morgan('combined', {
  stream: {
    write: (message) => logger.info(message.trim())
  }
}));

// Request duration middleware
app.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    const duration = (Date.now() - start) / 1000;
    httpRequestDuration
      .labels(req.method, req.route?.path || req.path, res.statusCode)
      .observe(duration);
  });
  next();
});

// Rate limiting configuration
const apiLimiter = rateLimit({
  windowMs: parseInt(process.env.RATE_LIMIT_WINDOW_MS) || 15 * 60 * 1000, // 15 minutes
  max: parseInt(process.env.RATE_LIMIT_MAX_REQUESTS) || 100, // Max 100 requests per window
  standardHeaders: true, // Return rate limit info in the `RateLimit-*` headers
  legacyHeaders: false, // Disable the `X-RateLimit-*` headers
  handler: (req, res) => {
    logger.warn(`Rate limit exceeded for IP: ${req.ip}`);
    res.status(429).json({
      success: false,
      error: 'Too many requests, please try again later.',
      retryAfter: Math.ceil(req.rateLimit.resetTime / 1000)
    });
  },
  skip: (req) => {
    // Skip rate limiting for health checks
    return req.path.startsWith('/health') || req.path === '/metrics';
  }
});

// Stricter rate limit for task creation
const createTaskLimiter = rateLimit({
  windowMs: 60 * 1000, // 1 minute
  max: 10, // Max 10 task creations per minute
  message: {
    success: false,
    error: 'Too many task creation requests, please slow down.'
  }
});

// Input validation middleware
const validateRequest = (req, res, next) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) {
    return res.status(400).json({
      success: false,
      errors: errors.array().map(err => ({
        field: err.path,
        message: err.msg,
        value: err.value
      }))
    });
  }
  next();
};

// Health check endpoints
app.get('/health/live', (req, res) => {
  res.status(200).json({ status: 'ok', timestamp: new Date().toISOString() });
});

app.get('/health/ready', async (req, res) => {
  const checks = {
    database: 'unknown',
    redis: 'unknown',
    rabbitmq: 'unknown'
  };

  try {
    // Check database
    await db.query('SELECT 1');
    checks.database = 'ok';
  } catch (err) {
    checks.database = 'failed';
    logger.error('Database health check failed:', err);
  }

  try {
    // Check Redis
    await redisClient.ping();
    checks.redis = 'ok';
  } catch (err) {
    checks.redis = 'failed';
    logger.error('Redis health check failed:', err);
  }

  try {
    // Check RabbitMQ
    if (rabbitChannel) {
      checks.rabbitmq = 'ok';
    } else {
      checks.rabbitmq = 'failed';
    }
  } catch (err) {
    checks.rabbitmq = 'failed';
    logger.error('RabbitMQ health check failed:', err);
  }

  const allHealthy = Object.values(checks).every(status => status === 'ok');
  const statusCode = allHealthy ? 200 : 503;

  res.status(statusCode).json({
    status: allHealthy ? 'ready' : 'not_ready',
    checks,
    timestamp: new Date().toISOString()
  });
});

// Metrics endpoint
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

// Apply rate limiting to all API routes
app.use('/api/v1', apiLimiter);

// API Routes
app.get('/api/v1/tasks', async (req, res) => {
  try {
    const userId = req.query.user_id || '00000000-0000-0000-0000-000000000001';
    const limit = parseInt(req.query.limit) || 20;
    const offset = parseInt(req.query.offset) || 0;

    const result = await db.query(
      `SELECT t.*,
              s.transcription,
              l.summary
       FROM tasks t
       LEFT JOIN stt_results s ON t.id = s.task_id
       LEFT JOIN llm_summaries l ON t.id = l.task_id
       WHERE t.user_id = $1
       ORDER BY t.created_at DESC
       LIMIT $2 OFFSET $3`,
      [userId, limit, offset]
    );

    res.json({
      success: true,
      data: result.rows,
      pagination: {
        limit,
        offset,
        total: result.rowCount
      }
    });

    logger.info(`Listed tasks for user ${userId}`);
  } catch (error) {
    logger.error('Error listing tasks:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to list tasks'
    });
  }
});

app.get('/api/v1/tasks/:id', async (req, res) => {
  try {
    const { id } = req.params;

    // Try cache first
    const cacheKey = `task:${id}`;
    const cached = await redisClient.get(cacheKey);

    if (cached) {
      logger.info(`Cache hit for task ${id}`);
      return res.json({
        success: true,
        data: JSON.parse(cached),
        cached: true
      });
    }

    // Query database
    const result = await db.query(
      `SELECT t.*,
              s.transcription, s.confidence, s.language,
              l.summary, l.model_name, l.tokens_used
       FROM tasks t
       LEFT JOIN stt_results s ON t.id = s.task_id
       LEFT JOIN llm_summaries l ON t.id = l.task_id
       WHERE t.id = $1`,
      [id]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({
        success: false,
        error: 'Task not found'
      });
    }

    const task = result.rows[0];

    // Cache the result (1 hour TTL)
    if (task.status === 'completed') {
      await redisClient.setEx(cacheKey, 3600, JSON.stringify(task));
    }

    res.json({
      success: true,
      data: task,
      cached: false
    });

    logger.info(`Retrieved task ${id}`);
  } catch (error) {
    logger.error('Error retrieving task:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to retrieve task'
    });
  }
});

// Task creation validation rules
const createTaskValidation = [
  body('audio_url')
    .optional()
    .isURL()
    .withMessage('audio_url must be a valid URL'),
  body('audio_duration')
    .optional()
    .isInt({ min: 1, max: 7200 })
    .withMessage('audio_duration must be between 1 and 7200 seconds'),
  body('user_id')
    .optional()
    .isUUID()
    .withMessage('user_id must be a valid UUID')
];

app.post('/api/v1/tasks',
  createTaskLimiter,
  createTaskValidation,
  validateRequest,
  async (req, res) => {
  const client = await db.connect();

  try {
    const userId = req.body.user_id || '00000000-0000-0000-0000-000000000001';
    const audioUrl = req.body.audio_url || 'mock://audio/demo.mp3';
    const audioDuration = req.body.audio_duration || 60;

    await client.query('BEGIN');

    // Create task
    const taskResult = await client.query(
      `INSERT INTO tasks (user_id, status, audio_url, audio_duration_seconds, metadata)
       VALUES ($1, $2, $3, $4, $5)
       RETURNING *`,
      [userId, 'pending', audioUrl, audioDuration, { source: 'api' }]
    );

    const task = taskResult.rows[0];

    // Publish to STT queue
    const message = {
      task_id: task.id,
      audio_url: audioUrl,
      timestamp: new Date().toISOString()
    };

    rabbitChannel.sendToQueue(
      'stt-queue',
      Buffer.from(JSON.stringify(message)),
      { persistent: true }
    );

    await client.query('COMMIT');

    // Update metrics
    taskCounter.labels('created').inc();

    res.status(202).json({
      success: true,
      data: {
        task_id: task.id,
        status: task.status,
        status_url: `/api/v1/tasks/${task.id}`,
        estimated_completion_time: new Date(Date.now() + 120000).toISOString()
      }
    });

    logger.info(`Task ${task.id} created and published to STT queue`);
  } catch (error) {
    await client.query('ROLLBACK');
    logger.error('Error creating task:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to create task'
    });
  } finally {
    client.release();
  }
});

app.delete('/api/v1/tasks/:id', async (req, res) => {
  try {
    const { id } = req.params;

    const result = await db.query(
      'DELETE FROM tasks WHERE id = $1 RETURNING id',
      [id]
    );

    if (result.rowCount === 0) {
      return res.status(404).json({
        success: false,
        error: 'Task not found'
      });
    }

    // Delete from cache
    await redisClient.del(`task:${id}`);

    res.json({
      success: true,
      message: 'Task deleted successfully'
    });

    logger.info(`Task ${id} deleted`);
  } catch (error) {
    logger.error('Error deleting task:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to delete task'
    });
  }
});

// Statistics endpoint
app.get('/api/v1/stats', async (req, res) => {
  try {
    const result = await db.query(`
      SELECT
        COUNT(*) FILTER (WHERE status = 'completed') as completed,
        COUNT(*) FILTER (WHERE status = 'failed') as failed,
        COUNT(*) FILTER (WHERE status = 'pending') as pending,
        COUNT(*) FILTER (WHERE status LIKE 'processing%') as processing,
        COUNT(*) as total,
        AVG(EXTRACT(EPOCH FROM (completed_at - created_at))) FILTER (WHERE completed_at IS NOT NULL) as avg_duration_seconds
      FROM tasks
      WHERE created_at > NOW() - INTERVAL '24 hours'
    `);

    res.json({
      success: true,
      data: result.rows[0],
      period: 'last_24_hours'
    });
  } catch (error) {
    logger.error('Error retrieving stats:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to retrieve statistics'
    });
  }
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({
    success: false,
    error: 'Endpoint not found'
  });
});

// Error handler
app.use((err, req, res, next) => {
  logger.error('Unhandled error:', err);
  res.status(500).json({
    success: false,
    error: 'Internal server error'
  });
});

// Graceful shutdown
process.on('SIGTERM', async () => {
  logger.info('SIGTERM received, shutting down gracefully');

  await db.end();
  await redisClient.quit();
  if (rabbitChannel) {
    await rabbitChannel.close();
  }

  process.exit(0);
});

// Start server
app.listen(PORT, () => {
  logger.info(`🚀 API Service running on port ${PORT}`);
  logger.info(`📊 Health check: http://localhost:${PORT}/health/ready`);
  logger.info(`📈 Metrics: http://localhost:${PORT}/metrics`);
});

module.exports = app;
