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