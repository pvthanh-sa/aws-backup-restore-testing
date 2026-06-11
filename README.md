# AWS Backup Restore Testing Lab

An automated system that proves your AWS Backup recovery points are actually **restorable**. It periodically restores recovery points to throwaway resources, validates them automatically, and cleans up — so you catch backup failures before a real incident, not during one.

This is a complete 1:1 port of the [AWS CloudFormation template](https://aws.amazon.com/blogs/storage/automating-backup-restore-testing-for-aws-backup/) plus supporting infrastructure to run end-to-end from scratch.

## Quick Facts

| Item | Value |
|------|-------|
| **IaC** | Terraform `>= 1.9` |
| **Provider** | AWS `>= 5.70` |
| **Region** | `ap-southeast-1` (Singapore) |
| **Environment** | `dev` (practice lab) |
| **Estimated Cost** | ~$15–22/month (if left running) |

## Architecture

For a detailed walkthrough of the two-phase design (Backup → Vault → Restore-testing + Validation), including diagrams and numbered flow, see **[docs/infrastructure.md](docs/infrastructure.md)**.

**High-level:** The system has two halves connected by a backup vault. Phase 1 creates recovery points nightly at 01:00 UTC. Phase 2 pulls a recent point at 22:00 UTC, restores it to temporary resources, runs automated validators, reports pass/fail, and auto-cleans.

## Getting Started

### Prerequisites

- AWS Account with `ap-southeast-1` access
- Terraform `>= 1.9`
- AWS CLI v2
- Configured AWS credentials (OIDC or IAM keys)

### Initial Setup

```bash
cd environments/dev-singapore

# 1. Create backend config (gitignored — contains AWS Account ID)
cat > backend-dev.hcl <<EOF
bucket         = "terraform-state-ACCOUNT_ID"
key            = "dev-singapore/terraform.tfstate"
region         = "ap-southeast-1"
dynamodb_table = "terraform-lock"
use_lockfile   = true
EOF

# 2. Initialize backend
terraform init -backend-config=backend-dev.hcl

# 3. Review plan
terraform plan -out=tfplan

# 4. Apply
terraform apply tfplan
```

### Trigger Initial Backup (optional)

Day 0 typically has no recovery point. Manually trigger a backup if you want immediate testing:

```bash
aws backup start-backup-job \
  --backup-vault-name dev-restore-lab-vault \
  --resource-arn arn:aws:rds:ap-southeast-1:ACCOUNT_ID:db:dev-restore-lab-test \
  --iam-role-arn arn:aws:iam::ACCOUNT_ID:role/dev-restore-lab-backup-service \
  --region ap-southeast-1
```

Restore-testing only finds recovery points within the 7-day window (`selection_window_days`).

### Cleanup

```bash
terraform destroy

# Note:
# - S3 bucket has versioning → requires force_destroy = true
# - Vault won't delete until recovery points expire (delete_after = 2 days)
```

## Directory Layout

```
.
├── README.md                              ← You are here
├── CLAUDE.md                              ← Claude Code guidelines
├── modules/
│   ├── backup-restore-testing/            ← Main restore-testing module
│   │   ├── versions.tf
│   │   ├── variables.tf
│   │   ├── main.tf
│   │   ├── locals.tf
│   │   ├── outputs.tf
│   │   ├── data.tf
│   │   ├── lambda/
│   │   │   ├── coordinator/handler.py     ← Coordinator Lambda (Python 3.12)
│   │   │   ├── validator_s3/handler.py    ← S3 Validator Lambda
│   │   │   └── validator_rds/handler.py   ← RDS Validator Lambda
│   │   └── README.md
│   ├── network/                           ← VPC, subnets, security groups
│   ├── rds/                               ← RDS test database
│   └── s3_backend_storage/                ← S3 test bucket
│
├── environments/
│   └── dev-singapore/                     ← Single environment
│       ├── backend.tf
│       ├── providers.tf
│       ├── versions.tf
│       ├── variables.tf
│       ├── main.tf
│       ├── locals.tf
│       ├── outputs.tf
│       └── backend-dev.hcl                ← Gitignored — create by hand
│
└── docs/
    ├── infrastructure.md                  ← Architecture deep-dive (living doc)
    ├── specs/
    │   └── terraform-spec.md              ← Complete Terraform spec (source of truth)
    ├── reviews/
    │   └── dev-singapore-2026-06-05.md    ← Security & cost review (Well-Architected)
    └── diagrams/
        ├── infra.drawio                   ← Edit in draw.io
        └── infra.png                      ← Exported PNG
```

## Key Gotchas

⚠️ **Exact-match values from CloudFormation — do not "fix":**
- S3 validator: `object_count > 1` (NOT `>= 1`)
- RDS validator: `DBInstanceStatus == "available"`
- Status field: `"SUCCESSFUL"` / `"FAILED"` (NOT `"SUCCESS"`)

⚠️ **EventBridge pattern:**
- Filters on `detail.status` (NOT `detail.state`)
- Requires `restoreTestingPlanArn` prefix

⚠️ **RDS subnet group name:**
- `restore_metadata_overrides` key is `dbSubnetGroupName` (camelCase)
- Missing or invalid → restore job **fails**

⚠️ **Two RDS backup sources — don't confuse:**
- **Backup plan** → recovery point in vault (tested by lab)
- **RDS automated backups** → `backup_retention_period = 7` (RDS-managed, not in vault)

⚠️ **Cost Warning:**
- ~$11–14/month: always-on RDS instance
- ~$2–4/month: restore validations (~4h each)
- ~$1–2/month: backup storage
- **Total: ~$15–22/month if left running**

💡 **Save money:**
- `terraform destroy` after each session (~$18/month savings)
- `enable_rds=false` for S3-only path (~$15/month)

For full details, see [docs/specs/terraform-spec.md](docs/specs/terraform-spec.md) § 15.

## Validation & Deployment

```bash
cd environments/dev-singapore

# 1. Format
terraform fmt -recursive ../../

# 2. Validate syntax
terraform validate

# 3. Lint
tflint --recursive ../../

# 4. Security scan
checkov -d . --framework terraform --quiet

# 5. Plan & review
terraform plan -out=tfplan

# 6. Apply (only with explicit tfplan, never -auto-approve)
terraform apply tfplan
```

## Documentation

- **[docs/infrastructure.md](docs/infrastructure.md)** — Architecture walkthrough, components, network design, security posture (living document)
- **[docs/specs/terraform-spec.md](docs/specs/terraform-spec.md)** — Complete Terraform spec (source of truth)
- **[docs/reviews/dev-singapore-2026-06-05.md](docs/reviews/dev-singapore-2026-06-05.md)** — Security & cost review via Well-Architected Framework
- **[CLAUDE.md](CLAUDE.md)** — Claude Code guidelines & available agents

## Security & Terraform Rules

📋 See [.claude/rules/security.md](.claude/rules/security.md):
- ✅ No hardcoded credentials, API keys, tokens
- ✅ RDS password auto-generated into Secrets Manager
- ✅ Least-privilege IAM (coordinator scoped to validator ARNs)
- ✅ Encryption at rest (S3 SSE-S3, RDS encrypted)
- ✅ RDS private (not publicly accessible), security group deny-all egress

📋 See [.claude/rules/terraform.md](.claude/rules/terraform.md):
- ✅ S3 backend with `use_lockfile = true`
- ✅ Pinned provider versions (`>= 6.0.0, < 7.0.0`)
- ✅ All variables & outputs have `description`
- ✅ IAM policies via `data.aws_iam_policy_document` (no inline JSON)
- ✅ No hardcoded account IDs, regions, secrets

## Available Skills & Agents

Type `/` to see all, or invoke directly:

| Skill | Purpose |
|-------|---------|
| **terraform-engineer** | Module & environment authoring |
| **cloud-architect** | AWS architecture & design trade-offs |
| **devops-engineer** | Deployment automation, CI/CD |
| **secure-code-guardian** | Secrets, IAM, code security |
| **security-reviewer** | Infrastructure security audit |
| **infra-reviewer** | Comprehensive security + best practices + cost |
| **cost-optimizer** | Cost analysis & optimization |
| **incident-responder** | Troubleshooting & diagnostics |

Agents: `.claude/agents/` — `infra-reviewer`, `cost-optimizer`, `incident-responder`, `security-auditor`

## FAQ

**Q: When does the backup run?**  
A: Nightly at 01:00 UTC (cron `0 1 * * ? *`)

**Q: When does restore-testing run?**  
A: Nightly at 22:00 UTC (cron `0 22 ? * * *`)

**Q: How do I view validation results?**  
A: CloudWatch Logs → log group `dev-restore-lab-coordinator` or `/aws/lambda/RestoreValidationCoordinator`

**Q: Can I manually trigger a restore?**  
A: No — AWS Backup API has no direct "invoke restore plan" action. Only scheduled runs or `start-backup-job` to create new recovery points.

**Q: Can I use a different region?**  
A: Yes, but `environments/` assumes `dev-singapore`. Copy `environments/dev-singapore` → `environments/prod-us-east-1` and update `region` in `providers.tf`.

**Q: Why does S3 validator check `object_count > 1`?**  
A: To avoid false positives (empty bucket ≠ successful restore). Proof of restore is that it contains data.

**Q: Are there cost-saving options?**  
A: Yes. See [docs/specs/terraform-spec.md](docs/specs/terraform-spec.md) § 15 for `enable_rds=false` and teardown strategies.

## References

- **AWS Backup docs:** [AWS Backup User Guide](https://docs.aws.amazon.com/aws-backup/)
- **Original CloudFormation:** [AWS Blog: Backup Restore Testing](https://aws.amazon.com/blogs/storage/automating-backup-restore-testing-for-aws-backup/)
- **GitHub Issues:** Report bugs or feature requests

---

**Last updated:** 2026-06-11  
**Status:** Production-ready (dev lab)
