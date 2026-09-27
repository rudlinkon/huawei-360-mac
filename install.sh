#!/bin/bash
# Installs (or updates) "Huawei 360.app" from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/rudlinkon/huawei-360-mac/master/install.sh | bash
#
# Options (environment variables):
#   VERSION=0.1.0     install a specific release instead of the latest
#   INSTALL_DIR=...   default /Applications (falls back to ~/Applications if not writable)
#
# Files fetched with curl/gh are not quarantined, so Gatekeeper's "Open Anyway" step is not needed.
# The quarantine flag is also cleared explicitly in case the zip came from a browser.
set -euo pipefail

REPO="rudlinkon/huawei-360-mac"
APP_NAME="Huawei 360.app"
VERSION="${VERSION:-}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Requirements ---------------------------------------------------------
[ "$(uname -s)" = Darwin ] || die "this app is for macOS only."
[ "$(uname -m)" = arm64 ] || die "this app needs an Apple silicon Mac (M1 or newer)."
os_major=$(sw_vers -productVersion | cut -d. -f1)
[ "$os_major" -ge 15 ] || die "macOS 15 or later is required (this Mac has $(sw_vers -productVersion))."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- Download -------------------------------------------------------------
# Public repo: plain curl. Private repo: an authenticated GitHub CLI (gh) is used instead.
tag=""
if [ -n "$VERSION" ]; then tag="v${VERSION#v}"; fi

download_with_gh() {
    say "Downloading ${tag:-latest release} with GitHub CLI…"
    gh release download ${tag:+"$tag"} -R "$REPO" -p 'Huawei-360-*-macOS-arm64.zip*' -D "$tmp" --clobber
}

download_with_curl() {
    local api="https://api.github.com/repos/$REPO/releases/${tag:+tags/$tag}"
    [ -n "$tag" ] || api="${api}latest"
    local json
    json=$(curl -fsSL "$api") || return 1
    local urls
    urls=$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*macOS-arm64\.zip[^"]*"' | sed 's/.*"\(https[^"]*\)"/\1/')
    [ -n "$urls" ] || return 1
    say "Downloading $(printf '%s\n' "$urls" | head -1 | sed 's#.*/##')…"
    local u
    for u in $urls; do curl -fL --progress-bar -o "$tmp/${u##*/}" "$u"; done
}

if ! download_with_curl 2>/dev/null; then
    if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
        download_with_gh
    else
        die "could not download the release. If the repository is private, install and log in to GitHub CLI first: brew install gh && gh auth login"
    fi
fi

zip=$(ls "$tmp"/Huawei-360-*-macOS-arm64.zip 2>/dev/null | head -1)
[ -n "$zip" ] || die "release zip not found."

# --- Verify ---------------------------------------------------------------
if [ -f "$zip.sha256" ]; then
    (cd "$tmp" && shasum -a 256 -c "$(basename "$zip").sha256" >/dev/null) || die "checksum mismatch — download corrupted."
    say "Checksum OK"
else
    say "No checksum file in the release; skipping verification"
fi

ditto -x -k "$zip" "$tmp/unzipped"
[ -d "$tmp/unzipped/$APP_NAME" ] || die "zip does not contain $APP_NAME."
codesign --verify --deep --strict "$tmp/unzipped/$APP_NAME" 2>/dev/null || die "app signature is broken."
new_version=$(defaults read "$tmp/unzipped/$APP_NAME/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")

# --- Install --------------------------------------------------------------
if [ ! -w "$INSTALL_DIR" ]; then
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
fi
dest="$INSTALL_DIR/$APP_NAME"

if pgrep -f "$APP_NAME/Contents/MacOS/CV60Viewer" >/dev/null; then
    say "Quitting the running app…"
    osascript -e 'tell application id "local.cv60.viewer" to quit' >/dev/null 2>&1 || true
    sleep 2
    pkill -f "$APP_NAME/Contents/MacOS/CV60Viewer" 2>/dev/null || true
fi

if [ -d "$dest" ]; then
    old_version=$(defaults read "$dest/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")
    say "Replacing version $old_version"
    rm -rf "$dest"
fi
ditto "$tmp/unzipped/$APP_NAME" "$dest"
xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

say "Installed Huawei 360 $new_version → $dest"
echo
echo "  Open it:            open \"$dest\""
echo "  Command-line tool:  \"$dest/Contents/MacOS/cv60\" info"
echo "  Uninstall:          rm -rf \"$dest\""
