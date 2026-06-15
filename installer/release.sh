#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# release.sh — build + sign + DMG + notarize + staple FlySim, drop on ~/Desktop.
#
#   Driven by `make release`. Reads identity from ../signing.env:
#     SIGN_IDENTITY        Developer ID Application string
#     NOTARY_PROFILE_NAME  notarytool keychain profile
#
# FlySim is a single self-contained .app (system frameworks only — Cocoa /
# QuartzCore / Metal / Foundation), so the pipeline is: sign the bundle with a
# hardened runtime, wrap it in a drag-to-install DMG, sign + notarize + staple
# the DMG, then copy it to the Desktop.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
cd "$(dirname "$0")/.."                       # repo root

VERSION="${VERSION:-0.4}"
SIGN_IDENTITY="${SIGN_IDENTITY:?set SIGN_IDENTITY (see signing.env)}"
NOTARY_PROFILE="${NOTARY_PROFILE_NAME:-rs-notary}"

APP="app/build/FlySim.app"
DIST="build/installer"
STAGE="${DIST}/dmg-stage"
DMG="${DIST}/FlySim-${VERSION}.dmg"
DESKTOP_DMG="${HOME}/Desktop/FlySim-${VERSION}.dmg"
VOL_NAME="FlySim ${VERSION}"

echo "════════════════════════════════════════════════════════════════"
echo "  FlySim ${VERSION} — release pipeline"
echo "════════════════════════════════════════════════════════════════"

# ── 1. build the app ────────────────────────────────────────────────────────
echo "── building app"
make -C app >/dev/null
[ -d "${APP}" ] || { echo "FAIL: ${APP} not built" >&2; exit 1; }

# ── 2. codesign the bundle (hardened runtime + secure timestamp, deep) ───────
echo "── codesigning ${APP}"
/usr/bin/codesign --force --deep --options runtime --timestamp \
    --sign "${SIGN_IDENTITY}" "${APP}"
/usr/bin/codesign --verify --deep --strict --verbose=1 "${APP}"
/usr/bin/codesign --display --verbose=2 "${APP}" 2>&1 \
    | grep -E "^(Identifier|TeamIdentifier|Authority|Timestamp)=" | head

# ── 3. build the DMG ────────────────────────────────────────────────────────
# makehybrid (not `create -srcfolder`): create mounts a temp volume and macOS
# scans the .app on it, failing with "Resource busy". makehybrid builds the
# filesystem image directly without mounting.
echo "── building DMG"
rm -rf "${STAGE}"; mkdir -p "${STAGE}"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
mkdir -p "${DIST}"; rm -f "${DMG}" "${DMG}.rw.dmg"
/usr/bin/hdiutil makehybrid -hfs -default-volume-name "${VOL_NAME}" \
    -o "${DMG}.rw.dmg" "${STAGE}" >/dev/null
/usr/bin/hdiutil convert "${DMG}.rw.dmg" -format UDZO -ov -o "${DMG}" >/dev/null
rm -f "${DMG}.rw.dmg"; rm -rf "${STAGE}"

# ── 4. sign the DMG ─────────────────────────────────────────────────────────
echo "── codesigning DMG"
/usr/bin/codesign --force --timestamp --sign "${SIGN_IDENTITY}" "${DMG}"

# ── 5. notarize + staple ────────────────────────────────────────────────────
echo "── submitting to Apple notarization (profile: ${NOTARY_PROFILE}; 1–5 min)"
/usr/bin/xcrun notarytool submit "${DMG}" --keychain-profile "${NOTARY_PROFILE}" --wait
echo "── stapling ticket"
/usr/bin/xcrun stapler staple "${DMG}"
/usr/bin/xcrun stapler validate "${DMG}"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG}" || true

# ── 6. drop on the Desktop ──────────────────────────────────────────────────
# (the canonical artifact stays at ${DMG}; CI uploads that. Desktop is a
#  convenience for local builds — create it if missing so CI doesn't fail.)
mkdir -p "$(dirname "${DESKTOP_DMG}")"
cp "${DMG}" "${DESKTOP_DMG}"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  FlySim ${VERSION} ready (signed + notarized):"
ls -lh "${DESKTOP_DMG}" | awk '{print "  " $5 "  " $9}'
echo "════════════════════════════════════════════════════════════════"
