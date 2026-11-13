# Porthole

A native macOS app in SwiftUI for a Docker server's containers and logs
(the owner's Unraid server), replacing Dozzle. It connects with `ssh` and the
`docker` command; nothing is installed on the server. `agent/` is the optional
Rust agent with a web page, for use away from the Mac. `README.md` says what it does.

Shared rules for my Mac apps (build and check, design rules, skills, git):
@~/.claude/mac-app-conventions.md

## Layout

- `Sources/Porthole/` the app. `App.swift` has the window, menus, and the database location.
- `Sources/PortholeKit/` rules and data logic with no SwiftUI. Tests in `Tests/PortholeKitTests/`.
- `Package.swift` a Swift package. There is no Xcode project.
- `build.sh` builds, signs, and installs `~/Applications/Porthole.app`.
- `Icon/AppIcon.icon` the app icon, an Icon Composer file (JSON plus SVG layers). `build.sh` compiles it with `tools/make_icon.sh`; `tools/icon_review.sh` renders every look into one PNG.
- `docs/STORIES.md` the stories: what's built and what's next. The roadmap is "Porthole Roadmap" in Thimble.
- `Localization/Localizable.xcstrings` English and French. Every new string needs its French (`tools/l10n-check.sh` prints PASS). PortholeKit's visible words use `String(localized:bundle: .main)`, so they live in the same catalog.
- Release: `tools/release.sh <version>` (settings in `release.conf`, version in `Info.plist.in`; Sparkle key in the login keychain, account `porthole`). Use the mac-release skill.
- `agent/` the Rust agent (axum, bollard): `cargo test`, `cargo clippy -- -D warnings`, `agent/deploy.sh` to install it on the server. `agent/src/parse.rs` reads levels like `PortholeKit/LogLine.swift`: keep the two in step.

## Checks specific to this app

- The self-test runs in English; `APP_LANGUAGE=fr tools/selftest.sh` runs it in French.
