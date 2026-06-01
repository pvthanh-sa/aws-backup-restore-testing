# Infra Spec — AWS Backup Restore Testing

> **Đây là SPEC (bản liệt kê resource), KHÔNG phải source code.**
> Dùng file này feed cho Claude cá nhân (skills/agents riêng) để tự dựng Terraform source ở repo ngoài.
> Spec dịch từ `CFAWSBackupRestoreTestingV15.yaml` (blog AWS) sang resource model Terraform, tuân thủ `.claude/rules/terraform.md` + `.claude/rules/security.md`.

---

## 0. Tổng quan & quy ước

| Mục | Giá trị |
|---|---|
| Region | `ap-southeast-1` |
| Terraform core | `>= 1.9` |
| Provider `aws` | `>= 5.70.0` (resource `aws_backup_restore_testing_*` cần ≥ 5.32) |
| Provider `archive` | `>= 2.4` (zip Lambda) |
| Lambda runtime | `python3.12`, timeout 60s, memory 128MB |
| Naming | `${var.app_name}-<resource-type>`, `app_name = "restore-lab"` |
| Tag | `merge(var.tags, { Name = "...", ManagedBy = "Terraform" })` |
| IAM policy | luôn dùng `data.aws_iam_policy_document` — không inline JSON |
| State | local cho practice; block S3 backend `use_lockfile = true` viết sẵn dạng comment |

**Module layout đề xuất:**
```
modules/backup-restore-testing/   → versions / variables / locals / data / main / outputs + lambda/
envs/dev/                         → backend / providers / main / variables / terraform.tfvars / outputs / locals
```

**Phạm vi spec:**
- **Phần A** = dịch 1-1 từ CFN (restore-testing apparatus).
- **Phần B** = resource phụ trợ ngoài CFN gốc (vault + plan + selection + test S3/RDS) để lab chạy end-to-end từ con số 0.

**Khác biệt có chủ ý so với CFN** (xem bảng cuối file): bỏ Lambda subnet-finder + custom resource → thay bằng data source `aws_db_subnet_groups`.

---

## 1. Variables (module contract)

| Biến | Type | Default | Validation | Ghi chú |
|---|---|---|---|---|
| `app_name` | string | `"restore-lab"` | — | prefix mọi resource |
| `tags` | map(string) | `{}` | — | merge vào common_tags |
| `restore_testing_plan_name` | string | `"DailyRestorePlan"` | regex chỉ chữ/số/underscore | khớp CFN `RestoreTestingPlanName` |
| `restore_schedule_expression` | string | `"cron(0 22 ? * * *)"` | — | 10PM UTC daily — khớp CFN |
| `start_window_hours` | number | `4` | 1–168 | khớp CFN `StartWindowHours` |
| `validation_window_hours` | number | `4` | 1–168 | khớp CFN `ValidationWindowHours` |
| `selection_window_days` | number | `7` | 1–365 | khớp CFN `SelectionWindowDays` |
| `enable_s3` | bool | `true` | — | bật S3 selection + validator |
| `enable_rds` | bool | `true` | — | bật RDS selection + validator |
| `rds_subnet_group_name` | string | `""` | — | rỗng = auto-select qua data source |
| `lambda_log_retention_days` | number | `7` | giá trị CW hợp lệ | log group retention |

---

## 2. Data sources

| Data source | Điều kiện | Mục đích |
|---|---|---|
| `aws_caller_identity.current` | luôn | account_id cho ARN scoping |
| `aws_region.current` | luôn | region cho ARN scoping |
| `aws_partition.current` | luôn | partition cho managed-policy ARN |
| `aws_db_subnet_groups.available` | `enable_rds && rds_subnet_group_name == ""` | **thay Lambda subnet-finder của CFN** — auto-pick subnet group đầu tiên |

`locals.rds_subnet_group` = nếu `rds_subnet_group_name != ""` dùng biến; ngược lại lấy phần tử đầu của data source (giống logic `HasCustomSubnetGroup` trong CFN).

---

# PHẦN A — Dịch 1-1 từ CloudFormation

## 3. IAM Roles

> CFN có 5 role. Spec này còn **4** (bỏ `LambdaSubnetFinderRole` vì không còn Lambda subnet-finder).

### 3.1 `aws_iam_role.backup_service` — (CFN: `BackupServiceRole`)
- **Trust:** `backup.amazonaws.com`
- **Managed policies** (attach qua `for_each`, ARN ghép từ `data.aws_partition`):
  - `service-role/AWSBackupServiceRolePolicyForBackup`
  - `service-role/AWSBackupServiceRolePolicyForRestores`
  - `AWSBackupServiceRolePolicyForS3Backup`
  - `AWSBackupServiceRolePolicyForS3Restore`
- **Dùng bởi:** cả 2 restore testing selection (`iam_role_arn`).

### 3.2 `aws_iam_role.coordinator` — (CFN: `LambdaCoordinatorRole`)
- **Trust:** `lambda.amazonaws.com`
- **Managed:** `service-role/AWSLambdaBasicExecutionRole`
- **Inline policy** (chỉ tạo khi `enable_s3 || enable_rds`, tránh empty resources):
  - `lambda:InvokeFunction` → giới hạn vào ARN của validator_s3 + validator_rds đang bật (CFN để `*`, spec siết least-privilege theo security.md).

### 3.3 `aws_iam_role.validator_s3` — (CFN: `LambdaS3RestoreRole`) — `count = enable_s3 ? 1 : 0`
- **Trust:** `lambda.amazonaws.com`
- **Managed:** `service-role/AWSLambdaBasicExecutionRole`
- **Inline policy:**
  - `s3:ListBucket`, `s3:ListBucketVersions`, `s3:ListAllMyBuckets`, `s3:GetObject` (Resource `*` — khớp CFN)
  - `backup:PutRestoreValidationResult` (Resource `*`)

### 3.4 `aws_iam_role.validator_rds` — (CFN: `LambdaRDSRestoreRole`) — `count = enable_rds ? 1 : 0`
- **Trust:** `lambda.amazonaws.com`
- **Managed:** `service-role/AWSLambdaBasicExecutionRole`
- **Inline policy:**
  - `rds:DescribeDBInstances` (Resource `*`)
  - `backup:PutRestoreValidationResult` (Resource `*`)

---

## 4. Restore Testing Plan

### `aws_backup_restore_testing_plan.this` — (CFN: `BackupRestoreTestingPlan`)
| Argument | Giá trị | Nguồn CFN |
|---|---|---|
| `name` | `var.restore_testing_plan_name` (`"DailyRestorePlan"`) | `RestoreTestingPlanName` |
| `schedule_expression` | `var.restore_schedule_expression` (`cron(0 22 ? * * *)`) | `ScheduleExpression` |
| `schedule_expression_timezone` | `"UTC"` | (CFN ngầm UTC) |
| `start_window_hours` | `var.start_window_hours` (4) | `StartWindowHours` |
| `recovery_point_selection.algorithm` | `"LATEST_WITHIN_WINDOW"` | `Algorithm` |
| `recovery_point_selection.include_vaults` | `["*"]` | `IncludeVaults: ['*']` |
| `recovery_point_selection.recovery_point_types` | `["SNAPSHOT"]` | `RecoveryPointTypes` |
| `recovery_point_selection.selection_window_days` | `var.selection_window_days` (7) | `SelectionWindowDays` |

> ⚠️ `include_vaults = ["*"]` — quét recovery point ở **mọi** vault trong account, đúng như CFN.

---

## 5. Restore Testing Selections

### 5.1 `aws_backup_restore_testing_selection.s3` — (CFN: `BackupRestoreTestingSelectionS3`) — `count = enable_s3 ? 1 : 0`
| Argument | Giá trị |
|---|---|
| `name` | `"RestoreTestingSelectionS3"` |
| `restore_testing_plan_name` | ref plan ở §4 |
| `protected_resource_type` | `"S3"` |
| `iam_role_arn` | `aws_iam_role.backup_service.arn` |
| `protected_resource_arns` | `["*"]` |
| `validation_window_hours` | `var.validation_window_hours` (4) |

### 5.2 `aws_backup_restore_testing_selection.rds` — (CFN: `BackupRestoreTestingSelectionRDS`) — `count = enable_rds ? 1 : 0`
| Argument | Giá trị |
|---|---|
| `name` | `"RestoreTestingSelectionRDS"` |
| `restore_testing_plan_name` | ref plan ở §4 |
| `protected_resource_type` | `"RDS"` |
| `iam_role_arn` | `aws_iam_role.backup_service.arn` |
| `protected_resource_arns` | `["*"]` |
| `validation_window_hours` | `var.validation_window_hours` (4) |
| `restore_metadata_overrides` | `{ dbSubnetGroupName = local.rds_subnet_group }` |

> ⚠️ Key override là `dbSubnetGroupName` (camelCase, đúng như CFN `RestoreMetadataOverrides`).

---

## 6. Lambda Functions

> Tất cả: `runtime=python3.12`, `timeout=60`, `memory_size=128`. Source zip qua `data.archive_file`. Mỗi function 1 CloudWatch log group riêng (§8).

### 6.1 `aws_lambda_function.coordinator` — (CFN: `RestoreCoordinatorLambda`)
- **function_name:** `"RestoreValidationCoordinator"`
- **role:** `aws_iam_role.coordinator.arn`
- **handler:** `handler.lambda_handler` (file `lambda/coordinator/handler.py`)
- **environment:**
  - `VALIDATOR_S3` = function_name validator_s3 (hoặc `""` khi tắt)
  - `VALIDATOR_RDS` = function_name validator_rds (hoặc `""` khi tắt)
- **Logic handler (spec):**
  - Đọc `event.detail.resourceType` → map sang validator tương ứng.
  - **Invoke kiểu `RequestResponse`** (synchronous — khớp CFN; bản cũ dùng `Event`/async là SAI).
  - `resourceType` lạ → raise `ValueError` (khớp CFN).

### 6.2 `aws_lambda_function.validator_s3` — (CFN: `S3ValidationLambda`) — `count = enable_s3 ? 1 : 0`
- **function_name:** `"S3RestoreValidation"`
- **role:** `aws_iam_role.validator_s3[0].arn`
- **handler:** `handler.lambda_handler` (file `lambda/validator_s3/handler.py`)
- **Logic handler (spec):**
  - Lấy `restoreJobId`, `resourceType`, `createdResourceArn` từ `event.detail`.
  - Parse bucket name từ ARN → `s3.list_objects_v2(Bucket=...)`.
  - **Rule: `object_count > 1` → `SUCCESSFUL`**, ngược lại `FAILED` (khớp CFN chính xác — KHÔNG phải `>= 1`).
  - Gọi `backup.put_restore_validation_result(RestoreJobId, ValidationStatus, ValidationStatusMessage)`.
  - `ValidationStatus` ∈ {`"SUCCESSFUL"`, `"FAILED"`} (KHÔNG phải `"SUCCESS"`).

### 6.3 `aws_lambda_function.validator_rds` — (CFN: `RDSValidationLambda`) — `count = enable_rds ? 1 : 0`
- **function_name:** `"RDSRestoreValidation"`
- **role:** `aws_iam_role.validator_rds[0].arn`
- **handler:** `handler.lambda_handler` (file `lambda/validator_rds/handler.py`)
- **Logic handler (spec):**
  - Lấy `restoreJobId`, `resourceType`, `createdResourceArn` từ `event.detail`.
  - Parse instance id từ ARN → `rds.describe_db_instances(DBInstanceIdentifier=...)`.
  - **Rule: `DBInstanceStatus == "available"` → `SUCCESSFUL`**, ngược lại `FAILED` (khớp CFN).
  - Gọi `backup.put_restore_validation_result(...)`.

---

## 7. EventBridge

### 7.1 `aws_cloudwatch_event_rule.restore_completed` — (CFN: `BackupRestoreTestingEventRule`)
- **name:** `"Backup_restore_testing"`
- **event_pattern:**
  ```json
  {
    "source": ["aws.backup"],
    "detail-type": ["Restore Job State Change"],
    "detail": {
      "status": ["COMPLETED"],
      "restoreTestingPlanArn": [{ "prefix": "<arn của plan §4>" }]
    }
  }
  ```
  > ⚠️ Dùng `detail.status` (KHÔNG phải `detail.state`) + filter `restoreTestingPlanArn` prefix — khớp CFN, để rule chỉ kích hoạt cho plan này. Bản cũ dùng `detail.state` không có prefix là SAI.

### 7.2 `aws_cloudwatch_event_target.coordinator`
- rule = §7.1, arn = `aws_lambda_function.coordinator.arn`.

### 7.3 `aws_lambda_permission.eventbridge_invoke_coordinator` — (CFN: `LambdaInvokePermission`)
- `action = "lambda:InvokeFunction"`, `principal = "events.amazonaws.com"`, `source_arn = §7.1.arn`.

---

## 8. CloudWatch Log Groups

Tạo tường minh (không để Lambda auto-tạo) để set retention + được Terraform quản lý:
- `/aws/lambda/RestoreValidationCoordinator`
- `/aws/lambda/S3RestoreValidation` (count = enable_s3)
- `/aws/lambda/RDSRestoreValidation` (count = enable_rds)
- `retention_in_days = var.lambda_log_retention_days`
- Lambda function có `depends_on` log group tương ứng.

---

# PHẦN B — Resource phụ trợ (NGOÀI CFN gốc)

> CFN gốc giả định bạn đã có vault + recovery point. Phần này thêm vào `envs/dev/` để lab chạy được từ đầu. **Đánh dấu rõ là không thuộc blog gốc.** Có thể đặt trong `envs/dev/main.tf` (không nằm trong module).

## 9. Backup vault + plan + selection
- `aws_backup_vault.practice` — name `${app_name}-vault`, KMS AWS-managed (`aws/backup`).
- `aws_backup_plan.practice` — 1 rule: `schedule = cron(0 1 * * ? *)` (hoặc on-demand), `target_vault_name` = vault trên, `lifecycle { delete_after = 2 }` (retention ngắn cho practice).
- `aws_backup_selection.practice` — `iam_role_arn` = `module...backup_service_role_arn` (export ra output), `selection_tag { type="STRINGEQUALS" key="backup" value="true" }`.

## 10. Test resources (gắn tag `backup=true`)
- `aws_s3_bucket.test` — name unique (`${app_name}-test-<suffix>`), **bật:** versioning, SSE (`aws:kms` hoặc `AES256`), block public access toàn bộ. Upload ≥ 2 object để validator S3 (`> 1`) pass.
- `aws_db_instance.test` (count = enable_rds) — `db.t3.micro`, engine `postgres`, `storage_encrypted = true`, `multi_az = false`, `skip_final_snapshot = true`, đặt trong DB subnet group sẵn có / tạo mới, **không** public.

> ⚠️ Cảnh báo: không chạy trong VPC production. Test RDS chỉ phục vụ tạo recovery point.

---

## 11. Outputs (module)

| Output | Giá trị |
|---|---|
| `backup_service_role_arn` | `aws_iam_role.backup_service.arn` |
| `restore_testing_plan_name` | `aws_backup_restore_testing_plan.this.name` |
| `restore_testing_plan_arn` | `aws_backup_restore_testing_plan.this.arn` |
| `coordinator_function_name` | `aws_lambda_function.coordinator.function_name` |
| `validator_s3_function_name` | conditional |
| `validator_rds_function_name` | conditional |

---

## 12. Bảng khác biệt có chủ ý so với CFN

| Điểm | CFN gốc | Spec này | Lý do |
|---|---|---|---|
| RDS subnet finder | Lambda custom-resource (`RDSSubnetGroupFinder`) random-pick | `data "aws_db_subnet_groups"` | Bỏ Lambda thừa; data source native hơn |
| IAM role subnet finder | `LambdaSubnetFinderRole` | (bỏ) | Không còn Lambda đó |
| Coordinator invoke validator | function-name hardcode | env var `VALIDATOR_S3/RDS` | Tránh tight-coupling |
| Coordinator `lambda:InvokeFunction` | Resource `*` | giới hạn ARN validator | least-privilege (security.md) |
| IAM policy form | inline JSON | `data.aws_iam_policy_document` | terraform.md |
| Naming | CFN logical IDs cố định | `${var.app_name}-*` | naming convention |
| Vault/plan/test resource | không có (giả định sẵn) | thêm ở Phần B | lab chạy end-to-end |

**Giữ NGUYÊN theo CFN (không đổi):** function names (`RestoreValidationCoordinator`/`S3RestoreValidation`/`RDSRestoreValidation`), plan name `DailyRestorePlan`, selection names, schedule `cron(0 22 ? * * *)`, các window = 4h, selection window 7 ngày, `include_vaults=["*"]`, event pattern dùng `detail.status=COMPLETED` + `restoreTestingPlanArn` prefix, rule S3 `>1` object, rule RDS `available`, `ValidationStatus="SUCCESSFUL"`.

---

## 13. Validation chain (chạy sau khi Claude dựng source)

```bash
cd envs/dev
terraform fmt -recursive
terraform validate
tflint --recursive
checkov -d . --framework terraform --quiet
terraform plan -out=tfplan
terraform apply tfplan
```
