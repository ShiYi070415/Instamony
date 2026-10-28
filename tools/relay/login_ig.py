"""
用 instagrapi 登录 Instagram，把会话保存成 settings.json（供 relay 导入）。

为什么要这一层：IG 已经停用了旧的密码登录接口（一律回 needs_upgrade），
现在唯一还能密码登录的是 Bloks CAA 流程 —— instagrapi 把它跑通了并持续维护。
所以"登录"这件事交给它，我们的 relay 只负责导入会话 + 推送。

用法（在本目录下）：
    python login_ig.py

成功会打印 `OK <你的账号id>`，并在同目录生成 settings.json。
然后回到 relay：
    node relay.js --import-session settings.json

隐私：用户名/密码只输入到这台机器、只发往 IG；密码不回显、不写入任何文件。
settings.json 里是**会话**（等同密码），别外传。
"""

import getpass
import sys
from pathlib import Path

try:
    from instagrapi import Client
    from instagrapi.exceptions import (
        BadPassword,
        ChallengeRequired,
        PleaseWaitFewMinutes,
        TwoFactorRequired,
    )
except ImportError:
    print("没找到 instagrapi。先装：")
    print("  python -m pip install instagrapi")
    sys.exit(1)

HERE = Path(__file__).resolve().parent
SETTINGS = HERE / "settings.json"


def main() -> int:
    username = input("IG 用户名: ").strip()
    if not username:
        print("没输入用户名")
        return 1
    password = getpass.getpass("IG 密码（不回显）: ")
    if not password:
        print("没输入密码")
        return 1

    cl = Client()
    # 复用上次的设备身份，降低"新设备"风控概率
    if SETTINGS.exists():
        try:
            cl.load_settings(SETTINGS)
            print("已复用上次的设备身份（settings.json）")
        except Exception as error:  # noqa: BLE001
            print("旧 settings 读不了，按新设备来：", error)

    try:
        cl.login(username, password)
    except TwoFactorRequired:
        code = input("两步验证码（短信 / TOTP 六位）: ").strip()
        if not code:
            print("没输入验证码")
            return 1
        cl.login(username, password, verification_code=code)
    except ChallengeRequired:
        print()
        print("IG 要求人机校验（challenge_required）。")
        print("做法：打开手机上的 Instagram → 看到“是你在登录吗/这是一条安全提醒”就点「这是我」，")
        print("      等 2~3 分钟，再重新运行本脚本。")
        return 2
    except BadPassword:
        print("密码被拒（bad_password）。确认账号密码；刚改过密码的话等几分钟再试。")
        return 3
    except PleaseWaitFewMinutes:
        print("IG 要求稍等几分钟（请求太频繁）。等 5~10 分钟再试。")
        return 4

    cl.dump_settings(SETTINGS)
    print("OK", cl.user_id)
    print("会话已写入:", SETTINGS)
    print()
    print("下一步：")
    print("  node relay.js --import-session settings.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
