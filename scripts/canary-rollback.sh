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