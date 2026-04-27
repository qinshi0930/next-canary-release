# 灰度部署指南

从零部署基于 Podman Compose + Nginx 的灰度发布系统。

## 预设条件

- 服务器已安装 `podman` 和 `podman-compose`
- 应用构建产物 `dist/bundle/` 已就绪（Next.js standalone 输出）

## 使用 opencode 部署

**推荐的触发语句**（明确引用此文档，避免意外触发）：

> "按照 docs/guide/deployment.md 部署，前缀 myapp，端口 6080"

opencode 会读取本文档并按步骤执行：创建目录 → 生成密钥 → 写入配置文件 → 启动基础设施 → 构建镜像 → 启动生产环境。

以下步骤均可用 `opencode` 代替手动操作。将 `<PREFIX>` 替换为项目前缀（如 `myapp`），`<PORT>` 替换为监听端口（如 `6080`）。

---

## 步骤 1：创建目录和生成密钥

```bash
mkdir -p nginx infra/init-db
REDIS_PASSWORD=$(openssl rand -hex 16)
POSTGRES_PASSWORD=$(openssl rand -hex 16)
BETTER_AUTH_SECRET=$(openssl rand -hex 32)
```

## 步骤 2：创建 .env.production

```bash
cat > .env.production << EOF
NODE_ENV=production
REDIS_PASSWORD=${REDIS_PASSWORD}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=master_db
POSTGRES_USER=xingye
REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/0
DATABASE_URL=postgresql://xingye:${POSTGRES_PASSWORD}@postgres:5432/master_db
BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}
APP_ID=
APP_PEM_KEY_BASE64=
APP_INSTALLATION_ID=
AUTH_GITHUB_CLIENT_ID=
AUTH_GITHUB_CLIENT_SECRET=
SMTP_HOST=
SMTP_PORT=465
SMTP_USER=
SMTP_PASS=
SMTP_FROM=
SMTP_TO=
NEXT_PUBLIC_SUPABASE_URL=
NEXT_PUBLIC_SUPABASE_ANON_KEY=
SUPABASE_SERVICE_ROLE_KEY=
BETTER_AUTH_URL=
EOF

# 同时生成 .env.example（不含真实密码，供提交用）
sed 's/=.*/=/' .env.production | sed 's/REDIS_PASSWORD=/REDIS_PASSWORD=redis123/' | sed 's/POSTGRES_PASSWORD=/POSTGRES_PASSWORD=postgres123/' > .env.example
```

## 步骤 3：创建配置文件

以下模板中的 `<PREFIX>` 替换为项目前缀，`<PORT>` 替换为监听端口。

### compose.infra.yml — 基础设施

```yaml
# 基础设施配置 — PostgreSQL + Redis
# 无端口暴露，仅通过 <PREFIX>-network 内部通信
# 环境变量必须通过 --env-file 传入
services:
  redis:
    image: redis:7-alpine
    container_name: <PREFIX>-redis
    restart: unless-stopped
    command: redis-server --requirepass ${REDIS_PASSWORD} --appendonly yes
    volumes:
      - <PREFIX>-redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 10s
    networks:
      - <PREFIX>-network

  postgres:
    image: postgres:alpine
    container_name: <PREFIX>-postgres
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - <PREFIX>-postgres-data:/var/lib/postgresql/data
      - ./infra/init-db:/docker-entrypoint-initdb.d:ro
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    networks:
      - <PREFIX>-network

volumes:
  <PREFIX>-redis-data:
    driver: local
  <PREFIX>-postgres-data:
    driver: local

networks:
  <PREFIX>-network:
    external: true
```

### compose.production.yml — 生产环境（Nginx + stable-app）

```yaml
# 生产环境 — Nginx 网关 + stable 应用
services:
  nginx:
    image: nginx:alpine
    container_name: <PREFIX>-nginx
    restart: unless-stopped
    ports:
      - "<PORT>:<PORT>"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
    networks:
      - <PREFIX>-network

  stable-app:
    image: <PREFIX>:stable
    container_name: <PREFIX>-stable-app
    restart: unless-stopped
    env_file: .env.production
    environment:
      HOSTNAME: "0.0.0.0"
    networks:
      - <PREFIX>-network

networks:
  <PREFIX>-network:
    external: true
```

### compose.canary.yml — 金丝雀环境

```yaml
# 金丝雀环境 — canary 应用
services:
  canary-app:
    image: <PREFIX>:canary
    container_name: <PREFIX>-canary-app
    restart: unless-stopped
    env_file: .env.production
    environment:
      HOSTNAME: "0.0.0.0"
    networks:
      - <PREFIX>-network

networks:
  <PREFIX>-network:
    external: true
```

### nginx/nginx.conf — **必须使用多行格式**

upstream 块需要用多行（`{`、`server`、`}` 各占一行），否则后续流量控制技能的 sed 操作会出错。

```nginx
events {
    worker_connections 1024;
}

http {
    # canary 故障转移与权重路由配置
    #
    # 初始状态：upstream 只包含 stable-app，所有流量走 stable
    # 灰度发布时：通过 canary-traffic 技能添加 canary-app 并设置权重
    # canary 不可用时：max_fails + fail_timeout + proxy_next_upstream 自动回切 stable

    upstream backend {
        server stable-app:3000;
    }

    server {
        listen <PORT>;

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

### Dockerfile

```dockerfile
FROM node:22-alpine
ENV NODE_ENV=production

RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs

WORKDIR /app

COPY dist/bundle/ ./

RUN mkdir -p apps/app/.next/cache && chown nextjs:nodejs apps/app/.next/cache

USER nextjs

EXPOSE 3000
ENV PORT=3000

CMD ["node", "apps/app/server.js"]
```

### infra/init-db/01-init.sql

```sql
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
```

## 步骤 4：启动基础设施

```bash
podman network create <PREFIX>-network

podman-compose --env-file .env.production -f compose.infra.yml up -d

# 等待 Postgres 就绪（首次启动约 30s）
for i in $(seq 1 15); do
  podman exec <PREFIX>-postgres pg_isready -U xingye -d master_db 2>/dev/null && break
  sleep 2
done

# 验证 Redis
podman exec <PREFIX>-redis redis-cli -a ${REDIS_PASSWORD} ping
```

## 步骤 5：构建镜像并启动生产环境

```bash
# 构建应用镜像
podman build -t <PREFIX>:stable .

# 启动 Nginx + stable-app
podman-compose --env-file .env.production -f compose.production.yml up -d

# 验证
sleep 2
curl -s http://localhost:<PORT>/health
```

## 部署后日常操作

部署完成后，以下操作直接通过对话执行（无需引用部署指南）：

| 操作 | 对话示例 |
|------|---------|
| 改名 | "改名 newapp" |
| 灰度 | "设置 canary 权重 30%" · "promote canary" · "rollback canary" |
| Nginx | "修改端口为 8443" · "添加 location /api" · "配置 SSL" |
| 密码 | "重新生成 Redis 密码" · "一键轮转所有密码" |
| 帮助 | "怎么用" |

## 故障排查

| 问题 | 解决方法 |
|------|---------|
| `podman network create` 报 "already exists" | 忽略，网络已存在 |
| Postgres 启动超时 | 首次需 30s+，检查 `podman logs <PREFIX>-postgres` |
| Nginx 502 | `podman logs <PREFIX>-nginx`，检查 upstream DNS |
| `dist/bundle/` 缺失 | 从 monorepo 构建：`cd apps/app && npx next build` |
| 端口冲突 | 停止旧容器：`podman stop <name> && podman rm <name>` |
| 容器名冲突 | 使用不同 `PREFIX` 为新项目 |
