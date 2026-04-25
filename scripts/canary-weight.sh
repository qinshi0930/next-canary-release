#!/bin/bash
# 用法: ./scripts/canary-weight.sh <canary_weight>
# 示例: ./scripts/canary-weight.sh 10   # ~9% 流量到 canary
# 示例: ./scripts/canary-weight.sh 50   # 50/50 均分
# 示例: ./scripts/canary-weight.sh 0    # 停止灰度，移除 canary，全量走 stable
#
# 工作原理：
# - weight=0 时：从 upstream 中删除 canary-app 行
# - weight>0 时：在 upstream 中添加/更新 canary-app 行（含权重和故障转移参数）
#
# 注意：所有文件写入使用 cat > file（O_TRUNC）而非 sed -i（rename），
# 确保 bind mount 的 nginx 容器能立即看到更新，无需重启。

set -euo pipefail

CANARY_WEIGHT="${1:?用法: $0 <canary_weight(0-100)>}"
NGINX_CONF="./nginx/nginx.conf"

# sed 原地编辑（inode 安全版：cat > file 保留 inode，bind mount 容器立即可见）
sed_inplace() {
    local expr="$1"
    local file="$2"
    local tmp
    tmp=$(mktemp)
    sed "$expr" "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

if [[ "$CANARY_WEIGHT" -lt 0 || "$CANARY_WEIGHT" -gt 100 ]]; then
    echo "错误: weight 必须在 0-100 之间" >&2
    exit 1
fi

# 移除已有的 canary-app 行（如果存在）
sed_inplace '/server canary-app:3000/d' "$NGINX_CONF"

if [[ "$CANARY_WEIGHT" -eq 0 ]]; then
    # weight=0：确保只有 stable-app
    if ! grep -q 'server stable-app:3000' "$NGINX_CONF"; then
        sed_inplace "/upstream backend {/a\\        server stable-app:3000;" "$NGINX_CONF"
    else
        sed_inplace "s/server stable-app:3000.*$/server stable-app:3000;/" "$NGINX_CONF"
    fi
    echo "canary 已从 upstream 中移除，所有流量走 stable"

elif [[ "$CANARY_WEIGHT" -eq 100 ]]; then
    # weight=100：移除 stable-app 行，全量走 canary
    sed_inplace '/server stable-app:3000/d' "$NGINX_CONF"
    if ! grep -q 'server canary-app:3000' "$NGINX_CONF"; then
        sed_inplace "/upstream backend {/a\\        server canary-app:3000 weight=100 max_fails=3 fail_timeout=30s;" "$NGINX_CONF"
    else
        sed_inplace "s/server canary-app:3000.*$/server canary-app:3000 weight=100 max_fails=3 fail_timeout=30s;/" "$NGINX_CONF"
    fi
    echo "权重已更新: stable=0% canary=100%"

else
    STABLE_WEIGHT=$((100 - CANARY_WEIGHT))
    # 确保 stable-app 行存在再更新权重
    if ! grep -q 'server stable-app:3000' "$NGINX_CONF"; then
        sed_inplace "/upstream backend {/a\\        server stable-app:3000 weight=${STABLE_WEIGHT};" "$NGINX_CONF"
    else
        sed_inplace "s/server stable-app:3000.*$/server stable-app:3000 weight=${STABLE_WEIGHT};/" "$NGINX_CONF"
    fi
    # 插入 canary-app 行
    sed_inplace "/server stable-app:3000 weight=${STABLE_WEIGHT};/a\\        server canary-app:3000 weight=${CANARY_WEIGHT} max_fails=3 fail_timeout=30s;" "$NGINX_CONF"
    echo "权重已更新: stable=${STABLE_WEIGHT}% canary=${CANARY_WEIGHT}%"
fi

podman exec canary-nginx nginx -s reload
