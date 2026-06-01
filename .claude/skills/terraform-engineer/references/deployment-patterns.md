# Deployment Patterns

## 1. Blue-Green Deployment with CodeDeploy

### Terraform Configuration
```hcl
# CodeDeploy Application
resource "aws_codedeploy_app" "this" {
  compute_platform = "ECS"
  name             = var.app_name
}

# Deployment Group
resource "aws_codedeploy_deployment_group" "this" {
  app_name               = aws_codedeploy_app.this.name
  deployment_group_name  = "${var.app_name}-dg"
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"
  service_role_arn       = aws_iam_role.codedeploy.arn

  ecs_service {
    cluster_name = var.ecs_cluster_name
    service_name = var.ecs_service_name
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 5
    }
  }

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [var.listener_arn]
      }
      target_group {
        name = var.target_group_blue_name
      }
      target_group {
        name = var.target_group_green_name
      }
    }
  }
}
```

### AppSpec Template
```yaml
# codedeploy/appspec.yaml.tpl
version: 0.0
Resources:
  - TargetService:
      Type: AWS::ECS::Service
      Properties:
        TaskDefinition: "${task_definition_arn}"
        LoadBalancerInfo:
          ContainerName: "${container_name}"
          ContainerPort: ${container_port}
```

### ECS Service Lifecycle (Critical)
```hcl
resource "aws_ecs_service" "this" {
  # ... other config ...
  
  deployment_controller {
    type = "CODE_DEPLOY"
  }

  # CodeDeploy manages these fields — Terraform must not drift
  lifecycle {
    ignore_changes = [load_balancer, task_definition]
  }
}
```

## 2. Backend Pipeline (Django → ECR → ECS → CodeDeploy)

Pipeline: `CI → Setup → Build & Push → Deploy`

### Job Flow
```
PR opened/sync → CI (lint, type-check, Docker build cache)
PR merged      → CI → Setup (env) → Build (ECR) → Deploy (CodeDeploy blue-green)
Tag push (v*)  → CI → Setup (production) → Build (ECR) → Deploy (CodeDeploy blue-green)
Manual dispatch→ CI → Setup (selected env) → Build (ECR) → Deploy (CodeDeploy blue-green)
```

### Key Patterns from backend.yaml

**OIDC Authentication:**
```yaml
- name: Configure AWS credentials
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/${{ needs.setup.outputs.role_to_assume }}
    aws-region: ${{ vars.AWS_REGION }}
    role-session-name: GitHubActions-Backend-Build-${{ needs.setup.outputs.environment }}
```

**Environment Determination:**
```bash
case "$ENV" in
  "staging")    PREFIX="stg"  ;;
  "demo")       PREFIX="demo" ;;
  "production") PREFIX="prod" ;;
  "develop")    PREFIX="dev"  ;;
esac

echo "ecr_repository=${PREFIX}-app-server" >> $GITHUB_OUTPUT
echo "role_to_assume=${PREFIX}-app-github-oidc-role" >> $GITHUB_OUTPUT
echo "ecs_cluster=${PREFIX}-app-server" >> $GITHUB_OUTPUT
echo "ecs_service=${PREFIX}-app-server-service" >> $GITHUB_OUTPUT
```

**Deploy Flow:**
1. Get latest task definition from family (not service — respects Terraform updates)
2. Login to ECR
3. Update container image in task definition JSON
4. Register new task definition (preserves tags)
5. Download appspec template from S3
6. Update TaskDefinition ARN in appspec
7. Upload updated appspec to S3
8. Create CodeDeploy deployment
9. Wait for deployment to complete (timeout: 25min)

**Secret Masking Pattern:**
```yaml
# ECR Registry contains AWS Account ID — GitHub masks it
# Pass image tag separately, reconstruct URI in deploy job
echo "tag=${SHORT_SHA}" >> "$GITHUB_OUTPUT"  # Not full URI
```

## 3. Frontend Pipeline (Vue → S3 → CloudFront)

Pipeline: `CI → Setup → Build & Deploy`

### Job Flow
```
PR opened/sync → CI (lint)
PR merged      → CI → Setup (env) → Build & Deploy (S3 + CloudFront)
Tag push (v*)  → CI → Setup (production) → Build & Deploy (S3 + CloudFront)
```

### Key Patterns from frontend.yaml

**Build with Environment Variables:**
```yaml
- name: Build Vue application
  run: npm run build
  env:
    NODE_ENV: production
    VITE_BASE_URL_PATIENT: ${{ needs.setup.outputs.vite_base_url_patient }}
    VITE_BASE_URL_CLINIC: ${{ needs.setup.outputs.vite_base_url_clinic }}
    VITE_BASE_SOCKET_URL: ${{ needs.setup.outputs.vite_base_socket_url }}
```

**S3 Deploy + CloudFront Invalidation:**
```yaml
- name: Deploy to S3
  run: |
    aws s3 sync ./dist s3://${{ needs.setup.outputs.s3_bucket }}/ \
      --delete --no-progress

- name: Invalidate CloudFront cache
  run: |
    INVALIDATION_ID=$(aws cloudfront create-invalidation \
      --distribution-id ${{ needs.setup.outputs.cloudfront_id }} \
      --paths "/*" --query 'Invalidation.Id' --output text)
    aws cloudfront wait invalidation-completed \
      --distribution-id ${{ needs.setup.outputs.cloudfront_id }} \
      --id $INVALIDATION_ID
```

## 4. GitHub Actions OIDC (Terraform Module)

### IAM Role Permissions for CI/CD
```hcl
data "aws_iam_policy_document" "github_actions" {
  # ECR: Build and push images
  statement {
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload"
    ]
    resources = ["*"]
  }

  # ECS: Update services, describe tasks, register task definitions
  statement {
    effect = "Allow"
    actions = [
      "ecs:DescribeServices",
      "ecs:DescribeTaskDefinition",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
      "ecs:RegisterTaskDefinition",
      "ecs:UpdateService",
      "ecs:TagResource",
      "ecs:ListTagsForResource"
    ]
    resources = ["*"]
  }

  # CodeDeploy: Create and track deployments
  statement {
    effect = "Allow"
    actions = [
      "codedeploy:CreateDeployment",
      "codedeploy:GetDeployment",
      "codedeploy:GetDeploymentConfig",
      "codedeploy:RegisterApplicationRevision"
    ]
    resources = ["*"]
  }

  # S3: Upload artifacts (appspec, frontend assets)
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.app_name}-*", "arn:aws:s3:::${var.app_name}-*/*"]
  }

  # CloudFront: Create invalidations
  statement {
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
    resources = ["*"]
  }

  # IAM: PassRole for ECS task roles
  statement {
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}
```

## 5. Scheduled ECS Tasks

### EventBridge + ECS Pattern
```hcl
# EventBridge rule
resource "aws_cloudwatch_event_rule" "scheduled_task" {
  name                = "${var.app_name}-schedule"
  schedule_expression = var.schedule_expression  # "cron(0 9 * * ? *)"
}

resource "aws_cloudwatch_event_target" "ecs" {
  rule     = aws_cloudwatch_event_rule.scheduled_task.name
  arn      = var.cluster_arn
  role_arn = aws_iam_role.eventbridge.arn

  ecs_target {
    task_definition_arn = var.task_definition_arn
    launch_type         = "FARGATE"

    network_configuration {
      subnets         = var.subnet_ids
      security_groups = var.security_group_ids
    }
  }
}
```

### Monitoring Pattern
```hcl
# Alert if scheduled task hasn't run (heartbeat)
module "eventbridge_alarm" {
  source       = "../../scheduled_ecs_task_modules/cloudwatch_alarm_eventbridge"
  app_name     = var.app_name
  rule_name    = aws_cloudwatch_event_rule.scheduled_task.name
  alarm_actions = [var.sns_topic_arn]
}

# Alert on task failures (log pattern)
module "ecs_alarm" {
  source         = "../../scheduled_ecs_task_modules/cloudwatch_alarm_ecs_scheduled_task"
  app_name       = var.app_name
  log_group_name = aws_cloudwatch_log_group.task.name
  alarm_actions  = [var.sns_topic_arn]
}
```

## 6. Container Definition Template

### Template File Pattern
```json
// container_definitions/server-task-def.json.tpl
[
  {
    "name": "${container_name}",
    "image": "${ecr_image_uri}",
    "essential": true,
    "portMappings": [
      {
        "containerPort": ${container_port},
        "protocol": "tcp"
      }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/${app_name}",
        "awslogs-region": "${aws_region}",
        "awslogs-stream-prefix": "ecs"
      }
    },
    "environment": [],
    "secrets": []
  }
]
```

### Usage in Task Definition
```hcl
container_definitions = templatefile(
  "${path.module}/container_definitions/server-task-def.json.tpl",
  {
    container_name = var.container_names[0]
    container_port = var.container_port
    app_name       = var.app_name
    aws_region     = var.region
    ecr_image_uri  = var.ecr_image_uri
  }
)
```

## 7. RDS Password Rotation + Deployment Rollout

### Flow
1. Secrets Manager rotates RDS password (Lambda)
2. Rotation success triggers SNS notification
3. Rollout Lambda creates new CodeDeploy deployment with latest appspec
4. ECS tasks restart with new credentials from Secrets Manager

```hcl
module "rds_rotation" {
  source     = "../../modules/rds_secret_rotation"
  app_name   = var.app_name
  secret_arn = module.rds.secret_arn
  # ...
}

module "rotation_rollout" {
  source             = "../../modules/rds_rotation_rollout"
  app_name           = var.app_name
  ecs_cluster        = module.ecs_cluster.cluster_name
  ecs_service        = module.ecs.service_name
  secret_arn         = module.rds.secret_arn
  code_deploy_bucket = var.code_deploy_bucket
}
```

## 8. Concurrency & Safety Patterns

### GitHub Actions Concurrency
```yaml
# CI — safe to cancel on new push
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

# Deploy — never cancel mid-deployment
concurrency:
  group: deploy-${{ needs.setup.outputs.environment }}
  cancel-in-progress: false
```

### GitHub Step Summary
```yaml
- name: Deployment Summary
  if: always()
  run: |
    echo "## Deployment Summary" >> $GITHUB_STEP_SUMMARY
    echo "| Setting | Value |" >> $GITHUB_STEP_SUMMARY
    echo "|---------|-------|" >> $GITHUB_STEP_SUMMARY
    echo "| Environment | \`${{ needs.setup.outputs.environment }}\` |" >> $GITHUB_STEP_SUMMARY
    echo "| Deployment ID | \`${{ steps.create-deployment.outputs.deployment_id }}\` |" >> $GITHUB_STEP_SUMMARY
```
