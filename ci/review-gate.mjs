#!/usr/bin/env node
// 审核闸门：若该应用已有「待审」审核单，则跳过本次自动发布，避免每次运行都取消并重建审核单。
//
// 背景：ca-x action 的 skip_if_version_exists 只比对**已在线版本**，不知道「待审」状态。
// 按计划每天跑的话，同一版本会被反复提交，前一张审核单被系统取消 → 永远等不到审核结果。
//
// 用法: node ci/review-gate.mjs <package>
// 环境: LZC_USER_TOKEN（开发者 token，CI 里就是 secrets.LAZYCAT_TOKEN）
// 输出: $GITHUB_OUTPUT 的 skip=true|false
import fs from 'node:fs';

const API = 'https://appstore.api.lazycat.cloud/api/v3/developer';
const pkg = process.argv[2];
const TOKEN = process.env.LZC_USER_TOKEN || '';
const OUT = process.env.GITHUB_OUTPUT;

function emit(skip, why) {
  console.log(`[review-gate] skip=${skip} — ${why}`);
  if (OUT) fs.appendFileSync(OUT, `skip=${skip}\n`);
  process.exit(0);
}

// ── 黑名单硬闸（最高优先级，不依赖 token）─────────────────────────
// 权威来源：/lzcapp/document/智能体知识库/records/lpk-selection-preference-and-blacklist.md
// 命中即拒绝提交官方商店。修改黑名单必须同步更新所有仓库的副本。
// 权威来源：/lzcapp/document/智能体知识库/references/方法文档/06-选品方法.md §4 黑名单
// 命中即拒绝提交官方商店。修改黑名单必须同步更新所有仓库的副本。
const BLACKLIST = new Set([
  'alfio', 'azuracast', 'bambuddy1', 'ekko-studio',
  'ente', 'evcc1', 'flarum-forum', 'fuxa',
  'hindsight', 'humhub', 'jimureport',
  'jitsi', 'kolibri', 'librenms', 'llamafactory',
  'loomio', 'mantisbt', 'meedu', 'mlflow',
  'moviepilot', 'nodebb', 'ocs-inventory', 'offen',
  'openbiliclaw', 'openmetadata', 'openproject-ce', 'opensourcepos',
  'orangehrm', 'osticket', 'partdb1', 'perler-beads',
  'phpipam', 'picimpact', 'podfetch1', 'poster-design',
  'ragflow', 'relaydesk', 'romm-hub', 'slskd',
  'taiga', 'tick-stock-panel', 'traccar', 'umap',
  'wavelog', 'wazuh', 'wizarr', 'xzs',
  'zabbix', 'zulip',
]);
const shortId = String(pkg).replace(/^cloud\.lazycat\.apps?\./, '');

// 黑名单只拦「新选品上架」，不拦「已在架应用的维护性更新」：
// 应用已经建档在开发者后台（说明当初就是按显式要求提交过、并且在架），
// 后续版本更新属于修 bug / 跟随上游，不构成新选品，不能被黑名单判死。
// 顺序上必须等 app/list 查到建档记录后再判定，所以这里只先记标记。
const blacklisted = BLACKLIST.has(shortId);
const rejectBlacklisted = () => {
  console.error(
    `[review-gate] ❌ 拒绝发布：${pkg} 命中黑名单（${shortId}），且开发者后台查无此应用的建档记录。\n` +
    `  依据 records/lpk-selection-preference-and-blacklist.md —— 该应用禁止提交官方商店。\n` +
    `  若确属误判，请先修改黑名单文件并同步更新本脚本，不要绕过闸门。`
  );
  process.exit(1);
};

// tag 推送是显式发布意图，绕过闸门
if (process.env.GITHUB_EVENT_NAME === 'push' && !blacklisted) emit(false, 'tag 推送，按显式意图发布');
// 黑名单应用即使 tag 推送也要先确认「是否已在架」，避免绕过闸门
if (!pkg) emit(false, '未提供 package，放行');
if (!TOKEN) {
  if (blacklisted) console.warn(`[review-gate] ⚠️ ${shortId} 在黑名单里，但缺少 LZC_USER_TOKEN 无法判断是否已在架，放行以免挡住自动更新`);
  emit(false, '缺少 LZC_USER_TOKEN，放行（无法判断待审状态）');
}

const HEAD = { 'X-User-Token': TOKEN, Cookie: `userToken=${TOKEN}`, 'Content-Type': 'application/json' };

try {
  let list;
  for (let i = 0; i < 3; i++) {
    const r = await fetch(`${API}/app/list?size=200`, { headers: HEAD, signal: AbortSignal.timeout(30000) });
    const t = await r.text();
    if (r.status >= 400) throw new Error(`HTTP ${r.status} ${t.slice(0, 120)}`);
    list = JSON.parse(t);
    break;
  }
  const apps = list.items || list.list || (Array.isArray(list) ? list : []);
  const app = apps.find((a) => a && a.package === pkg);
  if (!app) {
    if (blacklisted) rejectBlacklisted();
    emit(false, `应用 ${pkg} 尚无建档记录，放行让 action 处理`);
  }

  if (blacklisted) {
    console.warn(
      `[review-gate] ⚠️ ${shortId} 在黑名单里，但已在开发者后台建档（app_id=${app.id}, resource_id=${app.resource_id}）。\n` +
      `  判定为「已在架应用的维护性更新」，放行；黑名单只约束新选品上架。`
    );
  }

  const rv = app.review;
  if (rv && String(rv.status) === '0') {
    emit(true, `已有待审审核单 #${rv.id}（提交于 ${rv.created_at || '?'}），等审核出结果再发`);
  }
  emit(false, `当前没有待审审核单（最近一张 #${rv && rv.id} 状态 ${rv && rv.status}），可以发布`);
} catch (e) {
  emit(false, `查询失败（${e.message}），放行以免挡住自动更新`);
}
