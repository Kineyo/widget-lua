#!/usr/bin/env bash
# ============================================================================
# build_packages.sh - Builds Qwen-Widget v2.0 Packages Locally (Pop!_OS / Linux)
# Outputs in dist/:
#   1. qwen-widget_2.0.0_amd64.deb (Debian / Ubuntu / Pop!_OS package)
#   2. qwen-widget-2.0.0-linux-x86_64.tar.gz (Universal portable tarball)
# ============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
VERSION="2.0.0"
ARCH="amd64"
export PATH="$HOME/.local/bin:$PATH"

echo "[1/4] Compiling C/C++ native extensions with CMake..."
mkdir -p "${ROOT_DIR}/build" "${DIST_DIR}"
cmake -S "${ROOT_DIR}" -B "${ROOT_DIR}/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "${ROOT_DIR}/build" -j"$(nproc 2>/dev/null || echo 2)" >/dev/null

# Locate lua5.3 runtime to bundle inside packages
LUA_BIN=""
for cand in "${ROOT_DIR}/bin/lua5.3" "/opt/qwen-widget/bin/lua5.3" "$HOME/.local/bin/lua5.3" /usr/bin/lua5.3; do
    if [ -x "$cand" ]; then
        LUA_BIN="$cand"
        break
    fi
done

echo "[2/4] Building Debian / Ubuntu / Pop!_OS package (.deb)..."
DEB_STAGE="$(mktemp -d)"
mkdir -p "${DEB_STAGE}/DEBIAN"
mkdir -p "${DEB_STAGE}/opt/qwen-widget/bin"
mkdir -p "${DEB_STAGE}/opt/qwen-widget/lib/native"
mkdir -p "${DEB_STAGE}/opt/qwen-widget/lib/skills"
mkdir -p "${DEB_STAGE}/opt/qwen-widget/assets/sprites"
mkdir -p "${DEB_STAGE}/opt/qwen-widget/assets/icons"
mkdir -p "${DEB_STAGE}/opt/qwen-widget/models"
mkdir -p "${DEB_STAGE}/usr/local/bin"
mkdir -p "${DEB_STAGE}/usr/share/applications"

cp -a "${ROOT_DIR}/bin/qwen-widget" "${DEB_STAGE}/opt/qwen-widget/bin/"
cp -a "${ROOT_DIR}/bin/qwen-power" "${DEB_STAGE}/opt/qwen-widget/bin/"
[ -f "${ROOT_DIR}/bin/qwen-widget-bin" ] && cp -a "${ROOT_DIR}/bin/qwen-widget-bin" "${DEB_STAGE}/opt/qwen-widget/bin/"
[ -f "${ROOT_DIR}/bin/llama-server" ] && cp -a "${ROOT_DIR}/bin/llama-server" "${DEB_STAGE}/opt/qwen-widget/bin/"
[ -n "$LUA_BIN" ] && cp -a "$LUA_BIN" "${DEB_STAGE}/opt/qwen-widget/bin/lua5.3"
chmod 755 "${DEB_STAGE}/opt/qwen-widget/bin/"*

cp -a "${ROOT_DIR}/lib/"*.lua "${DEB_STAGE}/opt/qwen-widget/lib/"
cp -a "${ROOT_DIR}/lib/"*.so "${DEB_STAGE}/opt/qwen-widget/lib/" 2>/dev/null || true
cp -a "${ROOT_DIR}/lib/skills/"*.lua "${DEB_STAGE}/opt/qwen-widget/lib/skills/"
cp -a "${ROOT_DIR}/lib/native/"* "${DEB_STAGE}/opt/qwen-widget/lib/native/" 2>/dev/null || true
cp -a "${ROOT_DIR}/assets/"* "${DEB_STAGE}/opt/qwen-widget/assets/"

ln -sf /opt/qwen-widget/bin/qwen-widget "${DEB_STAGE}/usr/local/bin/qwen-widget"
ln -sf /opt/qwen-widget/bin/qwen-power "${DEB_STAGE}/usr/local/bin/qwen-power"

cat > "${DEB_STAGE}/usr/share/applications/qwen-widget.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Qwen Widget
Comment=Hybrid Lua + C/C++ Desktop AI Widget with embedded llama.cpp and OpenClaw
Exec=/opt/qwen-widget/bin/qwen-widget
Icon=/opt/qwen-widget/assets/sprites/idle.png
Terminal=false
StartupNotify=false
Categories=Utility;
EOF

cat > "${DEB_STAGE}/DEBIAN/control" <<EOF
Package: qwen-widget
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${ARCH}
Depends: lua-lgi, gir1.2-gtk-3.0, gir1.2-gdkpixbuf-2.0, gir1.2-pango-1.0, libc6, libstdc++6, libx11-6, libxfixes3, libxi6, libglib2.0-0, curl
Maintainer: Qwen-Widget Engineering <dev@openclaw.local>
Description: Hybrid Lua + C/C++ Desktop AI Widget with embedded llama.cpp (< 500 MB RAM)
 Includes instant X11/Wayland text selection grammar corrector, YouTube Music
 and Spotify mini-player with synced lyrics, OpenClaw autonomous agent, and
 embedded llama.cpp inference with automatic GGUF model download on first run.
EOF

cat > "${DEB_STAGE}/DEBIAN/postinst" <<'EOF'
#!/usr/bin/env bash
set -e
chmod -R 755 /opt/qwen-widget/bin /opt/qwen-widget/lib
mkdir -p /opt/qwen-widget/models
chmod 777 /opt/qwen-widget/models
ln -sf /opt/qwen-widget/bin/qwen-widget /usr/local/bin/qwen-widget 2>/dev/null || true
ln -sf /opt/qwen-widget/bin/qwen-power /usr/local/bin/qwen-power 2>/dev/null || true
echo "[qwen-widget] Installed in /opt/qwen-widget. Default GGUF models (es-grammar & qwen3.0-0.8b) will download automatically on first launch if not present."
exit 0
EOF
chmod 755 "${DEB_STAGE}/DEBIAN/postinst"

DEB_OUT="${DIST_DIR}/qwen-widget_${VERSION}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "${DEB_STAGE}" "${DEB_OUT}" >/dev/null
rm -rf "${DEB_STAGE}"
echo "  -> Created: ${DEB_OUT}"

echo "[3/4] Building Universal Portable Tarball (.tar.gz)..."
TAR_STAGE="$(mktemp -d)"
PORTABLE_DIR="${TAR_STAGE}/qwen-widget-${VERSION}"
mkdir -p "${PORTABLE_DIR}/bin"
mkdir -p "${PORTABLE_DIR}/lib/native"
mkdir -p "${PORTABLE_DIR}/lib/skills"
mkdir -p "${PORTABLE_DIR}/assets"
mkdir -p "${PORTABLE_DIR}/models"

cp -a "${ROOT_DIR}/bin/qwen-widget" "${PORTABLE_DIR}/bin/"
cp -a "${ROOT_DIR}/bin/qwen-power" "${PORTABLE_DIR}/bin/"
[ -f "${ROOT_DIR}/bin/qwen-widget-bin" ] && cp -a "${ROOT_DIR}/bin/qwen-widget-bin" "${PORTABLE_DIR}/bin/"
[ -f "${ROOT_DIR}/bin/llama-server" ] && cp -a "${ROOT_DIR}/bin/llama-server" "${PORTABLE_DIR}/bin/"
[ -n "$LUA_BIN" ] && cp -a "$LUA_BIN" "${PORTABLE_DIR}/bin/lua5.3"
chmod 755 "${PORTABLE_DIR}/bin/"*

cp -a "${ROOT_DIR}/lib/"*.lua "${PORTABLE_DIR}/lib/"
cp -a "${ROOT_DIR}/lib/"*.so "${PORTABLE_DIR}/lib/" 2>/dev/null || true
cp -a "${ROOT_DIR}/lib/skills/"*.lua "${PORTABLE_DIR}/lib/skills/"
cp -a "${ROOT_DIR}/lib/native/"* "${PORTABLE_DIR}/lib/native/" 2>/dev/null || true
cp -a "${ROOT_DIR}/assets/"* "${PORTABLE_DIR}/assets/"
cp -a "${ROOT_DIR}/install.sh" "${PORTABLE_DIR}/"
cp -a "${ROOT_DIR}/run.sh" "${PORTABLE_DIR}/"
cp -a "${ROOT_DIR}/README.md" "${PORTABLE_DIR}/"

TAR_OUT="${DIST_DIR}/qwen-widget-${VERSION}-linux-x86_64.tar.gz"
tar -C "${TAR_STAGE}" -czf "${TAR_OUT}" "qwen-widget-${VERSION}"
rm -rf "${TAR_STAGE}"
echo "  -> Created: ${TAR_OUT}"

echo "[4/4] Package build complete:"
ls -lh "${DIST_DIR}"
