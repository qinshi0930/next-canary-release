---
name: canary-nginx
description: Use when user asks to modify nginx configuration such as change listen port, add/remove proxy headers, add location blocks, configure SSL, set rate limiting, configure cache, manage upstream servers, or mentions "nginx" "端口" "location" "SSL" "证书" "限流" "缓存" "header"
---

# Canary Nginx — Nginx 配置管理

## 关键机制

`nginx.conf` 通过 bind mount 挂载到容器。**所有修改必须保留 inode**，否则容器内 reload 读到旧文件。

```bash
sed_inplace() {
    local expr="$1" file="$2" tmp
    tmp=$(mktemp)
    sed "$expr" "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}
```

每次修改前自动备份：`cp nginx/nginx.conf nginx/nginx.conf.bak.$(date +%s)`

修改后 reload：`podman exec ${PREFIX}-nginx nginx -t && podman exec ${PREFIX}-nginx nginx -s reload`

## 操作前

```bash
PREFIX=$(grep 'container_name:' compose.production.yml | head -1 | sed 's/.*container_name: *//;s/-.*//')
NGINX_CONF="./nginx/nginx.conf"
PROD_COMPOSE="./compose.production.yml"
```

## 操作列表

### 1. 修改监听端口

将 `listen <old>` 改为 `listen <new>`，**同步更新 compose.production.yml 的 ports 映射**：

```bash
OLD_PORT=$(grep -oP 'listen \K\d+' "$NGINX_CONF")
NEW_PORT=<用户指定>

# 备份
cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%s)"

# 修改 nginx listen
sed_inplace "s/listen ${OLD_PORT}/listen ${NEW_PORT}/g" "$NGINX_CONF"

# 修改 compose ports 映射（YAML 中 "8080:8080" 格式）
sed -i "s|\"${OLD_PORT}:${OLD_PORT}\"|\"${NEW_PORT}:${NEW_PORT}\"|g" "$PROD_COMPOSE"

podman exec ${PREFIX}-nginx nginx -t && podman exec ${PREFIX}-nginx nginx -s reload
echo "端口已从 ${OLD_PORT} 改为 ${NEW_PORT}"
```

### 2. 添加 proxy header

```bash
HEADER_NAME=<X-Custom-Header>
HEADER_VALUE=<value>

sed_inplace "/proxy_pass http:\/\/backend;/a\\        proxy_set_header ${HEADER_NAME} ${HEADER_VALUE};" "$NGINX_CONF"

podman exec ${PREFIX}-nginx nginx -t && podman exec ${PREFIX}-nginx nginx -s reload
echo "已添加 header: ${HEADER_NAME}: ${HEADER_VALUE}"
```

### 3. 删除 proxy header

```bash
HEADER_NAME=<X-Custom-Header>
sed_inplace "/proxy_set_header ${HEADER_NAME}/d" "$NGINX_CONF"
podman exec ${PREFIX}-nginx nginx -t && podman exec ${PREFIX}-nginx nginx -s reload
echo "已删除 header: ${HEADER_NAME}"
```

### 4. 添加自定义 location 块

在 `/health` location 后插入：

```bash
LOC_PATH="/api"
PROXY_TARGET="http://backend"

sed_inplace "/location \/health {/,/}/{/}/{/a\\        location ${LOC_PATH} {\n            proxy_pass ${PROXY_TARGET};\n            proxy_set_header Host \$host;\n        }" "$NGINX_CONF" -- 但这个多行插入比较复杂，改用临时文件方式：
```

**推荐方式 — 用 awk 插入多行块：**

```bash
awk -v path="/api" -v target="http://backend" '
    /location \/health \{/ { in_health=1 }
    in_health && /\}/ { 
        print
        print "        location " path " {"
        print "            proxy_pass " target ";"
        print "            proxy_set_header Host $host;"
        print "        }"
        in_health=0
        next
    }
    { print }
' "$NGINX_CONF" > /tmp/nginx_new && cat /tmp/nginx_new > "$NGINX_CONF" && rm /tmp/nginx_new

podman exec ${PREFIX}-nginx nginx -t && podman exec ${PREFIX}-nginx nginx -s reload
echo "已添加 location: ${LOC_PATH}"
```

### 5. 删除 location 块

```bash
LOC_PATH="/api"
# 删除从 "location /api {" 到下一个 "}" 的所有行
sed_inplace "/location ${LOC_PATH} {/,/}/d" "$NGINX_CONF"
podman exec ${PREFIX}-nginx nginx -t && podman exec ${PREFIX}-nginx nginx -s reload
echo "已删除 location: ${LOC_PATH}"
```

### 6. 添加 upstream 服务器

```bash
SERVER_ADDR="new-backend:3000"
sed_inplace "/upstream backend {/a\\        server ${SERVER_ADDR};" "$NGINX_CONF"
podman exec ${PREFIX}-nginx nginx -t && podman exec ${PREFIX}-nginx nginx -s reload
echo "已添加 upstream: ${SERVER_ADDR}"
```

### 7. SSL 配置

先确认用户提供证书路径，然后修改 server 块：

```bash
CERT_PATH="/etc/nginx/ssl/fullchain.pem"
KEY_PATH="/etc/nginx/ssl/privkey.pem"

# 修改 listen 为 ssl
sed_inplace "s/listen [0-9]\+;/listen 443 ssl;/" "$NGINX_CONF"

# 添加 SSL 指令
sed_inplace "/listen 443 ssl;/a\\        ssl_certificate ${CERT_PATH};\n        ssl_certificate_key ${KEY_PATH};" "$NGINX_CONF"

# 同步 compose 挂载证书目录
# compose.production.yml 需要挂载: - ./nginx/ssl:/etc/nginx/ssl:ro

podman exec ${PREFIX}-nginx nginx -t && podman exec ${PREFIX}-nginx nginx -s reload
echo "SSL 已配置，证书路径: ${CERT_PATH}"
```

### 8. 限流配置

在 `http` 块添加 `limit_req_zone`，在 `location /` 中添加 `limit_req`：

```bash
RATE="10r/s"
BURST=20

# 在 http 块添加 zone 定义（在 upstream 之前）
sed_inplace "/upstream backend {/i\\    limit_req_zone \$binary_remote_addr zone=api_limit:10m rate=${RATE};" "$NGINX_CONF"

# 在 location / 中添加 limit_req
sed_inplace "/proxy_pass http:\/\/backend;/a\\            limit_req zone=api_limit burst=${BURST} nodelay;" "$NGINX_CONF"

podman exec ${PREFIX}-nginx nginx -t && podman exec ${PREFIX}-nginx nginx -s reload
echo "限流已配置: ${RATE}, burst=${BURST}"
```

### 9. 缓存配置

```bash
CACHE_PATH="/var/cache/nginx"
CACHE_SIZE="100m"
CACHE_TIME="60m"

# 在 http 块添加缓存定义
sed_inplace "/upstream backend {/i\\    proxy_cache_path ${CACHE_PATH} levels=1:2 keys_zone=backend_cache:10m max_size=${CACHE_SIZE} inactive=${CACHE_TIME};" "$NGINX_CONF"

# 在 location / 中添加缓存
sed_inplace "/proxy_pass http:\/\/backend;/a\\            proxy_cache backend_cache;\n            proxy_cache_valid 200 ${CACHE_TIME};" "$NGINX_CONF"

podman exec ${PREFIX}-nginx nginx -t && podman exec ${PREFIX}-nginx nginx -s reload
echo "缓存已配置: ${CACHE_SIZE}, ${CACHE_TIME}"
```

## 查看当前配置

```bash
PREFIX=$(grep 'container_name:' compose.production.yml | head -1 | sed 's/.*container_name: *//;s/-.*//')
cat nginx/nginx.conf
grep "listen\|server_name\|proxy_pass\|proxy_set_header" nginx/nginx.conf
podman exec ${PREFIX}-nginx nginx -T 2>/dev/null | head -80
```

## 回退配置

```bash
# 列出备份
ls -t nginx/nginx.conf.bak.*

# 恢复指定备份（inode-safe）
LATEST_BAK=$(ls -t nginx/nginx.conf.bak.* 2>/dev/null | head -1)
cat "$LATEST_BAK" > nginx/nginx.conf
podman exec ${PREFIX}-nginx nginx -t && podman exec ${PREFIX}-nginx nginx -s reload
echo "已回退到: $LATEST_BAK"
```
