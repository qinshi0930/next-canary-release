# 灰度发布系统 — 实施计划

## 设计决策汇总

| 决策项 | 选择 |
|---|---|
| 网络方案 | 外部网络 `canary-network` |
| 路由策略 | 权重路由（Nginx weight） |
| 基础设施共享 | 共用一套，**不暴露端口到宿主机** |
| Nginx 位置 | production compose 中 |
| Postgres 初始化 | 挂载 `infra/init-db/` 到 `/docker-entrypoint-initdb.d/`，支持自定义初始化脚本 |
| Redis 数据库 | canary 与 stable 共用 db0（确保 session 连续） |
| Redis 持久化 | AOF 持久化（`appendonly yes`） |
| Postgres 持久化 | 命名 volume `canary-postgres-data` |
| Redis 持久化存储 | 命名 volume `canary-redis-data` |
| Nginx 监听端口 | 6080（避免与顶层 Nginx 80 端口冲突） |
| 环境变量管理 | 统一放 `.env.production`，所有 compose 通过 `--env-file` 传入，不设默认值 |
| 跨文件依赖 | 去掉 `depends_on` 跨文件引用，依赖应用重连 + `restart: unless-stopped` 自愈 |
| Canary 故障转移 | Nginx `max_fails` + `fail_timeout` + `proxy_next_upstream`，自动将流量回切 stable |
| Canary 初始权重 | upstream 初始不含 canary-app 行（Nginx 不支持 weight=0），通过脚本动态添加/移除 |
| 应用绑定地址 | compose 中设置 `HOSTNAME=0.0.0.0`，确保 Next.js 监听所有接口 |
| 脚本执行顺序 | 先 weight=0 移除 canary 行 + reload nginx，再 down canary 容器，避免 DNS 解析失败 |
| 启动顺序 | 硬扛，应用内置重连机制（postgres.js 自动重连、ioredis 指数退避重试） |

## 最终目录结构

```
canary-release-demo/
├── compose.infra.yml          # 基础设施（PostgreSQL + Redis，无端口暴露）
├── compose.production.yml     # 生产环境（Nginx + stable-app）
├── compose.canary.yml         # 金丝雀环境（canary-app）
├── nginx/
│   └── nginx.conf             # 权重路由配置 + 故障转移
├── infra/
│   └── init-db/
│       └── 01-init.sql        # Postgres 初始化脚本
├── scripts/
│   ├── canary-weight.sh       # 灰度权重管理
│   ├── canary-promote.sh      # 金丝雀提升为稳定版
│   └── canary-rollback.sh     # 金丝雀回滚
├── dist/                      # 构建产物（由外部上传，目录结构与容器 /app/ 一致）
│   └── apps/app/...
├── Dockerfile                 # 构建 dist/ 产物为容器镜像
├── .env.example               # 环境变量模板
├── .env.production            # 实际环境变量（git ignored）
└── backup/
```

## 变更清单

| # | 操作 | 文件 |
|---|---|---|
| 1 | **创建** | `compose.infra.yml` — Redis(AOF) + Postgres(命名 volume + init-db)，无端口映射，无默认值 |
| 2 | **创建** | `compose.production.yml` — Nginx(6080) + stable-app，无 env_file，通过 --env-file 传入 |
| 3 | **创建** | `compose.canary.yml` — canary-app，无 env_file，通过 --env-file 传入 |
| 4 | **创建** | `nginx/nginx.conf` — upstream 仅含 stable-app（canary 行由脚本动态管理）|
| 5 | **创建** | `infra/init-db/01-init.sql` — Postgres 初始化脚本 |
| 6 | **创建** | `scripts/canary-weight.sh` — 灰度权重管理 |
| 7 | **创建** | `scripts/canary-weight.sh` — 灰度权重管理（动态添加/移除 canary-app 行）|
| 8 | **创建** | `scripts/canary-promote.sh` — 金丝雀提升为稳定版 |
| 9 | **创建** | `scripts/canary-rollback.sh` — 金丝雀回滚 |
| 10 | **移动+重命名** | `preview/` → `dist/`（构建产物目录） |
| 10 | **删除** | `production/`（空目录，已无用） |
| 11 | **创建** | `.env.example` + `.env.production` |
| 12 | **更新** | `.gitignore` — 添加 `.env.production` 和 `dist/` |
| 13 | **简化** | `Dockerfile` — `COPY dist/ ./` 单行复制 |
| 14 | **删除** | `podman-compose.infra.yml` |

## compose.infra.yml

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

## compose.production.yml

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

## compose.canary.yml

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

## nginx/nginx.conf

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

## Dockerfile

位于根目录，`dist/` 由外部上传，目录布局需与容器内 `/app/` 一致：

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

> **dist/ 目录结构要求**：上传前需确保 `dist/` 内部布局如下：
> ```
> dist/
> ├── node_modules/.bun/...      # 顶层 Bun 依赖
> └── apps/app/
>     ├── server.js               # Next.js 入口
>     ├── package.json
>     ├── .next/                  # 构建产物（server/、static/）
>     ├── node_modules/           # app 级依赖（next, react）
>     ├── public/                 # 公共文件
>     └── src/contents/           # MDX 内容
> ```
> **注意**：`dist/` 中不应包含 `.env.production` 等配置文件，环境变量通过 `--env-file` 传入。

## .env.example

```env
# 基础设施
REDIS_PASSWORD=redis123
POSTGRES_PASSWORD=postgres123
POSTGRES_DB=master_db
POSTGRES_USER=xingye

# 应用连接（完整 URL，无需在 compose 中拼接）
NODE_ENV=production
REDIS_URL=redis://:redis123@redis:6379/0
DATABASE_URL=postgresql://xingye:postgres123@postgres:5432/master_db
```

> **注意**：实际部署时复制 `.env.example` 为 `.env.production`，修改密码等敏感值为真实值。`.env.production` 应加入 `.gitignore`。

## infra/init-db/01-init.sql

Postgres 初始化脚本，在容器首次启动时自动执行（仅执行一次）：

```sql
-- 创建具备创建数据库权限的管理用户
-- POSTGRES_USER 默认即具备 CREATEDB 权限，此处演示扩展用法
-- 可根据实际需求添加更多初始化逻辑：创建额外数据库、扩展插件等

-- 示例：启用常用扩展
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 示例：创建应用所需的额外数据库（主数据库由 POSTGRES_DB 环境变量自动创建）
-- CREATE DATABASE app_sessions;
-- GRANT ALL PRIVILEGES ON DATABASE app_sessions TO ${POSTGRES_USER};
```

> **注意**：`/docker-entrypoint-initdb.d/` 中的脚本仅在 Postgres 数据目录为空时（即首次初始化）执行。已有的数据卷不会重新执行。脚本按文件名排序执行（`01-` 前缀确保执行顺序）。

## scripts/canary-weight.sh

灰度权重管理脚本，用于调整 stable/canary 流量比例：

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

## scripts/canary-promote.sh

金丝雀提升为稳定版：

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

## scripts/canary-rollback.sh

金丝雀回滚：

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

## 启动命令

```bash
# 0. 准备环境变量（首次部署）
cp .env.example .env.production
# 编辑 .env.production，修改密码等敏感值

# 1. 创建网络（一次性）
podman network create canary-network

# 2. 启动基础设施
podman-compose --env-file .env.production -f compose.infra.yml up -d

# 3. 构建镜像（需先上传 dist/ 产物）
podman build -t xingye-site:stable .
podman build -t xingye-site:canary .

# 4. 启动生产
podman-compose --env-file .env.production -f compose.production.yml up -d

# 5. 启动金丝雀（灰度发布时）
podman-compose --env-file .env.production -f compose.canary.yml up -d

# 6. 开始灰度流量切换
./scripts/canary-weight.sh 10   # 10% 流量到 canary
```

## 回滚 / 调权重

```bash
# 调整灰度比例
./scripts/canary-weight.sh 30   # 30% 流量到 canary
./scripts/canary-weight.sh 50   # 50/50 均分

# 金丝雀回滚（停止 canary，全量回 stable）
./scripts/canary-rollback.sh

# 金丝雀提升为稳定版（全量切换）
./scripts/canary-promote.sh
```

## 注意事项

- **所有 compose 文件统一通过 `--env-file .env.production` 加载环境变量**：infra/production/canary 三个文件中的 `${VAR}` 均不含默认值，必须在 `.env.production` 中显式定义
- **Nginx 不支持 weight=0**：初始 upstream 仅含 `server stable-app:3000;`（无权重），灰度时通过 `canary-weight.sh` 动态添加 canary-app 行（含 `max_fails` 和 `fail_timeout`），weight=0 时移除 canary-app 行
- **脚本执行顺序至关重要**：rollback 和 promote 都必须先执行 `canary-weight.sh 0`（移除 canary 行 + reload nginx），再 down canary 容器，避免 nginx 加载引用了已停止容器的配置
- **Next.js standalone 默认绑定容器 IP**：compose 中需设置 `HOSTNAME=0.0.0.0` 确保应用监听所有接口
- **Postgres 初始化脚本仅在首次启动时执行**：`infra/init-db/` 中的 SQL 脚本只在数据卷为空时运行，已有数据不会重新执行
- **preview/ 目录**：已重命名为 `dist/`，由外部上传构建产物，目录布局需与容器 `/app/` 一致
- **production/ 目录**：已删除（一直为空，无作用）
- **dist/ 应加入 `.gitignore`**：构建产物不应入库，CI/CD 流程中生成

## 审查记录

| # | 问题 | 决策 |
|---|---|---|
| 1 | Postgres 数据持久化 | 命名 volume `canary-postgres-data` |
| 2 | Redis 数据持久化 | AOF 持久化，命名 volume `canary-redis-data` |
| 3 | Canary 不可用时流量处理 | Nginx `max_fails` + `fail_timeout` + `proxy_next_upstream`，自动回切 stable |
| 4 | Nginx 监听端口 | 6080（避免与顶层 Nginx 80 端口冲突） |
| 5 | 环境变量管理 | 统一放 `.env.production`，所有 compose 通过 `--env-file` 传入，不设默认值 |
| 6 | 跨文件 depends_on | 去掉，依赖应用重连 + `restart: unless-stopped` 自愈 |
| 7 | 应用启动顺序 | 硬扛，应用内置重连（postgres.js 自动重连、ioredis 指数退避） |
| 8 | Postgres 初始化 | 挂载 `infra/init-db/` 到 `/docker-entrypoint-initdb.d/`，支持自定义初始化脚本 |
| 9 | Canary 初始权重 | upstream 初始不含 canary-app 行（Nginx 不支持 weight=0），通过 `canary-weight.sh` 动态添加/移除 |
| 10 | 部署脚本 | `canary-weight.sh` 权重管理（动态添加/移除）、`canary-promote.sh` 提升、`canary-rollback.sh` 回滚 |
| 11 | Dockerfile | `COPY dist/ ./` 单行复制，dist 由外部上传 |
| 12 | 脚本执行顺序 | rollback/promote 必须先 weight=0 移除 canary 行再 down canary 容器，避免 nginx DNS 解析失败 |
| 13 | 应用绑定地址 | compose 中设置 `HOSTNAME=0.0.0.0`，确保 Next.js 监听所有接口 |