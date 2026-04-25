# 灰度发布系统 — 验证测试报告

**日期**: 2026-04-23  
**测试环境**: 本地 Podman  
**测试人**: 自动化验证

---

## 1. 测试概要

| 测试项 | 状态 | 备注 |
|---|---|---|
| dist/ 备份 | ✅ 通过 | 备份至 `backup/dist-backup-20260423192149/` |
| canary-network 创建 | ✅ 通过 | 外部 bridge 网络，子网 10.89.1.0/24 |
| compose.infra.yml 启动 | ✅ 通过 | Redis + Postgres 均健康 |
| Redis 连通性 | ✅ 通过 | `redis-cli ping` → PONG |
| Postgres 连通性 | ✅ 通过 | `pg_isready` → accepting connections |
| 应用镜像构建 | ✅ 通过 | `xingye-site:stable` + `xingye-site:canary` 构建成功 |
| stable-app 启动 | ✅ 通过 | Next.js 15.5.9 启动，端口 3000 |
| canary-app 启动 | ✅ 通过 | Next.js 15.5.9 启动，端口 3000 |
| 跨容器 HTTP 请求 | ✅ 通过 | 容器间通信正常 |
| compose.production.yml 启动 | ✅ 通过 | Nginx + stable-app 联合运行 |
| Nginx 6080 端口代理 | ✅ 通过 | HTTP 200，X-Served-By 头可见 |
| canary-weight.sh 权重切换 | ✅ 通过 | 10%/20%/30% 权重设置 + nginx reload 成功 |
| canary-weight.sh 0 回滚 | ✅ 通过 | canary-app 从 upstream 移除，nginx reload 成功 |
| canary-rollback.sh | ✅ 通过 | 先重置权重再停 canary，流程正确 |
| canary-promote.sh | ✅ 通过 | 先重置权重再停 canary 再提升，流程正确 |
| HOSTNAME=0.0.0.0 绑定 | ✅ 通过 | compose 中已设置，应用监听所有接口 |

---

## 2. 详细测试结果

### 2.1 基础设施（compose.infra.yml）

```
$ podman-compose --env-file .env.production -f compose.infra.yml up -d
→ canary-redis: Started (healthy)
→ canary-postgres: Started (healthy)
```

**结论**: Redis 和 Postgres 均正常启动，健康检查通过，无端口暴露到宿主机。

### 2.2 应用镜像构建

```
$ podman build -t xingye-site:stable .
→ Successfully tagged localhost/xingye-site:stable

$ podman tag xingye-site:stable xingye-site:canary
→ 成功
```

**结论**: Dockerfile 构建成功，`COPY dist/ ./` 正常工作。

### 2.3 Nginx 代理测试

```
$ curl -sI http://localhost:6080/
→ HTTP/1.1 200 OK
→ X-Served-By: 10.89.1.11:3000    # stable-app IP
```

**结论**: Nginx 在 6080 端口正确代理到 stable-app。

### 2.4 权重路由测试

#### 设置 canary 权重 10%

```
$ ./scripts/canary-weight.sh 10
→ 权重已更新: stable=90% canary=10%
→ nginx -s reload: signal process started

$ grep -A3 "upstream backend" nginx/nginx.conf
  upstream backend {
      server stable-app:3000 weight=90;
      server canary-app:3000 weight=10 max_fails=3 fail_timeout=30s;
  }
```

#### 回滚到 weight=0

```
$ ./scripts/canary-weight.sh 0
→ canary 已从 upstream 中移除，所有流量走 stable
→ nginx -s reload: signal process started

$ grep -A3 "upstream backend" nginx/nginx.conf
  upstream backend {
      server stable-app:3000;
  }
```

**结论**: `canary-weight.sh` 正确管理 upstream 中的 canary-app 行，weight=0 时移除（因为 Nginx 不支持 `weight=0`），weight>0 时添加含 `max_fails=3 fail_timeout=30s` 的行。

### 2.5 canary-rollback.sh 测试

```
$ ./scripts/canary-rollback.sh
→ 重置权重为 100/0（移除 canary-app 行）...
→ canary 已从 upstream 中移除，所有流量走 stable
→ nginx -s reload: signal process started
→ 停止金丝雀环境...
→ canary-canary-app stopped and removed
→ 金丝雀已回滚，流量已全量回 stable
```

**执行顺序**（修复后）: weight=0 → down canary，确保 nginx 先移除 canary-app 行再停止 canary 容器，避免 DNS 解析失败。

**验证**: 回滚后 `curl localhost:6080/` 返回 HTTP 200，只有 stable-app 在 upstream 中。

### 2.6 canary-promote.sh 测试

```
$ ./scripts/canary-promote.sh
→ 重置权重为 100/0（移除 canary-app 行）...
→ canary 已从 upstream 中移除，所有流量走 stable
→ nginx -s reload: signal process started
→ 停止金丝雀环境...
→ canary-canary-app stopped and removed
→ 将 canary 提升为 stable...
→ podman tag xingye-site:canary xingye-site:stable
→ podman-compose up -d  (nginx + stable-app 重启)
→ 金丝雀已提升为稳定版，流量已全量切换
```

**执行顺序**（修复后）: weight=0 → down canary → tag + up production，确保每一步 nginx 都能正常解析 upstream 中的主机名。

**验证**: 提升后 `curl localhost:6080/` 返回 HTTP 200，只有 stable-app 在 upstream 中。

---

## 3. 已知问题

| # | 问题 | 严重性 | 状态 | 解决方案 |
|---|---|---|---|---|
| 1 | Nginx 不支持 `weight=0` | 高 | ✅ 已修复 | 初始 upstream 只含 stable-app，通过 canary-weight.sh 动态添加/移除 canary-app 行 |
| 2 | canary-app 未运行时 nginx 启动失败（DNS 解析失败） | 高 | ✅ 已修复 | 初始状态不包含 canary-app 行，灰度发布时（容器已启动）再添加 |
| 3 | promote/rollback 脚本执行顺序导致 nginx reload 失败 | 高 | ✅ 已修复 | 调整为先 weight=0 移除 canary 行，再 down canary 容器，最后 up production |
| 4 | dist/Dockerfile 和 dist/podman-compose.yml 残留（root 权限） | 低 | 待清理 | `sudo rm dist/Dockerfile dist/podman-compose.yml` |
| 5 | Better Auth 缺少 BETTER_AUTH_SECRET | 低 | 信息 | 在 `.env.production` 中添加配置 |
| 6 | podman-compose down 报 pod 容器移除错误 | 低 | 信息 | 不影响功能，是 pod 残留容器的已知问题 |
| 7 | Next.js standalone 默认绑定容器 IP | 中 | ✅ 已修复 | compose 中已设置 `HOSTNAME=0.0.0.0` |

---

## 4. 关键设计决策

### 4.1 Nginx upstream 动态管理

由于 Nginx 不支持 `server canary-app:3000 weight=0;`（会报 `invalid parameter "weight=0"` 错误），采用以下策略：

- **初始状态**: upstream 只含 `server stable-app:3000;`（无权重，默认 weight=1，即 100% 流量）
- **灰度发布时**: `canary-weight.sh <N>` 动态添加 `server canary-app:3000 weight=N max_fails=3 fail_timeout=30s;`，同时给 stable-app 加上 `weight=(100-N)`
- **回滚时**: `canary-weight.sh 0` 删除 canary-app 行，stable-app 恢复为无权重

### 4.2 脚本执行顺序

promote 和 rollback 脚本的关键约束是：**不能让 nginx 加载引用了已停止容器的 upstream 配置**。

- **rollback**: weight=0（移除 canary 行 + reload）→ down canary
- **promote**: weight=0（移除 canary 行 + reload）→ down canary → tag + up production

### 4.3 容器网络架构

```
┌─────────────────────────────────────────────────┐
│              canary-network (10.89.1.0/24)      │
│                                                  │
│  ┌──────────┐ ┌─────────────┐ ┌──────────────┐ │
│  │  redis    │ │  postgres   │ │  nginx       │ │
│  │  :6379   │ │  :5432      │ │  :6080→:3000 │ │
│  └──────────┘ └─────────────┘ └──────────────┘ │
│                                    │             │
│                        ┌───────────┼──────────┐ │
│                        ▼           ▼          │ │
│                ┌──────────┐ ┌──────────────┐  │ │
│                │stable-app│ │ canary-app   │  │ │
│                │ :3000    │ │ :3000        │  │ │
│                └──────────┘ └──────────────┘  │ │
│                                                  │
└─────────────────────────────────────────────────┘
```

---

## 5. 环境信息

```
Podman: 5.x
Network: canary-network (10.89.1.0/24)
Containers: canary-redis, canary-postgres, canary-nginx, canary-stable-app
Images: xingye-site:stable, xingye-site:canary, nginx:alpine
Ports exposed: 6080 (nginx → host)
```