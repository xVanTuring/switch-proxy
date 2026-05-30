#!/usr/bin/env bash
# scripts/release.sh
#
# Bump version → build → Developer-ID-sign → notarize → staple → zip + DMG →
# publish GitHub release.
#
# Usage:
#   ./scripts/release.sh <version> [--prerelease <suffix>] [--notes-file <path>] [--dry-run]
#
# Examples:
#   ./scripts/release.sh 1.0.0
#   ./scripts/release.sh 1.1.0 --prerelease beta
#   ./scripts/release.sh 1.0.0 --notes-file CHANGELOG.md
#   ./scripts/release.sh 1.0.0 --dry-run
#
# One-time machine setup is documented in docs/release.md.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ── Project constants (override TEAM_ID / NOTARY_PROFILE via env if needed) ──
TEAM_ID="${TEAM_ID:-T8F5T6HKG8}"
NOTARY_PROFILE="${NOTARY_PROFILE:-noticky-notary}"
SCHEME="SwitchProxy"
PROJECT="SwitchProxy.xcodeproj"
PRODUCT="SwitchProxy"
GH_REPO="xVanTuring/switch-proxy"
BUILD_DIR=".build/release"

# ── Args ────────────────────────────────────────────────────────────
usage() {
    cat <<EOF >&2
Usage: $(basename "$0") <version> [--prerelease <suffix>] [--notes-file <path>] [--dry-run]

  <version>          CFBundleShortVersionString, e.g. 1.0.0
  --prerelease X     Mark as pre-release; tag becomes v<version>-<X>.
  --notes-file PATH  File whose contents become the GitHub release body
                     (default: gh --generate-notes from commit messages).
  --dry-run          Bump version + verify Debug build + commit locally,
                     but skip push / archive / notarize / release.
EOF
    exit 1
}

VERSION=""; PRERELEASE=""; NOTES_FILE=""; DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prerelease)  PRERELEASE="${2:?--prerelease needs a value}"; shift 2 ;;
        --notes-file)  NOTES_FILE="${2:?--notes-file needs a path}"; shift 2 ;;
        --dry-run)     DRY_RUN=true; shift ;;
        -h|--help)     usage ;;
        -*)            echo "Unknown flag: $1" >&2; usage ;;
        *) if [[ -z "$VERSION" ]]; then VERSION="$1"; shift
           else echo "Unexpected positional: $1" >&2; usage; fi ;;
    esac
done

[[ -z "$VERSION" ]] && usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "ERROR: version must be X.Y.Z (got '$VERSION')" >&2; exit 1; }

if [[ -n "$PRERELEASE" ]]; then
    TAG="v${VERSION}-${PRERELEASE}"; TITLE="v${VERSION} ${PRERELEASE}"
    DIST_DIR="dist/${TAG}"; ZIP_ASSET="${PRODUCT}-${VERSION}-${PRERELEASE}.zip"
    DMG_ASSET="${PRODUCT}-${VERSION}-${PRERELEASE}.dmg"; PRERELEASE_FLAG="--prerelease"
else
    TAG="v${VERSION}"; TITLE="v${VERSION}"
    DIST_DIR="dist/${TAG}"; ZIP_ASSET="${PRODUCT}-${VERSION}.zip"
    DMG_ASSET="${PRODUCT}-${VERSION}.dmg"; PRERELEASE_FLAG=""
fi
ZIP="${DIST_DIR}/${ZIP_ASSET}"; DMG="${DIST_DIR}/${DMG_ASSET}"
APP="${DIST_DIR}/${PRODUCT}.app"
ARCHIVE="${BUILD_DIR}/${PRODUCT}.xcarchive"; EXPORT_DIR="${BUILD_DIR}/export"

echo "==> Version $VERSION  •  Tag $TAG  •  Assets $ZIP_ASSET + $DMG_ASSET"

# ── Pre-flight ──────────────────────────────────────────────────────
echo "==> Pre-flight checks"
[[ -f project.yml ]] || { echo "ERROR: run from repo root (no project.yml)" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "ERROR: xcodegen not on PATH (brew install xcodegen)" >&2; exit 1; }
command -v gh >/dev/null || { echo "ERROR: gh CLI not on PATH (brew install gh)" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated. Run 'gh auth login'." >&2; exit 1; }

security find-identity -v -p codesigning \
    | grep -q "Developer ID Application.*${TEAM_ID}" \
    || { echo "ERROR: no 'Developer ID Application' cert for team ${TEAM_ID} in keychain." >&2
         echo "       Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application." >&2
         exit 1; }

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || { echo "ERROR: notarytool profile '${NOTARY_PROFILE}' missing or invalid." >&2
         echo "       Create once: xcrun notarytool store-credentials ${NOTARY_PROFILE} \\" >&2
         echo "         --apple-id <id> --team-id ${TEAM_ID} --password <app-specific-pw>" >&2
         echo "       Or override with NOTARY_PROFILE=<name> $(basename "$0") ..." >&2
         exit 1; }

[[ -z "$(git status --porcelain)" ]] \
    || { echo "ERROR: working tree dirty. Commit or stash first." >&2; git status --short >&2; exit 1; }

if git rev-parse --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
    echo "ERROR: tag ${TAG} already exists locally." >&2; exit 1; fi
if git ls-remote --tags origin "${TAG}" | grep -q "refs/tags/${TAG}$"; then
    echo "ERROR: tag ${TAG} already exists on origin." >&2; exit 1; fi
[[ -z "$NOTES_FILE" || -f "$NOTES_FILE" ]] || { echo "ERROR: --notes-file not found: $NOTES_FILE" >&2; exit 1; }

[[ -d "$PROJECT" ]] || { echo "==> Generating xcodeproj (first run)"; xcodegen >/dev/null; }

# ── Bump version in project.yml ─────────────────────────────────────
current_short=$(grep -E 'CFBundleShortVersionString:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
current_build=$(grep -E 'CFBundleVersion:' project.yml | head -1 | sed -E 's/.*"([0-9]+)".*/\1/')
next_build=$((current_build + 1))
echo "==> Version bump  ${current_short} (build ${current_build}) → ${VERSION} (build ${next_build})"

sed -i.bak -E "s/(CFBundleShortVersionString: )\"[^\"]+\"/\\1\"${VERSION}\"/" project.yml
sed -i.bak -E "s/(CFBundleVersion: )\"[^\"]+\"/\\1\"${next_build}\"/" project.yml
rm -f project.yml.bak
xcodegen >/dev/null

echo "==> Verifying Debug build before commit"
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
        -derivedDataPath "$BUILD_DIR" build 2>&1 | grep -E "(error:|BUILD )" | tail -20; then
    echo "ERROR: Debug build failed. Reverting version bump." >&2
    git checkout -- project.yml; xcodegen >/dev/null; exit 1
fi

echo "==> Committing version bump"
git add project.yml
git commit -m "release: bump to ${VERSION} (build ${next_build})"

if [[ "$DRY_RUN" == "true" ]]; then
    echo "==> [dry-run] stopping before push/archive/release."
    echo "    To undo:  git reset --hard HEAD~1 && xcodegen"
    exit 0
fi

echo "==> Pushing main"
git push origin main

# ── Build + Developer ID export ─────────────────────────────────────
echo "==> Cleaning ${DIST_DIR}"
rm -rf "${DIST_DIR}" "${ARCHIVE}" "${EXPORT_DIR}"; mkdir -p "${DIST_DIR}"

echo "==> Archiving Release (Developer ID + hardened runtime)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -derivedDataPath "$BUILD_DIR" -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates -quiet archive
[[ -d "$ARCHIVE" ]] || { echo "ERROR: archive not produced at $ARCHIVE" >&2; exit 1; }

# Developer ID export options (generated so teamID stays in sync with TEAM_ID).
EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>${TEAM_ID}</string>
</dict></plist>
PLIST

echo "==> Exporting + re-signing as Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" -allowProvisioningUpdates | tail -20

BUILT_APP="${EXPORT_DIR}/${PRODUCT}.app"
[[ -d "$BUILT_APP" ]] || { echo "ERROR: exported .app missing at $BUILT_APP" >&2; exit 1; }
ditto "$BUILT_APP" "$APP"

echo "==> Verifying codesign"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --verbose=2 "$APP" 2>&1 | grep -E "TeamIdentifier|Authority|Format|flags" || true

# ── Zip + notarize app ──────────────────────────────────────────────
echo "==> Zipping for notarization"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Submitting .zip to Apple notarization (--wait)"
NOTARY_LOG="${DIST_DIR}/notary-app.log"
if ! xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$NOTARY_LOG"; then
    echo "ERROR: notarization failed. Detailed log:" >&2
    echo "  xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
fi

echo "==> Stapling ticket onto .app"
xcrun stapler staple "$APP" && xcrun stapler validate "$APP"
spctl -a -t exec -vv "$APP" 2>&1 || true

echo "==> Re-zipping stapled app"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# ── DMG (parallel asset for manual download) ────────────────────────
echo "==> Creating DMG"
DMG_STAGE="${DIST_DIR}/.dmg-stage"; rm -rf "$DMG_STAGE"; mkdir -p "$DMG_STAGE"
ditto "$APP" "${DMG_STAGE}/${PRODUCT}.app"
ln -s /Applications "${DMG_STAGE}/Applications"
hdiutil create -volname "${PRODUCT} ${VERSION}" -srcfolder "$DMG_STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_STAGE"

echo "==> Submitting .dmg to notarization"
if ! xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "${DIST_DIR}/notary-dmg.log"; then
    echo "ERROR: DMG notarization failed." >&2; exit 1
fi
echo "==> Stapling DMG"
xcrun stapler staple "$DMG" && xcrun stapler validate "$DMG"

# ── Tag + GitHub release ────────────────────────────────────────────
echo "==> Tagging ${TAG}"
git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"

echo "==> Creating GitHub release"
if [[ -n "$NOTES_FILE" ]]; then
    gh release create "$TAG" $PRERELEASE_FLAG --title "$TITLE" --notes-file "$NOTES_FILE" "$ZIP" "$DMG"
else
    gh release create "$TAG" $PRERELEASE_FLAG --title "$TITLE" --generate-notes "$ZIP" "$DMG"
fi

echo
echo "================================================================"
echo "Release ${TAG} done"
echo "  .zip : ${ZIP} ($(du -h "$ZIP" | cut -f1))"
echo "  .dmg : ${DMG} ($(du -h "$DMG" | cut -f1))"
echo "  URL  : https://github.com/${GH_REPO}/releases/tag/${TAG}"
echo "================================================================"
echo "Smoke test: open the DMG, drag to /Applications, launch, check menu-bar icon."
