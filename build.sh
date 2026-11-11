#!/bin/zsh
# Builds Porthole and installs it to ~/Applications/Porthole.app.
# Build products live in ~/Library/Developer/Porthole, outside the repo
# (and outside Dropbox or iCloud, which would try to sync them).
#
# Usage: ./build.sh            release build, install
#        ./build.sh --debug    debug build, install
#        ./build.sh --open     install, then quit the running copy and open the new one
set -euo pipefail
here=${0:A:h}
name="Porthole"
scratch="$HOME/Library/Developer/$name/build"
config=release
[[ " $* " == *" --debug "* ]] && config=debug

# Sign with your Apple Development certificate when you have one (Xcode >
# Settings > Accounts). Otherwise sign ad hoc, which is fine for your own Mac.
identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  # The certificate's hash, not its name: two certificates can share a name.
  identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Apple Development: ' | awk '{print $2}' || true)
fi
[[ -n "$identity" ]] || identity=-

swift build -c $config --package-path "$here" --scratch-path "$scratch" 2>&1 | grep -E "error|warning|Build complete" | grep -v "^\[" || true
bin="$scratch/$config/$name"
[[ -x "$bin" ]] || { echo "build failed"; exit 1; }
# swift build can report success while an edited file failed to compile. Catch that.
stale=$(find "$here/Sources" -name '*.swift' -newer "$bin" | head -1)
if [[ -n "$stale" ]]; then
  # A change that compiles to the same code (a comment) leaves the binary older too, so
  # build again: real errors show up there; none means the binary is current.
  errors=$(swift build -c $config --package-path "$here" --scratch-path "$scratch" 2>&1 | grep -E "error" | head -20 || true)
  if [[ -n "$errors" ]]; then
    echo "build failed: binary is older than $stale"
    echo "$errors"
    exit 1
  fi
  touch "$bin"
fi

app="$HOME/Applications/$name.app"
mkdir -p "$HOME/Applications"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$name"
# Package resources (LogKit's viewer strings): Bundle.module finds them in Contents/Resources.
for bundle in "$scratch/$config"/*.bundle(N); do cp -R "$bundle" "$app/Contents/Resources/"; done
sed -e "s/__BUILD__/$(date +%Y%m%d%H%M)/" "$here/Info.plist.in" > "$app/Contents/Info.plist"
# The icon: Icon/AppIcon.icon -> Resources/Assets.car + AppIcon.icns, rebuilt when it changed.
if [[ -d "$here/Icon/AppIcon.icon" ]]; then
  car="$here/Resources/Assets.car"
  if [[ ! -f "$car" || -n "$(find "$here/Icon/AppIcon.icon" -newer "$car" | head -1)" ]]; then
    "$here/tools/make_icon.sh"
  fi
  cp -X "$car" "$here/Resources/AppIcon.icns" "$app/Contents/Resources/"
fi
# Translations: Localization/*.xcstrings -> <lang>.lproj/*.strings
for catalog in "$here"/Localization/*.xcstrings(N); do
  xcrun xcstringstool compile "$catalog" --output-directory "$app/Contents/Resources"
done
mkdir -p "$app/Contents/Resources/en.lproj"
# Sparkle, for automatic updates.
framework="$scratch/$config/Sparkle.framework"
if [[ -d "$framework" ]]; then
  mkdir -p "$app/Contents/Frameworks"
  ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"
fi
xattr -cr "$app"
[[ -d "$app/Contents/Frameworks/Sparkle.framework" ]] && codesign --force --deep --sign "$identity" "$app/Contents/Frameworks/Sparkle.framework" 2>&1 | grep -v "replacing existing signature" || true
codesign --force --sign "$identity" "$app" 2>&1 | grep -v "replacing existing signature" || true
echo "installed $app (signed: ${identity})"

if [[ " $* " == *" --open "* ]]; then
  osascript -e "quit app \"$name\"" 2>/dev/null || true
  sleep 0.5
  open "$app"
fi
