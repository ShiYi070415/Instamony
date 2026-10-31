/*
 * 把 base/string.json 里 en_US 缺少的键补齐（人工翻译表）。
 *
 * 只追加缺失键，不覆盖已有英文；已有键保持原顺序。
 * 用法：node tools/i18n-fill-en.cjs
 */
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const baseFile = path.join(root, 'entry/src/main/resources/base/element/string.json');
const enFile = path.join(root, 'entry/src/main/resources/en_US/element/string.json');

const translations = {
  common_cancel: 'Cancel',
  login_recheck_short: 'Recheck',
  login_register: 'Create account',
  login_register_hint: 'Registration completes on Instagram’s official website. Come back to this page and sign in with the new account.',
  feed_recommended_title: 'Recommended for you',
  feed_recommended_hint: 'You’ve seen the latest posts from people you follow. Here’s what we recommend next.',
  challenge_title: 'Account needs verification',
  challenge_hint: 'Instagram requires a human or device check. Complete it on the web page, then return to the app.',
  challenge_action: 'Verify',
  challenge_action_verify: 'Go to verification',
  login_label_username: 'Username',
  login_label_password: 'Password',
  login_label_code: 'Code',
  login_label_challenge_code: 'Security code',
  login_web_short: 'Web sign-in',
  login_verify_title: 'Two-factor verification',
  login_verify_hint: 'This account has extra verification enabled. Enter the 6-digit code Instagram sent you (SMS / authenticator / backup code).',
  login_verify_approval_hint: 'If Instagram asks you to approve this sign-in on another device, approve it there and switch back — the app retries automatically, no code needed.',
  login_verify_action: 'Verify and sign in',
  login_verify_cancel: 'Cancel',
  login_verify_web_title: 'Extra verification required',
  login_verify_web_hint: 'This account needs Instagram’s own verification flow (account recovery / security check); the code field here won’t work. Tap the button below to complete it on the web page; the app stays signed in afterwards.',
  login_verify_web_action: 'Verify on web',
  login_saved_accounts: 'Saved accounts (tap to switch)',
  login_label_session: 'sessionid',
  login_session_hint: 'The string starting with your numeric account id (called sessionid in browser cookies)',
  login_use_session: 'Sign in with sessionid',
  login_use_session_action: 'Sign in with sessionid',
  login_use_password: 'Use username and password',
  login_password_note: 'By default the app uses its own sign-in protocol (no web page). If the human check fails, use “Web sign-in” above; accounts with two-factor enabled will show a code panel.',
  login_username_hint: 'Instagram username',
  login_password_hint: 'Password',
  login_code_hint: 'Two-factor code',
  login_challenge_code_hint: 'Security code',
  login_submit_code: 'Submit code',
  login_web_fallback: 'Sign in on Instagram web',
  login_challenge_hint: 'Instagram requires a security check for this account. Complete it in the official Instagram app or website, then come back and sign in.',
  login_upgrade_hint: 'Instagram only allows its latest official client to sign in with a password; third-party clients are rejected (regardless of credentials). Tap the button above to use web sign-in; the app works the same afterwards.',
  login_challenge_web: 'Verify on web',
  status_session_expired: 'Your session expired. Sign out in Settings and sign in again.',
  notify_yesterday: 'Yesterday',
  notify_past_7d: 'Past 7 days',
  notify_past_30d: 'Past 30 days',
  notify_show_more: 'Show more',
  notify_this_month: 'This month',
  account_add: 'Add account',
  account_unnamed: 'Unnamed account',
  account_switch_failed: 'Couldn’t switch accounts. Please sign in to this account again.',
  story_your_story: 'Your story',
  profile_chip_add: 'Add',
  profile_action_edit: 'Edit profile',
  profile_action_share: 'Share profile',
  profile_highlight_new: 'New',
  profile_highlight_suggest: 'Suggested',
  story_create_pending: 'Story posting isn’t connected yet — this is the entry point',
  direct_send_failed: 'Not sent · Tap to retry',
  direct_sending: 'Sending…',
  settings_group_media: 'Photos and videos',
  settings_image_quality: 'Image quality',
  settings_video_quality: 'Video quality',
  settings_quality_auto: 'Auto',
  settings_quality_saver: 'Data saver',
  settings_quality_high: 'HD',
  settings_quality_original: 'Original',
  settings_media_quality_hint: 'Auto picks based on your network: HD on Wi-Fi, data saver on mobile data. Downloads always keep the original image/video.'
};

const base = JSON.parse(fs.readFileSync(baseFile, 'utf8'));
const en = JSON.parse(fs.readFileSync(enFile, 'utf8'));
const have = new Set((en.string || []).map((x) => x.name));
const missing = [];
for (const item of base.string || []) {
  if (!item || !item.name || have.has(item.name)) continue;
  missing.push(item.name);
  if (!translations[item.name]) {
    console.error(`missing translation: ${item.name}`);
    process.exit(1);
  }
  en.string.push({ name: item.name, value: translations[item.name] });
  have.add(item.name);
}
fs.writeFileSync(enFile, JSON.stringify(en, null, 2) + '\n', 'utf8');
console.log(`filled ${missing.length} keys: ${missing.join(', ')}`);
