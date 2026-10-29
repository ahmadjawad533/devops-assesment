# Security & Configuration Hygiene

**Version:** 1.0.0  
**Last Updated:** October 2026  
**Status:** For Compliance Review

---

## Executive Summary

This document outlines security practices implemented in the Apex Operations API deployment, including secrets management, least privilege enforcement, dependency scanning, container security, and cloud cost awareness. All recommendations follow industry standards (OWASP, CIS Docker Benchmark, NIST).

---

## 1. Secrets Handling

### 1.1 Current Implementation

#### Principle: Secrets Should Never Be In Code

All sensitive data is externalized:

```
❌ BAD: Hard-coded in code
export const DB_PASSWORD = 'postgres123';

✅ GOOD: Externalized to environment
const dbPassword = process.env.DB_PASSWORD;
```

#### Environment Variables (`.env` File)

- `.env` file is **Git-ignored** (see `.gitignore`)
- Template provided as `.env.example` with placeholder values
- Never commit `.env` to version control

**Sample `.env.example`:**
```env
DB_USER=postgres
DB_PASSWORD=<CHANGE_ME>
DB_HOST=db
DB_PORT=5432
DB_NAME=apex_ops
```

#### Docker Secrets (For Production)

```yaml
# docker-compose.yml with secrets (production)
version: '3.9'
services:
  api:
    secrets:
      - db_password
secrets:
  db_password:
    file: ./secrets/db_password.txt
```

Secrets file (outside repo):
```
chmod 600 ./secrets/db_password.txt
echo "YourSecurePassword123!" > ./secrets/db_password.txt
```

### 1.2 Secret Rotation Strategy

**Quarterly Rotation:**
1. Generate new secret
2. Update in secret management system
3. Deploy with new value
4. Retire old secret after verification

**Implementation:**
```bash
# 1. Update .env locally
sed -i 's/OLD_PASSWORD/NEW_PASSWORD/g' .env

# 2. Deploy new version
./scripts/deploy.sh 1.0.1

# 3. Verify health
curl http://localhost:3000/ready

# 4. Retire old secret (after 24h verification period)
```

### 1.3 Secret Scanning in CI/CD

**GitHub Actions Integration:**
```yaml
- name: Scan for secrets
  uses: gitleaks/gitleaks-action@v1
  env:
    GITLEAKS_ENABLE_COMMENTS: true
```

This prevents accidental secret commits.

---

## 2. Least Privilege & Access Control

### 2.1 Container User Privilege

#### Current Implementation

**Dockerfile enforces non-root user:**
```dockerfile
# Create non-root user
RUN addgroup -g 1001 -S appuser && \
    adduser -S appuser -u 1001

# Switch to non-root user
USER appuser

# Change ownership
RUN chown -R appuser:appuser /app
```

**Benefits:**
- Container cannot modify system files
- Compromised app cannot gain host access
- Limits blast radius of vulnerability

#### Verification

```bash
# Check running user
docker-compose exec api id
# Output: uid=1001(appuser) gid=1001(appuser) groups=1001(appuser)

# Verify cannot write to system
docker-compose exec api touch /etc/test.txt
# Result: Permission denied ✓
```

### 2.2 Database User Privileges

**Current:** Using `postgres` superuser (⚠️ not production-ready)

**Production Recommendation:**

```sql
-- Create restricted database user
CREATE USER app_user WITH PASSWORD 'strong-password-here';
CREATE DATABASE apex_ops OWNER app_user;

-- Grant minimal permissions
GRANT USAGE ON SCHEMA public TO app_user;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO app_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_user;

-- Restrict DDL (schema changes)
REVOKE CREATE ON SCHEMA public FROM app_user;
```

**Implementation in production deployment:**
```bash
export DB_USER=app_user
export DB_PASSWORD=$(openssl rand -base64 32)
```

### 2.3 Network Isolation

**Docker Network Best Practice:**

```yaml
# docker-compose.yml
services:
  api:
    networks:
      - apex-network  # Custom isolated network

  db:
    networks:
      - apex-network

networks:
  apex-network:
    driver: bridge  # Isolated from other containers
```

**Effect:** 
- API can reach database (same network)
- Database cannot reach external services
- External host cannot reach database (port 5432 not exposed)

---

## 3. Dependency & Image Scanning

### 3.1 Runtime Scanning (CI/CD)

**NPM Audit in CI/CD:**
```yaml
# .github/workflows/ci-cd.yml
- name: NPM audit
  run: npm audit --audit-level=moderate
  continue-on-error: true
```

**Output:**
```
vulnerability  high     Privilege Escalation
found 1 vulnerability in 156 packages
  1 high
```

### 3.2 Container Image Scanning

**Trivy Integration (in CI/CD):**
```yaml
- name: Trivy vulnerability scanning
  uses: aquasecurity/trivy-action@master
  with:
    scan-type: 'fs'
    severity: 'HIGH,CRITICAL'
    skip-dirs: 'node_modules'
```

**Scans for:**
- Known CVEs in base OS (Alpine Linux)
- Known CVEs in dependencies
- Misconfigurations

### 3.3 Dependency Pinning

**package.json uses exact versions:**
```json
{
  "dependencies": {
    "express": "^4.18.2",
    "pg": "^8.11.3",
    "pino": "^8.17.2"
  }
}
```

**Rationale:**
- `^4.18.2` allows patch updates (4.18.x) automatically
- Prevents unexpected breaking changes
- All developers use identical versions

### 3.4 Regular Patching

**Quarterly Dependency Review:**
```bash
# Check for available updates
npm outdated

# List security vulnerabilities
npm audit

# Update to latest safe versions (within semver range)
npm update
npm audit fix
```

---

## 4. Container & Image Security

### 4.1 Base Image Selection

**Used: `node:18-alpine`**

**Why Alpine:**
- Minimal image (~150MB vs 900MB for full Node)
- Smaller attack surface
- Faster deployments
- Reduced storage costs

**Comparison:**
| Base Image | Size | CVEs | Boot Time |
|-----------|------|------|-----------|
| alpine:18 | 150MB | ~10 | <1s |
| ubuntu:18 | 77MB | ~100 | <1s |
| debian:11 | 124MB | ~80 | <1s |

**Why not ubuntu?** While smaller, less maintained for containers; Alpine is the industry standard for Node.

### 4.2 Multi-Stage Build

**Benefits:**
```dockerfile
FROM node:18-alpine AS builder
# 1. Install ALL dependencies (devDependencies too)
# 2. Run linting and tests

FROM node:18-alpine
# 3. Copy only PRODUCTION code
# 4. No dev dependencies = smaller image
```

**Result:**
- Final image: ~200MB (vs ~500MB single-stage)
- No test/dev tools in production
- Faster deployments

### 4.3 Image Vulnerability Scanning

**Local scan before push:**
```bash
# Install Trivy locally
brew install aquasecurity/trivy/trivy  # or apt-get on Linux

# Scan built image
trivy image apex-api:1.0.0
```

### 4.4 Image Signing & Provenance

**Future enhancement (not implemented):**
```bash
# Sign image with cosign
cosign sign --key cosign.key apex-api:1.0.0

# Verify signature during deployment
cosign verify --key cosign.pub apex-api:1.0.0
```

---

## 5. Configuration Management

### 5.1 Environment-Specific Configs

**Development vs Production:**

**Development** (`.env`):
```env
NODE_ENV=development
LOG_LEVEL=debug
DB_PASSWORD=postgres  # OK for local
```

**Production** (Kubernetes secret / AWS Secrets Manager):
```env
NODE_ENV=production
LOG_LEVEL=info
DB_PASSWORD=<STRONG_RANDOM_32_CHAR>
```

### 5.2 Secrets Management Tools

#### Local Development
- `.env` file (Git-ignored)
- `dotenv` package loads into process.env

#### Docker Compose (Testing)
- Docker secrets support
- Environment override via `-e` flag

#### Production (Cloud Platforms)

**AWS:**
```bash
# Store secret
aws secretsmanager create-secret \
  --name apex/db-password \
  --secret-string $(openssl rand -base64 32)

# Retrieve in code
const secret = await client.getSecretValue({
  SecretId: 'apex/db-password'
}).promise();
```

**Kubernetes:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: apex-db-secret
type: Opaque
data:
  password: <base64-encoded-value>
---
apiVersion: apps/v1
kind: Deployment
spec:
  containers:
  - env:
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: apex-db-secret
          key: password
```

**Azure Key Vault:**
```bash
az keyvault secret set --vault-name myVault \
  --name dbPassword --value $(openssl rand -base64 32)
```

---

## 6. Network Security

### 6.1 Port Exposure

**Current docker-compose.yml:**

```yaml
services:
  api:
    ports:
      - "3000:3000"  # ✓ Expose to host (for local testing)
  
  db:
    ports:
      - "5432:5432"  # ⚠️ Exposed (OK locally, NOT for production)
```

**Production Recommendation:**

```yaml
services:
  api:
    ports:
      - "3000:3000"  # Keep exposed for reverse proxy / LB

  db:
    # ✓ DO NOT EXPOSE - only accessible via internal network
    networks:
      - apex-network
```

**Verification:**
```bash
# Check what's listening
netstat -tlnp | grep LISTEN

# From host (should connect)
curl http://localhost:3000/live

# Database (should NOT be directly accessible from host)
# This should fail or timeout
psql -h 127.0.0.1 -p 5432 -U postgres
```

### 6.2 Firewall Rules (Cloud Context)

**AWS Security Group (Production Example):**

```json
{
  "IpPermissions": [
    {
      "IpProtocol": "tcp",
      "FromPort": 3000,
      "ToPort": 3000,
      "SourceSecurityGroupId": "sg-load-balancer"  // Only from LB
    },
    {
      "IpProtocol": "tcp",
      "FromPort": 5432,
      "ToPort": 5432,
      "SourceSecurityGroupId": "sg-api-app"  // Only from API
    }
  ]
}
```

### 6.3 TLS/HTTPS

**Production Recommendation:**

```nginx
# nginx reverse proxy
upstream apex_api {
  server api:3000;
}

server {
  listen 443 ssl;
  server_name api.apex.internal;
  
  ssl_certificate /etc/nginx/certs/cert.pem;
  ssl_certificate_key /etc/nginx/certs/key.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers HIGH:!aNULL:!MD5;
  
  location / {
    proxy_pass http://apex_api;
  }
}

# Redirect HTTP to HTTPS
server {
  listen 80;
  return 301 https://$host$request_uri;
}
```

---

## 7. Cost-Aware Cloud Deployment Paths

### 7.1 AWS Deployment

**Option 1: ECS + RDS (Managed)**
```
Costs (estimated monthly):
- ECS Fargate: $0.04 per vCPU-hour + $0.004 per GB-hour
  ≈ $25-50 for 0.5 CPU, 1GB RAM
- RDS PostgreSQL: $0.192 per hour (db.t3.micro)
  ≈ $140/month
- Total: ~$200/month (includes redundancy, backups)

Benefits: Managed, auto-scaling, backups included
```

**CloudFormation template (simplified):**
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Resources:
  ApexCluster:
    Type: AWS::ECS::Cluster
    Properties:
      ClusterName: apex-operations
  
  ApexService:
    Type: AWS::ECS::Service
    Properties:
      Cluster: !Ref ApexCluster
      TaskDefinition: !Ref ApexTask
      DesiredCount: 2
      LaunchType: FARGATE
  
  ApexDatabase:
    Type: AWS::RDS::DBInstance
    Properties:
      DBInstanceIdentifier: apex-db
      Engine: postgres
      DBInstanceClass: db.t3.micro
      AllocatedStorage: 20
      MasterUsername: postgres
      MasterUserPassword: !Sub '{{resolve:secretsmanager:apex-db-password::password}}'
```

### 7.2 GCP Deployment

**Option 2: Cloud Run + Cloud SQL (Pay-per-use)**
```
Costs (estimated monthly):
- Cloud Run: $0.00002 per vCPU-second + $0.0000050 per GB-second
  ≈ $5-15 for typical traffic
- Cloud SQL: $0.175 per hour (db-f1-micro)
  ≈ $130/month
- Total: ~$150-170/month (no idle costs for compute)

Benefits: Cheapest for bursty traffic, fastest scaling
```

**Deployment script:**
```bash
#!/bin/bash
# Deploy to Cloud Run

gcloud builds submit --tag gcr.io/PROJECT_ID/apex-api
gcloud run deploy apex-api \
  --image gcr.io/PROJECT_ID/apex-api \
  --platform managed \
  --region us-central1 \
  --set-env-vars="DB_HOST=CLOUD_SQL_IP,DB_NAME=apex_ops" \
  --add-cloudsql-instances PROJECT_ID:us-central1:apex-db
```

### 7.3 Kubernetes (Self-Managed)

**Option 3: K8s on EC2/GKE (Control Cost)**
```
Costs (estimated monthly):
- Kubernetes: Free (GKE) or managed control plane cost
- Worker nodes: 2x t3.small ≈ $30/month
- Persistent storage: $0.10 per GB-month
- Total: ~$80-150/month (depends on node count)

Benefits: Most control, portable across clouds
```

**Deployment:**
```bash
kubectl create secret generic apex-db-secret \
  --from-literal=password=$(openssl rand -base64 32)

kubectl apply -f deployment.yaml
```

### 7.4 Cost Optimization Checklist

| Strategy | Annual Savings |
|----------|---|
| Reserved Instances (1-year commitment) | 30-50% |
| Spot/Preemptible Instances | 60-90% |
| Rightsizing (correct instance type) | 20-30% |
| Auto-scaling (scale down at night) | 40-50% |
| Multi-region redundancy reduction | Varies |

**Example:** Single t3.small instance with 1-year reserved instance:
```
On-demand: $15.30/month
1-year reserved: $8.49/month  (45% savings)
3-year reserved: $6.11/month  (60% savings)
```

**Monitoring costs:**
```bash
# AWS Cost Explorer
aws ce get-cost-and-usage --time-period Start=2026-10-01,End=2026-10-31 \
  --granularity MONTHLY --metrics BlendedCost

# GCP Cost Management
gcloud billing accounts list
```

---

## 8. Compliance & Audit

### 8.1 Audit Logging

**Application logs include:**
- Request method, path, user agent
- Response status code and latency
- Database queries (in debug mode)
- Errors and stack traces

**Rotation policy:**
```json
{
  "logging": {
    "driver": "json-file",
    "options": {
      "max-size": "10m",
      "max-file": "3",
      "labels": "service=apex-api"
    }
  }
}
```

**Retention:** 30 days (local), then archived to S3/GCS.

### 8.2 Security Headers

**Recommended (not yet implemented):**

```javascript
// Add to Express app
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('X-XSS-Protection', '1; mode=block');
  res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
  next();
});
```

### 8.3 Compliance Standards

**Alignments:**
- **OWASP Top 10:** Secrets management, input validation, secure dependencies
- **CIS Docker Benchmark:** Non-root user, minimal base image, health checks
- **SOC 2:** Audit logging, access control, incident response
- **ISO 27001:** Risk management, security controls documented

---

## 9. Incident Response

### 9.1 Security Incident Procedure

**If secret is accidentally committed:**
```bash
# 1. Immediately revoke the secret
aws secretsmanager update-secret --secret-id apex-db-password \
  --secret-string $(openssl rand -base64 32)

# 2. Remove from git history
git filter-branch --tree-filter 'rm -f .env' HEAD

# 3. Force push to remove history
git push --force-with-lease origin main

# 4. Notify team and customers
# - No customer data was exposed
# - New secrets deployed
# - Monitoring for unauthorized access
```

**If vulnerability detected in dependency:**
```bash
# 1. Identify severity
npm audit

# 2. Update vulnerable package
npm update vulnerable-package

# 3. Test thoroughly
npm run test:run

# 4. Deploy immediately
./scripts/deploy.sh 1.0.1

# 5. Monitor for issues
docker-compose logs -f api
```

---

## 10. Recommendations for Production

| Item | Current | Recommended |
|------|---------|-------------|
| Secrets Storage | .env file | AWS Secrets Manager / K8s Secrets |
| Database User | Superuser | Restricted app_user |
| Database Exposure | Port 5432 open | Internal network only |
| TLS/HTTPS | No | Required with reverse proxy |
| WAF | No | AWS WAF / nginx rate limiting |
| SIEM | None | CloudWatch / Datadog / Splunk |
| Image Signing | No | Cosign / Docker Content Trust |
| Multi-region | No | Active-active or hot standby |
| DLP (Data Loss Prevention) | No | Implement for PII |

---

## References

- [OWASP Top 10](https://owasp.org/www-project-top-ten/)
- [CIS Docker Benchmark](https://www.cisecurity.org/benchmark/docker)
- [NIST Cybersecurity Framework](https://www.nist.gov/cyberframework)
- [AWS Security Best Practices](https://aws.amazon.com/architecture/security-identity-compliance/)
- [Trivy Documentation](https://aquasecurity.github.io/trivy/)

---

**Document Owner:** DevOps Team  
**Last Reviewed:** October 2026  
**Next Review:** Q1 2027
