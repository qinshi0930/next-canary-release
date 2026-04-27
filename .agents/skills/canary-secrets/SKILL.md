---
name: canary-secrets
description: Use when user asks to rotate passwords, regenerate secrets, update Redis/Postgres/BetterAuth passwords, or mentions "密码" "secret" "password" "轮转" "rotate" "重新生成" "更新密钥"
---

# Canary Secrets — 密码轮转

## Overview

安全更新 `.env.production` 中的凭据并重启受影响容器。支持单独更新或一键全量轮转。

## 操作流程

### 0. 检测前缀和加载当前值

```bash
PREFIX=$(grep 'container_name:' compose.production.yml | head -1 | sed 's/.*container_name: *//;s/-.*//')
ENV_FILE=".env.production"

# 读取当前值（用于构建新 URL）
source "$ENV_FILE"
```

### 1. 更新单个密码

#### Redis 密码

```bash
NEW_PASS=$(openssl rand -hex 16)
sed -i "s/^REDIS_PASSWORD=.*/REDIS_PASSWORD=${NEW_PASS}/" "$ENV_FILE"
sed -i "s|^REDIS_URL=redis://:.*@redis:6379/0|REDIS_URL=redis://:${NEW_PASS}@redis:6379/0|" "$ENV_FILE"

echo "Redis 密码已更新"
echo "新密码: ${NEW_PASS}"

# 重启 Redis 和应用
podman restart ${PREFIX}-redis
sleep 3
podman restart ${PREFIX}-stable-app
echo "容器已重启"
```

#### Postgres 密码

```bash
NEW_PASS=$(openssl rand -hex 16)
CURRENT_USER=$(grep '^POSTGRES_USER=' "$ENV_FILE" | cut -d= -f2)
CURRENT_DB=$(grep '^POSTGRES_DB=' "$ENV_FILE" | cut -d= -f2)

sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${NEW_PASS}/" "$ENV_FILE"
sed -i "s|^DATABASE_URL=postgresql://${CURRENT_USER}:.*@postgres:5432/${CURRENT_DB}|DATABASE_URL=postgresql://${CURRENT_USER}:${NEW_PASS}@postgres:5432/${CURRENT_DB}|" "$ENV_FILE"

echo "Postgres 密码已更新"
echo "新密码: ${NEW_PASS}"

# 重启 Postgres 和应用
podman restart ${PREFIX}-postgres
sleep 5
podman restart ${PREFIX}-stable-app
echo "容器已重启"

# 同时更新容器内的密码（Postgres 需要在数据库层面改）
podman exec ${PREFIX}-postgres psql -U ${CURRENT_USER} -d ${CURRENT_DB} -c "ALTER USER ${CURRENT_USER} WITH PASSWORD '${NEW_PASS}';" 2>/dev/null || echo "注意: 需手动在 psql 中执行 ALTER USER 语句"
```

#### Better Auth Secret

```bash
NEW_SECRET=$(openssl rand -hex 32)
sed -i "s/^BETTER_AUTH_SECRET=.*/BETTER_AUTH_SECRET=${NEW_SECRET}/" "$ENV_FILE"

echo "Better Auth Secret 已更新"
echo "新密钥: ${NEW_SECRET}"

podman restart ${PREFIX}-stable-app
```

### 2. 一键轮转所有密码

```bash
# 生成
NEW_REDIS=$(openssl rand -hex 16)
NEW_POSTGRES=$(openssl rand -hex 16)
NEW_AUTH=$(openssl rand -hex 32)
CURRENT_USER=$(grep '^POSTGRES_USER=' "$ENV_FILE" | cut -d= -f2)
CURRENT_DB=$(grep '^POSTGRES_DB=' "$ENV_FILE" | cut -d= -f2)

# 备份
cp "$ENV_FILE" "${ENV_FILE}.bak.$(date +%s)"

# 更新
sed -i "s/^REDIS_PASSWORD=.*/REDIS_PASSWORD=${NEW_REDIS}/" "$ENV_FILE"
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${NEW_POSTGRES}/" "$ENV_FILE"
sed -i "s/^BETTER_AUTH_SECRET=.*/BETTER_AUTH_SECRET=${NEW_AUTH}/" "$ENV_FILE"
sed -i "s|^REDIS_URL=redis://:.*@redis:6379/0|REDIS_URL=redis://:${NEW_REDIS}@redis:6379/0|" "$ENV_FILE"
sed -i "s|^DATABASE_URL=postgresql://${CURRENT_USER}:.*@postgres:5432/${CURRENT_DB}|DATABASE_URL=postgresql://${CURRENT_USER}:${NEW_POSTGRES}@postgres:5432/${CURRENT_DB}|" "$ENV_FILE"

echo "所有密码已更新:"
echo "  REDIS_PASSWORD:       ${NEW_REDIS}"
echo "  POSTGRES_PASSWORD:    ${NEW_POSTGRES}"
echo "  BETTER_AUTH_SECRET:   ${NEW_AUTH}"

# 重启（先基础设施再应用）
podman restart ${PREFIX}-redis ${PREFIX}-postgres
sleep 5
# 更新 Postgres 容器内密码
podman exec ${PREFIX}-postgres psql -U ${CURRENT_USER} -d ${CURRENT_DB} \
    -c "ALTER USER ${CURRENT_USER} WITH PASSWORD '${NEW_POSTGRES}';" 2>/dev/null || true
podman restart ${PREFIX}-stable-app

echo "所有服务已重启"
```

### 3. 查看当前密码（脱敏）

```bash
echo "=== 当前密码（仅末4位） ==="
grep -E 'PASSWORD|SECRET' "$ENV_FILE" | while read line; do
    key=$(echo "$line" | cut -d= -f1)
    val=$(echo "$line" | cut -d= -f2-)
    if [ ${#val} -gt 4 ]; then
        echo "${key}=****${val: -4}"
    else
        echo "${key}=****"
    fi
done
```

## 安全提示

- 轮转后**立即保存输出中的新密码**，open code 会话结束后不可恢复
- 旧的 `.env.production.bak.*` 文件应在确认新密码可用后手动删除
- 如果应用使用了连接池（如 Prisma），重启应用容器后会自动用新密码连接
- Postgres 容器内需要执行 `ALTER USER` 更新数据库层面的密码
