---
globs:
  - '**/*'
---
# Security Rules (Global)

## Secrets & Credentials
- Never hardcode credentials, API keys, tokens, or passwords in source code
- Never commit `.env` files, `credentials.json`, private keys, or certificate files
- Use AWS Secrets Manager or SSM Parameter Store for runtime secrets
- Use GitHub Environment Secrets for CI/CD credentials
- If you discover any hardcoded secret, flag it immediately to the user

## IAM & Access Control
- Always apply least-privilege IAM policies
- Never use wildcard (`*`) for IAM actions in production policies
- Use `condition` blocks in IAM policies for additional restrictions
- Prefer IAM roles over IAM users for service-to-service authentication
- Use OIDC for GitHub Actions → AWS authentication

## Encryption
- Enable encryption at rest for all storage: S3, RDS, EBS, EFS, ElastiCache
- Use TLS/HTTPS for all data in transit
- Use AWS-managed KMS keys unless custom key rotation is required
- Enable SSL enforcement for database connections

## Network
- Use VPC endpoints for AWS service access from private subnets
- Default-deny security groups — only open required ports
- Never open port 0.0.0.0/0 for SSH (port 22) in production
- Use bastion hosts or SSM Session Manager for server access

## Container Security
- Scan container images with `trivy` before deployment
- Run containers as non-root user
- Use read-only root filesystem where possible
- Never store secrets in Docker images or environment variables in Dockerfile

## Dependency Security
- Run `npm audit` / `pip audit` / `bundle audit` regularly
- Pin dependency versions to prevent supply chain attacks
- Enable Dependabot or Renovate for automated security updates

## Logging & Audit
- Never log sensitive data (passwords, tokens, PII)
- Enable CloudTrail for AWS API audit logging
- Enable VPC Flow Logs for network auditing
- Use structured logging with correlation IDs
