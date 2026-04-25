#!/bin/bash
# 用法: ./scripts/canary-weight.sh <canary_weight>
# 示例: ./scripts/canary-weight.sh 10   # ~9% 流量到 canary
# 示例: ./scripts/canary-weight.sh 50   # 50/50 均分
# 示例: ./scripts/canary-weight.sh 0    # 停止灰度，移除 canary，全量走 stable
#
# 工作原理：
# - weight=0 时：从 upstream 中删除 canary-app 行
# - weight>0 时：在 upstream 中添加/更新 canary-app 行（含权重和故障转移参数）

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