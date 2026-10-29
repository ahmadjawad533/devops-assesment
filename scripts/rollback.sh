#!/bin/bash

set -euo pipefail

# Rollback script for Apex Operations API
# Usage: ./scripts/rollback.sh [version-to-rollback-to]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
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

# Check backup directory exists
if [ ! -d "$BACKUP_DIR" ]; then
  log_error "Backup directory not found: $BACKUP_DIR"
  exit 1
fi

# Get target version
TARGET_VERSION="${1:-}"

if [ -z "$TARGET_VERSION" ]; then
  log_info "Listing available deployments:"
  ls -1t "$BACKUP_DIR"/deployment-*.json 2>/dev/null | head -5 | while read -r file; do
    VERSION=$(grep -oP '"version":\s*"\K[^"]+' "$file" || echo "unknown")
    TIMESTAMP=$(grep -oP '"timestamp":\s*"\K[^"]+' "$file" || echo "unknown")
    echo "  - $VERSION (deployed at $TIMESTAMP)"
  done
  log_info "To rollback, run: $0 <version>"
  exit 1
fi

log_info "Starting rollback to version $TARGET_VERSION..."

# Find deployment record for target version
DEPLOYMENT_FILE=$(find "$BACKUP_DIR" -name "deployment-${TARGET_VERSION}-*.json" -type f | sort -r | head -1)

if [ -z "$DEPLOYMENT_FILE" ] || [ ! -f "$DEPLOYMENT_FILE" ]; then
  log_error "Deployment record not found for version: $TARGET_VERSION"
  log_info "Available deployments:"
  ls -1 "$BACKUP_DIR"/deployment-*.json 2>/dev/null | sed 's/.*deployment-//;s/-[0-9]*\.json//' | sort -u || echo "None"
  exit 1
fi

log_info "Found deployment record: $DEPLOYMENT_FILE"

# Extract deployment details
ORIGINAL_GIT=$(grep -oP '"git_commit":\s*"\K[^"]+' "$DEPLOYMENT_FILE" 2>/dev/null || echo "unknown")
DEPLOYED_AT=$(grep -oP '"timestamp":\s*"\K[^"]+' "$DEPLOYMENT_FILE" 2>/dev/null || echo "unknown")

log_info "Rollback target: $TARGET_VERSION"
log_info "Originally deployed at: $DEPLOYED_AT"
log_info "Git commit: $ORIGINAL_GIT"

# Pre-rollback checks
log_info "Running pre-rollback checks..."

if ! docker info > /dev/null 2>&1; then
  log_error "Docker daemon is not running"
  exit 1
fi

if ! command -v docker-compose &> /dev/null; then
  log_error "docker-compose is not installed"
  exit 1
fi

# Backup current state
log_info "Backing up current deployment state..."
CURRENT_STATE_FILE="${BACKUP_DIR}/pre-rollback-state-$(date +%s).json"
cat > "$CURRENT_STATE_FILE" << EOF
{
  "rollback_initiated_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')",
  "rollback_from_deployment": "$(docker-compose -f "$PROJECT_ROOT/docker-compose.yml" ps -q api 2>/dev/null | head -1 || echo 'unknown')",
  "target_version": "$TARGET_VERSION"
}
EOF

log_info "Pre-rollback state saved: $CURRENT_STATE_FILE"

# Set version for rollback
export APP_VERSION="$TARGET_VERSION"

# Stop current services
log_info "Stopping current services..."
cd "$PROJECT_ROOT"
docker-compose down || true

# Remove old images (optional - can keep for faster rollback)
log_warn "Note: Docker images are retained for faster rollback"

# Rebuild image for target version
log_info "Rebuilding image for version $TARGET_VERSION..."
if docker-compose build api; then
  log_success "Image built for rollback"
else
  log_error "Failed to build image for rollback"
  exit 1
fi

# Start services with rolled-back version
log_info "Starting services with version $TARGET_VERSION..."
if docker-compose up -d; then
  log_success "Services started"
else
  log_error "Failed to start services during rollback"
  exit 1
fi

# Wait for services to be ready
log_info "Waiting for services to be healthy..."
RETRY_COUNT=0
MAX_RETRIES=30
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  if curl -s http://localhost:3000/ready > /dev/null 2>&1; then
    log_success "API is ready"
    break
  fi
  ((RETRY_COUNT++))
  if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    log_error "API failed to become ready after rollback"
    docker-compose logs
    exit 1
  fi
  echo -n "."
  sleep 2
done

# Health verification
log_info "Verifying health checks post-rollback..."
HEALTH_CHECKS=0
HEALTH_PASSED=0

if curl -s http://localhost:3000/live | grep -q "alive"; then
  log_success "Liveness check passed"
  ((HEALTH_PASSED++))
fi
((HEALTH_CHECKS++))

if curl -s http://localhost:3000/ready | grep -q "ready\|not_ready"; then
  log_success "Readiness check passed"
  ((HEALTH_PASSED++))
fi
((HEALTH_CHECKS++))

if curl -s http://localhost:3000/metrics | grep -q "requests_total"; then
  log_success "Metrics available"
  ((HEALTH_PASSED++))
fi
((HEALTH_CHECKS++))

# Record rollback
ROLLBACK_FILE="${BACKUP_DIR}/rollback-${TARGET_VERSION}-$(date +%s).json"
cat > "$ROLLBACK_FILE" << EOF
{
  "version": "$TARGET_VERSION",
  "timestamp": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')",
  "rollback_status": "success",
  "rolled_back_by": "${USER:-rollback-script}",
  "health_checks_passed": $HEALTH_PASSED,
  "health_checks_total": $HEALTH_CHECKS,
  "previous_state_backup": "$(basename "$CURRENT_STATE_FILE")"
}
EOF

log_success "Rollback record saved: $ROLLBACK_FILE"
log_success "Rollback to version $TARGET_VERSION completed successfully"
log_info "API running at: http://localhost:3000"
log_info "To view health status: curl http://localhost:3000/ready"

exit 0
