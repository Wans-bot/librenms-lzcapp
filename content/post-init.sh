#!/bin/sh
# LibreNMS 首次初始化（由 entrypoint.sh 后台启动）：
#   1. 等 Web UI 起来（cont-init 的 migrate / db:seed 跑完）
#   2. 建管理员（admin）与演示设备（127.0.0.1，community=librenmsdocker）
#   3. 立刻 discover + poll 一次，让「打开就有真实流量图」成立
#   4. 修 cron 属主：上游把 crontab 建成 root 所有，busybox crond 于是以 root 跑
#      `php artisan schedule:run`，被 LibreNMS 以 "artisan must not run as root" 拒绝，
#      调度器（轮询、告警、维护清理）从此永不执行 —— 表现为设备 "Never polled"、
#      图表全空/500、仪表盘没有任何数据。
#   5. 标记安装完成（去掉 INSTALL）、让 .env 生效（清配置缓存 + 重启 php-fpm）
LOG=/tmp/post-init.log
log() { echo "[post-init] $*" >> "$LOG"; }

# 以 librenms 身份跑 artisan 子命令（LibreNMS 拒绝以 root 运行 poller/schedule 类命令）
as_lnms() { s6-setuidgid librenms "$@"; }

fetch() { # $1=url -> 0 if reachable
  if command -v curl >/dev/null 2>&1; then
    curl -sf -o /dev/null "$1"
  else
    wget -q -O /dev/null "$1"
  fi
}

log "waiting for LibreNMS web UI..."
i=0
while [ "$i" -lt 180 ]; do
  if fetch "http://127.0.0.1:8000/login"; then
    log "web UI reachable"
    break
  fi
  sleep 5
  i=$((i + 1))
done
# give the database migrations a moment to finish
sleep 30

ADMIN_USER="${LNMS_ADMIN_USER:-admin}"
ADMIN_PASS="${LNMS_ADMIN_PASS:-LibreNMS@Lazy2026}"
ADMIN_EMAIL="${LNMS_ADMIN_EMAIL:-admin@librenms.local}"

cd /opt/librenms 2>/dev/null || true

# 创建管理员（首个用户）。
# 幂等：cont-init 的 09-lzc-install.sh 正常情况下已经建好了 admin。这里若无条件再
# `user:add` 一次，users 表里会出现两条 username=admin（唯一索引是 auth_type+username，
# 先建的那条 auth_type 为 NULL 时不冲突），之后每次 POST /login 都会
#   Illuminate\Database\UniqueConstraintViolationException: Duplicate entry 'mysql-admin'
# 整页 "Whoops, looks like something went wrong."（审核驳回截图就是这个）。先查再建。
if [ -n "$(mariadb -N -B -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" \
     -e "SELECT user_id FROM users WHERE username = '$ADMIN_USER' LIMIT 1;" 2>/dev/null | head -1)" ]; then
  log "admin user already exists, skip user:add"
elif ! lnms user:add -r admin -e "$ADMIN_EMAIL" -p "$ADMIN_PASS" "$ADMIN_USER" >>"$LOG" 2>&1; then
  log "user:add returned non-zero"
fi

# 界面语言默认简体中文。
# LibreNMS 的语言来自 users_prefs.locale（由 LoadUserPreferences 中间件读进会话），
# 而命令行建出来的用户没有这条偏好，于是全新安装后页面是英文 —— 官方审核指南
# §8 明确「纯英文界面不予上架」，这正是本次返工要修的一条。
# 这里给管理员写入 zh-CN，使「打开即中文」成立；用户在「设置 → 我的设置」里可再改。
if mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" \
     -e "INSERT INTO users_prefs (user_id, pref, value)
         SELECT user_id, 'locale', 'zh-CN' FROM users WHERE username = '$ADMIN_USER'
         ON DUPLICATE KEY UPDATE value = VALUES(value);" >>"$LOG" 2>&1; then
  log "admin locale -> zh-CN"
else
  log "admin locale set failed"
fi

# 添加演示设备（本机 SNMP）
if ! lnms device:add 127.0.0.1 --v2c -c librenmsdocker >>"$LOG" 2>&1; then
  log "device:add returned non-zero (may already exist)"
fi

# ── 演示数据清理与地理信息（2026-10-13 返工 #20378）─────────────────────────
# 驳回原文：「地图、端口、磁盘io、存储空间信息功能块不可用」。
#   1) 存储页：演示设备是"容器自身"，hrStorage 会把 bind 单文件（/etc/hosts、
#      /lzcapp/run/*.yml）、/proc、/sys 等无意义挂载列为 storage——评审看到
#      "20 行 127.0.0.1"。追加 ignore 规则，只保留有意义条目（如 /data）。
#   2) 地图：演示设备没有经纬度 → /map 页面无标记。写入演示坐标（与设备
#      syslocation 占位一致的"演示"性质），使地理页有可见内容。
# 幂等：重复执行不产生重复配置（先查再写）；升级时会覆盖为同一值。
cfg_add() { # $1=父键 $2=要追加的项
  cur=$(as_lnms php lnms config:get "$1" 2>/dev/null)
  if printf '%s' "$cur" | grep -qF "$2"; then
    log "config $1 already has $2"
  else
    as_lnms php lnms config:set "$1.+" "$2" >>"$LOG" 2>&1 && log "config $1 += $2" || log "config $1 set failed: $2"
  fi
}
for pat in '^\/etc\/' '^\/proc\/' '^\/sys\/' '^\/lzcapp\/' '^\/opt\/librenms\/html\/lzc-'; do
  cfg_add ignore_mount_regexp "/$pat/"
done
# LibreNMS 26 的坐标存在 locations 表（devices 无 lat/lng 列，实测报
# Unknown column 'latitude'）。按 syslocation 的名称匹配（不改名，避免
# discovery 把改动视为新位置而重复建行），设坐标并置 fixed_coordinates=1
# 防止后续 discovery 覆盖。演示坐标与设备 syslocation 的占位性质一致。
mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" \
  -e "UPDATE locations SET lat=39.9042, lng=116.4074, fixed_coordinates=1, timestamp=NOW() WHERE location LIKE '%[Lat, Lon]%';" >>"$LOG" 2>&1 \
  && log "demo device coordinates set on locations (for /map)" || log "coordinates update failed"

# 立刻采集一次：否则新装实例上设备显示 "Never polled"、所有图表 500（RRD 还没生成）。
# 跑两轮 discover+poll：首轮建 OS/端口/存储，部分模块（处理器、内存池等）要等首轮结果
# 落库后才会被发现，只跑一轮的话设备页会出现 "No Processors" 和空白图表。
for round in 1 2; do
  if as_lnms php lnms device:discover 127.0.0.1 >>"$LOG" 2>&1; then
    log "discover round $round ok"
  else
    log "discover round $round failed (scheduler will retry)"
  fi
  if as_lnms php lnms device:poll 127.0.0.1 >>"$LOG" 2>&1; then
    log "poll round $round ok"
  else
    log "poll round $round failed (scheduler will retry)"
  fi
done

# 全量 discovery 不一定能把 hr-mib 的处理器模块跑出来（SNMP 走 hrProcessorLoad 的表，
# 采集窗口内有负载/超时就会拿到空表），设备页于是显示 "No Processors" 和空白图表。
# 这里显式指定模块重试几次，确认处理器进库后再 poll 一次建 RRD。
db_count() { # $1=sql
  mariadb -N -B -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -e "$1" 2>/dev/null | head -1
}
attempt=0
while [ "$attempt" -lt 4 ]; do
  attempt=$((attempt + 1))
  procs=$(db_count "SELECT COUNT(*) FROM processors;")
  case "$procs" in
    ''|0) : ;;
    *) log "processors discovered: $procs"; break ;;
  esac
  as_lnms php lnms device:discover 127.0.0.1 -m processors >>"$LOG" 2>&1 || true
  as_lnms php lnms device:poll 127.0.0.1 >>"$LOG" 2>&1 || true
  [ "$attempt" -lt 4 ] && sleep 10
done
[ "${procs:-0}" = "0" ] && log "processors still missing after $attempt attempt(s); periodic discovery will pick them up"

# --- 默认仪表盘 ---
# 命令行建出来的用户在「概况」页只有一个空占位块（要自己点 Edit Dashboard 加组件），
# 新装打开就是一片空白。这里按用户第一次会做的操作，预置几个立刻有数据的组件。
# 标题取 LibreNMS 自带的语言包（zh-CN 优先，回退 en），与界面语言一致。
widget_title() { # $1=widget type
  php -r '$t = $argv[1];
    foreach (["zh-CN", "en"] as $l) {
      $f = "/opt/librenms/lang/$l/widgets.php";
      if (is_file($f)) { $a = include $f; if (!empty($a[$t]["title"])) { echo $a[$t]["title"]; exit; } }
    }' "$1" 2>/dev/null
}

seed_dashboard() {
  db() { mariadb -N -B -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -e "$1" 2>/dev/null; }
  dash_id=$(db "SELECT d.dashboard_id FROM dashboards d JOIN users u ON u.user_id = d.user_id WHERE u.username = '$ADMIN_USER' AND d.dashboard_name = 'Default' LIMIT 1;" | head -1)
  if [ -z "$dash_id" ]; then
    # 「Default」仪表盘是首次打开页面时才懒创建的，命令行建的用户还没有，这里补上
    db "INSERT INTO dashboards (user_id, dashboard_name, access) SELECT user_id, 'Default', 0 FROM users WHERE username = '$ADMIN_USER';" >/dev/null
    dash_id=$(db "SELECT d.dashboard_id FROM dashboards d JOIN users u ON u.user_id = d.user_id WHERE u.username = '$ADMIN_USER' AND d.dashboard_name = 'Default' LIMIT 1;" | head -1)
  fi
  [ -n "$dash_id" ] || { log "dashboard seed skipped (no Default dashboard)"; return; }
  have=$(db "SELECT COUNT(*) FROM users_widgets WHERE dashboard_id = $dash_id;" | head -1)
  [ "$have" = "0" ] || { log "dashboard already has $have widget(s)"; return; }

  # 布局：设备摘要（整行）→ 告警日志 + 事件日志（左右）→ 可用性地图（整行）
  for spec in "device-summary-horiz|1|1|12|3" "alertlog|1|4|6|3" "eventlog|7|4|6|3" "availability-map|1|7|12|4"; do
    type=${spec%%|*}; rest=${spec#*|}
    col=${rest%%|*}; rest=${rest#*|}
    row=${rest%%|*}; rest=${rest#*|}
    sx=${rest%%|*}; sy=${rest##*|}
    title=$(widget_title "$type")
    [ -n "$title" ] || title=$type
    db "INSERT INTO users_widgets (user_id, widget, col, row, size_x, size_y, title, refresh, settings, dashboard_id)
        SELECT user_id, '$type', $col, $row, $sx, $sy, '$title', 60, '', $dash_id FROM dashboards WHERE dashboard_id = $dash_id;" >/dev/null || log "widget $type insert failed"
  done
  log "dashboard seeded with default widgets"
}
seed_dashboard

# --- 调度器可用性 ---
# 上游 07-svc-cron.sh 以 root 创建 /var/spool/cron/crontabs/librenms，busybox crond
# 按 crontab 文件属主决定以谁的身份执行 → root → LibreNMS 直接拒绝
# （RunningAsIncorrectUserException: artisan must not run as root），
# 于是 schedule:run（轮询/告警/维护）永不执行。改属主即可让调度器真正跑起来。
if [ -f /var/spool/cron/crontabs/librenms ]; then
  if chown librenms:librenms /var/spool/cron/crontabs/librenms 2>/dev/null; then
    log "crontab ownership -> librenms"
  else
    log "crontab chown failed"
  fi
  s6-svc -r /var/run/s6/services/cron 2>/dev/null || true
fi

# --- Mixed Content 修复 ---
# 懒猫 ingress 转发到容器时请求 scheme 是 http。LibreNMS 页面用 Laravel asset() 生成
# 静态资源 URL，asset() 默认取「当前请求的 scheme + host」→ 生成 http://<子域名>/...，
# 浏览器在 HTTPS 页面下以 Mixed Content 拦截全部 css/js（jQuery 未加载 → "$ is not defined"）。
# 正常路径由 entrypoint.sh 预写 /data/.env 完成（第一个请求即生效）；这里兜住旧实例升级。
if [ -n "$LAZYCAT_APP_DOMAIN" ] && ! grep -q '^ASSET_URL=' /opt/librenms/.env 2>/dev/null; then
  log "writing ASSET_URL=https://${LAZYCAT_APP_DOMAIN}"
  echo "ASSET_URL=https://${LAZYCAT_APP_DOMAIN}" >> /opt/librenms/.env
fi

# 让 LibreNMS 信任上游代理的 X-Forwarded-Proto（否则登录表单会指向 http://）。
if ! grep -q '^APP_TRUSTED_PROXIES=' /opt/librenms/.env 2>/dev/null; then
  log "writing APP_TRUSTED_PROXIES=*"
  echo 'APP_TRUSTED_PROXIES=*' >> /opt/librenms/.env
else
  sed -i 's#^APP_TRUSTED_PROXIES=.*#APP_TRUSTED_PROXIES=*#' /opt/librenms/.env
fi

# --- 标记安装完成 ---
# 首次启动 DB 为空时 cont-init 会写入 INSTALL=user,finish 触发首次运行向导（/install）。
# 这里已用命令行建好 admin 用户与演示设备（等价于走完向导），从 .env 移除 INSTALL 行，
# 避免用户被卡在 /install/user 向导页。
if grep -q '^INSTALL=' /opt/librenms/.env 2>/dev/null; then
  log "removing INSTALL from .env (mark install complete)"
  sed -i '/^INSTALL=/d' /opt/librenms/.env
fi

# --- 让 .env 改动生效 ---
# cont-init 执行过 `artisan config:cache`，Laravel 会一直读缓存里的旧配置；
# artisan 拒绝以 root 运行，这里直接删除缓存文件让配置在下次请求时重建，
# 并重启 php-fpm 以丢弃 opcache 中的旧配置。
rm -f /opt/librenms/bootstrap/cache/config.php 2>/dev/null || true
s6-svc -r /var/run/s6/services/php-fpm 2>/dev/null || true

log "done"
