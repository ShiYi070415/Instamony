// @ts-nocheck – Template file, only used when copied into a project directory
import { appTasks } from '@ohos/hvigor-ohos-plugin';

/*
 * 调试包和发布包共用一份 AppScope/app.json5，但调试证书的包名要独立：
 *   · 默认 / 发布：com.oneleaf.instamony（release 证书与 AGC Profile 绑定这个包名）
 *   · debug 证书：com.yijin.instamony（侧载调试包与正式包可同时安装）
 *
 * 构建脚本通过 INSTAMONY_BUNDLE_NAME 传入，未传时不覆盖，保持 app.json5 原值。
 * 参考：hvigorfile.ts 的 config.ohos.overrides.appOpt.bundleName。
 */
const debugBundleName: string | undefined = process.env.INSTAMONY_BUNDLE_NAME;

export default {
  system: appTasks /* Built-in plugin of Hvigor. It cannot be modified. */,
  config: {
    ohos: debugBundleName !== undefined && debugBundleName.length > 0
      ? { overrides: { appOpt: { bundleName: debugBundleName } } }
      : {}
  },
  plugins: [] /* Custom plugin to extend the functionality of Hvigor. */,
};
