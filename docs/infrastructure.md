<!--
  Infrastructure Document (living doc) — produced by /infra-document (Stage 5).
  Every fact is derived from the spec + Terraform code. Re-run the skill when infra changes.
  Diagram upkeep: open diagrams/infra.drawio → Export PNG → diagrams/infra.png → then delete the
  Mermaid verification block in §2.
-->

# Infrastructure — AWS Backup Restore Testing / dev-singapore

- **Environment:** `dev` (dir `environments/dev-singapore`) **Region:** `ap-southeast-1` **Account:** `637423473957`
- **Source of truth:** Terraform at `environments/dev-singapore` · Spec: [`specs/terraform-spec.md`](specs/terraform-spec.md)
- **Last generated:** 2026-06-08 by `/infra-document` (living document — re-run after changes)

## 1. Overview

- **Purpose:** A lab that proves your AWS backups are actually **restorable**. It periodically restores
  recovery points to throwaway resources and validates them automatically — so you find out backups are
  broken _before_ a real incident, not during one. (Ported 1:1 from the AWS blog CloudFormation
  `CFAWSBackupRestoreTestingV15.yaml`, plus the supporting resources to run end-to-end from zero.)
- **The big picture:** The system has two halves connected by one shared store. One half **creates
  backups** of a test database and a test bucket every night and drops them into a **vault**. The other
  half, later each night, **pulls a backup back out of the vault, restores it** to a temporary copy, and
  runs a small check to confirm the restore worked — then throws the copy away and records pass/fail.
  The vault in the middle is the handoff between the two halves.
- **Stack:** AWS Backup (vault / plan / restore-testing plan / selections), Lambda (Python 3.12 ×3),
  RDS PostgreSQL, S3, EventBridge, CloudWatch Logs, IAM, Secrets Manager, VPC.
- **Scope of this doc:** this environment only (`dev-singapore`) — the single env for this lab.

## 2. Architecture diagram

![Infrastructure](diagrams/infra.png)

<!-- ^ PNG not exported yet. Source: diagrams/infra.drawio (open in draw.io → Export → PNG). -->

**How to read this diagram:** the two boxed groups are the two halves — **Phase 1 (Backup)** on top,
**Phase 2 (Restore-testing)** below; the **Vault sits between them as the shared handoff**. Solid
**numbered** arrows are the main path in order: green ① ② = Phase 1, blue ③–⑧ = Phase 2. Dashed arrows
are supporting links (creds, logs, reads) that aren't part of the main sequence.

**The numbered path:** ① back up `backup=true` resources → ② store recovery point in the vault →
③ restore-testing reads a point (within the 7-day window) → ④ restore to a temporary resource →
⑤ "restore COMPLETED" event fires → ⑥ invoke Coordinator Lambda → ⑦ Coordinator calls the matching
validator → ⑧ validator reports SUCCESS/FAIL, then AWS Backup deletes the temp resource.

## 3. How it works (architecture walkthrough)

> Understand the system here; §4–§5 are the precise reference. Numbers ①–⑧ match the §2 diagram.

**The shape — two halves + a vault between them.** You can't test a restore without something to
restore, so the lab is split: **Phase 1 makes** recovery points, **Phase 2 consumes** them. They never
talk directly — the **backup vault** is the only shared thing (Phase 1 writes, Phase 2 reads). That
separation is the whole design.

**Phase 1 — Backup** · _nightly 01:00 UTC_

- A test DB (`module.rds`) and test bucket (`module.test_bucket`) are both tagged `backup=true`.
- The **backup plan** + tag-based **selection** grab everything with that tag ① → store a recovery point in the **vault** ②.
- The tag _is_ the contract: tag anything `backup=true` and it auto-joins the lab.
- The bucket holds 2 sample objects on purpose — the S3 validator later checks "> 1 object".

**Phase 2 — Restore-testing + validation** · _nightly 22:00 UTC_ · _(the ported apparatus, `module.backup_restore_testing`)_

- `DailyRestorePlan` pulls a recent recovery point ③ → restores it to a **temporary** resource ④.
- Restore done → AWS Backup fires a "COMPLETED" event ⑤ → **EventBridge** invokes the **Coordinator Lambda** ⑥.
- Coordinator routes by resource type to the **S3** or **RDS validator** ⑦.
- Validator checks the copy (S3: > 1 object · RDS: instance `available`) → reports SUCCESS/FAIL via `PutRestoreValidationResult` ⑧.
- **Auto-delete:** AWS Backup keeps each temp copy for the **validation window** (`validation_window_hours` = **4h**, from the COMPLETED time), then deletes it. Reporting early (⑧) does _not_ shorten the window. Terraform never manages these temp resources — AWS Backup creates/destroys them, never in TF state.
- **Net result:** a daily automated pass/fail on whether backups actually restore, and ~4h later nothing is left behind.

**Key design decisions**

- **3 Lambdas, not 1** — coordinator decouples "something restored" from "how to check type X": add a type = add a validator, no rewiring. IAM tightly scoped (coordinator → only the validator ARNs; each validator → only its own type).
- **Network almost empty** — the test DB needs no internet: private subnets only (**no IGW/NAT**), RDS SG egress deny-all.
- **Cheap & disposable on purpose** — single-AZ, `db.t4g.micro`, vault keeps points only 2 days. Dev lab, not a production backup system.

> ⚠️ **Two RDS backup sources (don't confuse):** the **backup plan** creates _vault_ recovery points
> (tag-driven — what this lab tests). The RDS instance _also_ has its **own automated backups**
> (`backup_retention_period = 7`) — RDS-managed, **not** in the vault.

## 4. Components

| Module / resource                                         | AWS resource(s)                                                                                                                                                                          | Role                                                 | Tier / subnet      |
| --------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------- | ------------------ |
| `module.network` _(enable_rds)_                           | VPC `10.20.0.0/16`, 2 database subnets (az a/b), DB subnet group, route table; **no IGW/NAT**                                                                                            | Network foundation for the test DB                   | — (private only)   |
| `module.rds` _(enable_rds)_                               | `aws_db_instance` (PostgreSQL 17.6, `db.t4g.micro`, encrypted, single-AZ, **not public**), SG (deny-all egress), Secrets Manager secret (auto-gen password), parameter group, log groups | Test database; tagged `backup=true`                  | private DB subnets |
| `module.test_bucket` (`s3_backend_storage`) _(enable_s3)_ | `aws_s3_bucket` (versioned, SSE-S3/AES256, public-access-block, `force_destroy`, lifecycle expire noncurrent 7d)                                                                         | Test bucket; tagged `backup=true`                    | —                  |
| `aws_s3_object.sample` ×2 _(enable_s3)_                   | 2 objects under `validation/`                                                                                                                                                            | Make `object_count > 1` so the S3 validator passes   | —                  |
| `aws_backup_vault.practice`                               | Backup vault (AWS-managed `aws/backup` KMS)                                                                                                                                              | Holds recovery points                                | —                  |
| `aws_backup_plan.practice`                                | Backup plan, rule `cron(0 1 * * ? *)`, `delete_after = 2`                                                                                                                                | Creates recovery points from `backup=true` resources | —                  |
| `aws_backup_selection.practice`                           | Selection by tag `backup=true`, uses backup-service role                                                                                                                                 | Tells the plan what to back up                       | —                  |
| `module.backup_restore_testing` (**Part A**)              | Restore-testing plan `DailyRestorePlan` (`cron(0 22 ? * * *)`), S3 + RDS restore-testing selections, 3× Lambda, EventBridge rule/target/permission, 3× CloudWatch log group, 4× IAM role | The restore-testing + auto-validation apparatus      | —                  |

**IAM roles (in `module.backup_restore_testing`):** `backup_service` (trust `backup.amazonaws.com`, 4 managed policies — also used by Part B selection), `coordinator` (invoke scoped to validator ARNs), `validator_s3`, `validator_rds`.

**Lambdas (Python 3.12, 60s, 128MB):** `RestoreValidationCoordinator`, `S3RestoreValidation` _(enable_s3)_, `RDSRestoreValidation` _(enable_rds)_.

## 5. Network

- **VPC CIDR:** `10.20.0.0/16` · **AZs:** `ap-southeast-1a`, `ap-southeast-1b` (database subnets `10.20.101.0/24`, `10.20.102.0/24`).
- **Subnets:** database/private only — there are **no public subnets**, no IGW, no NAT (the test DB needs no internet path).
- **Security groups:** RDS SG — ingress only from `restricted_security_group_ids` (none here), **egress deny-all by default** (`egress_rules = []`).
- **Egress / endpoints:** none. VPC endpoints not provisioned (no workloads call AWS APIs from the VPC).
- _Network exists only when `enable_rds = true`._

## 6. Environments & naming

- **Prefix:** `${environment}-${app_name}` → **`dev-restore-lab`** (resource names like `dev-restore-lab-vault`, `dev-restore-lab-test`). Fixed CFN-derived names are kept exact: `DailyRestorePlan`, `RestoreValidationCoordinator`, `S3RestoreValidation`, `RDSRestoreValidation`, `Backup_restore_testing`.
- **State:** S3 backend, `key = "dev-singapore/terraform.tfstate"`, `use_lockfile = true`. Account-specific values are in **`backend-dev.hcl`** (gitignored) — init with `terraform init -backend-config=backend-dev.hcl`.
- **Provider:** `aws >= 6.0.0, < 7.0.0` (resolved v6.48.0); `archive`, `random`. Toggles: `enable_s3`, `enable_rds` (both `true`).
- **Sibling environments:** none (single-env lab).

## 7. Security posture

- **IAM:** all policies via `data.aws_iam_policy_document` (no inline JSON). Coordinator's `lambda:InvokeFunction` is scoped to the enabled validator ARNs. Validator S3 read scoped to `awsbackup-restore-*` buckets — this **must** match the names AWS Backup gives restored buckets (`awsbackup-restore-test-*`); an earlier `aws-backup-restore-*` typo caused S3 validation `AccessDenied` → `TIMED_OUT` (fixed 2026-06-08, var `s3_restore_bucket_name_patterns`). `backup:PutRestoreValidationResult` / `rds:DescribeDBInstances` use `*` (no resource-level scoping available — matches CFN).
- **Encryption at rest:** RDS `storage_encrypted = true`; S3 SSE-S3 (AES256) + public-access-block + versioning; backup vault uses AWS-managed `aws/backup` key. (CMK is a documented future option, not used in the lab.)
- **Secrets:** RDS master password is auto-generated into **Secrets Manager** (never in tfvars/state inputs). No hardcoded secrets.
- **Network:** RDS is private (not publicly accessible), SG egress deny-all.
- **Edge protection:** n/a (no public ingress; this is an internal backup-validation system).
- **Review (Well-Architected Security coverage):** latest `/infra-review` → **GO** (deep run 2026-06-05). 0 Critical, 0 High after fixes (both Highs — `tfplan` exposure, hardcoded account ID in backend — remediated). Open items are Medium/Low hardening: data-protection (CMK/KMS), IAM (DB auth, wildcard scoping), infrastructure-protection (default NACL/SG). Report: [`reviews/dev-singapore-2026-06-05.md`](reviews/dev-singapore-2026-06-05.md).

## 8. Cost summary

| Item                     | Config                                         | Cost/month (est.)              |
| ------------------------ | ---------------------------------------------- | ------------------------------ |
| Test RDS (always-on)     | `db.t4g.micro` PostgreSQL, single-AZ, 20GB gp3 | ~$11–14                        |
| RDS restore-testing runs | 1 restored instance/day × ~4h + temp storage   | ~$2–4                          |
| Backup storage           | RDS + S3 snapshots, 2-day retention            | ~$1–2                          |
| Lambda (×3)              | few invokes/day, 128MB/60s                     | ~$0 (free tier)                |
| CloudWatch Logs          | 7-day retention                                | ~$0–1                          |
| S3 test bucket           | few objects + versioning                       | ~$0                            |
| **Total (est.)**         |                                                | **~$15–22/mo if left running** |

- **Savings levers (from review):** `terraform destroy` after each session (~$18/mo); `enable_rds=false` for the cheap S3-only path (~$15/mo). See spec §15 and the review report.
