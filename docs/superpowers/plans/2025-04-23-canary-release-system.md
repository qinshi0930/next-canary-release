# 灰度发布系统 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 搭建基于 Podman Compose + Nginx 权重路由的灰度发布系统，支持 stable/canary 双版本流量切换、故障自动回切、一键提升/回滚。

**Architecture:** 三个独立 compose 文件（infra/production/canary）通过外部网络 `canary-network` 互通。Nginx 作为流量网关以 weight 权重路由请求，canary 故障时自动回切 stable。Shell 脚本管理权重切换、提升、回滚操作。环境变量统一通过 `--env-file .env.production` 传入，compose 中不设默认值。

**Tech Stack:** Podman Compose, Nginx (alpine), Node.js 22 (alpine), Redis 7 (alpine), Postgres (alpine), Bash

**Spec:** `docs/plans/canary-release-plan.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `compose.infra.yml` | Redis + Postgres 基础设施，命名 volume 持久化，无端口暴露 |
| `compose.production.yml` | Nginx 网关(6080) + stable-app |
| `compose.canary.yml` | canary-app |
| `nginx/nginx.conf` | 权重路由 + 故障转移配置 |
| `infra/init-db/01-init.sql` | Postgres 首次初始化脚本 |
| `scripts/canary-weight.sh` | 动态调整 canary 权重 + nginx reload |
| `scripts/canary-promote.sh` | canary 提升为 stable |
| `scripts/canary-rollback.sh` | canary 回滚 |
| `Dockerfile` | 从 dist/ 构建应用镜像，单行 COPY |
| `.env.example` | 环境变量模板 |
| `.gitignore` | 忽略 dist/ 和 .env.production |

---

### Task 1: Create .gitignore

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Create .gitignore**

```
dist/
.env.production
```

- [ ] **Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: add .gitignore for dist/ and .env.production"
```

---

### Task 2: Create .env.example

**Files:**
- Create: `.env.example`

- [ ] **Step 1: Create .env.example**

```env
# 基础设施
REDIS_PASSWORD=redis123
POSTGRES_PASSWORD=postgres123
POSTGRES_DB=master_db
POSTGRES_USER=xingye

# 应用连接（完整 URL）
NODE_ENV=production
REDIS_URL=redis://:redis123@redis:6379/0
DATABASE_URL=postgresql://xingye:postgres123@postgres:5432/master_db
```

- [ ] **Step 2: Commit**

```bash
git add .env.example
git commit -m "chore: add .env.example template"
```

---

### Task 3: Create compose.infra.yml

**Files:**
- Create: `compose.infra.yml`

- [ ] **Step 1: Create compose.infra.yml**

```yaml
# 基础设施配置 — PostgreSQL + Redis
# 无端口暴露，仅通过 canary-network 内部通信
# 环境变量必须通过 --env-file 传入，不设默认值
# 启动顺序：先启动此文件，再启动 production/canary
# 应用内置重连机制，无需 depends_on 跨文件依赖
services:
  redis:
    image: redis:7-alpine
    container_name: canary-redis
    restart: unless-stopped
    command: redis-server --requirepass ${REDIS_PASSWORD} --appendonly yes
    volumes:
      - canary-redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 10s
    networks:
      - canary-network

  postgres:
    image: postgres:alpine
    container_name: canary-postgres
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - canary-postgres-data:/var/lib/postgresql/data
      - ./infra/init-db:/docker-entrypoint-initdb.d:ro
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    networks:
      - canary-network

volumes:
  canary-redis-data:
    driver: local
  canary-postgres-data:
    driver: local

networks:
  canary-network:
    external: true
```

- [ ] **Step 2: Commit**

```bash
git add compose.infra.yml
git commit -m "feat: add compose.infra.yml for Redis and Postgres"
```

---

### Task 4: Create compose.production.yml

**Files:**
- Create: `compose.production.yml`

- [ ] **Step 1: Create compose.production.yml**

```yaml
# 生产环境 — Nginx 网关 + stable 应用
# 环境变量必须通过 --env-file .env.production 传入
services:
  nginx:
    image: nginx:alpine
    container_name: canary-nginx
    restart: unless-stopped
    ports:
      - "6080:6080"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
    networks:
      - canary-network

  stable-app:
    image: xingye-site:stable
    container_name: canary-stable-app
    restart: unless-stopped
    environment:
      NODE_ENV: production
      HOSTNAME: "0.0.0.0"
      REDIS_URL: ${REDIS_URL}
      DATABASE_URL: ${DATABASE_URL}
    networks:
      - canary-network

networks:
  canary-network:
    external: true
```

- [ ] **Step 2: Commit**

```bash
git add compose.production.yml
git commit -m "feat: add compose.production.yml for Nginx and stable-app"
```

---

### Task 5: Create compose.canary.yml

**Files:**
- Create: `compose.canary.yml`

- [ ] **Step 1: Create compose.canary.yml**

```yaml
# 金丝雀环境 — canary 应用
# Redis 使用 db0，与 stable 共享，确保 session 连续
# 环境变量必须通过 --env-file .env.production 传入
services:
  canary-app:
    image: xingye-site:canary
    container_name: canary-canary-app
    restart: unless-stopped
    environment:
      NODE_ENV: production
      HOSTNAME: "0.0.0.0"
      REDIS_URL: ${REDIS_URL}
      DATABASE_URL: ${DATABASE_URL}
    networks:
      - canary-network

networks:
  canary-network:
    external: true
```

- [ ] **Step 2: Commit**

```bash
git add compose.canary.yml
git commit -m "feat: add compose.canary.yml for canary-app"
```

---

### Task 6: Create nginx/nginx.conf

**Files:**
- Create: `nginx/nginx.conf`

- [ ] **Step 1: Create directory and nginx.conf**

```bash
mkdir -p nginx
```

```nginx
events {
    worker_connections 1024;
}

http {
    # canary 故障转移与权重路由配置
    #
    # 初始状态：upstream 只包含 stable-app，所有流量走 stable
    # 灰度发布时：通过 scripts/canary-weight.sh 添加 canary-app 并设置权重
    # canary 不可用时：max_fails + fail_timeout + proxy_next_upstream 自动回切 stable
    #
    # 注意：canary-app 行由 canary-weight.sh 动态管理，初始不存在
    #       Nginx 不支持 weight=0，所以初始不能包含 canary-app 行

    upstream backend {
        server stable-app:3000;
    }

    server {
        listen 6080;

        location / {
            proxy_pass http://backend;
            proxy_next_upstream error timeout;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            add_header X-Served-By $upstream_addr;
        }

        location /health {
            access_log off;
            return 200 'ok';
            add_header Content-Type text/plain;
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add nginx/nginx.conf
git commit -m "feat: add nginx.conf with weight-based canary routing"
```

---

### Task 7: Create infra/init-db/01-init.sql

**Files:**
- Create: `infra/init-db/01-init.sql`

- [ ] **Step 1: Create directory and init SQL**

```bash
mkdir -p infra/init-db
```

```sql
-- Postgres 初始化脚本
-- 仅在容器首次启动（数据卷为空）时执行
-- 可根据实际需求扩展：创建额外数据库、授权、启用扩展等

-- 启用常用扩展
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 示例：创建额外数据库（主数据库由 POSTGRES_DB 环境变量自动创建）
-- CREATE DATABASE app_sessions;
-- GRANT ALL PRIVILEGES ON DATABASE app_sessions TO xingye;
```

- [ ] **Step 2: Commit**

```bash
git add infra/init-db/01-init.sql
git commit -m "feat: add Postgres initialization script with uuid-ossp extension"
```

---

### Task 8: Create scripts

**Files:**
- Create: `scripts/canary-weight.sh`
- Create: `scripts/canary-promote.sh`
- Create: `scripts/canary-rollback.sh`

- [ ] **Step 1: Create scripts directory**

```bash
mkdir -p scripts
```

- [ ] **Step 2: Create canary-weight.sh**

```bash
#!/bin/bash
# 用法: ./scripts/canary-weight.sh <canary_weight>
# 示例: ./scripts/canary-weight.sh 10   # ~9% 流量到 canary
# 示例: ./scripts/canary-weight.sh 50   # 50/50 均分
# 示例: ./scripts/canary-weight.sh 0    # 停止灰度，移除 canary，全量走 stable
#
# 工作原理：
# - weight=0 时：从 upstream 中删除 canary-app 行
# - weight>0 时：在 upstream 中添加/更新 canary-app 行（含权重和故障转移参数）
# - Nginx 不支持 weight=0，所以初始 upstream 只包含 stable-app

set -euo pipefail

CANARY_WEIGHT="${1:?用法: $0 <canary_weight(0-100)>}"
NGINX_CONF="./nginx/nginx.conf"

if [[ "$CANARY_WEIGHT" -lt 0 || "$CANARY_WEIGHT" -gt 100 ]]; then
    echo "错误: weight 必须在 0-100 之间" >&2
    exit 1
fi

# 移除已有的 canary-app 行（如果存在）
sed -i '/server canary-app:3000/d' "$NGINX_CONF"

if [[ "$CANARY_WEIGHT" -eq 0 ]]; then
    # weight=0：重置 stable 为无权重，移除 canary-app 行
    sed -i "s/server stable-app:3000.*$/server stable-app:3000;/" "$NGINX_CONF"
    echo "canary 已从 upstream 中移除，所有流量走 stable"
else
    STABLE_WEIGHT=$((100 - CANARY_WEIGHT))
    # 更新 stable-app 权重
    sed -i "s/server stable-app:3000.*$/server stable-app:3000 weight=${STABLE_WEIGHT};/" "$NGINX_CONF"
    # 在 stable-app 行后插入 canary-app 行
    sed -i "/server stable-app:3000 weight=${STABLE_WEIGHT};/a\\        server canary-app:3000 weight=${CANARY_WEIGHT} max_fails=3 fail_timeout=30s;" "$NGINX_CONF"
    echo "权重已更新: stable=${STABLE_WEIGHT}% canary=${CANARY_WEIGHT}%"
fi

podman exec canary-nginx nginx -s reload
```

- [ ] **Step 3: Create canary-promote.sh**

```bash
#!/bin/bash
# 用法: ./scripts/canary-promote.sh
# 将 canary 镜像标记为 stable，重启生产环境
#
# 执行顺序：
# 1. 先移除 canary-app 行并 reload nginx（避免后续 nginx 重启时 DNS 解析失败）
# 2. 停止 canary 容器
# 3. 将 canary 镜像标记为 stable 并重启生产环境

set -euo pipefail

echo "重置权重为 100/0（移除 canary-app 行）..."
./scripts/canary-weight.sh 0

echo "停止金丝雀环境..."
podman-compose --env-file .env.production -f compose.canary.yml down

echo "将 canary 提升为 stable..."
podman tag xingye-site:canary xingye-site:stable
podman-compose --env-file .env.production -f compose.production.yml up -d

echo "金丝雀已提升为稳定版，流量已全量切换"
```

- [ ] **Step 4: Create canary-rollback.sh**

```bash
#!/bin/bash
# 用法: ./scripts/canary-rollback.sh
# 停止金丝雀，流量全回 stable
#
# 执行顺序：
# 1. 先移除 canary-app 行并 reload nginx（确保流量切回 stable）
# 2. 再停止 canary 容器（避免 nginx 保留对已停止容器的引用）

set -euo pipefail

echo "重置权重为 100/0（移除 canary-app 行）..."
./scripts/canary-weight.sh 0

echo "停止金丝雀环境..."
podman-compose --env-file .env.production -f compose.canary.yml down

echo "金丝雀已回滚，流量已全量回 stable"
```

- [ ] **Step 5: Make scripts executable**

```bash
chmod +x scripts/canary-weight.sh scripts/canary-promote.sh scripts/canary-rollback.sh
```

- [ ] **Step 6: Commit**

```bash
git add scripts/
git commit -m "feat: add canary weight management, promote, and rollback scripts"
```

---

### Task 9: Create Dockerfile

**Files:**
- Create: `Dockerfile`

- [ ] **Step 1: Create Dockerfile**

```dockerfile
FROM node:22-alpine
ENV NODE_ENV=production

RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs

WORKDIR /app

COPY dist/ ./

RUN mkdir -p apps/app/.next/cache && chown nextjs:nodejs apps/app/.next/cache

USER nextjs

EXPOSE 3000
ENV PORT=3000

CMD ["node", "apps/app/server.js"]
```

- [ ] **Step 2: Commit**

```bash
git add Dockerfile
git commit -m "feat: add Dockerfile with single COPY from dist/"
```

---

### Task 10: Reorganize directories

**Files:**
- Move: `preview/` → `dist/`
- Delete: `production/`
- Delete: `podman-compose.infra.yml` (old infra compose at project root)
- Delete: `preview/podman-compose.yml` and `preview/Dockerfile` (moved/replaced)

- [ ] **Step 1: Rename preview/ to dist/**

```bash
mv preview dist
```

- [ ] **Step 2: Remove old preview compose and Dockerfile (now in dist/)**

```bash
rm -f dist/podman-compose.yml dist/Dockerfile
```

- [ ] **Step 3: Delete production/ directory**

```bash
rm -rf production
```

- [ ] **Step 4: Delete old root-level infra compose**

```bash
rm -f podman-compose.infra.yml
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: rename preview/ to dist/, remove obsolete files"
```

---

### Task 11: Create .env.production for local testing

**Files:**
- Create: `.env.production` (gitignored, for local verification)

- [ ] **Step 1: Copy .env.example to .env.production**

```bash
cp .env.example .env.production
```

---

### Task 12: Delete compose.infra.yml created earlier

The `compose.infra.yml` was already created at the project root during brainstorming. Verify it matches the spec and hasn't diverged.

- [ ] **Step 1: Verify compose.infra.yml matches spec**

Read `compose.infra.yml` and compare with the content in Task 3. If it already matches, no action needed.

- [ ] **Step 2: If content differs, overwrite with spec content**

If the file differs from the Task 3 content, rewrite it to match.

---

### Task 13: Create canary-network and verify stack startup

This task verifies the entire system by starting all services.

**Prerequisites:** `podman` and `podman-compose` must be available. The `dist/` directory must contain build artifacts (or the image `xingye-site:stable`/`xingye-site:canary` must be available).

- [ ] **Step 1: Create the external network**

```bash
podman network create canary-network
```

- [ ] **Step 2: Start infrastructure**

```bash
podman-compose --env-file .env.production -f compose.infra.yml up -d
```

- [ ] **Step 3: Verify Redis and Postgres are healthy**

```bash
podman ps
podman exec canary-redis redis-cli -a redis123 ping
podman exec canary-postgres pg_isready -U xingye -d master_db
```

- [ ] **Step 4: Commit all remaining changes if any**

```bash
git add -A
git commit -m "chore: finalize canary release system setup"
```