---
name: init-project
description: 'Initialize Claude Code Core for the current project. Analyzes project structure and README (for CI/CD tech), generates CLAUDE.md, selectively copies relevant skills/agents/rules, and creates a project-specific .mcp.json.'
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Bash, Write
argument-hint: '[output-path]'
---

# Init Project — Full Claude Code Core Setup

Initialize Claude Code Core for the current project in 4 phases:

1. Analyze project structure and detect tech stack (including CI/CD from README)
2. Generate a tailored CLAUDE.md
3. Copy **only the relevant** skills, agents, rules, and settings based on what was detected
4. Generate `.mcp.json` with **only the relevant** MCP servers

**Output path for CLAUDE.md:** `$ARGUMENTS` if provided, otherwise auto-detect:

- Use `.claude/CLAUDE.md` if `.claude/` directory exists
- Use `CLAUDE.md` at project root otherwise

---

## Phase 1: Explore Project Structure

```bash
find . -maxdepth 3 -type f \
  ! -path '*/.git/*' ! -path '*/node_modules/*' ! -path '*/.terraform/*' \
  ! -path '*/venv/*' ! -path '*/__pycache__/*' ! -path '*/dist/*' \
  ! -path '*/dist-packages/*' ! -path '*/.next/*' \
  | sort
```

Read the following files to build a complete picture of the project:

- `README.md` — project overview, CI/CD platform, deployment description
- `package.json` / `Pipfile` / `go.mod` / `Cargo.toml` — language/framework/dependencies
- `.env.example` — required environment variables
- `docker-compose.yml` or `docker-compose.yaml` — local dev services

**CI/CD Detection:** Read `README.md` only — do NOT look for `.github/workflows/`. CI/CD files may not exist yet; the README describes the intended CI/CD platform (GitHub Actions, GitLab CI, Jenkins, CircleCI, ArgoCD, etc.).

After reading, build a detection matrix. For each item below, note **yes / no / maybe**:

| Category             | Detected? | Evidence                                  |
| -------------------- | --------- | ----------------------------------------- |
| Terraform            |           | .tf files found?                          |
| Docker               |           | Dockerfile / docker-compose?              |
| Kubernetes / Helm    |           | k8s/ charts/ manifests?                   |
| ECS (AWS)            |           | ecs in terraform or README?               |
| EKS (AWS)            |           | eks in terraform or README?               |
| PostgreSQL / Aurora  |           | db deps, .env vars, terraform?            |
| MySQL                |           |                                           |
| Redis / ElastiCache  |           |                                           |
| Lambda / Serverless  |           |                                           |
| SQS / SNS            |           |                                           |
| Kafka / MSK          |           |                                           |
| Grafana / Prometheus |           |                                           |
| CI/CD platform       |           | GitHub Actions / GitLab / Jenkins / other |
| CLI tool project     |           | entrypoint is a CLI?                      |
| SRE / SLO patterns   |           | SLO, error budget mentioned?              |

---

## Phase 2: Analyze Infrastructure

**Terraform (if detected):**

- Glob `**/*.tf` and `**/*.tfvars`
- Identify: AWS resources used, environments (dirs under `environments/`, `envs/`), modules, backend

**Docker (if detected):**

- Read `Dockerfile*` and `docker-compose*.yml`
- Identify: base images, services, ports, multi-stage structure

**Kubernetes (if detected):**

- Glob `**/*.yaml` in `k8s/`, `kubernetes/`, `helm/`, `charts/`
- Identify: namespaces, resource types, ingress

---

## Phase 3: Generate CLAUDE.md

Write a concise CLAUDE.md (~100-150 lines). **Only include sections that actually apply — omit any section that would be N/A or placeholder-only.**

````markdown
# [Project Name] — Claude Code Guidelines

## Stack

- **Language/Framework:** [detected]
- **Infrastructure:** [Terraform + AWS resources / K8s / etc.]
- **Database:** [PostgreSQL/MySQL/Redis/etc.]
- **CI/CD:** [GitHub Actions / GitLab CI / Jenkins / etc. — from README]

## Essential Commands

```bash
# Local dev
[actual dev command from README or docker-compose]

# Test
[actual test command]

# Build
[actual build command]

# Deploy (if manual step exists)
[actual deploy command]
```
````

## Architecture

[2-5 bullet points — key decisions not obvious from code]

## Environments

| Env | Branch | Deploy Trigger |
| --- | ------ | -------------- |

[fill from README or CI/CD description — omit if unknown]

## Gotchas

[Non-obvious behaviors, known pitfalls — omit if none found]

## Skills Available

[List only the skills that were copied in Phase 4]

````

**Rules:**
- Under 150 lines total
- Do NOT repeat what can be inferred from reading the code
- Write specific, verifiable instructions — not generic advice

---

## Phase 4: Copy Relevant Claude Core Files

Based on the detection matrix from Phase 1, selectively copy **only what's needed**.

```bash
GUIDELINE_CLAUDE="$(dirname "$(dirname "$CLAUDE_SKILL_DIR")")"
mkdir -p .claude/skills .claude/agents .claude/rules
````

### Skills — copy based on detection

```bash
# Always copy (foundation)
cp -r "$GUIDELINE_CLAUDE/skills/init-project"   ".claude/skills/"
cp -r "$GUIDELINE_CLAUDE/skills/devops-engineer" ".claude/skills/"
cp -r "$GUIDELINE_CLAUDE/skills/secure-code-guardian" ".claude/skills/"

# If Terraform detected
cp -r "$GUIDELINE_CLAUDE/skills/terraform-engineer" ".claude/skills/"
cp -r "$GUIDELINE_CLAUDE/skills/cloud-architect"    ".claude/skills/"

# If Kubernetes / Helm detected
cp -r "$GUIDELINE_CLAUDE/skills/kubernetes-specialist" ".claude/skills/"

# If PostgreSQL / Aurora detected
cp -r "$GUIDELINE_CLAUDE/skills/postgres-pro"       ".claude/skills/"
cp -r "$GUIDELINE_CLAUDE/skills/database-optimizer" ".claude/skills/"

# If Grafana / Prometheus / CloudWatch monitoring detected
cp -r "$GUIDELINE_CLAUDE/skills/monitoring-expert" ".claude/skills/"

# If SRE / SLO patterns mentioned in README
cp -r "$GUIDELINE_CLAUDE/skills/sre-engineer" ".claude/skills/"

# If security-sensitive project (IAM complexity, PII, compliance)
cp -r "$GUIDELINE_CLAUDE/skills/security-reviewer" ".claude/skills/"

# If CLI tool project
cp -r "$GUIDELINE_CLAUDE/skills/cli-developer" ".claude/skills/"

# If chaos / resilience testing mentioned
cp -r "$GUIDELINE_CLAUDE/skills/chaos-engineer" ".claude/skills/"
```

### Agents — copy based on detection

```bash
# If Terraform or any IaC detected
cp "$GUIDELINE_CLAUDE/agents/infra-reviewer.md" ".claude/agents/"

# If AWS project (ECS, EKS, RDS, Lambda, etc.)
cp "$GUIDELINE_CLAUDE/agents/cost-optimizer.md"    ".claude/agents/"
cp "$GUIDELINE_CLAUDE/agents/incident-responder.md" ".claude/agents/"

# If security-sensitive (finance, healthcare, PII, compliance requirements)
cp "$GUIDELINE_CLAUDE/agents/security-auditor.md" ".claude/agents/"
```

### Rules — copy based on detection

```bash
# Always copy
cp "$GUIDELINE_CLAUDE/rules/security.md" ".claude/rules/"

# If Terraform detected
cp "$GUIDELINE_CLAUDE/rules/terraform.md" ".claude/rules/"

# If Kubernetes / Helm detected
cp "$GUIDELINE_CLAUDE/rules/kubernetes.md" ".claude/rules/"

# If Docker / docker-compose detected
cp "$GUIDELINE_CLAUDE/rules/docker.md" ".claude/rules/"

# If CI/CD platform mentioned in README
cp "$GUIDELINE_CLAUDE/rules/cicd.md" ".claude/rules/"
```

### Settings — copy if not exists

```bash
[ -f ".claude/settings.json" ] || cp "$GUIDELINE_CLAUDE/settings.json" ".claude/settings.json"
```

---

## Phase 5: Generate .mcp.json

Create `.mcp.json` with **only** the MCP servers that match what was detected in Phase 1–2.
**Skip entirely if `.mcp.json` already exists.**

Use the same detection matrix — no server is added by default. Every server requires a detected reason.

| Condition                                          | Add MCP servers                                 |
| -------------------------------------------------- | ----------------------------------------------- |
| Any AWS service detected (ECS/EKS/RDS/Lambda/etc.) | `aws-api`, `aws-knowledge`, `cloudwatch`, `iam` |
| New project / architecture design phase            | `well-architected`                              |
| Terraform detected                                 | `terraform`, `iac`                              |
| ECS detected                                       | `ecs`                                           |
| EKS / Kubernetes detected                          | `eks`                                           |
| PostgreSQL / Aurora detected                       | `aurora-postgresql`                             |
| MySQL detected                                     | `aurora-mysql`                                  |
| Redis / ElastiCache detected                       | `elasticache`, `elasticache-valkey`             |
| Lambda / Serverless detected                       | `serverless`, `lambda-tool`                     |
| SQS / SNS detected                                 | `sns-sqs`                                       |
| Kafka / MSK detected                               | `msk`                                           |
| GitHub Actions in README                           | `github`                                        |
| GitLab CI in README                                | `gitlab`                                        |
| Jenkins in README                                  | `jenkins`                                       |
| Grafana / Prometheus detected                      | `grafana`                                       |

Build `.mcp.json` using only the selected entries. Reference templates:

```json
{
  "mcpServers": {
    "aws-api": {
      "command": "uvx",
      "args": ["awslabs.aws-api-mcp-server@latest"],
      "env": {
        "AWS_PROFILE": "<your-aws-profile>",
        "AWS_REGION": "<your-aws-region>"
      }
    },
    "aws-knowledge": {
      "type": "http",
      "url": "https://knowledge-mcp.global.api.aws"
    },
    "cloudwatch": {
      "command": "uvx",
      "args": ["awslabs.cloudwatch-mcp-server@latest"],
      "env": {
        "AWS_PROFILE": "<your-aws-profile>",
        "AWS_REGION": "<your-aws-region>"
      }
    },
    "iam": {
      "command": "uvx",
      "args": ["awslabs.iam-mcp-server@latest"],
      "env": {
        "AWS_PROFILE": "<your-aws-profile>",
        "AWS_REGION": "<your-aws-region>"
      }
    },
    "well-architected": {
      "command": "uvx",
      "args": [
        "--from",
        "awslabs.well-architected-security-mcp-server",
        "well-architected-security-mcp-server"
      ],
      "env": {
        "AWS_PROFILE": "<your-aws-profile>",
        "AWS_REGION": "<your-aws-region>"
      }
    },
    "terraform": {
      "command": "docker",
      "args": ["run", "-i", "--rm", "hashicorp/terraform-mcp-server"]
    },
    "iac": {
      "command": "uvx",
      "args": ["awslabs.aws-iac-mcp-server@latest"],
      "env": {
        "AWS_PROFILE": "<your-aws-profile>",
        "AWS_REGION": "<your-aws-region>"
      }
    },
    "ecs": {
      "command": "uvx",
      "args": ["--from", "awslabs-ecs-mcp-server", "ecs-mcp-server"],
      "env": {
        "AWS_PROFILE": "<your-aws-profile>",
        "AWS_REGION": "<your-aws-region>"
      }
    },
    "eks": {
      "command": "uvx",
      "args": ["awslabs.eks-mcp-server@latest"],
      "env": {
        "AWS_PROFILE": "<your-aws-profile>",
        "AWS_REGION": "<your-aws-region>"
      }
    },
    "aurora-postgresql": {
      "command": "uvx",
      "args": ["awslabs.postgres-mcp-server@latest"],
      "env": {
        "AWS_PROFILE": "<your-aws-profile>",
        "AWS_REGION": "<your-aws-region>"
      }
    },
    "aurora-mysql": {
      "command": "uvx",
      "args": ["awslabs.mysql-mcp-server@latest"],
      "env": {
        "AWS_PROFILE": "<your-aws-profile>",
        "AWS_REGION": "<your-aws-region>"
      }
    },
    "elasticache": {
      "command": "uvx",
      "args": ["awslabs.elasticache-mcp-server@latest"],
      "env": {
        "AWS_PROFILE": "<your-aws-profile>",
        "AWS_REGION": "<your-aws-region>"
      }
    },
    "elasticache-valkey": {
      "command": "uvx",
      "args": ["awslabs.valkey-mcp-server@latest"],
      "env": {
        "AWS_PROFILE": "<your-aws-profile>",
        "AWS_REGION": "<your-aws-region>"
      }
    },
    "serverless": {
      "command": "uvx",
      "args": ["awslabs.aws-serverless-mcp-server@latest"],
      "env": {
        "AWS_PROFILE": "<your-aws-profile>",
        "AWS_REGION": "<your-aws-region>"
      }
    },
    "lambda-tool": {
      "command": "uvx",
      "args": ["awslabs.lambda-tool-mcp-server@latest"],
      "env": {
        "AWS_PROFILE": "<your-aws-profile>",
        "AWS_REGION": "<your-aws-region>"
      }
    },
    "sns-sqs": {
      "command": "uvx",
      "args": ["awslabs.amazon-sns-sqs-mcp-server@latest"],
      "env": {
        "AWS_PROFILE": "<your-aws-profile>",
        "AWS_REGION": "<your-aws-region>"
      }
    },
    "msk": {
      "command": "uvx",
      "args": ["awslabs.aws-msk-mcp-server@latest"],
      "env": {
        "AWS_PROFILE": "<your-aws-profile>",
        "AWS_REGION": "<your-aws-region>"
      }
    },
    "github": {
      "command": "docker",
      "args": [
        "run",
        "-i",
        "--rm",
        "-e",
        "GITHUB_PERSONAL_ACCESS_TOKEN",
        "ghcr.io/github/github-mcp-server"
      ],
      "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "<your-github-pat>" }
    },
    "gitlab": { "type": "http", "url": "https://gitlab.com/api/v4/mcp" },
    "jenkins": {
      "type": "http",
      "url": "http://<jenkins-host>/mcp-server/mcp",
      "headers": { "Authorization": "Basic <base64-of-user:api-token>" }
    },
    "grafana": {
      "command": "npx",
      "args": ["-y", "@grafana/mcp-grafana"],
      "env": {
        "GRAFANA_URL": "<your-grafana-url>",
        "GRAFANA_TOKEN": "<your-grafana-api-token>"
      }
    }
  }
}
```

**Add `.mcp.json` to `.gitignore`:**

```bash
grep -q "\.mcp\.json" .gitignore 2>/dev/null || echo ".mcp.json" >> .gitignore
```

---

## Phase 6: Summary

After completing all phases, print a summary:

```
## Claude Code Core Setup Complete

### Detection Results:
[List what was detected — tech stack, CI/CD platform, AWS services]

### Files created:
- [CLAUDE.md path]
- .claude/settings.json
- .claude/skills/  [N skills copied: list them]
- .claude/agents/  [N agents copied: list them]
- .claude/rules/   [N rules copied: list them]
- .mcp.json (gitignored) — [N MCP servers configured]

### Next steps:
1. Fill in placeholders in .mcp.json:
   - <your-aws-profile>  →  e.g., my-project-dev
   - <your-aws-region>   →  e.g., ap-southeast-1
   [list other placeholders relevant to what was included]

2. Review CLAUDE.md — add gotchas, verify commands are correct

3. Commit to git:
   git add CLAUDE.md .claude/
   git commit -m "chore: add Claude Code guidelines"
   # .mcp.json is gitignored — do not commit
```
