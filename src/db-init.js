const { Pool } = require('pg');
const pino = require('pino');

const logger = pino();

async function initializeDatabase() {
  const pool = new Pool({
    user: process.env.DB_USER || 'postgres',
    password: process.env.DB_PASSWORD || 'postgres',
    host: process.env.DB_HOST || 'localhost',
    port: process.env.DB_PORT || 5432,
    database: process.env.DB_NAME || 'apex_ops',
    connectionTimeoutMillis: 5000,
  });

  try {
    logger.info('Connecting to database...');
    const client = await pool.connect();
    logger.info('Connected to database');

    // Create operations table
    await client.query(`
      CREATE TABLE IF NOT EXISTS operations (
        id SERIAL PRIMARY KEY,
        name VARCHAR(255) NOT NULL,
        status VARCHAR(50) NOT NULL DEFAULT 'pending',
        created_at TIMESTAMP DEFAULT NOW(),
        updated_at TIMESTAMP DEFAULT NOW()
      );
    `);
    logger.info('Operations table created/verified');

    // Create index for faster queries
    await client.query(`
      CREATE INDEX IF NOT EXISTS idx_operations_status ON operations(status);
    `);
    logger.info('Index created/verified');

    // Insert sample data
    await client.query(`
      INSERT INTO operations (name, status) VALUES 
        ('Deploy v1.0.0', 'completed'),
        ('Scale database', 'in_progress'),
        ('Update certificates', 'pending')
      ON CONFLICT DO NOTHING;
    `);
    logger.info('Sample data seeded');

    client.release();
    logger.info('Database initialization complete');
    process.exit(0);
  } catch (err) {
    logger.error({ err }, 'Database initialization failed');
    process.exit(1);
  } finally {
    await pool.end();
  }
}

initializeDatabase();
