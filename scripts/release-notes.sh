#!/usr/bin/env bash
#
# release-notes.sh — print the GitHub Release notes for a MacMiniMixer release.
#
# Usage:
#   scripts/release-notes.sh <tag> <version>
#   scripts/release-notes.sh v0.14 0.14
#
# Prints, to stdout:
#   1. the fixed download / install / requirements text,
#   2. "## What's new": the "### Highlights" subsection of the "## [v<version>]"
#      section of CHANGELOG.md (the whole section when it has no Highlights),
#   3. a link to the full CHANGELOG.md at the tag.
#
# Used by .github/workflows/release.yml and for manual releases (docs/RELEASING.md).
#
# Environment:
#   GH_REPO / GITHUB_REPOSITORY   owner/name used for the CHANGELOG link (default: derived
#                                 from the "origin" remote).
#
# Note: written for the macOS system bash (3.2) — no bash 4+ features.

set -euo pipefail

if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
  sed -n '3,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "usage: scripts/release-notes.sh <tag> <version>   (e.g. v0.14 0.14)" >&2
  exit 2
fi

tag="$1"
version="$2"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
changelog="${repo_root}/CHANGELOG.md"

repo="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
if [ -z "$repo" ]; then
  origin="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
  repo="$(printf '%s\n' "$origin" | sed -E -e 's#^(git@github\.com:|https://github\.com/|ssh://git@github\.com/)##' -e 's#\.git$##')"
  case "$repo" in
    */*) ;;
    *) repo="" ;;
  esac
fi

sed -e "s/@VERSION@/${version}/g" -e "s/@TAG@/${tag}/g" <<'EOF'
MacMiniMixer @TAG@ — a native macOS menu bar audio mixer (Swift + SwiftUI).

## Download

- `MacMiniMixer-@VERSION@.zip` — unzip it and move `MacMiniMixer.app` to `/Applications`.
- `MacMiniMixer-@VERSION@.zip.sha256` — SHA-256 checksum. To verify, run
  `shasum -a 256 -c MacMiniMixer-@VERSION@.zip.sha256` in the download folder.

MacMiniMixer is a menu bar app: it has no Dock icon and no main window. After launching it,
look for its icon in the menu bar.

## Before you install

- **Ad-hoc signed, not notarized.** This build is not signed with an Apple Developer ID and
  has not been notarized by Apple, so Gatekeeper blocks the first launch:
  - macOS 13–14: Control-click (right-click) `MacMiniMixer.app` → **Open** → **Open**.
  - macOS 15 or later: try to open the app once, then go to **System Settings → Privacy &
    Security** and click **Open Anyway**.
  - Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/MacMiniMixer.app`
- **Requirements:** the app runs on **macOS 13.0 or later**. Per-app audio features (Product
  Real Control and other Process Tap features) require **macOS 14.2 or later**.
- **Product Real Control is experimental, always on, and has no app-count limit.** There is no
  on/off toggle: an app row only becomes Real after you interact with it (move its slider or
  mute it), and nothing is captured before that. Until then the row is a UI preview only. Every
  Real app adds its own CPU load.
- **Advanced diagnostics are developer-only.** The Advanced section appears only in developer
  mode: `defaults write com.example.MacMiniMixer MacMiniMixerDeveloperMode -bool YES`, then
  relaunch.
- macOS asks for **System Audio Recording** permission the first time you use a Process Tap
  feature. Because this build is ad-hoc signed, macOS may ask again (or the permission may
  need to be re-enabled in System Settings) after updating to a newer build.
EOF

# This version's CHANGELOG.md section ("## [vX.Y] ...") without its heading.
section=""
if [ -f "$changelog" ]; then
  section="$(awk -v hdr="## [v${version}]" '
    index($0, hdr) == 1 { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' "$changelog")"
fi

# Its "### Highlights" subsection (up to the next "##" / "###" heading); leading blank lines dropped.
highlights="$(printf '%s\n' "$section" | awk '
  /^### Highlights[ \t]*$/ { found = 1; next }
  found && !done && (/^## / || /^### /) { done = 1 }
  found && !done {
    if (!started && $0 ~ /^[ \t]*$/) next
    started = 1
    print
  }
')"

if [ -n "$highlights" ]; then
  whats_new="$highlights"
else
  # No Highlights subsection: fall back to the whole section, minus leading blank lines.
  whats_new="$(printf '%s\n' "$section" | awk '
    !started && $0 ~ /^[ \t]*$/ { next }
    { started = 1; print }
  ')"
fi
if [ -n "$whats_new" ]; then
  echo
  echo "## What's new"
  echo
  printf '%s\n' "$whats_new"
fi

echo
if [ -n "$repo" ]; then
  echo "Full changelog: [CHANGELOG.md](https://github.com/${repo}/blob/${tag}/CHANGELOG.md)"
else
  echo "Full changelog: CHANGELOG.md at tag ${tag}."
fi
