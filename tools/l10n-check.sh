#!/bin/zsh
# Lists interface strings with no French translation. Exit 0 when none is missing.
# Interface strings come from the compiler, PortholeKit's too: its visible words (event
# summaries, insights, disk names) use String(localized:bundle: .main), the app's catalog.
set -u
here=${0:A:h:h}
tmp=$(mktemp -d)
# An up-to-date build compiles nothing and emits no strings, so start clean.
rm -rf "$HOME/Library/Developer/Porthole/l10n-build"
swift build --package-path "$here" --scratch-path "$HOME/Library/Developer/Porthole/l10n-build" \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$tmp" >/dev/null 2>&1
expected=$(ls "$here"/Sources/Porthole/**/*.swift | wc -l)
found=$(ls "$tmp"/*.stringsdata 2>/dev/null | wc -l)
if (( found < expected )); then echo "L10N FAIL the build emitted $found of $expected string files"; exit 1; fi
echo '{"sourceLanguage":"en","strings":{},"version":"1.0"}' > "$tmp/Localizable.xcstrings"
xcrun xcstringstool sync "$tmp/Localizable.xcstrings" --stringsdata "$tmp"/*.stringsdata
python3 -I - "$tmp/Localizable.xcstrings" "$here/Localization/Localizable.xcstrings" <<'PY'
import json, sys
found = set(json.load(open(sys.argv[1]))["strings"])
have = {k for k, v in json.load(open(sys.argv[2]))["strings"].items() if "fr" in v.get("localizations", {})}
missing = sorted(found - have)
for key in missing: print("MISSING", repr(key))
print("L10N PASS" if not missing else f"L10N FAIL {len(missing)} missing")
sys.exit(1 if missing else 0)
PY
