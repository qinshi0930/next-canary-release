# 灰度部署 — 启动与验证

在 `docs/guide/deployment.md` 构建完成项目结构后，使用本文档启动服务并验证。

## 使用 opencode

> "按照 docs/guide/verification.md 启动并验证项目 myapp 端口 6080"

---

## 前置检测（必须执行）

在启动任何服务之前，逐项验证。任一项不满足则**停止**。

```bash
# 1. 检查 compose.infra.yml（deployment.md 的产物）
[ -f compose.infra.yml ] \
  || { echo "❌ compose.infra.yml 不存在，请先执行 docs/guide/deployment.md 构建项目"; exit 1; }

# 2. 检查 .env.production
grep -q 'REDIS_PASSWORD=' .env.production 2>/dev/null \
  || { echo "❌ .env.production 无效，请先执行 docs/guide/deployment.md 构建项目"; exit 1; }

# 3. 检查 dist/bundle/
[ -f dist/bundle/apps/app/server.js ] \
  || { echo "❌ dist/bundle/ 缺失，请先从 monorepo 构建: cd apps/app && npx next build"; exit 1; }
echo "✓ dist/bundle/ 就绪"

# 4. 检查端口未被占用
ss -tlnp | grep -q ":${PORT} " \
  && { echo "❌ 端口 ${PORT} 已被占用"; exit 1; } \
  || echo "✓ 端口 ${PORT} 可用"
```

## 步骤 1：启动基础设施

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

## 步骤 2：构建镜像并启动生产环境

```bash
# 构建应用镜像
podman build -t <PREFIX>:stable .

# 启动 Nginx + stable-app
podman-compose --env-file .env.production -f compose.production.yml up -d

# 验证
sleep 2
curl -s http://localhost:<PORT>/health
```

## 步骤 3：验证清单

```bash
echo "=== 容器状态 ===" && podman ps --filter "name=<PREFIX>" --format "table {{.Names}}\t{{.Status}}"
echo "=== Nginx 语法 ===" && podman exec <PREFIX>-nginx nginx -t
echo "=== Health Check ===" && curl -s http://localhost:<PORT>/health
echo "=== 主页 ===" && curl -s -o /dev/null -w "HTTP %{http_code}" http://localhost:<PORT>/
echo "=== upstream ===" && podman exec <PREFIX>-nginx grep -A 3 "upstream backend" /etc/nginx/nginx.conf
```

## 部署后日常操作

部署完成后，以下操作直接通过对话执行：

| 操作 | 对话示例 |
|------|---------|
| 灰度 | "设置 canary 权重 30%" · "promote canary" · "rollback canary" |
| Nginx | "修改端口为 8443" · "添加 location /api" · "配置 SSL" |
| 密码 | "重新生成 Redis 密码" · "一键轮转所有密码" |
| 改名 | "改名 newapp" |
| 帮助 | "怎么用" |

## 故障排查

| 问题 | 解决方法 |
|------|---------|
| `podman network create` 报 "already exists" | 忽略 |
| Postgres 启动超时 | `podman logs <PREFIX>-postgres`，首次需 30s+ |
| Nginx 502 | `podman logs <PREFIX>-nginx`，检查 upstream DNS |
| 端口冲突 | `ss -tlnp | grep <PORT>` 查看占用进程 |
| 容器名冲突 | 使用不同 `PREFIX` 为新项目 |
