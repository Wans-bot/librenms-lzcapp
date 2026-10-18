#!/bin/bash
# 懒猫微服：LibreNMS 的数据库初始化（由 entrypoint.sh 在后台启动）。
#
# 为什么要有这个脚本（对应审核驳回 #20220「启动失败」、#19181「启动失败，重启进入后登录失败」）：
#   上游把「等数据库 → lnms migrate → db:seed」放在 s6 的 cont-init 阶段，而 nginx/php-fpm
#   的服务定义也是那段脚本在 migrate 之后才写的 —— 于是 **migrate 跑完之前容器根本不监听 8000**。
#   平台自己的健康检查（librenms:8000）在这个窗口里一直是 connection refused，
#   数据库慢的机器上窗口是几分钟到十几分钟，超过 start_period 后评审看到的就是
#   「应用状态错误 / 启动失败」。
#
#   本脚本把这套步骤整个搬到后台：
#     entrypoint.sh 先把 nginx/php-fpm 的服务定义写出来 → s6 立即拉起端口
#     → 静态健康检查文件立刻 200 → 本脚本在后台完成数据库初始化
#     → 完成后放行 PHP 页面（/tmp/lzc-php-ok）。
#
# 顺序（每一步都留日志）：
#   1) 等数据库可连接（DB_TIMEOUT，默认 1800s）
#   2) 跑上游 /opt/lzc-04-svc-main.sh（migrate + db:seed + cache + 服务定义，内容未改）
#   3) 跑 lzc-install.sh（建管理员、移除 INSTALL、清配置缓存）—— 不向用户暴露首装向导
#   4) 放行 PHP 页面
#   5) 跑 post-init.sh（演示设备、首次轮询、默认中文、cron 属主）
#
# 失败兜底：无论成败都会放行 PHP 页面（第 4 步），让用户看到 LibreNMS 自己的错误页，
# 而不是被守卫永久挡在「正在初始化」页上。

set -u

CONTENT=/lzcapp/pkg/content
LNMS_PATH=/opt/librenms
LNMS_ENV=${LNMS_PATH}/.env
READY_MARK=/tmp/lzc-php-ok
DB_TIMEOUT=${DB_TIMEOUT:-1800}

log() { echo "[lzc-db-init] $*"; }

env_get() { # 从 /opt/librenms/.env 取键值（去引号）
  sed -n "s/^$1=//p" "$LNMS_ENV" 2>/dev/null | tail -1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//"
}

# 以进程环境优先，其次解析 /opt/librenms/.env（Laravel 的键名），最后默认值
DB_HOST=${DB_HOST:-$(env_get DB_HOST)}
DB_PORT=${DB_PORT:-$(env_get DB_PORT)}
DB_USER=${DB_USER:-$(env_get DB_USERNAME)}
DB_NAME=${DB_NAME:-$(env_get DB_DATABASE)}
DB_PASSWORD=${DB_PASSWORD:-$(env_get DB_PASSWORD)}
DB_HOST=${DB_HOST:-db}
DB_PORT=${DB_PORT:-3306}
DB_USER=${DB_USER:-librenms}
DB_NAME=${DB_NAME:-librenms}

CLIENT=$(command -v mariadb || command -v mysql || echo MISSING)
log "start: host=$DB_HOST port=$DB_PORT user=$DB_USER db=$DB_NAME pwlen=${#DB_PASSWORD} client=$CLIENT timeout=${DB_TIMEOUT}s"

dbq() {
  "$CLIENT" -N -B -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -e "$1" 2>/dev/null
}

# ---- 1) 等数据库 ----
if [ "$CLIENT" = "MISSING" ]; then
  log "没有 mariadb/mysql 客户端，跳过等待（交给上游脚本）"
else
  waited=0
  until dbq "SELECT 1;" >/dev/null 2>&1; do
    if [ "$waited" -ge "$DB_TIMEOUT" ]; then
      log "等待数据库超时（${DB_TIMEOUT}s），放行 PHP 页面交给上层排查"
      touch "$READY_MARK"
      exit 0
    fi
    sleep 5
    waited=$((waited + 5))
    if [ $((waited % 60)) -eq 0 ]; then log "still waiting for database (${waited}s)"; fi
  done
  log "database reachable after ${waited}s"
fi

# ---- 2) 上游 04：migrate / db:seed / cache / 服务定义 ----
if [ -f /opt/lzc-04-svc-main.sh ]; then
  log "running upstream 04-svc-main.sh (migrate + seed)"
  if bash /opt/lzc-04-svc-main.sh; then
    log "upstream 04-svc-main.sh OK"
  else
    log "upstream 04-svc-main.sh FAILED (rc=$?)，放行 PHP 页面"
    touch "$READY_MARK"
    exit 0
  fi
else
  log "warning: /opt/lzc-04-svc-main.sh missing"
fi

# ---- 3) 建管理员 / 移除 INSTALL（不暴露首装向导） ----
if [ -f "$CONTENT/lzc-install.sh" ]; then
  log "running lzc-install.sh (admin + remove INSTALL)"
  bash "$CONTENT/lzc-install.sh" || log "lzc-install.sh returned non-zero"
fi

# ---- 4) 放行 PHP 页面 ----
touch "$READY_MARK"
log "php pages released ($READY_MARK)"

# ---- 5) post-init：演示设备、首次轮询、默认中文、cron 属主 ----
if [ -f "$CONTENT/post-init.sh" ]; then
  log "running post-init.sh"
  bash "$CONTENT/post-init.sh" || log "post-init.sh returned non-zero"
fi

log "done"
