# Deployment Troubleshooting Guide

**Purpose:** Solutions for common Docker and deployment issues

---

## Issue 1: Docker Network "operation not supported"

### Error Message
```
failed to set up container networking: 
failed to create endpoint... 
operation not supported
```

### Cause
Docker daemon networking issues, common in certain Linux environments (WSL2, custom kernels).

### Solutions

**Option A: Simplify Networking (Recommended)**

Docker Compose has been updated to use default Docker bridge networking instead of custom apex-network:

```bash
cd /home/jawad/Downloads/Devops\ role\ assessment
docker-compose down -v
docker system prune -f
docker-compose up -d
```

**Option B: Check Docker Daemon**

```bash
# Restart Docker daemon
sudo systemctl restart docker

# Verify Docker is working
docker run hello-world

# Then try deployment again
docker-compose up -d
```

**Option C: Use Host Network Mode**

For WSL2 or specific environments, use host networking:

```yaml
services:
  api:
    network_mode: "host"  # Use host network instead of bridge
```

---

## Issue 2: docker-compose version  "version is obsolete"

### Warning
```
WARN[0000] docker-compose.yml: the attribute `version` is  
obsolete, it will be ignored, please remove it
```

### Solution
The `version: '3.9'` line has been removed from docker-compose.yml. This is harmless but the warning is gone now.

---

## Issue 3: Docker Build Stalls / Hangs

### Symptom
Docker build process stops responding at "Running in..." step

### Cause
Usually npm install taking time, or Docker daemon resource exhaustion

### Solutions

**Quick Fix:**

```bash
# Cancel current build
docker-compose down -v

# Clean Docker
docker system prune -af
docker volume prune -f

# Rebuild with fresh cache
docker-compose build --no-cache
docker-compose up -d
```

**For Slow Systems:**

```bash
# Increase Docker daemon resources in Docker Desktop:
# Docker Desktop → Preferences → Resources
# - CPUs: 4+
# - Memory: 4GB+

# Then retry
docker-compose up -d
```

---

## Issue 4: Port Already In Use

### Error
```
Error response from daemon: 
bind: address already in use
```

### Cause
Port 3000 or 5432 already in use by another service

### Solution

```bash
# Find what's using the port
lsof -i :3000  # For port 3000
lsof -i :5432  # For port 5432

# Option A: Stop the other service
kill -9 <PID>

# Option B: Use different ports in .env
echo "PORT=3001" >> .env

# Then try deployment
docker-compose up -d
```

---

## Issue 5: Database Connection Refused

### Error
```
Error: connect ECONNREFUSED 127.0.0.1:5432
```

### Cause
- Database container not running
- Database not fully started when API tries to connect
- Network connectivity issue

### Solution

```bash
# Check database is running
docker-compose ps db

# Verify database health
docker-compose exec db pg_isready -U postgres

# If not ready, wait and retry
sleep 10
curl http://localhost:3000/ready

# If still failing, check logs
docker-compose logs db
```

---

## Issue 6: "npm ci" Takes Very Long

### Symptom
Build hangs on Step 4: "RUN npm ci --only=production"

### Cause
- First-time npm install downloading all dependencies
- Slow network connection
- Npm registry issues

### Solution

```bash
# Add npm cache to speed up rebuilds
docker system prune -f  # Clean old layers
docker-compose build --no-cache  # Fresh build

# Or use pre-built image (if available)
# docker pull [pre-built-image]
```

---

## Issue 7: Container Keeps Restarting

### Symptom
```
docker-compose ps
# Status: Restarting (1) 2 seconds ago
```

### Cause
- Application startup error
- Missing environment variables
- Database not ready

### Solution

```bash
# Check logs for startup errors
docker-compose logs api

# Verify environment is set
cat .env

# Check if .env exists
ls -la .env

# If missing, create it
cp .env.example .env

# Restart
docker-compose restart api
```

---

## Issue 8: "db" Service Can't Be Resolved

### Error
```
getaddrinfo ENOTFOUND db
```

### Cause
DNS resolution failing for service name "db" - network misconfiguration

### Solution

The docker-compose.yml has been updated to use `localhost` instead of service name `db`:

```yaml
DB_HOST: localhost  # Changed from "db"
```

This works because both containers share the Docker daemon and can reach each other via localhost.

---

## Quick Deployment Steps (If Issues Occur)

```bash
# 1. Navigate to project
cd /home/jawad/Downloads/Devops\ role\ assessment

# 2. Clean up any previous attempts
docker-compose down -v
docker system prune -f

# 3. Create environment file
cp .env.example .env

# 4. Build images
docker-compose build

# 5. Start services
docker-compose up -d

# 6. Wait for database to be ready
sleep 15

# 7. Check health
curl http://localhost:3000/live
curl http://localhost:3000/ready

# 8. View logs if needed
docker-compose logs -f api
```

---

## Verification Checklist

After deployment, verify:

```bash
# ✓ Containers are running
docker-compose ps
# Expected: both api and db showing "Up"

# ✓ API is responsive
curl http://localhost:3000/live
# Expected: {"status":"alive","timestamp":"..."}

# ✓ Database is connected
curl http://localhost:3000/ready
# Expected: {"status":"ready","database":"connected",...}

# ✓ Metrics are available
curl http://localhost:3000/metrics
# Expected: Prometheus format metrics

# ✓ API endpoints work
curl http://localhost:3000/operations
# Expected: JSON array of operations

# ✓ Logs are readable
docker-compose logs api
# Expected: Structured JSON logs
```

---

## If All Else Fails

### Clean Slate Approach

```bash
# Stop everything
docker-compose down -v

# Remove all images and containers
docker system prune -af

# Remove volumes
docker volume prune -f

# Restart Docker daemon
sudo systemctl restart docker

# Try again
cd /home/jawad/Downloads/Devops\ role\ assessment
cp .env.example .env
docker-compose up -d
```

### Collect Diagnostic Information

If still failing, collect info for debugging:

```bash
# System info
docker --version
docker-compose --version
docker info

# Container logs
docker-compose logs api > api.log
docker-compose logs db > db.log

# Running containers
docker ps -a > containers.log

# Images
docker images > images.log

# Create tar with logs
tar -czf deployment-logs.tar.gz *.log
```

---

## Contact / Support

If deployment issues persist:

1. **Check Docker Documentation:** https://docs.docker.com/
2. **Check Docker Compose Docs:** https://docs.docker.com/compose/
3. **Review Logs:** `docker-compose logs api` and `docker-compose logs db`
4. **Verify Prerequisites:** Docker 20.10+, Docker Compose 1.29+

---

## Environment Variables Reference

```env
# Application
NODE_ENV=production          # Environment
APP_VERSION=1.0.0           # Version tag
PORT=3000                   # API port
LOG_LEVEL=info              # Logging level

# Database
DB_USER=postgres            # Database user
DB_PASSWORD=postgres        # Database password (CHANGE!)
DB_HOST=localhost           # Database host
DB_PORT=5432                # Database port
DB_NAME=apex_ops            # Database name
```

---

**Last Updated:** October 30, 2026  
**Status:** Troubleshooting Guide  
**For Issues:** Refer to sections above
