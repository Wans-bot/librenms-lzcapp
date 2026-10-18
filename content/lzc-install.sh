#!/bin/bash
# 懒猫微服：首装不向用户暴露 LibreNMS 的「首次运行向导」（/install）。
#
# 背景（有实测证据）：
#   上游 /etc/cont-init.d/04-svc-main.sh 在「DB 里还没有任何表」时执行
#       echo "INSTALL=user,finish" >> /opt/librenms/.env
#   于是 s6 起 nginx/php-fpm 之后，任何访问者看到的都是 "Create Admin User" 向导页，
#   而不是登录页。我们的免密登录注入脚本（auto-login.js）会在这个页面上找到
#   username/password 输入框并「自动提交」它 —— 结果是 users 表里出现第一个 admin；
#   随后 post-init.sh 又 `lnms user:add admin` 建了第二个 admin。users 上的唯一索引是
#   users_auth_type_username_unique，于是之后每次 POST /login 都会
#       Illuminate\Database\UniqueConstraintViolationException
#       SQLSTATE[23000]: Integrity constraint violation: 1062
#       Duplicate entry 'mysql-admin' for key 'users_auth_type_username_unique'
#       (SQL: update `users` set `auth_type` = mysql, `auth_id` = 1 ... where `user_id` = 1)
#   整页渲染成 "Whoops, looks like something went wrong. Check your librenms.log."
#   —— 这正是本次审核驳回截图（cloud.lazycat.app.librenms #19695）。
#
# 对策：cont-init 阶段（**服务启动之前**）就把安装状态收尾：
#   1) 用命令行建好管理员（等价于走完向导）；
#   2) 确认管理员存在后，从 .env 删除 INSTALL 行；
#   3) 删掉 04 生成的 config 缓存，让随后启动的 php-fpm 读到新配置。
# 这样第一个 HTTP 请求看到的就是 /login 登录页，注入脚本只会在真正的登录表单上工作。
#
# 脚本名 09-* ：s6-overlay 按文件名字典序执行 cont-init，09 排在 04-svc-main.sh（它做
# migrate / db:seed / config:cache）以及 05~08 之后，且全部 cont-init 跑完才会起服务。
#
# 注意（踩过的坑）：04-svc-main.sh 用的是 **进程环境变量** DB_HOST/DB_USER/DB_NAME/
# DB_PASSWORD，而且它在第 59 行 `unset DB_PASSWORD`；/opt/librenms/.env 里存的又是
# Laravel 自己的键名 DB_HOST/DB_PORT/DB_DATABASE/DB_USERNAME/DB_PASSWORD。所以本脚本
# 的取值顺序是「进程环境优先，其次解析 /opt/librenms/.env」，两边都拿不到才用默认值，
# 并且把探测失败原因原样打进容器日志，避免再次出现「静默 30 次空结果」。
set -u

LNMS_PATH=/opt/librenms
LNMS_ENV=${LNMS_PATH}/.env
ADMIN_USER="${LNMS_ADMIN_USER:-admin}"
ADMIN_PASS="${LNMS_ADMIN_PASS:-LibreNMS@Lazy2026}"
ADMIN_EMAIL="${LNMS_ADMIN_EMAIL:-admin@librenms.local}"

log() { echo "[lzc-install] $*"; }

# 从 /opt/librenms/.env 里取 KEY 的值（去掉可能的引号）
env_get() {
  sed -n "s/^$1=//p" "$LNMS_ENV" 2>/dev/null | tail -1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//"
}

DB_HOST=${DB_HOST:-$(env_get DB_HOST)}
DB_PORT=${DB_PORT:-$(env_get DB_PORT)}
DB_USER=${DB_USER:-$(env_get DB_USERNAME)}
DB_NAME=${DB_NAME:-$(env_get DB_DATABASE)}
DB_PASSWORD=${DB_PASSWORD:-$(env_get DB_PASSWORD)}
DB_HOST=${DB_HOST:-db}
DB_PORT=${DB_PORT:-3306}
DB_USER=${DB_USER:-librenms}
DB_NAME=${DB_NAME:-librenms}

log "env: host=$DB_HOST port=$DB_PORT user=$DB_USER db=$DB_NAME pwlen=${#DB_PASSWORD} client=$(command -v mariadb || echo MISSING)"

dbq() { # $1=SQL
  mariadb -N -B -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -e "$1"
}
admin_exists() {
  [ -n "$(dbq "SELECT user_id FROM users WHERE username='${ADMIN_USER}' LIMIT 1;" 2>/dev/null)" ]
}

# --- 1) 等 users 表出现（04 已经跑完 migrate，正常这里立刻就绪） ---
tbl=""
for i in $(seq 1 30); do
  raw=$(dbq "SHOW TABLES LIKE 'users';" 2>&1); rc=$?
  if [ $rc -eq 0 ] && [ -n "$raw" ]; then tbl="$raw"; break; fi
  # 前两次把真实错误打出来，便于排查（此前静默 30 次空结果，白等 60s）
  if [ "$i" -le 2 ]; then
    log "probe#$i rc=$rc detail=$(printf '%s' "$raw" | tr '\n' ' ' | cut -c1-220)"
  fi
  sleep 2
done
if [ -n "$tbl" ]; then log "users 表已就绪"; else log "users 表 60s 内未出现"; fi

# --- 2) 建管理员：以 lnms 的返回值为准，DB 探测只作辅助（幂等） ---
admin_ok=0
for i in 1 2 3; do
  if admin_exists; then admin_ok=1; log "管理员 ${ADMIN_USER} 已存在"; break; fi
  log "创建管理员 ${ADMIN_USER}（第 ${i} 次）..."
  out=$(cd "$LNMS_PATH" && s6-setuidgid librenms ./lnms user:add -r admin \
          -e "$ADMIN_EMAIL" -p "$ADMIN_PASS" "$ADMIN_USER" 2>&1); rc=$?
  log "lnms user:add rc=$rc out=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-220)"
  if [ $rc -eq 0 ]; then admin_ok=1; break; fi
  if printf '%s' "$out" | grep -qiE 'already exists|duplicate|unique'; then admin_ok=1; break; fi
  if admin_exists; then admin_ok=1; break; fi
  sleep 3
done

# --- 3) 只有管理员确实存在，才标记安装完成（否则宁可保留向导，避免无人可登录） ---
if [ "$admin_ok" != 1 ]; then
  log "管理员未确认存在，保留 INSTALL（post-init 仍会兜底）"
  exit 0
fi
log "管理员 ${ADMIN_USER} 就绪，开始收尾安装状态"

if grep -q '^INSTALL=' "$LNMS_ENV" 2>/dev/null; then
  sed -i '/^INSTALL=/d' "$LNMS_ENV"
  log "已从 .env 移除 INSTALL，首次运行向导不再出现"
else
  log ".env 里没有 INSTALL 行（无需处理）"
fi

# 04 执行过 `artisan config:cache`，Laravel 会一直读 bootstrap/cache/config.php 里的旧值，
# 删掉它使配置在 php-fpm 启动后的第一个请求里重建（php-fpm 还由 s6 启动，未运行）。
rm -f "${LNMS_PATH}/bootstrap/cache/config.php" 2>/dev/null || true
chown librenms:librenms "$LNMS_ENV" 2>/dev/null || true

exit 0
