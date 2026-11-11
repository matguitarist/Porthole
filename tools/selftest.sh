#!/bin/zsh
# Runs the in-app self-test against a fresh store in /tmp. Exit code 0 when every check passed.
set -u
rm -rf ~/Library/Saved\ Application\ State/com.mathieuares.porthole.savedState
store=/tmp/Porthole-self.store
rm -f $store $store-shm $store-wal
# The app in English whatever the Mac uses; APP_LANGUAGE=fr for French.
# The language goes first: after --selftest, macOS would read the pair as a setting.
APP_STORE=$store ~/Applications/Porthole.app/Contents/MacOS/Porthole -AppleLanguages "(${APP_LANGUAGE:-en})" --selftest
