## Infrastructure Review Report (G4) — `environments/dev-singapore`
_Saved: docs/reviews/dev-singapore-2026-06-05.md · mode: --deep (loop-until-dry) · run `wf_1d125d1e-05c` · reviewers: security-auditor · infra-reviewer · cost-optimizer_

### Recommendation: GO-WITH-FIXES → High + cheap env-local Lows **fixed** (see addendum); now **GO**
Deep (loop-until-dry) review of the lab across security, infra, and cost. **0 Critical, 1 High, 5 Medium, 8 Low.**
The one High is new (single passes missed it): the saved binary `tfplan` is not gitignored and can embed
the auto-generated RDS master password / Secrets Manager `secret_string` in plaintext — fix before any
commit. Remaining items are hardening (CMK/KMS, default NACL/SG, wildcard IAM scoping, IAM DB auth,
variable validations) and cost. Both prior-round Highs (RDS egress, account-ID-in-backend) stayed fixed.

### Severity:  Critical 0 · High 1 · Medium 5 · Low 8
### Estimated savings: ~$19.01/month

### Must fix before apply/commit (High)
1. **[High][infra] Binary `tfplan` not gitignored — may embed RDS password in plaintext** — `environments/dev-singapore/tfplan`
   → Saved plans contain full attribute values incl. `random_password` and the secret `secret_string`.
   Add `tfplan` + `*.tfplan` to `.gitignore`, run `git rm --cached environments/dev-singapore/tfplan` if
   tracked, and never commit plan artifacts.

### Should fix (Medium)
1. **[security] RDS uses AWS-managed default KMS key; no CMK option** — `modules/rds/main.tf:283` → add optional `kms_key_id` (default null), pass to instance + replica.
2. **[security] RDS lacks IAM DB auth / secret rotation** — `modules/rds/main.tf:263` → `iam_database_authentication_enabled = true`; add `aws_secretsmanager_secret_rotation` or document manual rotation.
3. **[security] S3 buckets use SSE-S3 (AES256), not SSE-KMS** — `modules/s3_backend_storage/main.tf:86` → parameterize SSE to allow `aws:kms` + optional `kms_master_key_id`, keep `bucket_key_enabled`.
4. **[infra] Default NACL / default SG allow-all `0.0.0.0/0`** — `modules/network/variables.tf:491-535` → restrict default NACL/SG to VPC CIDR or deny-all (DB traffic already governed by `aws_security_group.db`).
5. **[infra] `enable_rds` defaults to true — bills on every apply/run** — `environments/dev-singapore/terraform.tfvars:10` → for a practice lab, default `false` (S3-only) or add a prominent cost warning; document `terraform destroy`. (~$14.84/mo)

### Low (8)
1. **[security] S3 selection / RDS validator IAM wildcard resources** — `modules/backup-restore-testing/main.tf:200` → scope `rds:DescribeDBInstances` + selection ARNs / add region/vault conditions (`backup:PutRestoreValidationResult` wildcard is unavoidable — no resource scoping).
2. **[infra] RDS S3-integration policy falls back to `"*"` when `s3_bucket_arns` null** — `modules/rds/data.tf:12` → require `s3_bucket_arns` when `enable_s3_integration=true`; drop the `["*"]` fallback. *(Not exercised here.)*
3. **[security] Backup vault uses AWS-managed key, no CMK / vault-lock** — `environments/dev-singapore/main.tf:92` → CMK + `aws_backup_vault_lock_configuration` for prod. Acceptable for lab.
4. **[infra] Provider constraints inconsistent across modules vs env** — add `< 7.0.0` upper bound in every module `versions.tf`; align `required_version` (network/iam_role/rds floor at `>= 1.4.0`) to `>= 1.9`.
5. **[security] No VPC endpoints; Secrets Manager / S3 toggles disabled** — `environments/dev-singapore/main.tf:8` → enable `enable_secretsmanager_endpoint`/`enable_s3_endpoint` if the network is reused for API-calling workloads.
6. **[infra] Env input vars lack validation** — `variables.tf:1-16` → add validation for `region`, `environment`, and the two cron `schedule_expression` strings.
7. **[infra] `vpc_cidr` / `database_subnet_cidrs` lack CIDR-format validation** — `variables.tf:36-51` → add `can(cidrhost(...))` checks.
8. **[infra] `aws_backup_selection.practice` missing tags / Name** — `environments/dev-singapore/main.tf:114-124` → add tags if taggable, else comment that it is non-taggable.

### Top cost-saving recommendations
1. **`enable_rds=false` when not validating RDS restores** — ~$14.84/mo (drops VPC, `db.t4g.micro`, gp3, RDS validator). S3 branch alone still exercises the EventBridge→Lambda pipeline. (risk: Low)
2. **`terraform destroy` after each observation session** — recovers the rest of the ~$19/mo; all resources reproducible from code. (risk: Low)

---

### Notes
- **`--deep` recall win:** the `tfplan` exposure (High) was **not** found in the two prior single-pass runs — confirms the skill's "single pass is not exhaustive" caveat.
- **Stayed fixed:** RDS SG egress (now deny-all default) and the hardcoded account-ID backend (now partial config) — neither reappeared.
- **Honesty caveat:** G4 is *contextual judgment*, not provably clean. The deterministic baseline is the tool gates — `checkov`/`tflint` (Stage 3) and `betterleaks`/`gitleaks` (Stage 6) — which were not run here.
- Several Medium/Low items are in **vendored** modules (`rds`, `network`, `s3_backend_storage`) → fixes there go to the `custom-infrastructure` source first, then re-copy.

---

## Addendum — fixes applied (2026-06-05)

Working tree only (`terraform validate` ✓; not applied/committed):

- **[High] `tfplan` exposure** — `.gitignore` now actively ignores `tfplan` / `*.tfplan` / `*tfplan*`
  (verified `git check-ignore`). The file was untracked, so nothing leaked.
- **[Low] env variable validations** — added to `environments/dev-singapore/variables.tf`: `region`
  (regex), `environment` (dev/staging/prod), `restore_schedule_expression` + `backup_schedule_expression`
  (must start `cron(`/`rate(`), `vpc_cidr` + `database_subnet_cidrs` (CIDR-format via `cidrhost`).
- **[Low] provider/version consistency** — added `< 7.0.0` upper bound to `aws` in every module
  (`backup-restore-testing` + vendored `rds`/`network`/`iam_role`/`s3_backend_storage`) and aligned
  their `required_version` to `>= 1.9`. Vendored edits made at the `custom-infrastructure` source first,
  then re-copied.
- **[Low] `aws_backup_selection` tags** — confirmed non-taggable; added a clarifying comment instead.

**Remaining (deferred — not apply-blockers):** Medium KMS/CMK options (RDS/S3/vault), IAM DB auth +
secret rotation, default NACL/SG tightening, `enable_rds` default; Low IAM wildcard scoping, VPC
endpoints. Several are vendored-module hardening or deliberate spec/lab choices.

**Resulting posture:** 0 Critical, **0 High**, 5 Medium, 7 Low. Effective recommendation: **GO**.

## Runtime follow-up — M1 S3-validator scoping corrected (2026-06-08)

The earlier M1 hardening (scope the S3 validator's `s3:ListBucket`/`GetObject` to the restore-test
bucket prefix) shipped with the **wrong prefix**: `aws-backup-restore-*`. AWS Backup actually names
restored buckets `awsbackup-restore-test-*` (no hyphen between "aws" and "backup"). In production this
caused the S3 validator to fail with `AccessDenied` on `ListObjectsV2` → restore job
`ValidationStatus = TIMED_OUT` (RDS validation was unaffected — it uses `rds:DescribeDBInstances`,
unscoped). Confirmed via `aws backup list-restore-jobs` + `/aws/lambda/S3RestoreValidation` logs.
**Fix:** `s3_restore_bucket_name_patterns` default → `["awsbackup-restore-*"]`
(`modules/backup-restore-testing/variables.tf`); `terraform validate` ✓. Requires `terraform apply`
to update the `validator_s3` inline policy; verify next cycle shows `SUCCESSFUL`.
