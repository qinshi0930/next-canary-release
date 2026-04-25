# 灰度发布系统

基于 Podman Compose + Nginx 权重路由的灰度发布系统，支持 stable/canary 双版本流量切换、故障自动回切、一键提升/回滚。

## 架构

```
                    ┌──────────┐
                    │  客户端   │
                    └────┬─────┘
                         │ :6080
                    ┌────┴─────┐
                    │  Nginx   │  权重路由 + 故障转移
                    └────┬─────┘
                    ┌────┴─────┐
                    │          │
               ┌────┴──┐  ┌───┴──────┐
               │stable │  │ canary   │
               │ :3000 │  │  :3000   │
               └───┬───┘  └────┬─────┘
                   │           │
              ┌────┴───────────┴────┐
              │  Redis + Postgres   │
              └─────────────────────┘
```

所有服务运行在 `canary-network` 外部网络中，Nginx 是唯一对外入口（端口 6080），应用端口不暴露到宿主机。canary 初始不在 upstream 中，灰度发布时通过脚本动态添加并设置权重。

## 目录结构

```
canary-release-demo/
├── compose.infra.yml           # Redis + Postgres 基础设施
├── compose.production.yml      # Nginx 网关 + stable-app
├── compose.canary.yml          # canary-app
├── nginx/nginx.conf            # 权重路由 + 故障转移
├── infra/init-db/01-init.sql   # Postgres 初始化脚本
├── scripts/
│   ├── canary-weight.sh        # 动态调整 canary 权重
│   ├── canary-promote.sh       # canary 提升为 stable
│   └── canary-rollback.sh      # canary 回滚
├── Dockerfile                  # 从 dist/ 构建应用镜像
├── .env.example                # 环境变量模板
├── .env.production             # 实际环境变量（gitignored）
├── dist/                       # 构建产物（gitignored，由外部上传）
└── backup/                     # 备份目录
```

## 快速开始

### 前置条件

- Podman + podman-compose
- 应用构建产物（`dist/` 目录）

### 1. 配置环境变量

```bash
cp .env.example .env.production
# 编辑 .env.production，修改密码等敏感值
```

### 2. 创建网络

```bash
podman network create canary-network
```

### 3. 启动基础设施

```bash
podman-compose --env-file .env.production -f compose.infra.yml up -d
```

验证：

```bash
podman exec canary-redis redis-cli -a <密码> ping    # → PONG
podman exec canary-postgres pg_isready -U xingye -d master_db  # → accepting connections
```

### 4. 构建应用镜像

```bash
# 确保 dist/ 目录存在且包含构建产物
podman build -t xingye-site:stable .
podman tag xingye-site:stable xingye-site:canary
```

### 5. 启动生产环境

```bash
podman-compose --env-file .env.production -f compose.production.yml up -d
```

验证：

```bash
curl -sI http://localhost:6080/     # → HTTP 200
curl -sI http://localhost:6080/health  # → 200 ok
```

### 6. 启动金丝雀（灰度发布时）

```bash
podman-compose --env-file .env.production -f compose.canary.yml up -d

# 开始灰度：10% 流量到 canary
./scripts/canary-weight.sh 10
```

## 灰度操作

### 调整权重

```bash
./scripts/canary-weight.sh 10    # ~9% 流量到 canary
./scripts/canary-weight.sh 30    # 30% 流量到 canary
./scripts/canary-weight.sh 50    # 50/50 均分
./scripts/canary-weight.sh 0     # 停止灰度，移除 canary，全量走 stable
```

权重机制：Nginx 不支持 `weight=0`，所以 weight=0 时从 upstream 中移除 canary-app 行。

### 金丝雀回滚

停止 canary 容器，流量全量切回 stable：

```bash
./scripts/canary-rollback.sh
```

执行顺序：先移除 canary-app 行并 reload Nginx（确保流量切回），再停止 canary 容器。

### 金丝雀提升

将 canary 镜像标记为 stable，全量切换：

```bash
./scripts/canary-promote.sh
```

执行顺序：先移除 canary-app 行并 reload Nginx，停止 canary 容器，然后将 canary 镜像 tag 为 stable 并重启生产环境。

## 故障转移

canary-app 在 upstream 中配置了故障转移参数：

- `max_fails=3` — 连续 3 次请求失败后标记为不可用
- `fail_timeout=30s` — 30 秒后重新尝试
- `proxy_next_upstream error timeout` — 请求失败时自动转发到 stable-app

当 canary 不可用时，Nginx 自动将流量回切到 stable-app，无需手动干预。

## 关键设计

| 决策 | 原因 |
|---|---|
| 三层 compose 架构 | 独立生命周期管理，灰度发布只需启停 canary |
| Nginx 动态添加/移除 canary 行 | Nginx 不支持 weight=0，参考已停止的容器会导致启动失败 |
| 脚本先 weight=0 再 down canary | 避免 Nginx 加载引用了已停止容器的 upstream 配置 |
| HOSTNAME=0.0.0.0 | Next.js standalone 默认绑定容器 hostname，需显式设置为 0.0.0.0 |
| Redis/Postgres 不暴露端口 | 减少攻击面，仅通过 canary-network 内部通信 |
| 应用不映射端口到宿主机 | Nginx 是唯一入口，应用无需外部直接访问 |

## 关停

```bash
# 停止金丝雀
podman-compose --env-file .env.production -f compose.canary.yml down

# 停止生产
podman-compose --env-file .env.production -f compose.production.yml down

# 停止基础设施
podman-compose --env-file .env.production -f compose.infra.yml down

# 删除网络
podman network rm canary-network
```