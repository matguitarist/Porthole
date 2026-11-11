#!/bin/bash
# Releases a macOS app: Developer ID signature, one notarization, a disk image
# for new installs, a zip and a signed Sparkle appcast for updates, and a
# GitHub release that holds all three.
#
# The same file lives in every app as tools/release.sh. What differs between
# apps is in release.conf at the repo root (see the end of this header).
#
# Usage: tools/release.sh 1.2.3            check, build, notarize, publish
#        tools/release.sh 1.2.3 --local    the same without publishing anything
#        tools/release.sh 1.2.3 --check    the checks only (seconds, nothing built)
#        tools/release.sh 1.2.3 --yes      publish without the confirmation prompt
#
# Release notes: release-notes/<version>.md when it exists, otherwise drafted
# from the commit subjects since the last tag (written to that file and
# committed with the release, so every release keeps its notes).
#
# Once per Mac:
#   - a "Developer ID Application" certificate in the login Keychain
#   - xcrun notarytool store-credentials <NOTARY_PROFILE> --apple-id <id> --team-id <team>
#   - the app's Sparkle EdDSA key in the login Keychain (generate_keys --account <SPARKLE_ACCOUNT>)
#     Back it up: generate_keys --account <account> -x <file>. Without it, installed
#     copies never accept an update again.
#   - gh logged in
#
# Speed: everything that can fail is checked before the build. The disk image
# is notarized once; the app inside it is stapled from that same ticket, so
# Apple is asked once, not twice. Build and notary output go to the log in the
# release folder; the terminal shows one line per step.
#
# Written for /bin/bash 3.2 (the one macOS ships) so it runs on any Mac.
#
# release.conf (sourced as shell):
#   NAME=Attic                         bundle name: Attic.app, Attic.dmg, Attic-1.2.3.zip
#   TITLE="Attic"                      shown in the release title and the disk image
#   REPO=matguitarist/attic
#   NOTARY_PROFILE=ares-notary
#   SPARKLE_ACCOUNT=attic              Keychain account of the EdDSA key (ed25519 is Sparkle's default)
#   VERSION_IN=project.yml             VERSION | Info.plist.in | project.yml
#   BUILD=xcode                        xcode | script
#     XCODE_PROJECT=Attic.xcodeproj    for BUILD=xcode
#     XCODE_SCHEME=Attic
#     XCODEGEN=1                       regenerate the project after the version bump (a committed one joins the release commit)
#     BUILD_CMD=./build.sh             for BUILD=script: builds the app...
#     BUILT_APP=~/Applications/X.app   ...here
#   SPARKLE_TOOLS=2.10.1               optional: version of Sparkle's command-line tools

set -Eeuo pipefail   # -E: the error trap also fires inside functions

# --- Arguments ---------------------------------------------------------------

root=$(cd "$(dirname "$0")/.." && pwd)
version=""; mode=publish; assume_yes=0
for arg in "$@"; do
  case "$arg" in
    --local) mode=local ;;
    --check) mode=check ;;
    --yes)   assume_yes=1 ;;
    -*)      echo "unknown option: $arg" >&2; exit 2 ;;
    *)       version=$arg ;;
  esac
done
[[ -n $version ]] || { echo "usage: tools/release.sh <version> [--local|--check] [--yes]" >&2; exit 2; }

conf="$root/release.conf"
[[ -f $conf ]] || { echo "no release.conf at $root" >&2; exit 2; }
NAME="" TITLE="" REPO="" NOTARY_PROFILE="" SPARKLE_ACCOUNT=ed25519 VERSION_IN="" BUILD=""
XCODE_PROJECT="" XCODE_SCHEME="" XCODEGEN=0 BUILD_CMD="" BUILT_APP="" SPARKLE_TOOLS=2.10.1
# shellcheck source=/dev/null
source "$conf"
TITLE=${TITLE:-$NAME}
tag="v$version"
cd "$root"

# --- Output: one line per step, details in the log -----------------------------

work="$HOME/Library/Developer/$NAME/release/$version"
log="$work/release.log"
step() { printf '→ %s\n' "$*"; printf '\n=== %s\n' "$*" >>"$log"; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }
quiet() { "$@" >>"$log" 2>&1; }   # run a command, its output to the log only
on_error() {
  local code=$?
  if [[ -f $log ]]; then
    printf '✗ failed (exit %s). Last lines of %s:\n' "$code" "$log" >&2
    tail -25 "$log" >&2
  fi
}
trap on_error ERR

# --- 1. Checks: all of them, before anything slow ------------------------------

fails=()
fail() { fails+=("$1"); }

[[ $(uname) == Darwin ]] || fail "this runs on macOS only"
for key in NAME REPO NOTARY_PROFILE VERSION_IN BUILD; do
  [[ -n ${!key} ]] || fail "release.conf: $key is empty"
done
case "$BUILD" in
  xcode)  [[ -n $XCODE_PROJECT && -n $XCODE_SCHEME ]] || fail "release.conf: BUILD=xcode needs XCODE_PROJECT and XCODE_SCHEME" ;;
  script) [[ -n $BUILD_CMD && -n $BUILT_APP ]] || fail "release.conf: BUILD=script needs BUILD_CMD and BUILT_APP" ;;
  *)      fail "release.conf: BUILD must be xcode or script" ;;
esac
[[ $version =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail "version $version doesn't look like 1.2.3"

notes_file="release-notes/$version.md"
# The notes for this version may be the only change: they're committed with the release.
dirty=$(git status --porcelain --untracked-files=all | grep -v " $notes_file\$" || true)
[[ -z $dirty ]] || fail "uncommitted changes (commit them first)"
[[ $(git branch --show-current) == main ]] || fail "not on main"
if git fetch -q --tags origin 2>/dev/null; then
  behind=$(git rev-list --count HEAD..@{u} 2>/dev/null || echo 0)
  [[ $behind == 0 ]] || fail "$behind commits behind origin: pull first"
else
  fail "can't reach origin"
fi
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && fail "$tag already exists"
last=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
if [[ -n $last ]]; then
  newest=$(printf '%s\n%s\n' "${last#v}" "$version" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
  [[ $newest == "$version" && ${last#v} != "$version" ]] || fail "$version isn't newer than $last"
fi

command -v gh >/dev/null && { gh auth status >/dev/null 2>&1 || fail "gh isn't logged in (gh auth login)"; } || fail "gh isn't installed (brew install gh)"
[[ $BUILD == xcode && $XCODEGEN == 1 ]] && ! command -v xcodegen >/dev/null && fail "xcodegen isn't installed"
identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Developer ID Application' | awk '{print $2}' || true)
[[ -n $identity ]] || fail "no Developer ID Application certificate in the Keychain"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || fail "no notary credentials: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id <team>"
security find-generic-password -s https://sparkle-project.org -a "$SPARKLE_ACCOUNT" >/dev/null 2>&1 \
  || fail "no Sparkle key for account $SPARKLE_ACCOUNT in the login Keychain (never make a new one for an app that shipped)"
if pgrep -f "/$NAME.app/Contents/MacOS/" >/dev/null 2>&1; then
  # A copy running from the build's path stops matching its signature, and Sparkle then refuses to update it.
  if [[ $mode == check ]]; then fail "$NAME is running"; else osascript -e "quit app \"$NAME\"" >/dev/null 2>&1 || true; fi
fi

if (( ${#fails[@]} )); then
  printf '✗ %s\n' "${fails[@]}" >&2
  exit 1
fi
echo "✓ checks pass: $TITLE ${last#v}${last:+ → }$version"
[[ $mode == check ]] && exit 0

rm -rf "$work"; mkdir -p "$work"
: >"$log"

# --- 2. Release notes ------------------------------------------------------------

notes="$work/notes.md"
if [[ -s $notes_file ]]; then
  cp "$notes_file" "$notes"
else
  # Commit subjects since the last tag, without the release plumbing.
  range=${last:+$last..}HEAD
  git log --no-merges --reverse --format='- %s' "$range" \
    | grep -viE '^- (release|appcast|update appcast|update feed|readme|version [0-9])' \
    | head -12 >"$notes" || true
  [[ -s $notes ]] || echo "- Fixes and improvements." >"$notes"
fi
echo "  notes:"; sed 's/^/    /' "$notes"

if [[ $mode == publish && $assume_yes == 0 ]]; then
  [[ -t 0 ]] || die "publishing needs --yes when there's no terminal to confirm in"
  printf 'Publish %s %s to everyone (tag, GitHub release, Sparkle update)? [y/N] ' "$TITLE" "$version"
  read -r answer
  [[ $answer == [yY]* ]] || die "stopped; nothing was changed"
fi

# --- 3. Version ------------------------------------------------------------------

step "version $version"
version_files=()
case "$VERSION_IN" in
  VERSION)
    echo "$version" >VERSION
    version_files=(VERSION) ;;
  Info.plist.in)
    sed -i '' -E "s|(<key>CFBundleShortVersionString</key>[[:space:]]*<string>)[^<]*|\1$version|" Info.plist.in
    version_files=(Info.plist.in) ;;
  project.yml)
    build_number=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\{0,1\}\([0-9]*\)"\{0,1\}.*/\1/p' project.yml | head -1)
    [[ -n $build_number ]] || die "no CURRENT_PROJECT_VERSION in project.yml"
    sed -i '' -E \
      -e "s|^( *MARKETING_VERSION: *)\"?[^\"]*\"?|\1\"$version\"|" \
      -e "s|^( *CURRENT_PROJECT_VERSION: *)\"?[0-9]+\"?|\1\"$((build_number + 1))\"|" project.yml
    version_files=(project.yml) ;;
  *) die "release.conf: VERSION_IN must be VERSION, Info.plist.in or project.yml" ;;
esac
committed=0
restore_version() {
  (( committed == 0 && ${#version_files[@]} )) || return 0
  git checkout -- "${version_files[@]}" 2>/dev/null || true
}
# Until the release commit exists, any exit (failure, Ctrl-C, --local) leaves the repo as it was.
trap restore_version EXIT

# --- 4. Build --------------------------------------------------------------------

step "build"
if [[ $BUILD == xcode ]]; then
  if [[ $XCODEGEN == 1 ]]; then
    # The new version reaches the build through the generated project.
    quiet xcodegen generate --quiet
    # A committed project changes with it, so it joins the release commit.
    if git ls-files --error-unmatch "$XCODE_PROJECT" >/dev/null 2>&1; then version_files+=("$XCODE_PROJECT"); fi
  fi
  derived="$HOME/Library/Developer/$NAME/release-derived"   # outside iCloud: its attributes break codesign
  quiet xcodebuild build -project "$XCODE_PROJECT" -scheme "$XCODE_SCHEME" -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -quiet
  built="$derived/Build/Products/Release/$NAME.app"
else
  quiet eval "$BUILD_CMD"
  built=${BUILT_APP/#\~/$HOME}
fi
[[ -d $built ]] || die "the build made no app at $built"

app="$work/$NAME.app"
ditto --noextattr --norsrc "$built" "$app"
xattr -cr "$app"

# --- 5. Sign, inside out ---------------------------------------------------------

step "sign with Developer ID"
sign() { quiet codesign --force --options runtime --timestamp --sign "$identity" "$@"; }

# Every Mach-O file first, then every nested bundle from the deepest up, then the app.
# Nested code keeps the entitlements it was built with (Sparkle's Downloader.xpc needs its own).
# (if-statements, not "&&", inside loops: bash 3.2 can stop on a loop whose last test was false)
while IFS= read -r -d '' binary; do
  if file -b "$binary" | grep -q 'Mach-O'; then sign --preserve-metadata=entitlements "$binary"; fi
done < <(find "$app/Contents" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0)
find "$app/Contents" -type d \( -name '*.app' -o -name '*.xpc' -o -name '*.framework' -o -name '*.appex' -o -name '*.bundle' \) \
  | awk -F/ '{ print NF "\t" $0 }' | sort -rn | cut -f2- \
  | while IFS= read -r bundle; do
      # A resource bundle with no code (SwiftPM makes these) has nothing to sign.
      if [[ $bundle != *.bundle || -d $bundle/Contents/MacOS ]]; then
        sign --preserve-metadata=entitlements "$bundle"
      fi
    done

# The app keeps its own entitlements, minus the debugger one notarization refuses.
entitlements="$work/entitlements.plist"
if codesign -d --entitlements - --xml "$app" >"$entitlements" 2>/dev/null && [[ -s $entitlements ]]; then
  /usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$entitlements" >/dev/null 2>&1 || true
  sign --entitlements "$entitlements" "$app"
else
  sign "$app"
fi
quiet codesign --verify --deep --strict --verbose=2 "$app"

# --- 6. Disk image, one notarization -----------------------------------------------

step "disk image"
dmg="$work/$NAME.dmg"   # a fixed name keeps README links to releases/latest/download/<NAME>.dmg working
stage="$work/dmg"
mkdir -p "$stage"
ditto --noextattr --norsrc "$app" "$stage/$NAME.app"
ln -s /Applications "$stage/Applications"
quiet hdiutil create -volname "$TITLE" -srcfolder "$stage" -format UDZO -imagekey zlib-level=9 -ov "$dmg"
rm -rf "$stage"
sign "$dmg"

notarize() {   # notarize <file>: waits for Apple, prints Apple's log when it says no
  local result status id
  result=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json 2>>"$log" || true)
  echo "$result" >>"$log"
  status=$(sed -n 's/.*"status" *: *"\([^"]*\)".*/\1/p' <<<"$result" | head -1)
  id=$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' <<<"$result" | head -1)
  if [[ $status != Accepted ]]; then
    [[ -n $id ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >>"$log" 2>&1
    die "notarization: ${status:-no answer} (Apple's log is in $log)"
  fi
}

step "notarize (Apple usually answers within a few minutes)"
notarize "$dmg"
quiet xcrun stapler staple "$dmg"
# The disk image's ticket covers the app inside it: same signature, so the copy
# Sparkle ships can be stapled without a second submission.
if ! quiet xcrun stapler staple "$app"; then
  step "notarize the app on its own (the disk image's ticket didn't cover it)"
  ditto -c -k --norsrc --noextattr --keepParent "$app" "$work/notarize.zip"
  notarize "$work/notarize.zip"
  rm -f "$work/notarize.zip"
  quiet xcrun stapler staple "$app"
fi
quiet xcrun stapler validate "$app"
quiet spctl --assess --type execute --verbose "$app"
quiet spctl --assess --type open --context context:primary-signature --verbose "$dmg"

# --- 7. Sparkle: zip and appcast -------------------------------------------------

step "Sparkle appcast"
sparkle_bin="$HOME/Library/Developer/mac-release/sparkle-$SPARKLE_TOOLS/bin"
if [[ ! -x $sparkle_bin/generate_appcast ]]; then
  # Sparkle's command-line tools from its official release, once per Mac for all apps.
  dl=$(mktemp -d)
  quiet gh release download "$SPARKLE_TOOLS" -R sparkle-project/Sparkle -p "Sparkle-$SPARKLE_TOOLS.tar.xz" -D "$dl"
  mkdir -p "${sparkle_bin%/bin}"
  tar -xf "$dl/Sparkle-$SPARKLE_TOOLS.tar.xz" -C "${sparkle_bin%/bin}" bin
  rm -rf "$dl"
fi

feed="$work/feed"
mkdir -p "$feed"
zip_name="$NAME-$version.zip"
ditto -c -k --norsrc --noextattr --keepParent "$app" "$feed/$zip_name"
cp "$notes" "$feed/$NAME-$version.md"   # same base name as the zip: generate_appcast embeds it

# The feed keeps its history: start from the one in the repo, or the newest release's.
feed_in_repo=0
if git ls-files --error-unmatch appcast.xml >/dev/null 2>&1; then
  feed_in_repo=1
  cp appcast.xml "$feed/appcast.xml"
else
  quiet gh release download -R "$REPO" -p appcast.xml -D "$feed" || true
fi
quiet "$sparkle_bin/generate_appcast" --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$tag/" \
  --embed-release-notes --maximum-versions 0 --maximum-deltas 0 "$feed"
grep -q "$zip_name" "$feed/appcast.xml" || die "the appcast doesn't list $zip_name"
appcast="$work/appcast.xml"
cp "$feed/appcast.xml" "$appcast"
cp "$feed/$zip_name" "$work/$zip_name"

if [[ $mode == local ]]; then
  echo "✓ built $dmg, $work/$zip_name and $appcast (nothing published)"
  exit 0
fi

# --- 8. Publish ------------------------------------------------------------------

step "publish $tag"
mkdir -p release-notes
cp "$notes" "$notes_file"
git add -- "${version_files[@]}" "$notes_file"
quiet git commit -m "Release $version"
committed=1
quiet git tag -a "$tag" -m "$TITLE $version"
quiet git push origin HEAD "$tag"
# Not a draft: Sparkle and the README read releases/latest, which skips drafts.
quiet gh release create "$tag" "$dmg" "$work/$zip_name" "$appcast" -R "$REPO" \
  --title "$TITLE $version" --notes-file "$notes" --verify-tag
if (( feed_in_repo )); then
  # Last, so the feed never points at a download that doesn't exist yet.
  cp "$appcast" appcast.xml
  git add appcast.xml
  quiet git commit -m "Appcast: $TITLE $version"
  quiet git push origin HEAD
fi

# --- 9. Check what people get ------------------------------------------------------

step "check the update feed"
feed_url=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$app/Contents/Info.plist" 2>/dev/null || true)
seen=0
if [[ -n $feed_url ]]; then
  # raw.githubusercontent.com caches for a few minutes.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsL "$feed_url" 2>/dev/null | grep -q "<sparkle:shortVersionString>$version<"; then seen=1; break; fi
    sleep 30
  done
fi
download="https://github.com/$REPO/releases/download/$tag/$zip_name"
code=$(curl -sIL -o /dev/null -w '%{http_code}' "$download" || true)
[[ $code == 200 ]] || die "the update download answers ${code:-nothing}: $download"

echo "✓ released $TITLE $version: https://github.com/$REPO/releases/tag/$tag"
if [[ -z $feed_url ]]; then
  echo "! the app has no SUFeedURL: it never checks for updates"
elif (( seen )); then
  echo "✓ the feed offers $version ($feed_url)"
else
  echo "! the feed doesn't show $version yet ($feed_url); it may still be cached"
fi
