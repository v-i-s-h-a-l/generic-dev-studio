---
name: Turnip Project Config
description: Canonical project paths and identifiers for the Turnip iOS (Zaps) app
type: reference
---

# Turnip iOS Project Config

## Xcode Project
- Repo root: `/Users/vishalsingh/Documents/Turnip.gg/turnip-ios`
- Project: `/Users/vishalsingh/Documents/Turnip.gg/turnip-ios/zaps-app/Turnip.xcodeproj`
- Project (worktree-relative): `zaps-app/Turnip.xcodeproj`
- Scheme: `Zaps`
- pbxproj: `/Users/vishalsingh/Documents/Turnip.gg/turnip-ios/zaps-app/Turnip.xcodeproj/project.pbxproj`
- xcpretty: `/Users/vishalsingh/.gem/ruby/2.6.0/bin/xcpretty`

> **Why the worktree-relative form (#238).** This repo has multiple `Turnip.xcodeproj` directories (`zaps-app/`, `turnip-aap/`, the root-level stub) — `xcodebuild` without `-project` auto-picks the first one it finds at the worktree root, which is the stub (no `project.pbxproj`), and bails before scheme resolution. Achilles + the gate scripts pass this relpath to xcodebuild's `-project` flag so the canonical project is pinned regardless of cwd. Constant across all worktrees of this repo.

## App Store Connect
- Runtime config: `~/.dev-studio/<project>/config/release.env`
- Key file: `~/.dev-studio/<project>/secrets/appstoreconnect/AuthKey_<key-id>.p8`
- App ID: configured as `STUDIO_TF_APP_ID`
- Bundle ID: `gg.zaps.ios`

## Crashlytics
- GoogleService-Info.plist: `/Users/vishalsingh/Documents/Turnip.gg/turnip-ios/zaps-app/Zaps/Firebase/Prod/GoogleService-Info.plist`
