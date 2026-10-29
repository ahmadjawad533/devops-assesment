const express = require('express');
const http = require('http');
const pinoHttp = require('pino-http');
const pino = require('pino');
const { Pool } = require('pg');

// Initialize logger with structured logging
const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  transport: {
    target: 'pino-pretty',
    options: {
      colorize: true,
      singleLine: true,
      translateTime: 'SYS:standard',
      ignore: 'pid,hostname',
    },
  },
});

const app = express();

// Middleware
app.use(pinoHttp({ logger }));
app.use(express.json());

// Database connection pool
const pool = new Pool({
  user: process.env.DB_USER || 'postgres',
  password: process.env.DB_PASSWORD || 'postgres',
  host: process.env.DB_HOST || 'localhost',
  port: process.env.DB_PORT || 5432,
  database: process.env.DB_NAME || 'apex_ops',
  max: 20,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 2000,
});

// Track database connectivity
let dbHealthy = false;
pool.on('error', (err) => {
  logger.error({ err }, 'Unexpected error on idle client');
  dbHealthy = false;
});

// Initialize database connection on startup
pool.connect((err, client, release) => {
  if (err) {
    logger.error({ err }, 'Failed to connect to database on startup');
    dbHealthy = false;
  } else {
    logger.info('Database connection pool initialized');
    dbHealthy = true;
    if (client) release();
  }
});

// Metrics counter
const metrics = {
  requests_total: 0,
  requests_success: 0,
  requests_error: 0,
  db_queries: 0,
  db_errors: 0,
};

// ============ HEALTH & READINESS ENDPOINTS ============

// Liveness probe - is the app running?
app.get('/live', (req, res) => {
  res.status(200).json({ status: 'alive', timestamp: new Date().toISOString() });
});

// Readiness probe - is the app ready to serve traffic?
app.get('/ready', async (req, res) => {
  try {
    const result = await pool.query('SELECT NOW()');
    if (result.rows.length > 0) {
      dbHealthy = true;
      res.status(200).json({
        status: 'ready',
        database: 'connected',
        timestamp: new Date().toISOString(),
      });
    } else {
      throw new Error('No response from database');
    }
  } catch (err) {
    logger.error({ err }, 'Readiness check failed');
    dbHealthy = false;
    res.status(503).json({
      status: 'not_ready',
      database: 'disconnected',
      error: err.message,
      timestamp: new Date().toISOString(),
    });
  }
});

// ============ METRICS ENDPOINT ============

app.get('/metrics', (req, res) => {
  const metricsText = `
# HELP requests_total Total number of requests
# TYPE requests_total counter
requests_total ${metrics.requests_total}

# HELP requests_success Total number of successful requests
# TYPE requests_success counter
requests_success ${metrics.requests_success}

# HELP requests_error Total number of failed requests
# TYPE requests_error counter
requests_error ${metrics.requests_error}

# HELP db_queries Total number of database queries
# TYPE db_queries counter
db_queries ${metrics.db_queries}

# HELP db_errors Total number of database errors
# TYPE db_errors counter
db_errors ${metrics.db_errors}

# HELP app_info Application information
# TYPE app_info gauge
app_info{version="${process.env.APP_VERSION || '1.0.0'}"} 1
  `.trim();
  
  res.set('Content-Type', 'text/plain; charset=utf-8');
  res.send(metricsText);
});

// ============ API ENDPOINTS ============

// GET /operations - List all operations
app.get('/operations', async (req, res) => {
  metrics.requests_total++;
  try {
    metrics.db_queries++;
    const result = await pool.query(
      'SELECT id, name, status, created_at, updated_at FROM operations ORDER BY created_at DESC'
    );
    metrics.requests_success++;
    logger.info({ count: result.rows.length }, 'Operations retrieved');
    res.json(result.rows);
  } catch (err) {
    metrics.requests_error++;
    metrics.db_errors++;
    logger.error({ err }, 'Failed to retrieve operations');
    res.status(500).json({ error: 'Internal server error', message: err.message });
  }
});

// GET /operations/:id - Get single operation
app.get('/operations/:id', async (req, res) => {
  metrics.requests_total++;
  try {
    const { id } = req.params;
    metrics.db_queries++;
    const result = await pool.query(
      'SELECT id, name, status, created_at, updated_at FROM operations WHERE id = $1',
      [id]
    );
    if (result.rows.length === 0) {
      metrics.requests_success++;
      return res.status(404).json({ error: 'Operation not found' });
    }
    metrics.requests_success++;
    logger.info({ id }, 'Operation retrieved');
    res.json(result.rows[0]);
  } catch (err) {
    metrics.requests_error++;
    metrics.db_errors++;
    logger.error({ err, id: req.params.id }, 'Failed to retrieve operation');
    res.status(500).json({ error: 'Internal server error', message: err.message });
  }
});

// POST /operations - Create new operation
app.post('/operations', async (req, res) => {
  metrics.requests_total++;
  try {
    const { name, status = 'pending' } = req.body;
    
    if (!name || typeof name !== 'string' || name.trim().length === 0) {
      metrics.requests_success++;
      return res.status(400).json({ error: 'Invalid request', details: 'name is required and must be non-empty string' });
    }

    metrics.db_queries++;
    const result = await pool.query(
      'INSERT INTO operations (name, status, created_at, updated_at) VALUES ($1, $2, NOW(), NOW()) RETURNING id, name, status, created_at, updated_at',
      [name, status]
    );
    metrics.requests_success++;
    logger.info({ name, status }, 'Operation created');
    res.status(201).json(result.rows[0]);
  } catch (err) {
    metrics.requests_error++;
    metrics.db_errors++;
    logger.error({ err }, 'Failed to create operation');
    res.status(500).json({ error: 'Internal server error', message: err.message });
  }
});

// ============ ERROR HANDLING ============

app.use((req, res) => {
  metrics.requests_total++;
  metrics.requests_error++;
  logger.warn({ method: req.method, path: req.path }, 'Route not found');
  res.status(404).json({ error: 'Not found' });
});

app.use((err, req, res, next) => {
  metrics.requests_total++;
  metrics.requests_error++;
  logger.error({ err }, 'Unhandled error');
  res.status(500).json({ error: 'Internal server error', message: err.message });
});

// ============ SERVER STARTUP ============

const PORT = process.env.PORT || 3000;
const server = http.createServer(app);

server.listen(PORT, '0.0.0.0', () => {
  logger.info(
    {
      port: PORT,
      env: process.env.NODE_ENV || 'development',
      version: process.env.APP_VERSION || '1.0.0',
    },
    'Server started'
  );
});

// Graceful shutdown
process.on('SIGTERM', () => {
  logger.info('SIGTERM received, shutting down gracefully...');
  server.close(() => {
    logger.info('HTTP server closed');
    pool.end(() => {
      logger.info('Database pool closed');
      process.exit(0);
    });
  });
});

process.on('SIGINT', () => {
  logger.info('SIGINT received, shutting down gracefully...');
  server.close(() => {
    logger.info('HTTP server closed');
    pool.end(() => {
      logger.info('Database pool closed');
      process.exit(0);
    });
  });
});

module.exports = app;
