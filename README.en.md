# Instarmony

A native **HarmonyOS** (ArkTS / ArkUI) Instagram client: the entire UI is built with ArkUI,
and the data comes from **a session held by a hidden WebView + the private mobile API used by
instagrapi**.

Personal project for learning and daily use. Not affiliated with Instagram or Meta.

[中文](README.md) · Released under [Apache-2.0](LICENSE).

<p align="center">
  <img src="https://img.shields.io/badge/version-1.2.0-1677FF?style=flat-square" alt="version 1.2.0">
  <img src="https://img.shields.io/badge/HarmonyOS-API%2020-1677FF?style=flat-square" alt="HarmonyOS API 20">
  <img src="https://img.shields.io/badge/ArkTS-Stage-0B0B0D?style=flat-square" alt="ArkTS Stage model">
  <img src="https://img.shields.io/badge/License-Apache--2.0-2EA44F?style=flat-square" alt="Apache-2.0">
</p>

## Features

| | |
|:--|:--|
| **Full feed experience** | Home timeline (pull to refresh / infinite scroll / skeleton), story tray and viewer, full-screen vertical Reels, post page with a comments sheet. |
| **Direct messages** | Inbox, thread view (text / media / shared post / reel / sticker / voice and other XMA types), sending text, prefetch and snapshot cache. |
| **Search** | Account search by keyword, a three-column recommended waterfall for an empty query, tap to open Reels. |
| **Profiles** | Posts / Reels / Saved / Tagged tabs on your own profile; other users' profiles reuse the same page; the Reels tab opens the Reels page. |
| **Notifications** | Grouped as Today / Yesterday / Past 7 days / Past 30 days / Earlier / Suggested for you; the older two are collapsed behind a "Show more" row. |
| **Interactions** | Like, save, repost, follow, comment and comment like all go through direct HTTP calls; state is kept in session-level override tables so it stays consistent across pages. |
| **Native HarmonyOS design** | ArkUI components, system symbols, HDS immersive materials with graceful degradation, light/dark themes, two material thickness levels. |
| **Honest degradation** | When an endpoint is rate limited, a template expires or the session dies, the UI shows the concrete reason and falls back step by step (mobile API → template replay → web driven). |

## How it works

The hidden WebView handles **login** and holds the session (cookie jar). The native side wraps
that session in an official-Android-app identity and calls `i.instagram.com/api/v1/...`, so:

- the UI does **not** scrape the web page DOM (an early version did; it was slow and brittle);
- most data sources are a single private REST call: stories, direct messages, profiles,
  notifications, likes, saves, follows, search;
- the few endpoints without a REST equivalent (feed timeline, first Reels page, repost,
  comment like) use **template replay**: the page issues the request once, the request is
  stored as a template, and the native side replays it later, falling back to web driving.

## Project configuration

| Item | Value |
|:--|:--|
| App | `Instarmony` · `com.oneleaf.instamony` · version `1.2.0` (`versionCode` 1002000) |
| Module | `entry` · Stage model |
| SDK | target `26.0.0` · **compatible `6.0.0 (API 20)`** |
| Devices | `phone`, `tablet` · full-screen `EntryAbility` |
| Permissions | `ohos.permission.INTERNET` |
| Build | DevEco Studio 6.x / hvigor `6.26.4` |

## Build

**DevEco Studio (recommended)**

1. Install DevEco Studio 6.x and the HarmonyOS SDK (API 20 or newer);
2. Copy the signing template and configure signing:
   ```powershell
   copy build-profile.example.json5 build-profile.json5
   ```
   File > Project Structure > Signing Configs > "Automatically generate signature";
3. Run.

**Command line (no IDE)**

```powershell
.\tools\build.ps1            # build the debug HAP
.\tools\build.ps1 -Install   # build + install + launch + 8s of logs
```

Artifact: `entry\build\default\outputs\default\entry-default-signed.hap`

> `build-profile.json5` holds **local signing configuration** (absolute paths and key/store
> passwords) and is not committed; the repository only ships `build-profile.example.json5`.
> The script redirects the hvigor / npm caches into `.hvigor-home` inside the workspace, which
> is required when `~/.hvigor` is not writable; see the comments in the script.

## Usage

1. Install the app and log in with **your own Instagram account** inside the app (the login
   happens in the hidden WebView; the session stays in the local cookie jar and is never
   uploaded anywhere);
2. On some pages the app may let the hidden page run once to capture request templates;
   the log always states why.

## Risks (read first)

- It uses **non-public endpoints**; Instagram can change them at any time. Every failure path
  has a fallback and an explanation, but features may break without notice.
- Frequent requests can trigger `feedback_required` / rate limits. There is a request gate with
  cooldowns, but it is still possible.
- The **translation** feature sends the text to third-party online translation services
  (see the header of `core/Translator.ets`).
- Do not stress test with your main account. Any non-official client carries account risk;
  use at your own discretion.

## Layout

```
AppScope/                app-level config (bundle name, icons, version)
entry/src/main/ets/
  entryability/          entry ability: engine init, warm-up, deep links
  pages/                 pages (Index is the shell + NavDestinations)
  components/            native components (FeedList / ReelsPage / CommentsPanel / MaterialSurface …)
  viewmodel/             page state and cursor chains
  core/                  protocol layer: fetching / interactions / cache / throttling / identity / translation
    mobileapi/           instagrapi private API port (session, signing, endpoints)
  bridge/                hidden WebView script injection and template capture
  model/                 UI data models
  probe/                 web probe panel (diagnostics)
entry/src/main/resources/ strings / colors / media / bundled request templates
tools/                   build and check scripts
```

## Documentation

- [`RELEASE_1.2.md`](RELEASE_1.2.md) — **what changed in 1.2.0**, known issues, not implemented yet
- [`RELEASE_1.1.md`](RELEASE_1.1.md) — what changed in 1.1.0, known issues, not implemented yet
- [`RELEASE_1.0.md`](RELEASE_1.0.md) — 1.0.0 feature list, known issues, not implemented yet
- [`INSTAGRAPI_PORT.md`](INSTAGRAPI_PORT.md) — mobile API port log: endpoint table, parameters, criteria, rate limits
- [`FINGERPRINT_ANALYSIS.md`](FINGERPRINT_ANALYSIS.md) — why IG may treat the client as automation, and the countermeasures
- [`AUDIT_TODO.md`](AUDIT_TODO.md) — audit todos and leftovers

## License

Released under the [Apache License 2.0](LICENSE).
