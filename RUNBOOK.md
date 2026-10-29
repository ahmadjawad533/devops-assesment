# Apex Operations API - Operational Runbook

**Last Updated:** October 2026  
**Version:** 1.0.0  
**Owner:** DevOps Team  
**On-call Escalation:** [Team Lead] → [Engineering Manager]

---

## Table of Contents

1. [Overview](#overview)
2. [Environment Setup](#environment-setup)
3. [Deployment](#deployment)
4. [Rollback Procedure](#rollback-procedure)
5. [Incident Response](#incident-response)
6. [Troubleshooting](#troubleshooting)
7. [Monitoring & Alerts](#monitoring--alerts)
8. [Maintenance](#maintenance)

---

## Overview

**Apex Operations API** is a Node.js/Express microservice that provides operations management capabilities backed by PostgreSQL. The application runs in Docker containers orchestrated with Docker Compose for local deployment.

### Key Architecture Components

- **API**: Node.js Express application (port 3000, runs as non-root user `appuser:1001`)
- **Database**: PostgreSQL 15 (port 5432, persistent volume `postgres_data`)
- **Monitoring**: Prometheus metrics endpoint at `/metrics`
- **Observability**: Structured JSON logging via Pino

### Service Endpoints

| Endpoint | Method | Purpose | Response |
|----------|--------|---------|----------|
| `/live` | GET | Liveness probe | `{"status": "alive", "timestamp": "..."}` |
| `/ready` | GET | Readiness probe | `{"status": "ready/not_ready", "database": "connected/disconnected"}` |
| `/metrics` | GET | Prometheus metrics | Text-based metric format |
| `/operations` | GET | List all operations | JSON array of operations |
| `/operations/:id` | GET | Get specific operation | JSON operation object |
| `/operations` | POST | Create new operation | JSON operation object with ID |

---

## Environment Setup

### Prerequisites

- Docker (v20.10+)
- Docker Compose (v1.29+)
- Git (for version control)
- Bash shell (for deployment scripts)
- `curl` (for health checks)

### Initial Setup

1. **Clone/extract the repository**
   ```bash
   cd /path/to/apex-operations-api
   ```

2. **Set up environment configuration**
   ```bash
   cp .env.example .env
   # Edit .env with appropriate values for your environment
   ```

3. **Build Docker image**
   ```bash
   docker-compose build
   ```

4. **Initialize volumes (if first time)**
   ```bash
   docker-compose down -v  # Clean slate
   docker-compose up -d db  # Start database
   docker-compose exec db psql -U postgres -d apex_ops -f /docker-entrypoint-initdb.d/01-init.sql
   ```

---

## Deployment

### Quick Start Deployment

```bash
# Start all services
docker-compose up -d

# Verify services are running
docker-compose ps

# Check API health
curl http://localhost:3000/ready
```

### Versioned Deployment (Recommended)

```bash
# Deploy specific version
./scripts/deploy.sh 1.0.0 production

# Expected output:
# [SUCCESS] Services started
# [SUCCESS] API is ready
# [SUCCESS] Health checks: 3/3 passed
# [SUCCESS] Deployment of version 1.0.0 completed successfully
```

### Deployment Process

1. **Pre-deployment checks** (Docker, docker-compose, .env)
2. **Image build** with version tag
3. **Service dependency pull** (latest DB images)
4. **Graceful stop** of existing containers
5. **Service startup** with new image
6. **Health verification** (liveness, readiness, metrics)
7. **Deployment recording** (timestamp, version, git commit)

### Environment Variables

Set in `.env` or pass directly to `docker-compose`:

```env
# Application
NODE_ENV=production
APP_VERSION=1.0.0
PORT=3000
LOG_LEVEL=info

# Database
DB_USER=postgres
DB_PASSWORD=<strong-password>  # CHANGE IN PRODUCTION
DB_HOST=db
DB_PORT=5432
DB_NAME=apex_ops
```

---

## Rollback Procedure

### When to Rollback

- Deployment health checks fail
- API returns unexpected 5xx errors
- Database migration corrupts data
- Critical performance degradation
- Security vulnerability detected

### Rollback Steps

1. **Assess the situation**
   ```bash
   # Check current state
   docker-compose logs --tail=50 api
   docker-compose exec api curl http://localhost:3000/ready
   ```

2. **Identify previous stable version**
   ```bash
   # List available deployments
   ls -la .deployments/deployment-*.json | tail -10
   ```

3. **Execute rollback**
   ```bash
   # Rollback to specific version
   ./scripts/rollback.sh 1.0.0

   # Expected output:
   # [SUCCESS] Rollback to version 1.0.0 completed successfully
   ```

4. **Verify health post-rollback**
   ```bash
   curl http://localhost:3000/live
   curl http://localhost:3000/ready
   curl http://localhost:3000/metrics
   ```

5. **Verify application functionality**
   ```bash
   # Test API endpoints
   curl http://localhost:3000/operations
   curl -X POST http://localhost:3000/operations -H "Content-Type: application/json" \
     -d '{"name": "Test Operation", "status": "pending"}'
   ```

6. **Document incident**
   ```bash
   # Create incident record
   cat >> .deployments/incidents.log << EOF
   [$(date)] Rollback to 1.0.0 - Reason: API errors detected - Status: Success
   EOF
   ```

### Rollback Limitations

- Rollback does **not** revert database schema changes (must be handled separately)
- Requires previous deployment record (automatically created by deploy.sh)
- Database data persists across rollbacks

---

## Incident Response

### Alert: API Unhealthy

**Indicators:**
- `/ready` endpoint returns 503
- `/live` endpoint returns 5xx
- Docker container restarting
- High error rate in logs

**Response:**
```bash
# 1. Check container status
docker-compose ps

# 2. Review logs
docker-compose logs --tail=100 api
docker-compose logs --tail=50 db

# 3. Check resource usage
docker stats

# 4. Verify database connectivity
docker-compose exec api curl http://localhost:5432  # Should timeout/fail gracefully
docker-compose exec db psql -U postgres -d apex_ops -c "SELECT NOW();"

# 5. If DB is down, restart it
docker-compose restart db

# 6. If API container is down, restart it
docker-compose restart api

# 7. If issues persist, perform rollback (see Rollback Procedure)
```

### Alert: Database Connection Errors

**Indicators:**
- Logs show "ECONNREFUSED 127.0.0.1:5432"
- `/ready` endpoint returns `"database": "disconnected"`
- POST/GET operations fail

**Response:**
```bash
# 1. Check database container
docker-compose ps db

# 2. Check database logs
docker-compose logs --tail=50 db

# 3. Verify persistent volume
docker volume ls | grep postgres_data

# 4. Verify database configuration in .env
cat .env | grep DB_

# 5. Restart database service
docker-compose restart db

# 6. Wait for readiness
sleep 10
curl http://localhost:3000/ready

# 7. If volume corrupted, backup and recreate:
docker-compose down
docker volume backup postgres_data  # Manual backup first
docker volume rm apex_operations_api_postgres_data
docker-compose up -d db
```

### Alert: High Error Rate

**Indicators:**
- `/metrics` shows `requests_error > 100` in short time
- Logs show repeated "ECONNREFUSED" or 500 errors
- Performance degradation

**Response:**
```bash
# 1. Check metrics
curl http://localhost:3000/metrics | grep -E "requests_error|db_errors"

# 2. Analyze logs for patterns
docker-compose logs api | grep -i error | tail -20

# 3. Check resource constraints
docker stats

# 4. If out of memory, increase Docker resource limits in docker-compose.yml
# Then restart:
docker-compose down
docker-compose up -d

# 5. If query performance issue, check database:
docker-compose exec db psql -U postgres -d apex_ops \
  -c "SELECT query, calls, total_time FROM pg_stat_statements ORDER BY total_time DESC LIMIT 5;"
```

### Alert: Container Restart Loop

**Indicators:**
- `docker-compose ps` shows API container `Restarting` state
- Exit code != 0 in container logs

**Response:**
```bash
# 1. Get recent logs
docker-compose logs --tail=200 api

# 2. Check for startup errors (DB not ready, missing config, etc.)
docker-compose logs api | grep -E "error|Error|ERROR" | head -10

# 3. Verify environment configuration
docker-compose config | grep -A 20 "environment:"

# 4. If database not ready, wait longer:
docker-compose up -d db
sleep 30
docker-compose up -d api

# 5. Check database health:
docker-compose exec db pg_isready -U postgres

# 6. If nothing helps, full restart:
docker-compose down
docker-compose up -d

# 7. If still failing after 5 minutes, escalate and consider rollback
```

---

## Troubleshooting

### Issue: "Connection refused" on API requests

**Diagnosis:**
```bash
docker-compose ps  # Is API container running?
curl -v http://localhost:3000/live  # Connection details
docker-compose logs api | tail -20  # Startup errors?
```

**Solution:**
```bash
# Check if port is already in use
lsof -i :3000

# If occupied, stop conflicting process or change PORT in .env
docker-compose down
docker-compose up -d
```

### Issue: Database migration failed / schema mismatch

**Diagnosis:**
```bash
docker-compose exec db psql -U postgres -d apex_ops -c "\dt"  # List tables
docker-compose exec db psql -U postgres -d apex_ops -c "\d operations"  # Inspect table
```

**Solution:**
```bash
# Backup data (if important)
docker-compose exec db pg_dump -U postgres apex_ops > backup-$(date +%s).sql

# Reset database schema
docker-compose exec db psql -U postgres -d apex_ops -f /docker-entrypoint-initdb.d/01-init.sql

# Reinit schema
docker-compose exec api node src/db-init.js
```

### Issue: Memory or CPU exhaustion

**Diagnosis:**
```bash
docker stats  # Real-time resource usage

# Inside container
docker-compose exec api ps aux
docker-compose exec db ps aux
```

**Solution:**
```bash
# Update resource limits in docker-compose.yml
# Example:
# deploy:
#   resources:
#     limits:
#       cpus: '2'
#       memory: 1G

docker-compose down
docker-compose up -d

# Or restart container
docker-compose restart api
```

### Issue: Logs not appearing / container running but no output

**Diagnosis:**
```bash
# Check if logs exist
docker-compose logs api
docker logs <container-id>

# Check logging configuration
docker-compose config | grep -A 10 "logging:"
```

**Solution:**
```bash
# Follow logs in real-time
docker-compose logs -f api

# Or check Docker daemon logs
docker inspect <container-id> | grep -i log
```

### Issue: Cannot connect to database from host machine

**Diagnosis:**
```bash
docker-compose ps db  # Is it running?
netstat -tlnp | grep 5432  # Is port bound?
```

**Solution:**
```bash
# If exposed, connect via:
PGPASSWORD=postgres psql -h localhost -U postgres -d apex_ops

# Or connect through container:
docker-compose exec db psql -U postgres -d apex_ops
```

---

## Monitoring & Alerts

### Health Check Endpoints

#### Liveness Probe (`/live`)
```bash
curl http://localhost:3000/live

# Expected (2xx)
{"status":"alive","timestamp":"2026-10-30T14:32:15.123Z"}

# Health check frequency: Every 30s
```

#### Readiness Probe (`/ready`)
```bash
curl http://localhost:3000/ready

# Expected (2xx when ready)
{"status":"ready","database":"connected","timestamp":"..."}

# Expected (5xx when not ready)
{"status":"not_ready","database":"disconnected","error":"...","timestamp":"..."}

# Health check frequency: Before routing traffic
```

#### Metrics (`/metrics`)
```bash
curl http://localhost:3000/metrics

# Prometheus format output:
# requests_total 150
# requests_success 145
# requests_error 5
# db_queries 200
# db_errors 2
# app_info{version="1.0.0"} 1
```

### Prometheus Integration (Optional)

Start Prometheus monitoring:
```bash
docker-compose --profile monitoring up -d prometheus

# Access dashboard: http://localhost:9090
# Prometheus queries:
# - requests_total (counter increasing)
# - requests_error / requests_total (error rate)
# - db_errors (database issues)
```

### Alert Rules (Example)

```yaml
# Would be in prometheus rules file
- alert: APIHealthCheckFailing
  expr: up{job="apex-api"} == 0
  for: 2m
  annotations:
    summary: "Apex API is down"

- alert: HighErrorRate
  expr: rate(requests_error[5m]) > 0.05
  for: 1m
  annotations:
    summary: "Error rate exceeds 5%"

- alert: DatabaseConnectionErrors
  expr: increase(db_errors[5m]) > 10
  for: 1m
  annotations:
    summary: "Database connection errors detected"
```

### Manual Monitoring Commands

```bash
# Watch API health
watch -n 5 'curl -s http://localhost:3000/ready | jq .'

# Monitor metrics
watch -n 10 'curl -s http://localhost:3000/metrics | grep requests'

# Stream logs with timestamps
docker-compose logs -f --timestamps api

# Check container resource usage
docker stats --no-stream
```

---

## Maintenance

### Regular Maintenance Tasks

#### Weekly
- Review error logs for patterns
- Check database query performance
- Verify backups are functioning
- Monitor disk usage of persistent volumes

#### Monthly
- Security patch updates for dependencies
- Database optimization (vacuum, analyze)
- Performance baseline comparison
- Update documentation

#### Quarterly
- Major version upgrades (after testing)
- Database backup restoration test
- Disaster recovery drill

### Database Maintenance

```bash
# Vacuum and analyze (run during low traffic)
docker-compose exec db psql -U postgres -d apex_ops -c "VACUUM ANALYZE;"

# Check table sizes
docker-compose exec db psql -U postgres -d apex_ops -c "
  SELECT tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename))
  FROM pg_tables WHERE schemaname != 'pg_catalog'
  ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
"

# Check index usage
docker-compose exec db psql -U postgres -d apex_ops -c "
  SELECT schemaname, tablename, indexname, idx_scan
  FROM pg_stat_user_indexes
  ORDER BY idx_scan DESC;
"
```

### Backup and Recovery

```bash
# Create backup
docker-compose exec db pg_dump -U postgres apex_ops > backup-$(date +%Y%m%d_%H%M%S).sql

# Restore from backup
docker-compose exec db psql -U postgres apex_ops < backup-20261030_120000.sql

# Backup entire database with custom format (faster restore)
docker-compose exec db pg_dump -U postgres -F c apex_ops > backup.dump

# Restore custom format
docker-compose exec db pg_restore -U postgres -d apex_ops backup.dump
```

### Capacity Planning

Monitor these metrics quarterly:

```bash
# Database size
docker-compose exec db psql -U postgres -d apex_ops -c "SELECT pg_size_pretty(pg_database_size('apex_ops'));"

# Docker volume usage
docker volume inspect apex_operations_api_postgres_data

# Request volume trends
# Track requests_total growth over time from /metrics endpoint
```

---

## Appendix

### Useful Commands Reference

```bash
# Services
docker-compose up -d                 # Start all services
docker-compose down                  # Stop all services
docker-compose restart api           # Restart API only
docker-compose ps                    # Show running containers
docker-compose logs -f api           # Follow API logs

# Database
docker-compose exec db psql -U postgres -d apex_ops  # Connect to DB
docker-compose exec db pg_isready    # Check DB health

# API Testing
curl http://localhost:3000/live      # Liveness
curl http://localhost:3000/ready     # Readiness
curl http://localhost:3000/metrics   # Metrics
curl http://localhost:3000/operations  # Get operations
curl -X POST http://localhost:3000/operations \
  -H "Content-Type: application/json" \
  -d '{"name":"Test","status":"pending"}'  # Create operation

# Deployment
./scripts/deploy.sh 1.0.0            # Deploy version
./scripts/rollback.sh 1.0.0          # Rollback to version

# Cleanup
docker-compose down -v               # Remove all (including volumes!)
docker system prune                  # Clean up unused resources
```

### Emergency Contacts

- **On-Call DevOps**: [Team Lead]
- **Platform Team**: [Contact]
- **Database Admin**: [Contact]
- **Incident Commander**: [Manager]

---

**Document Version:** 1.0.0  
**Last Updated:** October 2026  
**Reviewed By:** DevOps Team  
**Next Review:** January 2027
