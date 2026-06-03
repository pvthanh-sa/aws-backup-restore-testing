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

**Khác biệt có chủ ý so với CFN** (xem bảng cuối file): bỏ Lambda subnet-finder + custom resource → thay bằng **wiring tường minh**: Part B tạo DB subnet group cho test RDS và truyền `name` của nó vào module qua biến `rds_subnet_group_name`. Deterministic, không cần data source list (provider AWS **không có** `aws_db_subnet_groups` số nhiều), không cần Lambda.

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
| `rds_subnet_group_name` | string | `""` | `enable_rds` ⇒ phải non-empty (validation chéo) | tên DB subnet group cho restore-testing RDS; Part B truyền tên subnet group của test RDS vào đây |
| `lambda_log_retention_days` | number | `7` | giá trị CW hợp lệ | log group retention |

---

## 2. Data sources

| Data source | Điều kiện | Mục đích |
|---|---|---|
| `aws_caller_identity.current` | luôn | account_id cho ARN scoping |
| `aws_region.current` | luôn | region cho ARN scoping |
| `aws_partition.current` | luôn | partition cho managed-policy ARN |

> ⚠️ **KHÔNG** dùng data source để auto-pick subnet group: provider AWS chỉ có `aws_db_subnet_group` (số ít, **bắt buộc** `name`), **không có** `aws_db_subnet_groups` (số nhiều, list-all). CFN gốc dùng Lambda `describe_db_subnet_groups` + `random.choice` — vừa thừa vừa non-deterministic. Spec này thay bằng **wiring tường minh**: caller (`envs/dev`) truyền `rds_subnet_group_name` = `name` của DB subnet group mà Part B tạo cho test RDS.
>
> `locals.rds_subnet_group = var.rds_subnet_group_name` (không còn nhánh data source). Module thêm validation: khi `enable_rds == true` thì `rds_subnet_group_name` phải non-empty (precondition trong `lifecycle` hoặc `validation` ở biến).

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
| `restore_metadata_overrides` | `{ dbSubnetGroupName = local.rds_subnet_group }` (= `var.rds_subnet_group_name`) |

> ⚠️ Key override là `dbSubnetGroupName` (camelCase, đúng như CFN `RestoreMetadataOverrides`).
> ℹ️ AWS Backup tự suy luận (infer) phần lớn metadata restore RDS; chỉ cần override field nào mà default không còn hợp lệ. `dbSubnetGroupName` là field hay phải override nhất vì subnet/VPC default có thể đã bị xoá → nếu không có nó, restore job **thất bại**. Đây là lý do bắt buộc wiring subnet group đúng.

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
- `aws_db_subnet_group.test` (count = enable_rds) — tạo trên ≥ 2 subnet (≥ 2 AZ) của VPC test. **`name` của nó được truyền vào module qua `rds_subnet_group_name`** (đây là mắt xích thay cho Lambda subnet-finder của CFN — xem §2).
- `aws_db_instance.test` (count = enable_rds) — `db.t3.micro`, engine `postgres`, `storage_encrypted = true`, `multi_az = false`, `skip_final_snapshot = true`, `db_subnet_group_name = aws_db_subnet_group.test[0].name`, **không** public.

> ⚠️ Cảnh báo: không chạy trong VPC production. Test RDS chỉ phục vụ tạo recovery point.
> 🔗 **Wiring subnet group (quan trọng):** trong `envs/dev/main.tf`, module call truyền `rds_subnet_group_name = aws_db_subnet_group.test[0].name`. Nhờ vậy restore-testing RDS dùng đúng subnet group đang tồn tại → restore job không fail vì thiếu subnet hợp lệ.

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
| RDS subnet finder | Lambda custom-resource (`RDSSubnetGroupFinder`) random-pick | **Wiring tường minh**: Part B tạo `aws_db_subnet_group.test` → truyền `name` vào `rds_subnet_group_name` | Bỏ Lambda thừa + non-deterministic; **không** có data source `aws_db_subnet_groups` số nhiều trong provider → wiring là cách đúng & deterministic |
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

---

## 14. Environments & Naming

| Env | Prefix | Account/Region | Notes |
|---|---|---|---|
| dev (practice) | `restore-lab` | account lab / `ap-southeast-1` | môi trường duy nhất cho bài lab |

- Naming: `${var.app_name}-<resource-type>` (vd `restore-lab-vault`, `restore-lab-test-<suffix>`).
- IAM role names: dùng prefix `${var.app_name}-*` thay cho tên cố định của CFN (`BackupServiceRole`…) → tránh va chạm nếu chạy nhiều lần / nhiều account.
- State: local cho practice. Block S3 backend (`key = "dev/terraform.tfstate"`, `use_lockfile = true`) viết sẵn dạng comment trong `envs/dev/backend.tf`.

---

## 15. Cost estimate (ap-southeast-1, ước tính)

> ⚠️ **Restore testing tốn tiền thật:** mỗi lần validation, AWS Backup **tạo mới một RDS instance được restore** (và bucket S3 restore), giữ trong validation window (4h) rồi xoá. Đây là compute/storage có phí, **ngoài** test RDS chạy 24/7.

| Item | Cấu hình | Cost/tháng (ước tính) |
|---|---|---|
| Test RDS (always-on) | `db.t3.micro` postgres, single-AZ, 20GB gp3 | ~$13–16 |
| RDS restore-testing runs | 1 instance/ngày × ~4h `db.t3.micro` + storage tạm | ~$2–4 |
| Backup storage | vài GB snapshot RDS + S3, retention 2 ngày | ~$1–2 |
| Lambda (3 hàm) | vài invoke/ngày, 128MB/60s | ~$0 (free tier) |
| CloudWatch Logs | retention 7 ngày, ít log | ~$0–1 |
| KMS (`aws/backup` managed) | request-based | ~$0–1 |
| S3 test bucket | vài object + versioning | ~$0 |
| **Tổng** | | **~$17–25/tháng nếu để chạy** |

**Savings levers:** `terraform destroy` ngay sau khi quan sát xong (lab không cần chạy liên tục); `enable_rds=false` để chỉ luyện nhánh S3 (rẻ nhất); rút `selection_window_days`/retention; tắt test RDS khi không dùng.

---

## 16. SLO / RTO / RPO & Lab sequencing

- **Bản chất:** đây là cơ chế **validate khả năng restore** (recovery validation), không phải workload có SLA. Không có SLO uptime.
- **RPO/RTO của bài lab:** không áp dụng (lab). Restore testing chỉ chứng minh recovery point **restore được** và đạt validation rule.
- **⏱️ Lab sequencing (quan trọng — đừng tưởng lỗi):**
  1. `apply` xong → vault/plan/test resource tồn tại, **chưa** có recovery point.
  2. Backup plan Part B chạy theo schedule (`cron(0 1 * * ? *)`) **hoặc** chạy on-demand (`aws backup start-backup-job`) để có recovery point ngay.
  3. Restore-testing plan (`cron(0 22 ? * * *)`) chỉ tìm thấy recovery point khi nó nằm trong `selection_window_days` (7 ngày). → Ngày 0 thường **chưa** có gì để test nếu chưa có backup.
  4. Khi restore job COMPLETED → EventBridge → coordinator → validator → `PutRestoreValidationResult`. Xem kết quả ở AWS Backup console > Restore testing, và CloudWatch Logs của 3 Lambda.
- **Khuyến nghị test nhanh:** chạy on-demand backup job ngay sau apply, rồi trigger/đợi restore testing để rút ngắn vòng phản hồi.

---

## 17. Rollback / Teardown

- **Rollback khi apply lỗi:** `terraform destroy` hoặc revert tfvars rồi `apply` lại — toàn bộ là resource độc lập, không có data quý.
- **Teardown sau lab:**
  ```bash
  cd envs/dev
  terraform destroy
  ```
- **Lưu ý dọn dẹp thủ công (không nằm trong state):**
  - Restored RDS/S3 do restore-testing job tạo ra **tự xoá** sau validation window — nhưng nếu job đang chạy lúc destroy, kiểm tra AWS Backup console còn instance `awsbackup-restore-test-*` sót lại không.
  - Recovery point trong vault: phải hết lifecycle (`delete_after = 2` ngày) hoặc xoá tay trước khi xoá được vault; nếu `destroy` báo vault không rỗng → xoá recovery point rồi destroy lại.
  - CloudWatch log group đã khai báo tường minh nên `destroy` xoá theo; không còn orphan.
  - S3 test bucket có versioning → cần `force_destroy = true` (hoặc empty bucket trước) để destroy sạch.
