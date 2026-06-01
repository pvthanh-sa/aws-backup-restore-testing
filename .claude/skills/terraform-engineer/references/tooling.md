# Terraform Tooling

## terraform fmt

Auto-format Terraform files to canonical style:
```bash
# Format a single file
terraform fmt main.tf

# Format all files recursively
terraform fmt -recursive

# Check formatting without modifying (CI use)
terraform fmt -check -recursive
```

## terraform validate

Syntax and internal consistency check:
```bash
terraform init -backend=false  # Init without backend for validation
terraform validate
```

## tflint — Linting

### Installation
```bash
# macOS
brew install tflint

# Linux
curl -s https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash
```

### Configuration (`.tflint.hcl`)
```hcl
plugin "aws" {
  enabled = true
  version = "0.33.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

config {
  call_module_type = "local"
}

rule "terraform_naming_convention" {
  enabled = true
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_standard_module_structure" {
  enabled = true
}
```

### Usage
```bash
tflint --init              # Download plugins
tflint                     # Lint current directory
tflint --recursive         # Lint all modules
tflint --format=json       # Machine-readable output
```

## Checkov — Security Scanning

### Installation
```bash
pip install checkov
# or
brew install checkov
```

### Usage
```bash
# Scan current directory
checkov -d .

# Scan specific file
checkov -f main.tf

# Output formats
checkov -d . -o json
checkov -d . -o sarif    # For GitHub Security tab

# Skip specific checks
checkov -d . --skip-check CKV_AWS_144,CKV_AWS_145

# Scan with framework filter
checkov -d . --framework terraform
```

### Common Checks
| Check ID | Description |
|----------|-------------|
| CKV_AWS_144 | S3 bucket cross-region replication |
| CKV_AWS_145 | S3 bucket KMS encryption |
| CKV_AWS_18 | S3 bucket access logging |
| CKV_AWS_19 | S3 bucket encryption at rest |
| CKV_AWS_23 | Security group description |
| CKV_AWS_24 | Security group no unrestricted SSH |
| CKV_AWS_79 | IMDSv2 required on EC2 |
| CKV_AWS_338 | CloudWatch log group retention |

### Inline Suppression
```hcl
resource "aws_s3_bucket" "this" {
  #checkov:skip=CKV_AWS_144: Cross-region replication not needed for this use case
  bucket = var.bucket_name
}
```

## tfsec — Security Scanner (Alternative)

```bash
# Install
brew install tfsec

# Scan
tfsec .
tfsec . --format json
tfsec . --minimum-severity HIGH
```

## terraform-docs — Documentation Generator

### Installation
```bash
brew install terraform-docs
# or
go install github.com/terraform-docs/terraform-docs@latest
```

### Configuration (`.terraform-docs.yml`)
```yaml
formatter: "markdown table"

output:
  file: "README.md"
  mode: inject

content: |-
  {{ .Header }}

  ## Usage

  ```hcl
  module "example" {
    source = "./modules/{{ .Module.Name }}"
  }
  ```

  {{ .Requirements }}
  {{ .Providers }}
  {{ .Inputs }}
  {{ .Outputs }}

sort:
  enabled: true
  by: required
```

### Usage
```bash
# Generate README
terraform-docs markdown table . > README.md

# With config file
terraform-docs .

# Generate for all modules
find modules -name "*.tf" -exec dirname {} \; | sort -u | xargs -I {} terraform-docs {}
```

## Infracost — Cost Estimation

### Installation
```bash
brew install infracost
infracost auth login  # Free tier available
```

### Usage
```bash
# Estimate costs for current plan
infracost breakdown --path .

# Compare costs between branches
infracost diff --path . --compare-to main

# JSON output for CI integration
infracost breakdown --path . --format json > infracost.json

# Multiple projects
infracost breakdown --config-file infracost.yml
```

### CI Integration (GitHub Actions)
```yaml
- name: Infracost
  uses: infracost/actions/setup@v3
  with:
    api-key: ${{ secrets.INFRACOST_API_KEY }}

- name: Generate cost estimate
  run: |
    infracost breakdown --path . --format json --out-file /tmp/infracost.json
    infracost comment github --path /tmp/infracost.json \
      --repo ${{ github.repository }} \
      --pull-request ${{ github.event.pull_request.number }} \
      --github-token ${{ github.token }}
```

## Pre-commit Hooks

### Configuration (`.pre-commit-config.yaml`)
```yaml
repos:
  - repo: https://github.com/antonbabenko/pre-commit-tf
    rev: v1.96.1
    hooks:
      - id: terraform_fmt
      - id: terraform_validate
        args: ['--hook-config=--retry-once-with-cleanup=true']
      - id: terraform_tflint
        args: ['--args=--config=__GIT_WORKING_DIR__/.tflint.hcl']
      - id: terraform_docs
        args: ['--args=--config=.terraform-docs.yml']
      - id: terraform_checkov
        args: ['--args=--quiet']

  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks:
      - id: check-merge-conflict
      - id: end-of-file-fixer
      - id: trailing-whitespace
      - id: detect-private-key
      - id: check-added-large-files
```

### Setup
```bash
# Install pre-commit
pip install pre-commit

# Install hooks
pre-commit install

# Run on all files
pre-commit run --all-files

# Update hook versions
pre-commit autoupdate
```

## Terratest — Infrastructure Testing

### Basic Test (Go)
```go
package test

import (
    "testing"
    "github.com/gruntwork-io/terratest/modules/terraform"
    "github.com/stretchr/testify/assert"
)

func TestVPCModule(t *testing.T) {
    t.Parallel()

    terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
        TerraformDir: "../modules/network",
        Vars: map[string]interface{}{
            "app_name": "test-vpc",
            "vpc_cidr": "10.99.0.0/16",
        },
    })

    defer terraform.Destroy(t, terraformOptions)
    terraform.InitAndApply(t, terraformOptions)

    vpcId := terraform.Output(t, terraformOptions, "vpc_id")
    assert.NotEmpty(t, vpcId)
}
```

## Validation Chain (Recommended Order)

```bash
# 1. Format
terraform fmt -recursive

# 2. Validate
terraform init -backend=false && terraform validate

# 3. Lint
tflint --recursive

# 4. Security scan
checkov -d . --quiet

# 5. Plan
terraform plan -out=tfplan

# 6. Cost estimate (optional)
infracost breakdown --path .
```
