/*
 * 给最后一批硬编码 UI 文案补资源键（base 中文 + en_US 英文）。
 * 只追加缺失键，不覆盖已有值。
 * 用法：node tools/i18n-add-ui-keys.cjs
 */
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const baseFile = path.join(root, 'entry/src/main/resources/base/element/string.json');
const enFile = path.join(root, 'entry/src/main/resources/en_US/element/string.json');

const rows = [
  ['login_probe_busy', '正在核对…', 'Checking…'],
  ['login_probe_hint', '账号密码对不对？点这里用 IG 网页接口核对一次', 'Not sure about the password? Tap here to check it against Instagram’s web API.'],
  ['login_web_retry_hint', '还是进不去？用网页登录一次（能过人机验证）', 'Still can’t get in? Try signing in on the web page (it can pass the human check).'],
  ['settings_doh_scope_hint', 'HTTP、内置网页与登录链都改走加密 DNS；失败会在网页/登录链上自动退回系统解析。', 'HTTP, the built-in web page and the sign-in chain all use encrypted DNS; the web page and sign-in chain fall back to system DNS if that fails.'],
  ['settings_relay_endpoint', '中转上报地址', 'Relay report URL'],
  ['settings_relay_key', '共享密钥（可空，对应 relay 的 key）', 'Shared key (optional, matches the relay key)'],
  ['settings_relay_key_hint', '随便一串字符，和 relay 保持一致', 'Any string, as long as it matches the relay'],
  ['settings_relay_disabled', '已关闭中转上报', 'Relay reporting is off'],
  ['settings_clear_device_hint', '先退出登录，再清设备认证', 'Sign out first, then clear device credentials'],
  ['settings_login_help', '登录失败时：先点「登录通道自检」，再点「复制登录日志」把内容发我。\\n', 'If sign-in fails: run “Sign-in channel self-test”, then “Copy sign-in log” and send me the text.\\n'],
  ['settings_login_selftest_running', '正在自检登录通道（最多 15 秒）…', 'Running sign-in channel self-test (up to 15 s)…'],
  ['settings_ip_check_running', '正在查出口 IP（最多 10 秒）…', 'Checking egress IP (up to 10 s)…'],
  ['settings_ip_datacenter', '这是机房 IP，建议换节点再试', 'This is a datacenter IP. Try another node.'],
  ['settings_ip_normal', '这条线路看着正常', 'This route looks normal'],
  ['settings_login_log_copied', '登录日志已复制（粘贴发给开发者）', 'Sign-in log copied (paste it to the developer)'],
  ['settings_meow_login_sending', '正在推送登录日志到 MeoW…', 'Sending sign-in log to MeoW…'],
  ['settings_reels_log_empty', '还没有 reels 崩溃日志（没进过 reels，或日志已被清掉）', 'No Reels crash log yet (Reels not opened, or the log was cleared)'],
  ['settings_reels_log_prefix', '（设备与版本：%s）\\n\\n', '(Device and version: %s)\\n\\n'],
  ['settings_meow_reels_sending', '正在推送 reels 崩溃日志到 MeoW…', 'Sending Reels crash log to MeoW…'],
  ['login_error_transport', '登录请求异常：%s', 'Sign-in request failed: %s'],
  ['login_ok_session_pending', '%s成功（移动会话材料未就绪）', '%s succeeded (mobile session material not ready)'],
  ['system_http_failed', '系统 HTTP 栈也失败：%s', 'System HTTP stack also failed: %s'],
  ['notify_direct_fallback', '私信', 'Direct message'],
  ['notify_direct_count', '你有 %d 条新私信', 'You have %d new direct messages'],
  ['notify_direct_one', '你有一条新私信', 'You have a new direct message'],
  ['index_web_login_hint', '在页面里登录（可能要过人机验证），成功后会自己进入', 'Sign in on the page (you may need to pass a human check); the app enters automatically afterwards.'],
  ['index_open_link_failed', '打不开这个链接（系统里没有可用的浏览器？）', 'Couldn’t open this link (no browser available?)'],
  ['index_share_empty', '这条分享没有可打开的内容', 'This share has nothing to open'],
  ['linkin_title', '通过深链进入', 'Opened by deep link'],
  ['linkin_hint', '链接由系统通过 Want 送进本应用，下面是从 URI 里解析出来的内容。', 'The system delivered this link to the app via Want. Below is what was parsed from the URI.'],
  ['linkin_target_known', '✓ 认识这个目标', '✓ Known target'],
  ['linkin_target_unknown', '✗ 不认识的目标', '✗ Unknown target'],
  ['linkin_params_ok', '✓ 参数完整', '✓ Parameters complete'],
  ['linkin_params_missing', '✗ 参数缺失', '✗ Parameters missing'],
  ['linkin_open_action', '打开并执行这条链接', 'Open and run this link'],
  ['linkin_ignore', '忽略，直接进首页', 'Ignore and go to home'],
  ['linkin_supported', '支持的链接', 'Supported links'],
  ['story_diag_guide', '2) 再看 detail= 与「逐发轨迹」：detail=empty 表示服务端答了 200+JSON 但没有媒体；', '2) Then check detail= and the per-request trace: detail=empty means the server returned 200+JSON but no media.']
];

function load(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}
function save(file, data) {
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n', 'utf8');
}
function add(file, index, value) {
  const data = load(file);
  const have = new Set(data.string.map((x) => x.name));
  if (!have.has(rows[index][0])) data.string.push({ name: rows[index][0], value });
  save(file, data);
}

for (let i = 0; i < rows.length; i++) {
  add(baseFile, i, rows[i][1]);
  add(enFile, i, rows[i][2]);
}
console.log(`ensured ${rows.length} UI keys in base + en_US`);
