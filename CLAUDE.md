# AWS Backup Restore Testing — Claude Code Guidelines

Terraform lab that recreates the AWS "Automated Backup Restore Testing" blog (CFN
`CFAWSBackupRestoreTestingV15.yaml`) as native Terraform. **Status: greenfield** — only
`terraform-spec.md` exists; source is generated from that spec.

> `terraform-spec.md` is the authoritative contract. Read it before writing any `.tf`.
> Part A = 1-to-1 translation from CloudFormation. Part B = supporting lab resources (vault,
> plan, selection, test S3/RDS) so the lab runs end-to-end from zero.

## Stack

- **Language/Framework:** Terraform `>= 1.9`, Python 3.12 (Lambda handlers)
- **Provider:** `aws >= 5.70.0` (needs `aws_backup_restore_testing_*`, ≥ 5.32), `archive >= 2.4`
- **Infrastructure:** AWS Backup (restore testing plan/selection), IAM (4 roles), Lambda (3 fns:
  coordinator + S3/RDS validators), EventBridge, CloudWatch Logs, S3, RDS PostgreSQL, KMS
- **Region:** `ap-southeast-1`
- **State:** local for practice; S3 backend with `use_lockfile = true` written as a commented block

## Essential Commands

```bash
# Validation chain (run from envs/dev/)
cd envs/dev
terraform fmt -recursive
terraform validate
tflint --recursive
checkov -d . --framework terraform --quiet
terraform plan -out=tfplan
terraform apply tfplan
```

## Architecture

- **Module layout:** `modules/backup-restore-testing/` (versions/variables/locals/data/main/outputs
  + `lambda/`) consumed by `envs/dev/`. Part B lab resources live in `envs/dev/main.tf`, not the module.
- **Flow:** Backup restore-testing plan runs restore jobs → on `COMPLETED`, EventBridge rule fires →
  coordinator Lambda routes by `resourceType` → invokes S3/RDS validator **synchronously**
  (`RequestResponse`) → validator calls `backup:put_restore_validation_result`.
- **No Lambda subnet-finder:** the CFN custom resource is replaced by `data.aws_db_subnet_groups`
  (see spec §2, §12). One fewer Lambda + IAM role than the original CFN.
- **Feature flags:** `enable_s3` / `enable_rds` gate selections, validators, roles, and log groups via
  `count`. Coordinator inline policy is only created when at least one is enabled (avoids empty resources).
- **Conditional resources** use `count = enable_x ? 1 : 0`; reference with `[0]` and guard outputs.

## Spec invariants — do NOT change (match CFN exactly)

- Function names: `RestoreValidationCoordinator`, `S3RestoreValidation`, `RDSRestoreValidation`
- Plan name `DailyRestorePlan`, schedule `cron(0 22 ? * * *)` (10PM UTC), windows = 4h, selection = 7 days
- `recovery_point_selection.include_vaults = ["*"]` (scans every vault in the account)
- S3 validator rule: **`object_count > 1`** → `SUCCESSFUL` (not `>= 1`)
- RDS validator rule: `DBInstanceStatus == "available"` → `SUCCESSFUL`
- `ValidationStatus` ∈ {`"SUCCESSFUL"`, `"FAILED"`} — **never** `"SUCCESS"`
- EventBridge pattern uses `detail.status = ["COMPLETED"]` (not `detail.state`) + `restoreTestingPlanArn`
  prefix filter so the rule only fires for this plan
- RDS `restore_metadata_overrides` key is `dbSubnetGroupName` (camelCase)

## Gotchas

- **`include_vaults = ["*"]`** means restore testing scans recovery points across the whole account —
  intended, but be aware in shared accounts.
- IAM policies must use `data.aws_iam_policy_document` — **never inline JSON** (rules/terraform.md).
- Coordinator's `lambda:InvokeFunction` is scoped to the enabled validator ARNs (least-privilege),
  tighter than the CFN's `*`.
- Lambda invoke is **synchronous** (`RequestResponse`); async (`Event`) is wrong for this design.
- CloudWatch log groups are created explicitly (retention + TF-managed); Lambda fns `depends_on` them.
- **Test RDS is for generating recovery points only** — never run this in a production VPC.

## Skills Available

- `terraform-engineer`, `cloud-architect` — IaC authoring & AWS architecture
- `devops-engineer`, `secure-code-guardian` — workflow & secure-by-default review
- `postgres-pro`, `database-optimizer` — RDS PostgreSQL
- `monitoring-expert` — CloudWatch logging/observability
- `security-reviewer` — IAM least-privilege review

Agents: `infra-reviewer`, `security-auditor`, `cost-optimizer`, `incident-responder`.
Rules: `.claude/rules/terraform.md`, `.claude/rules/security.md`.
