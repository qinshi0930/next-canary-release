---
name: canary-help
description: Use when user asks "how to use" "help" "what can I do" "支持哪些操作" "有什么功能" "commands" "怎么用" "能做什么" about the canary deployment system, or when user seems unsure what operations are available
---

# Canary Help

## 可用对话命令

直接对 opencode 说以下任意一句即可执行：

| 类别 | 示例对话 |
|------|---------|
| **改名** | "改名 myapp" · "修改项目前缀为 xxx" |
| **流量** | "设置 canary 权重 30%" · "流量全回 stable" · "promote canary" · "查看当前流量" |
| **Nginx** | "修改 nginx 端口为 8443" · "添加 location /api" · "配置 SSL" · "设置限流 10/s" |
| **密码** | "重新生成 Redis 密码" · "更新 Postgres 密码" · "一键轮转所有密码" |
| **帮助** | "怎么用" · "help"（就是本条） |

## 初始化部署

部署是分两步的一次性操作，需明确引用文档：

> "按照 docs/guide/deployment.md 构建项目 myapp 端口 6080"
> "按照 docs/guide/verification.md 启动并验证"

第一步生成全部配置文件，**不启动服务**。构建完成后需上传 dist 产物，再执行第二步。

## 所有技能

| 技能 | 触发关键词 |
|------|-----------|
| canary-prefix | 改名、前缀、rename、prefix |
| canary-traffic | 流量、权重、weight、灰度、promote、rollback |
| canary-nginx | nginx、端口、port、location、SSL、限流、缓存、header |
| canary-secrets | 密码、secret、password、轮转、rotate |

## 日常操作 vs 初始化

| | 触发方式 | 目的 |
|---|---------|------|
| **日常** | 对话中直接说关键词 | 改名、调流量、改 nginx、轮转密码 |
| **初始化** | 明确引用 deployment.md | 从零创建项目结构并首次部署 |

任意问题直接说中文即可，opencode 会自动匹配对应技能执行。
