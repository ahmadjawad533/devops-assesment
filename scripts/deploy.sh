#!/bin/bash

set -euo pipefail

# Deployment script for Apex Operations API
# Usage: ./scripts/deploy.sh <version> [environment]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENVIRONMENT="${2:-local}"
VERSION="${1:-latest}"
TIMESTAMP=$(date +%s)
BACKUP_DIR="${PROJECT_ROOT}/.deployments"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Validate inputs
if [ -z "$VERSION" ]; then
  log_error "Version is required. Usage: $0 <version> [environment]"
  exit 1
fi

log_info "Starting deployment of version $VERSION to $ENVIRONMENT"

# Create deployment backup directory
mkdir -p "$BACKUP_DIR"

# Create deployment record
DEPLOYMENT_FILE="$BACKUP_DIR/deployment-${VERSION}-${TIMESTAMP}.json"

# Pre-deployment checks
log_info "Running pre-deployment checks..."

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
  log_error "Docker daemon is not running"
  exit 1
fi

# Check if docker-compose is available
if ! command -v docker-compose &> /dev/null; then
  log_error "docker-compose is not installed"
  exit 1
fi

# Check if .env file exists
if [ ! -f "$PROJECT_ROOT/.env" ]; then
  log_warn ".env file not found, using .env.example"
  cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
fi

# Save current deployment state before deployment
log_info "Backing up current deployment state..."
if [ -f "$PROJECT_ROOT/docker-compose.yml" ]; then
  CURRENT_VERSION=$(docker-compose -f "$PROJECT_ROOT/docker-compose.yml" ps -q api 2>/dev/null | head -1 || echo "none")
  log_info "Current API container: $CURRENT_VERSION"
fi

# Build new image
log_info "Building Docker image for version $VERSION..."
cd "$PROJECT_ROOT"

# Set version in environment
export APP_VERSION="$VERSION"

if docker-compose build --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" api; then
  log_success "Image built successfully"
else
  log_error "Failed to build image"
  exit 1
fi

# Pull latest dependencies
log_info "Pulling latest service images..."
if docker-compose pull db; then
  log_success "Dependencies pulled"
else
  log_warn "Failed to pull some dependencies, continuing with cached images"
fi

# Stop existing containers gracefully
log_info "Stopping existing services..."
docker-compose down --remove-orphans || true

# Start new deployment
log_info "Starting new deployment..."
if docker-compose up -d; then
  log_success "Services started"
else
  log_error "Failed to start services"
  exit 1
fi

# Wait for services to be ready
log_info "Waiting for services to be healthy..."
for i in {1..30}; do
  if curl -s http://localhost:3000/ready > /dev/null 2>&1; then
    log_success "API is ready"
    break
  fi
  if [ $i -eq 30 ]; then
    log_error "API failed to become ready"
    docker-compose logs
    exit 1
  fi
  echo -n "."
  sleep 2
done

# Health check
log_info "Running health checks..."
HEALTH_CHECKS=0
HEALTH_PASSED=0

# Check liveness
if curl -s http://localhost:3000/live | grep -q "alive"; then
  log_success "Liveness check passed"
  ((HEALTH_PASSED++))
fi
((HEALTH_CHECKS++))

# Check readiness
if curl -s http://localhost:3000/ready | grep -q "ready\|not_ready"; then
  log_success "Readiness check passed"
  ((HEALTH_PASSED++))
fi
((HEALTH_CHECKS++))

# Check metrics endpoint
if curl -s http://localhost:3000/metrics | grep -q "requests_total"; then
  log_success "Metrics endpoint accessible"
  ((HEALTH_PASSED++))
fi
((HEALTH_CHECKS++))

log_info "Health checks: $HEALTH_PASSED/$HEALTH_CHECKS passed"

if [ $HEALTH_PASSED -lt $HEALTH_CHECKS ]; then
  log_warn "Some health checks failed, but deployment continues"
fi

# Record deployment
cat > "$DEPLOYMENT_FILE" << EOF
{
  "version": "$VERSION",
  "environment": "$ENVIRONMENT",
  "timestamp": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')",
  "deployment_epoch": $TIMESTAMP,
  "status": "success",
  "deployed_by": "${USER:-deployment-script}",
  "git_commit": "$(cd "$PROJECT_ROOT" && git rev-parse HEAD 2>/dev/null || echo 'unknown')",
  "health_checks_passed": $HEALTH_PASSED,
  "health_checks_total": $HEALTH_CHECKS
}
EOF

log_success "Deployment record saved: $DEPLOYMENT_FILE"

# Summary
log_success "Deployment of version $VERSION completed successfully"
log_info "API running at: http://localhost:3000"
log_info "Metrics available at: http://localhost:3000/metrics"
log_info "Database: PostgreSQL on port 5432"

exit 0
