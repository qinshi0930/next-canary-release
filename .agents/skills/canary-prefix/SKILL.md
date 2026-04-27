---
name: canary-prefix
description: Use when user asks to rename a project, change project prefix, change container name prefix, or mentions "改名" "修改前缀" "重命名项目" "rename" "set prefix"
---

# Canary Prefix — 项目改名

## Overview

修改灰度部署项目的容器/网络/卷名前缀。不影响 Compose 服务名（DNS 名），每个项目通过独立网络隔离。

## 操作流程

### 1. 检测当前前缀

```bash
cd <project_dir>
CURRENT_PREFIX=$(grep 'container_name:' compose.production.yml | head -1 | sed 's/.*container_name: *//;s/-.*//')
echo "当前前缀: $CURRENT_PREFIX"
```

### 2. 获取新前缀

向用户确认新前缀。验证：`^[a-zA-Z][a-zA-Z0-9_-]*$`

### 3. 执行替换

对以下文件执行 sed（注意：不触碰 Compose 服务名如 `canary-app:` 作为 YAML key 的行）：

```bash
NEW_PREFIX=<用户输入>
CURRENT_PREFIX=<检测值>
CURRENT_IMAGE=$(grep 'image:' compose.production.yml | grep -v nginx | head -1 | sed 's/.*image: *//;s/:.*//')

for f in compose.infra.yml compose.production.yml compose.canary.yml; do
    [ -f "$f" ] || continue
    sed -i \
        -e "s|container_name: ${CURRENT_PREFIX}-|container_name: ${NEW_PREFIX}-|g" \
        -e "s|${CURRENT_PREFIX}-network|${NEW_PREFIX}-network|g" \
        -e "s|${CURRENT_PREFIX}-redis-data|${NEW_PREFIX}-redis-data|g" \
        -e "s|${CURRENT_PREFIX}-postgres-data|${NEW_PREFIX}-postgres-data|g" \
        -e "s|${CURRENT_PREFIX}-nginx|${NEW_PREFIX}-nginx|g" \
        -e "s|image: ${CURRENT_IMAGE}:|image: ${NEW_PREFIX}:|g" \
        -e "s|${CURRENT_IMAGE}:|${NEW_PREFIX}:|g" \
        "$f"
done
```

### 4. 输出结果

```bash
echo "已完成: $CURRENT_PREFIX → $NEW_PREFIX"
echo "后续步骤:"
echo "  podman network create ${NEW_PREFIX}-network"
echo "  podman build -t ${NEW_PREFIX}:stable ."
echo "  podman-compose --env-file .env.production -f compose.infra.yml up -d"
echo "  podman-compose --env-file .env.production -f compose.production.yml up -d"
```

## 不修改的内容

- Compose 服务名: `redis`, `postgres`, `nginx`, `stable-app`, `canary-app`
- nginx/nginx.conf upstream 中的 server 名（这些是 Compose DNS 名）
- .env.production 中的 hostname（`redis`, `postgres` 是 DNS 名）

## 验证

```bash
grep -r "${NEW_PREFIX}" compose.*.yml | head -10
grep "container_name:" compose.*.yml
```
