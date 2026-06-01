# Module Inventory

Reference: `custom-infrastructure/modules/` (32 modules) + `scheduled_ecs_task_modules/` (4 modules)

---

## 1. Network & Connectivity

### network
**Purpose:** VPC with multi-tier subnets, NAT gateways, route tables, and VPC endpoints.
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `vpc_cidr`, `azs`, `public_subnets`, `private_subnets`, `database_subnets`, `elasticache_subnets`, `intra_subnets` | `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `database_subnet_ids`, `nat_gateway_ips` |
| `single_nat_gateway`, `one_nat_gateway_per_az`, `enable_dns_hostnames` | `elasticache_subnet_ids`, `intra_subnet_ids`, `default_security_group_id` |

```hcl
module "network" {
  source           = "../../modules/network"
  app_name         = var.app_name
  vpc_cidr         = "10.22.0.0/16"
  azs_name         = ["a", "c", "d"]
  aws_region       = var.region
  public_subnets   = ["10.22.1.0/24", "10.22.2.0/24", "10.22.3.0/24"]
  private_subnets  = ["10.22.11.0/24", "10.22.12.0/24", "10.22.13.0/24"]
  database_subnets = ["10.22.21.0/24", "10.22.22.0/24", "10.22.23.0/24"]
  single_nat_gateway = true
  tags             = local.tags
}
```

### vpc-endpoints-network
**Purpose:** VPC endpoints for private subnet access to AWS services (S3, DynamoDB, Secrets Manager, ECR, CloudWatch).
| Key Inputs | Key Outputs |
|------------|-------------|
| `vpc_id`, `private_subnet_ids`, `region` | `endpoint_ids` |

### bastion_host
**Purpose:** EC2 bastion host for secure SSH/SSM access to private resources.
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `vpc_id`, `subnet_id`, `key_name`, `instance_type` | `instance_id`, `public_ip`, `security_group_id` |

### client_VPN_endpoints
**Purpose:** AWS Client VPN for remote access to VPC resources.
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `vpc_id`, `subnet_ids`, `server_cert_arn`, `client_cidr` | `vpn_endpoint_id` |

---

## 2. Load Balancing & CDN

### alb
**Purpose:** Application Load Balancer with security groups, listeners, target groups (supports blue-green).
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `vpc_id`, `subnet_ids`, `certificate_arn` | `alb_arn`, `alb_arn_suffix`, `alb_dns_name` |
| `container_port`, `health_check_path`, `allow_cloudfront_prefix_list` | `target_group_blue_arn`, `target_group_green_arn`, `security_group_id` |
| `load_balancer_type` (validates: "alb" or "nlb") | `listener_arn` |

### nlb
**Purpose:** Network Load Balancer for TCP/UDP workloads.
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `vpc_id`, `subnet_ids`, `container_port` | `nlb_arn`, `nlb_dns_name`, `target_group_arn` |

### cloudfront
**Purpose:** CloudFront distribution with custom origins, OAC, CloudFront functions (SPA routing, basic auth).
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `origin_domain`, `acm_certificate_arn` (us-east-1) | `distribution_id`, `distribution_domain_name` |
| `s3_origin_id`, `enable_spa_routing`, `enable_basic_auth` | `distribution_arn` |
| `custom_error_responses`, `price_class` | |

### acm
**Purpose:** ACM certificate with DNS validation via Route53.
| Key Inputs | Key Outputs |
|------------|-------------|
| `domain_name`, `zone_id`, `subject_alternative_names` | `certificate_arn`, `domain_validation_options` |
| `create_certificate` (conditional) | |

### internal_acm
**Purpose:** ACM certificate for internal/private domains.
| Key Inputs | Key Outputs |
|------------|-------------|
| `domain_name`, `zone_id` | `certificate_arn` |

---

## 3. Container & Compute

### ecs_cluster
**Purpose:** ECS cluster setup (Fargate or EC2 capacity providers).
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `tags` | `cluster_id`, `cluster_arn`, `cluster_name` |

### ecs
**Purpose:** ECS service with task definition, load balancer integration, and CodeDeploy blue-green support.
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `cluster_id`, `vpc_id`, `subnet_ids` | `service_name`, `task_definition_arn` |
| `container_port`, `container_names`, `ecr_image_uri` | `security_group_id`, `task_role_arn` |
| `target_group_blue_arn`, `target_group_green_arn` | `execution_role_arn`, `log_group_name` |
| `cpu`, `memory`, `desired_count`, `load_balancer_type` | |
| `region`, `environment_variables`, `secrets` | |

Key patterns:
- `deployment_controller { type = "CODE_DEPLOY" }` for blue-green
- `lifecycle { ignore_changes = [load_balancer, task_definition] }` when CodeDeploy manages
- Container definitions via `templatefile()` from `.json.tpl` files

### ecs_server(sample)
**Purpose:** Sample ECS server configuration for reference.

### ecr_private_registry
**Purpose:** ECR repository with lifecycle policies for image retention.
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `image_tag_mutability`, `max_image_count` | `repository_url`, `repository_arn` |

---

## 4. Database

### rds
**Purpose:** RDS Aurora cluster (PostgreSQL/MySQL) with optional Global Database, enhanced monitoring, parameter groups.
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `vpc_id`, `database_subnet_ids`, `engine` | `cluster_endpoint`, `reader_endpoint`, `cluster_id` |
| `engine_version`, `instance_class`, `instance_count` | `port`, `security_group_id`, `secret_arn` |
| `master_username`, `database_name` | `cluster_arn` |
| `setup_globaldb`, `setup_as_secondary`, `monitoring_interval` | |
| `allowed_security_groups`, `tags` | |

### rds_secret_rotation
**Purpose:** Automatic RDS password rotation via Secrets Manager and Lambda.
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `secret_arn`, `rotation_days` | `rotation_lambda_arn` |
| `rds_cluster_id`, `vpc_id`, `subnet_ids` | |

### rds_rotation_rollout
**Purpose:** Rollout strategy for database credential rotation (triggers ECS redeployment after rotation).
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `ecs_cluster`, `ecs_service` | `lambda_arn` |
| `secret_arn`, `code_deploy_bucket` | |

---

## 5. Caching

### elasticache_server_based
**Purpose:** ElastiCache cluster (Redis or Memcached) with server-based instances.
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `vpc_id`, `subnet_ids`, `engine` | `endpoint`, `port`, `security_group_id` |
| `node_type`, `num_cache_nodes` | |

### elasticache_serverless
**Purpose:** ElastiCache Serverless with Valkey engine, auto-scaling, daily snapshots.
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `vpc_id`, `subnet_ids` | `endpoint`, `security_group_id` |
| `snapshot_retention_limit` | |

### cloudwatch_alarm_elasticache_server_based
**Purpose:** CloudWatch alarms for ElastiCache metrics (CPU, memory, evictions).
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `cluster_id`, `alarm_actions` | `alarm_arns` |

---

## 6. Security & IAM

### iam_role
**Purpose:** Reusable IAM role module with policy attachments.
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `role_name_suffix`, `service_principals` | `role_arn`, `role_name`, `role_id` |
| `policy_arns_map`, `inline_policy`, `tags` | |

```hcl
module "ecs_task_role" {
  source             = "../../modules/iam_role"
  app_name           = var.app_name
  role_name_suffix   = "ecs-task-role"
  service_principals = ["ecs-tasks.amazonaws.com"]
  policy_arns_map    = { s3 = aws_iam_policy.s3_access.arn }
  tags               = local.tags
}
```

### aws_oidc_with_github_actions
**Purpose:** GitHub Actions OIDC provider + IAM role for CI/CD (ECR push, ECS deploy, CodeDeploy, S3, CloudFront).
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `github_org`, `github_repo` | `role_arn`, `oidc_provider_arn` |

### waf_standard
**Purpose:** WAFv2 with service-type presets (CloudFront, ALB, API Gateway, AppSync, Cognito, App Runner).
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `service_type`, `resource_arn` | `web_acl_arn`, `web_acl_id` |
| `rate_limit_override`, `tags` | |

Service presets configure rate limits and managed rule groups automatically based on `service_type`.

### waf_monitoring
**Purpose:** WAF metrics, dashboards, and alerting.
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `web_acl_name`, `alarm_actions` | `alarm_arns` |

---

## 7. Storage

### s3_frontend
**Purpose:** S3 bucket for frontend hosting with CloudFront OAC integration and optional CloudFront functions.
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `cloudfront_distribution_arn` | `bucket_id`, `bucket_arn`, `bucket_domain_name` |
| `enable_versioning` | |

### s3_backend_storage
**Purpose:** S3 bucket for backend application storage (uploads, attachments, etc.).
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `tags` | `bucket_id`, `bucket_arn` |

### s3_api_assets
**Purpose:** S3 bucket for API static assets.
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `tags` | `bucket_id`, `bucket_arn` |

---

## 8. Messaging & Notifications

### ses
**Purpose:** AWS SES for email sending with SMTP user and domain identity.
| Key Inputs | Key Outputs |
|------------|-------------|
| `domain`, `email_identities` | `smtp_username`, `smtp_password` |
| `zone_id` | `domain_identity_arn` |

### alert_email
**Purpose:** SNS topic for email-based alerts.
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `email_addresses` | `topic_arn` |

### chatbot_slack
**Purpose:** AWS Chatbot integration for Slack notifications.
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `slack_channel_id`, `slack_workspace_id` | `chatbot_arn` |
| `sns_topic_arns` | |

---

## 9. Monitoring

### cloudwatch_alarm_ecs
**Purpose:** CloudWatch alarms for ECS service (CPU, memory, error patterns in logs).
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `cluster_name`, `service_name` | `alarm_arns` |
| `log_group_name`, `alarm_actions` | |

Monitors: CPU utilization, memory utilization, log pattern matching (ERROR, CRITICAL, Exception).

### cloudwatch_alarm_rds_instance
**Purpose:** CloudWatch alarms for RDS (CPU, connections, storage, replication lag).
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `db_cluster_identifier`, `alarm_actions` | `alarm_arns` |

---

## 10. Deployment

### codedeploy
**Purpose:** AWS CodeDeploy application and deployment group for ECS blue-green deployments.
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `ecs_cluster_name`, `ecs_service_name` | `app_name`, `deployment_group_name` |
| `listener_arn`, `target_group_blue_name`, `target_group_green_name` | `codedeploy_role_arn` |
| `appspec_template_vars` | |

---

## 11. Scheduled Tasks (`scheduled_ecs_task_modules/`)

### ecs_scheduled_task
**Purpose:** ECS Fargate task definition and cluster for scheduled/one-off tasks.
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `ecr_image_uri`, `cpu`, `memory` | `cluster_arn`, `task_definition_arn` |
| `environment_variables`, `secrets`, `region` | `task_role_arn`, `execution_role_arn` |

### scheduled_task_eventbridge
**Purpose:** EventBridge rule for scheduling ECS tasks on cron expressions.
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `schedule_expression`, `cluster_arn` | `rule_arn` |
| `task_definition_arn`, `subnet_ids`, `security_group_ids` | |

### cloudwatch_alarm_ecs_scheduled_task
**Purpose:** Monitoring for scheduled ECS task failures (log pattern matching).
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `log_group_name`, `alarm_actions` | `alarm_arns` |

### cloudwatch_alarm_eventbridge
**Purpose:** EventBridge invocation monitoring (heartbeat — alert if task doesn't run).
| Key Inputs | Key Outputs |
|------------|-------------|
| `app_name`, `rule_name`, `alarm_actions` | `alarm_arns` |

---

## Common Module Composition Pattern

```hcl
# environments/tokyo-staging/main.tf

module "network"    { source = "../../modules/network" ... }
module "alb"        { source = "../../modules/alb"
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.public_subnet_ids
  ...
}
module "ecs_cluster" { source = "../../modules/ecs_cluster" ... }
module "ecs"         { source = "../../modules/ecs"
  cluster_id           = module.ecs_cluster.cluster_id
  vpc_id               = module.network.vpc_id
  subnet_ids           = module.network.private_subnet_ids
  target_group_blue_arn  = module.alb.target_group_blue_arn
  target_group_green_arn = module.alb.target_group_green_arn
  ...
}
module "rds"         { source = "../../modules/rds"
  vpc_id              = module.network.vpc_id
  database_subnet_ids = module.network.database_subnet_ids
  allowed_security_groups = { ecs = module.ecs.security_group_id }
  ...
}
module "codedeploy"  { source = "../../modules/codedeploy"
  ecs_cluster_name         = module.ecs_cluster.cluster_name
  ecs_service_name         = module.ecs.service_name
  listener_arn             = module.alb.listener_arn
  target_group_blue_name   = module.alb.target_group_blue_name
  target_group_green_name  = module.alb.target_group_green_name
  ...
}
```
