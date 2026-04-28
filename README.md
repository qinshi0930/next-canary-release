# Next Canary Release

基于 Podman Compose + Nginx 权重路由的灰度发布（Canary Release）系统。

通过 opencode 对话技能实现日常运维，通过部署指南实现一键初始化部署。**本仓库不含应用源码。**

## 架构

```
                   ┌─────────────┐
                   │   Nginx     │  ← 权重路由（stable/canary）
                   └──────┬──────┘
                          │
            ┌─────────────┼─────────────┐
            ▼             │             ▼
     ┌──────────┐         │      ┌──────────┐
     │ stable   │         │      │ canary   │
     │  app     │         │      │   app    │
     └────┬─────┘         │      └────┬─────┘
          │               │            │
     ┌────┴─────┐         │      ┌────┴─────┐
     │ Postgres │         │      │  Redis   │
     │          │         │      │          │
     └──────────┘         │      └──────────┘
            ┌─────────────┴─────────────┐
            │     {PREFIX}-network      │  ← 外部网络隔离
            └───────────────────────────┘
```

- **三层 compose**：`compose.infra.yml`（Redis + Postgres）、`compose.production.yml`（Nginx + stable）、`compose.canary.yml`（canary）
- **Canary 权重路由**：Nginx upstream 支持 `weight` 参数，按比例分配流量到 stable/canary
- **故障自动回切**：`max_fails` + `fail_timeout` + `proxy_next_upstream` 确保 canary 不可用时流量自动回到 stable
- **项目隔离**：不同项目使用不同 `PREFIX`，独立网络和容器前缀，互不干扰

## 快速开始

### 初始化部署

```bash
# 第一步：构建项目结构（生成配置文件，不启动服务）
"按照 docs/guide/deployment.md 构建项目 myapp 端口 6080"

# 第二步：上传 dist 产物
scp -r ./dist/bundle user@server:<项目目录>/

# 第三步：启动并验证
"按照 docs/guide/verification.md 启动并验证项目 myapp 端口 6080"
```

### 日常运维（对话式）

直接对 opencode 说：

| 操作 | 对话示例 |
|------|---------|
| 流量控制 | "设置 canary 权重 30%" · "promote canary" · "rollback canary" |
| Nginx 配置 | "修改端口为 8443" · "配置 SSL" · "设置限流 10/s" |
| 密码轮转 | "重新生成 Redis 密码" · "一键轮转所有密码" |
| 项目改名 | "改名为 newapp" |
| 查看帮助 | "怎么用" |

## 前置要求

| 工具 | 用途 |
|------|------|
| Podman | 容器运行时 |
| Podman Compose | 容器编排 |
| OpenCode CLI | 对话式运维 |

## 项目结构

```
.agents/skills/              ← opencode 对话技能
├── canary-help/              帮助入口
├── canary-prefix/            项目改名
├── canary-traffic/           流量控制
├── canary-nginx/             Nginx 配置
└── canary-secrets/           密码轮转
docs/
├── guide/                    部署指南
│   ├── deployment.md         项目结构构建
│   └── verification.md       启动与验证
├── rules/                    规则文档
│   └── git-branch-protection.md
└── superpowers/plans/        实施计划
```

## 注意事项

- 容器编排工具为 **Podman Compose**（非 Docker Compose）
- `dist/`、`.env.production`、`backup/` 已 gitignored
- 本仓库无构建、测试、lint 流程——这些在源码仓库完成
- nginx.conf 修改必须使用 inode-safe 方式（`cat > file` 而非 `sed -i`），否则 bind mount 容器 reload 不生效

## 手动命令（备选）

```bash
# 启动基础设施
podman network create <PREFIX>-network
podman-compose --env-file .env.production -f compose.infra.yml up -d

# 启动生产环境
podman build -t <PREFIX>:stable .
podman-compose --env-file .env.production -f compose.production.yml up -d

# 关停（反向顺序）
podman-compose --env-file .env.production -f compose.canary.yml down
podman-compose --env-file .env.production -f compose.production.yml down
podman-compose --env-file .env.production -f compose.infra.yml down
podman network rm <PREFIX>-network
```
