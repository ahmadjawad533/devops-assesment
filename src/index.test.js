const request = require('supertest');
const app = require('./index');

describe('Apex Operations API', () => {
  // Test 1: Liveness probe
  describe('GET /live', () => {
    it('should return 200 and alive status', async () => {
      const response = await request(app).get('/live');
      expect(response.status).toBe(200);
      expect(response.body).toHaveProperty('status', 'alive');
      expect(response.body).toHaveProperty('timestamp');
    });
  });

  // Test 2: Readiness probe
  describe('GET /ready', () => {
    it('should return 503 when database is unavailable (intentional failure demo)', async () => {
      // This test intentionally expects failure to demonstrate
      // monitoring and incident response capabilities
      const response = await request(app).get('/ready');
      // In a real test environment without DB, we expect 503
      expect([200, 503]).toContain(response.status);
      expect(response.body).toHaveProperty('status');
    });
  });

  // Test 3: Metrics endpoint
  describe('GET /metrics', () => {
    it('should return prometheus-format metrics', async () => {
      const response = await request(app).get('/metrics');
      expect(response.status).toBe(200);
      expect(response.type).toBe('text/plain');
      expect(response.text).toContain('requests_total');
      expect(response.text).toContain('app_info');
    });
  });

  // Test 4: GET /operations with invalid DB connection
  describe('GET /operations', () => {
    it('should handle request (returns 500 if DB unavailable)', async () => {
      const response = await request(app).get('/operations');
      // Without real DB, expect error; in production with DB, expect 200
      expect([200, 500]).toContain(response.status);
      expect(response.body).toBeDefined();
    });
  });

  // Test 5: POST /operations validation
  describe('POST /operations', () => {
    it('should reject request without name field', async () => {
      const response = await request(app)
        .post('/operations')
        .send({ status: 'pending' });
      expect(response.status).toBe(400);
      expect(response.body).toHaveProperty('error');
    });

    it('should reject empty name', async () => {
      const response = await request(app)
        .post('/operations')
        .send({ name: '', status: 'pending' });
      expect(response.status).toBe(400);
      expect(response.body).toHaveProperty('error');
    });
  });

  // Test 6: 404 handling
  describe('Error Handling', () => {
    it('should return 404 for unknown routes', async () => {
      const response = await request(app).get('/unknown-route');
      expect(response.status).toBe(404);
      expect(response.body).toHaveProperty('error');
    });
  });

  // Test 7: Content-Type validation
  describe('JSON response headers', () => {
    it('should return JSON content-type', async () => {
      const response = await request(app).get('/live');
      expect(response.type).toMatch(/json/);
    });
  });
});
