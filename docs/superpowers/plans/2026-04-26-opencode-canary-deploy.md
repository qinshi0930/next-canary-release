# Opencode Canary Deploy Skill 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 创建一个内联全部配置模板的 opencode skill，实现不依赖 git clone 的从零部署

**Architecture:** 单个自包含 skill (`canary-deploy`) 包含所有文件模板和部署命令序列。使用 `{{PROJECT_PREFIX}}` / `{{EXPOSE_PORT}}` 占位符实现多项目定制。配合 `deployment.md` 人类可读指南。

**Tech Stack:** OpenCode skills system, podman-compose, nginx, Next.js standalone

---

### Task 1: Create Skill Directory and Frontmatter

**Files:**
- Create: `.agents/skills/canary-deploy/SKILL.md`

- [ ] **Step 1: Create directory**

```bash
mkdir -p .agents/skills/canary-deploy
```

- [ ] **Step 2: Write frontmatter and overview**

Write the SKILL.md header with YAML frontmatter (`name`, `description`), overview, prerequisites, and deployment flowchart.

### Task 2: Write Configuration Collection and Secret Generation

- [ ] **Step 3: Write Steps 1-3**

Write the sections for:
1. Gathering configuration (PROJECT_PREFIX, EXPOSE_PORT, dist/ check)
2. Generating random secrets with openssl
3. Creating directory structure (mkdir commands)

### Task 3: Inline Infrastructure Templates

- [ ] **Step 4: Write Step 4 — compose.infra.yml template**

Inline complete `compose.infra.yml` with `{{PROJECT_PREFIX}}` placeholders.

- [ ] **Step 5: Write Step 4 — .env.example and .env.production templates**

Inline `.env.example` structure. Describe `.env.production` generation using generated secrets.

- [ ] **Step 6: Write Step 4 — SQL init script**

Inline `infra/init-db/01-init.sql`.

- [ ] **Step 7: Write Step 5 — infrastructure deployment commands**

Document network creation, compose up, health check wait loop.

### Task 4: Inline Runtime Templates

- [ ] **Step 8: Write Step 6 — Dockerfile**

Inline complete Dockerfile.

- [ ] **Step 9: Write Step 6 — nginx.conf with port variable**

Inline nginx.conf with `{{EXPOSE_PORT}}` placeholder.

- [ ] **Step 10: Write Step 6 — compose.production.yml and compose.canary.yml**

Inline both compose files with `{{PROJECT_PREFIX}}` and `{{EXPOSE_PORT}}` placeholders.

- [ ] **Step 11: Write Step 7 — build and deploy commands**

Document podman build, compose up, health verification.

### Task 5: Inline Traffic Scripts

- [ ] **Step 12: Write Step 8 — canary-weight.sh**

Inline complete weight control script with `{{PROJECT_PREFIX}}` in podman exec target.

- [ ] **Step 13: Write Step 8 — canary-promote.sh**

Inline complete promote script with `{{PROJECT_PREFIX}}` in podman tag.

- [ ] **Step 14: Write Step 8 — canary-rollback.sh**

Inline rollback script (no prefix-sensitive content but include for completeness).

- [ ] **Step 15: Write Step 9 — verification commands**

Document verification: podman ps, curl health, directory listing. Include output summary template.

### Task 6: Write Common Issues

- [ ] **Step 16: Write troubleshooting table**

Cover: network creation conflicts, Postgres startup timeout, 502 errors, DNS resolution, dist/ path issues, container name conflicts.

### Task 7: Create Deployment Guide

**Files:**
- Create: `docs/guide/deployment.md`

- [ ] **Step 17: Write deployment guide**

Human-readable guide with prerequisites, opencode quick start, full manual deployment steps, and troubleshooting.

### Task 8: Verify Traceability

- [ ] **Step 18: Compare skill templates with backup originals**

```bash
diff <(cat backup/2026-04-26-original/compose.infra.yml | sed 's/canary-/{{PROJECT_PREFIX}}-/g') \
     <(sed -n '/^### 4a/,/^### 4b/p' .agents/skills/canary-deploy/SKILL.md | sed -n '/^```yaml/,/^```/p' | head -n -1 | tail -n +2)
```

- [ ] **Step 19: Verify all backup files have corresponding skill templates**

Check: compose.infra.yml, compose.production.yml, compose.canary.yml, nginx/nginx.conf, Dockerfile, .env.example, init-db/01-init.sql, canary-weight.sh, canary-promote.sh, canary-rollback.sh.

### Task 9: Write Plan Record

**Files:**
- Create: `docs/superpowers/plans/2026-04-26-opencode-canary-deploy.md`

- [ ] **Step 20: Write this plan document**

---

## Verification

完成全部任务后运行：

```bash
# 确认 skill 文件存在且格式正确
head -5 .agents/skills/canary-deploy/SKILL.md

# 确认 deployment 指南存在
wc -l docs/guide/deployment.md

# 确认计划记录存在
wc -l docs/superpowers/plans/2026-04-26-opencode-canary-deploy.md
```
