# Git 分支保护与操作指南

## 当前保护策略（main 分支）

| 规则 | 状态 | 说明 |
|------|------|------|
| 需要 PR 才能合并 | ✅ | 禁止直接 push 到 main |
| 审批数量 | 1 | 非管理员需要 1 人 approve |
| 管理员豁免 | ✅ | admin 合并 PR 无需审批 |
| Code Owner 审查 | ✅ | 核心文件变更须指定人员审查 |
| 对话解决 | ✅ | review 讨论必须解决才能合并 |
| 过时审查驳回 | ✅ | 新 commit 后旧 approve 自动失效 |
| Force Push | ❌ | 禁止 |
| 分支删除 | ❌ | 禁止 |

## 管理员操作（qinshi0930）

你是仓库 admin，合并 PR 无需任何人审批。

### 日常提交流程

```bash
# 1. 创建功能分支
git checkout -b feat/my-change

# 2. 提交更改
git add .
git commit -m "feat: 变更描述"

# 3. 推送到远程
git push -u origin feat/my-change

# 4. 创建 PR
gh pr create --title "feat: 变更描述" --body "## 变更摘要\n..."

# 5. 直接合并（无需审批）
gh pr merge --merge --delete-branch
```

### 网页端合并

在 PR 页面点击 **"Merge without waiting for requirements"** 即可直接合并。

## 非管理员操作（其他协作者）

非管理员合并 PR 需满足：
1. 至少 1 人 approve
2. 如果变更触及 CODEOWNERS 保护的文件，须相应 Code Owner 审查
3. 所有 review 讨论已解决

## CODEOWNERS 保护范围

以下目录的变更必须由 `@qinshi0930` 审查：

| 路径 | 说明 |
|------|------|
| `scripts/` | 生产流量控制脚本 |
| `nginx/` | 路由配置 |
| `compose.*.yml` | 容器编排文件 |
| `Dockerfile` | 镜像构建定义 |
| `infra/` | 基础设施配置 |

## 紧急场景

### 需要临时关闭保护以绕过自身 check

当管理员被保护规则挡住时（如 Code Owner 审查要求自己 approve 自己）：

```bash
# 1. 临时放宽保护
gh api -X PUT /repos/qinshi0930/next-canary-release/branches/main/protection \
  --input - <<'EOF'
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0
  },
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": false
}
EOF

# 2. 合并 PR
gh pr merge <pr-number> --merge --delete-branch

# 3. 恢复保护
gh api -X PUT /repos/qinshi0930/next-canary-release/branches/main/protection \
  --input - <<'EOF'
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
EOF
```

## 查看当前保护配置

```bash
gh api /repos/qinshi0930/next-canary-release/branches/main/protection \
  --jq '{approvals: .required_pull_request_reviews.required_approving_review_count, code_owner: .required_pull_request_reviews.require_code_owner_reviews, force_push: .allow_force_pushes.enabled, deletion: .allow_deletions.enabled, enforce_admins: .enforce_admins.enabled}'
```
