# GitHub Actions CI/CD Patterns

## Pipeline Architecture

### Backend Pipeline (Django → ECR → ECS → CodeDeploy)
```
CI (lint, type-check, Docker cache) → Setup (environment) → Build & Push (ECR) → Deploy (CodeDeploy blue-green)
```

### Frontend Pipeline (Vue/React → S3 → CloudFront)
```
CI (lint, type-check) → Setup (environment) → Build & Deploy (S3 sync + CloudFront invalidation)
```

## Trigger Strategy

```yaml
on:
  # CI: Run on PR opened/updated
  pull_request:
    branches: [develop, demo, staging]
    types: [opened, synchronize, reopened, closed]

  # CD: Automatic deployment on tag push (Production)
  push:
    tags: ['v*']

  # CD: Manual deployment (non-prod only)
  workflow_dispatch:
    inputs:
      environment:
        type: choice
        options: [develop, demo, staging]
```

### When Each Job Runs
| Trigger | CI | CD (Setup → Build → Deploy) |
|---------|----|-----------------------------|
| PR opened/sync/reopen | Yes | No |
| PR merged to branch | Yes | Yes → target branch env |
| Tag push (v*) | Yes | Yes → production |
| workflow_dispatch | Yes | Yes → selected env |
| PR closed (no merge) | No | No |

### If Conditions
```yaml
# CI: Run unless PR closed without merge
if: |
  (github.event_name == 'pull_request' && github.event.action != 'closed') ||
  (github.event_name == 'pull_request' && github.event.pull_request.merged == true) ||
  github.event_name == 'workflow_dispatch' ||
  (github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v'))

# CD: Only on merge/dispatch/tag
if: |
  (github.event_name == 'pull_request' && github.event.pull_request.merged == true) ||
  github.event_name == 'workflow_dispatch' ||
  (github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v'))
```

## OIDC Authentication

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - name: Configure AWS credentials
    uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/${{ needs.setup.outputs.role_to_assume }}
      aws-region: ${{ vars.AWS_REGION }}
      role-session-name: GitHubActions-${{ needs.setup.outputs.environment }}
```

### Security Setup
- `AWS_ACCOUNT_ID` → GitHub Environment **Secret** (encrypted, hidden in logs)
- `AWS_REGION` → GitHub Environment **Variable** (plain text, visible)
- Each environment (develop, demo, staging, production) has its own secrets/variables
- Add protection rules (approvals) for staging and production

## Environment Determination

```yaml
- name: Determine environment
  id: env
  run: |
    if [[ "${{ github.event_name }}" == "push" && "${{ github.ref }}" == refs/tags/v* ]]; then
      ENV="production"
    elif [[ "${{ github.event_name }}" == "workflow_dispatch" ]]; then
      ENV="${{ github.event.inputs.environment }}"
    elif [[ "${{ github.event.pull_request.base.ref }}" == "staging" ]]; then
      ENV="staging"
    elif [[ "${{ github.event.pull_request.base.ref }}" == "demo" ]]; then
      ENV="demo"
    else
      ENV="develop"
    fi

    case "$ENV" in
      "staging")    PREFIX="stg"  ;;
      "demo")       PREFIX="demo" ;;
      "production") PREFIX="prod" ;;
      "develop")    PREFIX="dev"  ;;
    esac

    echo "environment=$ENV" >> $GITHUB_OUTPUT
    echo "ecr_repository=${PREFIX}-app-server" >> $GITHUB_OUTPUT
    echo "role_to_assume=${PREFIX}-app-github-oidc-role" >> $GITHUB_OUTPUT
    echo "ecs_cluster=${PREFIX}-app-server" >> $GITHUB_OUTPUT
    echo "ecs_service=${PREFIX}-app-server-service" >> $GITHUB_OUTPUT
```

## Backend Deploy Pattern

### Build & Push to ECR
```yaml
- name: Login to ECR
  id: login-ecr
  uses: aws-actions/amazon-ecr-login@v2

- name: Build and push
  env:
    ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
    ECR_REPOSITORY: ${{ needs.setup.outputs.ecr_repository }}
  run: |
    SHORT_SHA=$(echo ${{ github.sha }} | cut -c1-7)
    docker buildx build \
      --cache-from=type=local,src=/tmp/.buildx-cache \
      --cache-to=type=local,dest=/tmp/.buildx-cache-new,mode=max \
      --push --platform linux/amd64 \
      -t "${ECR_REGISTRY}/${ECR_REPOSITORY}:${SHORT_SHA}" \
      -t "${ECR_REGISTRY}/${ECR_REPOSITORY}:latest" .
    # Output only tag (not full URI) to avoid secret masking
    echo "tag=${SHORT_SHA}" >> "$GITHUB_OUTPUT"
```

### Deploy via CodeDeploy
```yaml
- name: Get & update task definition
  run: |
    # Get latest task def from family (respects Terraform updates)
    aws ecs describe-task-definition --task-definition $FAMILY > task-def.json
    
    # Update image, strip non-registrable fields
    jq --arg IMAGE "$NEW_IMAGE" '
      .containerDefinitions[0].image = $IMAGE |
      del(.taskDefinitionArn, .revision, .status, .requiresAttributes,
          .compatibilities, .registeredAt, .registeredBy)
    ' task-def.json > new-task-def.json
    
    # Register new task definition
    NEW_ARN=$(aws ecs register-task-definition \
      --cli-input-json file://new-task-def.json \
      --query 'taskDefinition.taskDefinitionArn' --output text)

- name: Create CodeDeploy deployment
  run: |
    DEPLOYMENT_ID=$(aws deploy create-deployment \
      --application-name $APP_NAME \
      --deployment-group-name $DG_NAME \
      --s3-location bucket=$BUCKET,key=appspec-${SHA}.yaml,bundleType=yaml \
      --deployment-config-name CodeDeployDefault.ECSAllAtOnce \
      --query "deploymentId" --output text)
```

## Frontend Deploy Pattern

```yaml
- name: Build
  run: npm run build
  env:
    NODE_ENV: production
    VITE_BASE_URL: ${{ needs.setup.outputs.api_url }}

- name: Deploy to S3
  run: aws s3 sync ./dist s3://${{ needs.setup.outputs.s3_bucket }}/ --delete

- name: Invalidate CloudFront
  run: |
    ID=$(aws cloudfront create-invalidation \
      --distribution-id ${{ needs.setup.outputs.cloudfront_id }} \
      --paths "/*" --query 'Invalidation.Id' --output text)
    aws cloudfront wait invalidation-completed \
      --distribution-id ${{ needs.setup.outputs.cloudfront_id }} --id $ID
```

## Concurrency Groups

```yaml
# CI — safe to cancel when new code pushed
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

# Deploy — never cancel mid-deployment
concurrency:
  group: deploy-${{ needs.setup.outputs.environment }}
  cancel-in-progress: false
```

## Docker Layer Caching

```yaml
# CI job: build and cache layers
- uses: actions/cache@v4
  with:
    path: /tmp/.buildx-cache
    key: ${{ runner.os }}-docker-${{ hashFiles('**/Pipfile.lock') }}
    restore-keys: ${{ runner.os }}-docker-

- run: |
    docker buildx build \
      --cache-from=type=local,src=/tmp/.buildx-cache \
      --cache-to=type=local,dest=/tmp/.buildx-cache-new,mode=max \
      --load -t app:test .
    rm -rf /tmp/.buildx-cache && mv /tmp/.buildx-cache-new /tmp/.buildx-cache
```

## GitHub Step Summary

```yaml
- name: Summary
  if: always()
  run: |
    echo "## Deployment Summary" >> $GITHUB_STEP_SUMMARY
    echo "| Setting | Value |" >> $GITHUB_STEP_SUMMARY
    echo "|---------|-------|" >> $GITHUB_STEP_SUMMARY
    echo "| Environment | \`$ENV\` |" >> $GITHUB_STEP_SUMMARY
    echo "| Image Tag | \`$TAG\` |" >> $GITHUB_STEP_SUMMARY
    echo "| Status | ${{ job.status }} |" >> $GITHUB_STEP_SUMMARY
```

## Workflow Template Checklist

When creating a new CI/CD workflow:
- [ ] OIDC auth (never long-lived keys)
- [ ] GitHub Environments for secrets
- [ ] Concurrency groups (cancel CI, protect deploy)
- [ ] Proper if conditions for CI vs CD
- [ ] Tag push → production only
- [ ] workflow_dispatch → non-prod only
- [ ] Docker layer caching
- [ ] Pin action versions (@v4)
- [ ] Step Summary for logging
- [ ] Timeout on deploy wait steps
- [ ] Environment-specific variables via setup job outputs
