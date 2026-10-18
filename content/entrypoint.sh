#!/bin/sh
# LibreNMS 懒猫微服入口包装。做六件事：
#
# 1) 启动前把平台相关变量预写进 /data/.env。
#    上游 /etc/cont-init.d/04-svc-main.sh 会把 /data/.env 追加进 /opt/librenms/.env。
#
# 2) 生成并持久化 Web Push 的 VAPID 密钥（详见旧版注释：缺它 /push/key 会 500）。
#
# 3) 中和上游 cont-init 里必然失败的时区写操作（懒猫只读绑定 /etc/localtime、/etc/timezone）。
#
# 4) 【本版新增】把 nginx / php-fpm / snmpd 的 s6 服务定义**自己写出来**，并从 cont-init 里
#    摘下上游的 04-svc-main.sh。
#    原因（对应审核驳回 #20220「启动失败」）：上游把「等数据库 → migrate → db:seed」
#    放在 cont-init 阶段，而 **HTTP 端口（8000）直到 migrate 跑完才会被 nginx 监听**。
#    数据库慢一点的机器上，这个窗口就是几分钟到十几分钟：平台自己的健康检查
#    （application.health_check.test_url 指向 librenms:8000）一直 connection refused，
#    超过 start_period 之后评审看到的就是「应用状态错误 / 启动失败」。
#    现在把数据库初始化挪到后台（lzc-db-init.sh），nginx/php-fpm 由 s6 立即拉起：
#    端口几秒内就绪，静态健康检查文件立刻 200；真正依赖数据库的 PHP 页面在初始化完成前
#    返回一张「正在初始化」页（见 03b-lzc-http-guard.sh），不再出现 connection refused。
#
# 5) 【本版新增】安装 /etc/cont-init.d/03b-lzc-http-guard.sh：给 nginx 的 PHP location
#    加一道「初始化未完成时返回 503 + 说明页」的守卫。
#
# 6) 后台跑 lzc-db-init.sh：等数据库 → 上游 04-svc-main.sh（migrate/seed/cache）
#    → 建管理员并移除 INSTALL → 拆掉 03b 的守卫 → post-init（演示设备、轮询、语言、cron 属主）。

DATA_ENV=/data/.env
LNMS_ENV=/opt/librenms/.env
CONTENT=/lzcapp/pkg/content

# ---------- 1) 预写 /data/.env ----------
# 注意：/data/.env 不存在时必须连 APP_KEY/NODE_ID 一起创建。
# 上游 04-svc-main.sh 只在「文件不存在」时才生成 APP_KEY，如果这里只写自己的变量，
# 应用会拿不到 APP_KEY 而直接启动失败。
if [ ! -d /data ]; then
  mkdir -p /data
fi
if [ ! -f "$DATA_ENV" ]; then
  {
    echo "APP_KEY=base64:$(php -r 'echo base64_encode(random_bytes(32));')"
    echo "NODE_ID=$(php -r 'echo uniqid();')"
  } > "$DATA_ENV"
fi

# 只在缺失时补写，避免每次启动覆盖（VAPID 密钥一旦变化，已注册的推送订阅就失效）
ensure_kv() { # $1=key $2=value
  if ! grep -q "^$1=" "$DATA_ENV" 2>/dev/null; then
    echo "$1=$2" >> "$DATA_ENV"
  fi
}

# 让 LibreNMS 信任上游代理的 X-Forwarded-Proto: https（容器只在应用内网暴露，置 * 即可）
ensure_kv APP_TRUSTED_PROXIES '*'

if [ -n "$LAZYCAT_APP_DOMAIN" ]; then
  ensure_kv ASSET_URL "https://${LAZYCAT_APP_DOMAIN}"
fi

# ---------- 2) VAPID 密钥（/push/key 500 的根治） ----------
if ! grep -q '^VAPID_PUBLIC_KEY=' "$DATA_ENV" 2>/dev/null; then
  keys=$(php -r 'require "/opt/librenms/vendor/autoload.php"; $k=Minishlink\WebPush\VAPID::createVapidKeys(); echo $k["publicKey"], " ", $k["privateKey"];' 2>/dev/null)
  pub=${keys%% *}
  priv=${keys##* }
  if [ -n "$pub" ] && [ -n "$priv" ] && [ "$pub" != "$priv" ]; then
    echo "VAPID_PUBLIC_KEY=$pub" >> "$DATA_ENV"
    echo "VAPID_PRIVATE_KEY=$priv" >> "$DATA_ENV"
  fi
fi
ensure_kv VAPID_PUBLIC_KEY ''
ensure_kv VAPID_PRIVATE_KEY ''
ensure_kv VAPID_SUBJECT 'mailto:admin@librenms.local'

# ---------- https base_url ----------
if [ -n "$LAZYCAT_APP_DOMAIN" ]; then
  export LIBRENMS_BASE_URL="https://${LAZYCAT_APP_DOMAIN}/"
fi

# 兜住「.env 已存在」的路径
if [ -f "$LNMS_ENV" ]; then
  grep -q '^APP_TRUSTED_PROXIES=' "$LNMS_ENV" \
    && sed -i 's#^APP_TRUSTED_PROXIES=.*#APP_TRUSTED_PROXIES=*#' "$LNMS_ENV" \
    || echo 'APP_TRUSTED_PROXIES=*' >> "$LNMS_ENV"
fi

# ---------- 3) 中和必定失败的时区写操作 ----------
sed -i \
  -e 's#^ln -snf /usr/share/zoneinfo/.*#true#' \
  -e 's#^echo .*>/etc/timezone#true#' \
  /etc/cont-init.d/03-config.sh 2>/dev/null || true

# ---------- 4) HTTP 服务定义 + 把数据库初始化移出 cont-init ----------
# 与上游 04-svc-main.sh 里写的完全一致，只是提前到这里，让端口先起来。
PUID_V="${PUID:-1000}"
PGID_V="${PGID:-1000}"

mkdir -p /etc/services.d/nginx
cat >/etc/services.d/nginx/run <<EOL
#!/usr/bin/execlineb -P
with-contenv
s6-setuidgid ${PUID_V}:${PGID_V}
nginx -g "daemon off;"
EOL
chmod +x /etc/services.d/nginx/run

mkdir -p /etc/services.d/php-fpm
cat >/etc/services.d/php-fpm/run <<EOL
#!/usr/bin/execlineb -P
with-contenv
s6-setuidgid ${PUID_V}:${PGID_V}
php-fpm84 -F
EOL
chmod +x /etc/services.d/php-fpm/run

mkdir -p /etc/services.d/snmpd
cat >/etc/services.d/snmpd/run <<EOL
#!/usr/bin/execlineb -P
with-contenv
/usr/sbin/snmpd -f -c /etc/snmp/snmpd.conf
EOL
chmod +x /etc/services.d/snmpd/run

# 把上游的 04-svc-main.sh 从 cont-init 目录移走（s6 只跑 cont-init.d 里的脚本），
# 改由 lzc-db-init.sh 在后台调用，内容不改。
if [ -f /etc/cont-init.d/04-svc-main.sh ]; then
  mv /etc/cont-init.d/04-svc-main.sh /opt/lzc-04-svc-main.sh
  chmod +x /opt/lzc-04-svc-main.sh
fi

# ---------- 5) 初始化守卫（PHP 页面在初始化完成前给说明页） ----------
if [ -f "$CONTENT/lzc-http-guard.sh" ]; then
  cp "$CONTENT/lzc-http-guard.sh" /etc/cont-init.d/03b-lzc-http-guard.sh
  chmod +x /etc/cont-init.d/03b-lzc-http-guard.sh
fi

# ---------- 6) 轮询/发现调度器（dispatcher） ----------
# 本版本 LibreNMS 的定时轮询不在 Laravel scheduler 里，而由 dispatcher 守护进程管理。
mkdir -p /etc/services.d/lzc-dispatcher
cat >/etc/services.d/lzc-dispatcher/run <<'EOL'
#!/usr/bin/execlineb -P
with-contenv
s6-setuidgid librenms
cd /opt/librenms
./librenms-service.py
EOL
chmod +x /etc/services.d/lzc-dispatcher/run

# ---------- 7) 后台数据库初始化（替代 cont-init 里的阻塞步骤） ----------
# 日志同时进容器 stdout 与 /tmp/lzc-db-init.log。
setsid sh "$CONTENT/lzc-db-init.sh" >>/tmp/lzc-db-init.log 2>&1 &

exec /init
