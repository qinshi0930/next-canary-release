# AGENTS.md

## 项目概述

灰度发布（Canary Release）部署仓库。基于 Podman Compose + Nginx 权重路由实现 stable/canary 双版本流量切换、故障自动回切和一键提升/回滚。**本仓库不含应用源码**，`dist/` 目录存放从外部 monorepo（`xingyed.site`）构建的 Next.js standalone 产物。

## 关键架构

- **三层 compose 独立生命周期**: `compose.infra.yml`（Redis+Postgres）、`compose.production.yml`（Nginx+stable-app）、`compose.canary.yml`（canary-app），通过外部 `canary-network` 互通
- **所有 compose 命令必须统一加载 env 文件**: `podman-compose --env-file .env.production -f <compose-file> <command>`
- **Nginx upstream 初始只含 stable-app**，canary-app 行由 `canary-weight.sh` 动态插入/删除（weight=0 时整行移除）
- **Next.js standalone 默认绑定容器 IP**，compose 中 `HOSTNAME=0.0.0.0` 不可省略

## 常用命令

```bash
# 基础设施（先启动）
podman network create canary-network
podman-compose --env-file .env.production -f compose.infra.yml up -d

# 生产环境
podman-compose --env-file .env.production -f compose.production.yml up -d

# 灰度实例
podman-compose --env-file .env.production -f compose.canary.yml up -d

# 灰度流量控制
./scripts/canary-weight.sh 10   # 10% → canary
./scripts/canary-weight.sh 0     # 全量回 stable

# 提升/回滚（脚本内部已处理 weight=0 和 nginx reload）
./scripts/canary-promote.sh      # canary → stable
./scripts/canary-rollback.sh    # 下线 canary

# 关停（反向顺序）
podman-compose --env-file .env.production -f compose.canary.yml down
podman-compose --env-file .env.production -f compose.production.yml down
podman-compose --env-file .env.production -f compose.infra.yml down
podman network rm canary-network
```

## 注意事项

- 容器编排工具为 **Podman Compose**，不是 Docker Compose
- `dist/` 和 `.env.production` 已 gitignored，不应提交
- 本仓库无构建、测试、lint 流程——这些在源码仓库完成
- 无 CI/CD 配置
- 应用镜像构建: `podman build -t xingye-site:stable .`（Dockerfile 从 `dist/bundle/` 复制到 `/app/`）