-- Create operations table if not exists
CREATE TABLE IF NOT EXISTS operations (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  status VARCHAR(50) NOT NULL DEFAULT 'pending',
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_operations_status ON operations(status);
CREATE INDEX IF NOT EXISTS idx_operations_created_at ON operations(created_at DESC);

-- Grant permissions to app user (if not postgres)
-- GRANT SELECT, INSERT, UPDATE ON operations TO app_user;
-- GRANT USAGE, SELECT ON SEQUENCE operations_id_seq TO app_user;

-- Seed sample data
INSERT INTO operations (name, status) VALUES 
  ('Deploy API v1.0.0', 'completed'),
  ('Database migration', 'completed'),
  ('Scale services', 'in_progress'),
  ('Update certificates', 'pending'),
  ('Performance audit', 'pending')
ON CONFLICT DO NOTHING;
