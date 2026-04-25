-- Postgres 初始化脚本
-- 仅在容器首次启动（数据卷为空）时执行
-- 可根据实际需求扩展：创建额外数据库、授权、启用扩展等

-- 启用常用扩展
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 示例：创建额外数据库（主数据库由 POSTGRES_DB 环境变量自动创建）
-- CREATE DATABASE app_sessions;
-- GRANT ALL PRIVILEGES ON DATABASE app_sessions TO xingye;