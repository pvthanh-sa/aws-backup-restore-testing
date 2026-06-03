# AWS Backup Restore Testing — Claude Code Guidelines

Terraform lab that provisions an **AWS Backup restore-testing** apparatus (ported from the
AWS blog CFN `CFAWSBackupRestoreTestingV15.yaml`) plus supporting resources so it runs
end-to-end from zero. Spec is the source of truth: `docs/specs/terraform-spec.md`.

## Stack

- **IaC:** Terraform `>= 1.9`, provider `aws >= 5.70` (`aws_backup_restore_testing_*` needs ≥ 5.32), `archive >= 2.4`
- **Cloud:** AWS — Backup (vault/plan/restore-testing-plan/selection), Lambda, RDS (Postgres), S3, IAM, EventBridge, CloudWatch Logs, KMS
- **Lambda:** Python 3.12, timeout 60s, memory 128MB (coordinator + S3 validator + RDS validator)
- **Region:** `ap-southeast-1` · single env: `dev` (practice)
- **CI/CD:** none (manual `terraform` workflow)

## Layout (target — build from spec)

```
modules/backup-restore-testing/   versions / variables / locals / data / main / outputs + lambda/
  lambda/coordinator/handler.py    lambda/validator_s3/handler.py    lambda/validator_rds/handler.py
envs/dev/                          backend / providers / main / variables / terraform.tfvars / outputs / locals
docs/specs/terraform-spec.md       approved spec (Part A = 1:1 CFN port, Part B = supporting lab resources)
```

## Essential Commands

```bash
cd envs/dev
terraform fmt -recursive
terraform validate
tflint --recursive
checkov -d . --framework terraform --quiet
terraform plan -out=tfplan
terraform apply tfplan
terraform destroy            # tear down after observing — lab need not run 24/7
```

## Architecture (non-obvious decisions)

- **No Lambda subnet-finder.** CFN used a custom-resource Lambda + `random.choice` over DB subnet
  groups. There is **no** `aws_db_subnet_groups` (plural) data source in the AWS provider, so the spec
  replaces it with **explicit wiring**: Part B creates `aws_db_subnet_group.test` and passes its `name`
  into the module via `var.rds_subnet_group_name`. Deterministic, no Lambda. Validate cross-field:
  `enable_rds == true` ⇒ `rds_subnet_group_name` non-empty.
- **Least-privilege IAM** (`rules/security.md`): coordinator's `lambda:InvokeFunction` is scoped to the
  enabled validator ARNs (CFN used `*`). All policies via `data.aws_iam_policy_document` — never inline JSON.
- **Conditional resources** via `count = enable_s3 ? 1 : 0` / `enable_rds ? 1 : 0` — S3 and RDS branches
  are independently toggleable. Inline coordinator policy only created when `enable_s3 || enable_rds`.
- **Explicit CloudWatch log groups** with retention (not Lambda auto-created); Lambda `depends_on` them.

## Gotchas

- **Exact-match values from CFN — do not "fix" them:** S3 validator rule is `object_count > 1` (NOT `>= 1`);
  RDS rule is `DBInstanceStatus == "available"`; `ValidationStatus` is `"SUCCESSFUL"`/`"FAILED"` (NOT `"SUCCESS"`).
- Coordinator invokes validators **synchronously** (`RequestResponse`), not async `Event`.
- EventBridge pattern filters on `detail.status` (NOT `detail.state`) + `restoreTestingPlanArn` prefix.
- `restore_metadata_overrides` key is `dbSubnetGroupName` (camelCase). Missing/invalid subnet group → restore job **fails**.
- `include_vaults = ["*"]` scans recovery points across **every** vault in the account.
- **Lab sequencing:** day 0 usually has no recovery point to test. Run an on-demand backup
  (`aws backup start-backup-job`) right after apply; restore-testing only finds points within `selection_window_days` (7).
- **Costs real money (~$17–25/mo if left running):** each validation run restores a live RDS instance for the
  validation window. Use `enable_rds=false` for the cheap S3-only path; `terraform destroy` when done.
- Teardown: S3 test bucket has versioning → needs `force_destroy = true`; vault won't delete until recovery
  points hit `delete_after = 2` lifecycle or are removed manually.

## Skills & Agents Available

- **terraform-engineer**, **cloud-architect** — module/env authoring, AWS architecture
- **devops-engineer** — deployment workflow, automation
- **secure-code-guardian**, **security-reviewer** — IAM least-privilege, secrets, infra security
- Agents: **infra-reviewer**, **cost-optimizer**, **incident-responder**, **security-auditor**
- Rules: `.claude/rules/terraform.md`, `.claude/rules/security.md`
