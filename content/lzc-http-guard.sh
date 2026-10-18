#!/bin/bash
# 懒猫微服：初始化期间的 HTTP 守卫（cont-init 03b，排在 03-config.sh 之后、服务启动之前）。
#
# 背景（对应审核驳回 #20220「启动失败」）：
#   本包现在把数据库初始化（migrate / db:seed）放到后台跑，nginx 会**先**起来。
#   nginx 起来之后、数据库初始化完成之前，PHP 页面会抛 500（例如 "Whoops, looks like
#   something went wrong"），对评审来说就是「界面报错」。
#
# 做法：给 nginx 的 PHP location 加一条判断——
#   /tmp/lzc-php-ok 不存在时，PHP 请求返回 503，并显示一张中文说明页（lzc-starting.html）；
#   初始化脚本 lzc-db-init.sh 完成（或放弃）后会创建该文件，PHP 页面随即放行。
#   静态文件（含平台健康检查用的 /lzc-healthz.txt）不受影响，始终立即可用。
#
# 安全：patch 前备份 /etc/nginx/nginx.conf，patch 后跑 nginx -t；一旦校验失败立即回滚，
# 保证 nginx 一定能起来（宁可没有守卫页，也不能因为守卫把 nginx 弄挂）。
set -u

CONF=/etc/nginx/nginx.conf
BAK=/etc/nginx/nginx.conf.lzc-guard-bak

log() { echo "[lzc-http-guard] $*"; }

if [ ! -f "$CONF" ]; then
  log "nginx.conf 不存在，跳过"
  exit 0
fi

cp "$CONF" "$BAK"

# 1) server 段：503 指向说明页
if ! grep -q 'lzc-starting.html' "$CONF"; then
  ln=$(grep -n '^[[:space:]]*index[[:space:]]\+index\.php;' "$CONF" | head -1 | cut -d: -f1)
  if [ -n "$ln" ]; then
    sed -i "${ln}a\\        error_page 503 /lzc-starting.html;" "$CONF"
    log "已插入 error_page 503"
  else
    log "warning: 找不到 index 行，未插入 error_page"
  fi
fi

# 2) PHP location：初始化未完成时返回 503
if ! grep -q 'lzc-php-ok' "$CONF"; then
  ln=$(grep -n 'location ~ \\\.php\$ {' "$CONF" | head -1 | cut -d: -f1)
  if [ -z "$ln" ]; then
    # 退一步：只要含有 .php$ 的 location 行
    ln=$(grep -n '\.php\$' "$CONF" | head -1 | cut -d: -f1)
  fi
  if [ -n "$ln" ]; then
    sed -i "${ln}a\\            if (!-f /tmp/lzc-php-ok) { return 503; }" "$CONF"
    log "已在 PHP location 插入初始化守卫"
  else
    log "warning: 找不到 PHP location，未插入守卫"
  fi
fi

# 3) 校验；失败就回滚
#
# 注意（本次实测踩到的坑）：`nginx -t` 会打开错误日志、并创建 pid 文件。
# 如果以 root 跑它，这两个文件就变成 root 所有；随后 s6 以 librenms(1000) 身份执行
# `nginx -g "daemon off;"` 时无法覆盖 root 的 pid 文件，nginx 直接
#   [emerg] open() "/var/run/nginx/nginx.pid" failed (13: Permission denied)
# 并且被 s6 反复重启，端口 8000 永远起不来。
# 校验仍然以 root 跑（以 librenms 身份跑时 nginx 连自己的 stderr `/proc/self/fd/2` 都打不开，
# 会误判成配置错误：[emerg] open() "/proc/self/fd/2" failed），随后把两个目录修正干净。
if [ -x "$(command -v nginx)" ]; then
  if nginx -t >/tmp/lzc-nginx-test.log 2>&1; then
    log "nginx -t OK"
  else
    log "nginx -t 失败，回滚原配置：$(tail -2 /tmp/lzc-nginx-test.log 2>/dev/null | tr '\n' ' ')"
    cp "$BAK" "$CONF"
  fi
fi

# 上面以 root 跑的 nginx -t 会把 pid 与错误日志建成 root 属主；而 s6 是用
# librenms(1000) 启动 `nginx -g "daemon off;"` 的，覆盖不了 root 的文件，会直接
#   [emerg] open() "/var/run/nginx/nginx.pid" failed (13: Permission denied)
# 并被 s6 反复重启。这里把运行时目录的属主与内容一次性修正干净。
mkdir -p /var/run/nginx /var/log/nginx
rm -f /var/run/nginx/nginx.pid
chown -R librenms:librenms /var/run/nginx /var/log/nginx 2>/dev/null || true
chmod 755 /var/run/nginx /var/log/nginx 2>/dev/null || true
log "nginx 运行时目录属主已修正为 librenms"

exit 0
