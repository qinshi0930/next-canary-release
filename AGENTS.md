# AGENTS.md

## 项目概述

基于 Podman Compose + Nginx 权重路由的灰度发布（Canary Release）系统。通过 opencode 对话技能实现日常运维，通过部署指南实现初始化部署。**本仓库不含应用源码**。

## 项目结构

```
.agents/skills/              ← opencode 对话技能（日常操作）
├── canary-help/SKILL.md     帮助入口
├── canary-prefix/SKILL.md   改名
├── canary-traffic/SKILL.md  流量控制
├── canary-nginx/SKILL.md    Nginx 配置
└── canary-secrets/SKILL.md  密码轮转

docs/guide/
├── deployment.md            项目结构构建（文件生成，不启动服务）
└── verification.md          启动与验证（容器启动 + 健康检查）
```

## 使用方式

### 初始化部署（一次性）

```
"按照 docs/guide/deployment.md 构建项目 myapp 端口 6080"
→ 上传 dist/bundle/ 产物
"按照 docs/guide/verification.md 启动并验证项目 myapp 端口 6080"
```

### 日常运维（对话式）

| 操作 | 对话示例 |
|------|---------|
| 流量控制 | "设置 canary 权重 30%" · "promote canary" · "rollback canary" |
| Nginx 配置 | "修改端口为 8443" · "添加 location /api" · "配置 SSL" |
| 密码轮转 | "重新生成 Redis 密码" · "一键轮转所有密码" |
| 项目改名 | "改名为 newapp" |
| 查看帮助 | "怎么用" |

## 关键架构

- **三层 compose**: `compose.infra.yml`（Redis+Postgres）、`compose.production.yml`（Nginx+stable-app）、`compose.canary.yml`（canary-app），通过外部 `{PREFIX}-network` 互通
- **Compose 服务名固定**: `redis`、`postgres`、`nginx`、`stable-app`、`canary-app` 不可变更，它们是应用内部 DNS 名
- **项目隔离**: 不同项目使用不同 `PREFIX`，独立网络和容器前缀，互不干扰
- **所有 compose 命令需加载 env 文件**: `podman-compose --env-file .env.production -f <file> <cmd>`

## 注意事项

- 容器编排工具为 **Podman Compose**
- `dist/`、`.env.production`、`backup/` 已 gitignored
- 本仓库无构建、测试、lint 流程——这些在源码仓库完成
- nginx.conf 修改必须使用 inode-safe 方式（`cat > file` 而非 `sed -i`），否则 bind mount 容器 reload 不生效

## Git 操作

main 分支已启用保护策略，详见 `docs/guide/git-branch-protection.md`。核心规则：

- **禁止直接 push**，所有变更须通过 PR
- **管理员可直接合并**，无需审批
- **非管理员需要 1 人 approve**

## 常见命令（手动操作备选）

```bash
# 构建镜像
podman build -t <PREFIX>:stable .

# 启动基础设施
podman network create <PREFIX>-network
podman-compose --env-file .env.production -f compose.infra.yml up -d

# 启动生产环境
podman-compose --env-file .env.production -f compose.production.yml up -d

# 关停（反向顺序）
podman-compose --env-file .env.production -f compose.canary.yml down
podman-compose --env-file .env.production -f compose.production.yml down
podman-compose --env-file .env.production -f compose.infra.yml down
podman network rm <PREFIX>-network
```
