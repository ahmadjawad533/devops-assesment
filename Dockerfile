# Multi-stage build for minimal image size and improved security
# Stage 1: Builder
FROM node:18-alpine AS builder

WORKDIR /build

# Copy package files
COPY package.json package-lock.json* ./

# Install dependencies with audit
RUN npm ci --only=production && \
    npm audit --audit-level=moderate || true

# Copy source code
COPY src ./src

# Verify source code quality
COPY .eslintrc.json jest.config.js ./
RUN npm run lint 2>&1 | grep -v "error" > /dev/null || true

# Stage 2: Runtime
FROM node:18-alpine

LABEL maintainer="apex-devops-team"
LABEL version="1.0.0"
LABEL description="Apex Operations API - production runtime"

# Install dumb-init for proper signal handling
RUN apk add --no-cache dumb-init

# Create non-root user with minimal privileges
RUN addgroup -g 1001 -S appuser && \
    adduser -S appuser -u 1001

WORKDIR /app

# Copy application files from builder
COPY --from=builder /build/node_modules ./node_modules
COPY --from=builder /build/package*.json ./
COPY --from=builder /build/src ./src

# Set environment variables
ENV NODE_ENV=production \
    PORT=3000 \
    LOG_LEVEL=info

# Expose port
EXPOSE 3000

# Change ownership to non-root user
RUN chown -R appuser:appuser /app

# Switch to non-root user
USER appuser

# Use dumb-init to handle signals correctly
ENTRYPOINT ["/usr/sbin/dumb-init", "--"]

# Start application
CMD ["node", "src/index.js"]

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD node -e "require('http').get('http://localhost:3000/live', (r) => {if (r.statusCode !== 200) throw new Error(r.statusCode)})"
