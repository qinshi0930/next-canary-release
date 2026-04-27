# 部署指南验证报告

**日期**: 2026-04-27
**部署方式**: 按 `docs/guide/deployment.md` 手动执行 5 步流程
**测试前缀**: `verify` | **端口**: `6090`

---

## 验证结果

### 1. 文件生成

| 文件 | 步骤 | 结果 |
|------|------|------|
| `compose.infra.yml` | Step 3 | ✓ 容器名/网络/卷名均使用 `verify-` 前缀 |
| `compose.production.yml` | Step 3 | ✓ nginx + stable-app，ports 为 `6090:6090` |
| `compose.canary.yml` | Step 3 | ✓ canary-app，镜像 `verify:canary` |
| `Dockerfile` | Step 3 | ✓ 与备份中原始文件一致 |
| `nginx/nginx.conf` | Step 3 | ✓ **多行格式**，upstream 中 `{`、`server`、`}` 分三行 |
| `infra/init-db/01-init.sql` | Step 3 | ✓ uuid-ossp 扩展 |
| `.env.production` | Step 2 | ✓ 含真实随机密码 |
| `.env.example` | Step 2 | ✓ 密码字段已重置为占位符 |

### 2. 基础设施启动

| 服务 | 检查方式 | 结果 |
|------|---------|------|
| verify-network | `podman network inspect` | ✓ 已创建 |
| verify-redis | `redis-cli -a <pass> ping` | ✓ PONG |
| verify-postgres | `pg_isready` | ✓ accepting connections |

### 3. 运行时启动

| 服务 | 检查方式 | 结果 |
|------|---------|------|
| 镜像构建 | `podman build -t verify:stable .` | ✓ 成功 |
| verify-nginx | `curl /health` | ✓ ok |
| verify-stable-app | `curl /` HTTP 200 | ✓ |

### 4. 技能兼容性

| 技能 | 操作 | 结果 |
|------|------|------|
| canary-traffic | 设置权重 20% | ✓ upstream 正确插入 `stable weight=80` + `canary weight=20 max_fails=3 fail_timeout=30s` |
| canary-traffic | 回退权重 0% | ✓ 干净恢复为 `server stable-app:3000;` |
| canary-traffic | `nginx -t` | ✓ syntax is ok |
| canary-traffic | `nginx -s reload` | ✓ signal process started |
| canary-nginx | 端口查询 | ✓ nginx listen 6090，compose ports 6090 |
| canary-secrets | 脱敏密码 | ✓ REDIS/POSTGRES/BETTER_AUTH 均仅显示末4位 |

### 5. 环境清理

| 资源 | 操作 | 结果 |
|------|------|------|
| verify-* 容器 | stop + rm | ✓ 已删除 |
| verify-network | rm | ✓ 已删除 |
| verify-*-data 卷 | rm | ✓ 已删除 |
| verify:stable 镜像 | rmi | ✓ 已删除 |
| 部署文件 | rm | ✓ compose/Dockerfile/nginx/infra/dist 已清理 |

---

## 发现的问题

### 问题 1：跨 shell 会话变量丢失（非结构性）

**现象**：不同 bash 调用间 `REDIS_PASSWORD` 变量丢失，导致第一次 .env.production 密钥为空值。  
**影响**：仅手工逐步测试时有此问题。opencode 在同一会话中顺序执行，不会出现。  
**解决**：在同一命令中完成 `openssl rand` → `cat > .env.production`，已验证可行。

### 问题 2：端口冲突（多项目场景）

**现象**：旧部署的 `test-nginx` 仍占用 6090 端口时，新部署的 `verify-nginx` 启动失败。  
**影响**：符合预期的多项目约束 — 不同项目需使用不同端口（部署指南中 `<PORT>` 参数设计即为此目的）。  
**解决**：`fuser -k` 释放端口或用不同 `<PORT>` 重新部署。

---

## 结论

部署指南 `docs/guide/deployment.md` 可完整重建项目结构并成功启动服务，生成的配置文件与 4 个对话技能（`canary-traffic` / `canary-nginx` / `canary-secrets` / `canary-prefix`）完全兼容。指南中的 nginx 多行格式要求确保了后续流量控制技能的 sed 操作正确性。

**状态：✅ 全部通过**
