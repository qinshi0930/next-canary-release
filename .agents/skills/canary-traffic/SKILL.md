---
name: canary-traffic
description: Use when user asks to control canary traffic, set canary weight, promote canary to stable, rollback canary, query current traffic distribution, or mentions "流量" "权重" "weight" "灰度" "promote" "rollback" "全量切换"
---

# Canary Traffic — 流量控制

## Overview

直接操作 nginx upstream 权重，实现 stable/canary 流量分配。**纯会话式操作，不依赖脚本文件。**

## 关键机制：inode-safe 文件修改

nginx.conf 通过 bind mount 挂载到容器。`sed -i` 会创建新 inode，导致容器内 reload 读到旧文件。

**所有 nginx.conf 修改必须用此模式：**

```bash
sed_inplace() {
    local expr="$1" file="$2" tmp
    tmp=$(mktemp)
    sed "$expr" "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}
```

## 操作流程

### 0. 检测前缀

```bash
PREFIX=$(grep 'container_name:' compose.production.yml | head -1 | sed 's/.*container_name: *//;s/-.*//')
NGINX_CONF="./nginx/nginx.conf"
```

### 1. 查询当前流量

```bash
echo "=== 当前 upstream 配置 ==="
grep -A 5 "upstream backend" "$NGINX_CONF" | grep "server"
```

### 2. 设置 canary 权重

用户说 "设置 canary 权重 30%" → `WEIGHT=30`：

```bash
WEIGHT=<用户给定值>
# 验证: 0 <= WEIGHT < 100

# 移除已有 canary-app 行
sed_inplace '/server canary-app:3000/d' "$NGINX_CONF"

if [ "$WEIGHT" -eq 0 ]; then
    # 全部回 stable
    sed_inplace 's/server stable-app:3000.*/server stable-app:3000;/' "$NGINX_CONF"
    echo "canary 已移除，所有流量走 stable"
else
    STABLE_WEIGHT=$((100 - WEIGHT))
    sed_inplace "s/server stable-app:3000.*/server stable-app:3000 weight=${STABLE_WEIGHT};/" "$NGINX_CONF"
    sed_inplace "/server stable-app:3000 weight=${STABLE_WEIGHT};/a\\        server canary-app:3000 weight=${WEIGHT} max_fails=3 fail_timeout=30s;" "$NGINX_CONF"
    echo "stable=${STABLE_WEIGHT}% canary=${WEIGHT}%"
fi

# reload（先语法检查）
podman exec ${PREFIX}-nginx nginx -t && podman exec ${PREFIX}-nginx nginx -s reload
```

### 3. 提升 canary → stable

用户说 "promote canary" 或 "提升 canary"：

```bash
# 先切流量回 stable
sed_inplace '/server canary-app:3000/d' "$NGINX_CONF"
sed_inplace 's/server stable-app:3000.*/server stable-app:3000;/' "$NGINX_CONF"
podman exec ${PREFIX}-nginx nginx -s reload

# 停止 canary
podman-compose --env-file .env.production -f compose.canary.yml down

# 标记为新 stable
podman tag ${PREFIX}:canary ${PREFIX}:stable

# 重启生产环境
podman-compose --env-file .env.production -f compose.production.yml up -d
echo "canary 已提升为 stable"
```

### 4. 回滚 canary

用户说 "rollback canary" 或 "回滚"：

```bash
sed_inplace '/server canary-app:3000/d' "$NGINX_CONF"
sed_inplace 's/server stable-app:3000.*/server stable-app:3000;/' "$NGINX_CONF"
podman exec ${PREFIX}-nginx nginx -s reload

podman-compose --env-file .env.production -f compose.canary.yml down
echo "canary 已回滚，流量全回 stable"
```

## 验证

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:<port>/
grep -A 5 "upstream backend" "$NGINX_CONF"
```
