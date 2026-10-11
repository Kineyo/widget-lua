#!/usr/bin/env bash
# ======================================================================
#  install.sh  –  Qwen-Widget Installer for Pop!_OS 24.04 LTS
#
#  Strategy:
#    1. Check / install system deps via apt (needs sudo)
#    2. Build Lua 5.3 locally if not found (LGI needs 5.3, not 5.4)
#    3. Copy everything to /opt/qwen-widget/ (needs sudo)
#    4. Create autostart .desktop in ~/.config/autostart/
# ======================================================================
set -euo pipefail

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="/opt/qwen-widget"
AUTOSTART_DIR="${HOME}/.config/autostart"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LUA_VERSION="5.3.6"
LUA_URL="https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz"

# ------------------------------------------------------------------
banner() {
    echo -e "${PURPLE}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║        ✦  Qwen-Widget Installer  ✦       ║"
    echo "  ║    Desktop Widget for Pop!_OS 24.04      ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${NC}"
}

info()  { echo -e "  ${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "  ${GREEN}[  OK]${NC}  $*"; }
warn()  { echo -e "  ${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "  ${RED}[FAIL]${NC}  $*"; exit 1; }

# ------------------------------------------------------------------
check_system_deps() {
    info "Verificando dependencias del sistema..."

    local PKGS_NEEDED=()

    dpkg -s lua-lgi             &>/dev/null || PKGS_NEEDED+=("lua-lgi")
    dpkg -s gir1.2-gtk-3.0      &>/dev/null || PKGS_NEEDED+=("gir1.2-gtk-3.0")
    dpkg -s gir1.2-gdkpixbuf-2.0 &>/dev/null || PKGS_NEEDED+=("gir1.2-gdkpixbuf-2.0")
    dpkg -s gir1.2-pango-1.0    &>/dev/null || PKGS_NEEDED+=("gir1.2-pango-1.0")
    dpkg -s liblua5.3-0         &>/dev/null || PKGS_NEEDED+=("liblua5.3-0")
    command -v curl              &>/dev/null || PKGS_NEEDED+=("curl")
    command -v gcc               &>/dev/null || PKGS_NEEDED+=("gcc")
    dpkg -s make                 &>/dev/null || PKGS_NEEDED+=("make")

    if [ ${#PKGS_NEEDED[@]} -gt 0 ]; then
        warn "Paquetes faltantes: ${PKGS_NEEDED[*]}"
        info "Instalando dependencias con apt..."
        sudo apt-get update -qq
        sudo apt-get install -y -qq "${PKGS_NEEDED[@]}"
        ok "Dependencias instaladas."
    else
        ok "Todas las dependencias están presentes."
    fi
}

# ------------------------------------------------------------------
ensure_lua53() {
    info "Verificando Lua 5.3..."

    # Check if lua5.3 binary exists somewhere usable
    local LUA_BIN=""
    for candidate in /usr/bin/lua5.3 /usr/local/bin/lua5.3 "$HOME/.local/bin/lua5.3"; do
        if [ -x "$candidate" ]; then
            LUA_BIN="$candidate"
            break
        fi
    done

    if [ -n "$LUA_BIN" ]; then
        # Verify it can load LGI
        if "$LUA_BIN" -e "
            package.path='/usr/share/lua/5.3/?.lua;/usr/share/lua/5.3/?/init.lua;'..package.path
            package.cpath='/usr/lib/x86_64-linux-gnu/lua/5.3/?.so;/usr/lib/x86_64-linux-gnu/lua/5.3/?/corelgilua51.so;'..package.cpath
            require('lgi')
        " &>/dev/null; then
            ok "Lua 5.3 con LGI funcional: $LUA_BIN"
            return 0
        else
            warn "Lua 5.3 encontrado pero LGI no carga. Recompilando..."
        fi
    fi

    # Build Lua 5.3 from source (needs -Wl,-E to export symbols for LGI)
    info "Compilando Lua ${LUA_VERSION} desde fuente..."
    local BUILD_DIR
    BUILD_DIR="$(mktemp -d)"

    (
        cd "$BUILD_DIR"
        curl -sL "$LUA_URL" -o lua.tar.gz
        tar xzf lua.tar.gz
        cd "lua-${LUA_VERSION}"

        # Build with exported symbols (-Wl,-E) so .so modules can bind
        make clean 2>/dev/null || true
        cd src
        gcc -std=gnu99 -O2 -Wall -DLUA_COMPAT_5_2 -DLUA_USE_POSIX -DLUA_USE_DLOPEN -c \
            lapi.c lcode.c lctype.c ldebug.c ldo.c ldump.c lfunc.c lgc.c llex.c \
            lmem.c lobject.c lopcodes.c lparser.c lstate.c lstring.c ltable.c \
            ltm.c lundump.c lvm.c lzio.c lauxlib.c lbaselib.c lbitlib.c \
            lcorolib.c ldblib.c liolib.c lmathlib.c loslib.c lstrlib.c \
            ltablib.c lutf8lib.c loadlib.c linit.c lua.c
        ar rcu liblua.a lapi.o lcode.o lctype.o ldebug.o ldo.o ldump.o lfunc.o \
            lgc.o llex.o lmem.o lobject.o lopcodes.o lparser.o lstate.o \
            lstring.o ltable.o ltm.o lundump.o lvm.o lzio.o lauxlib.o \
            lbaselib.o lbitlib.o lcorolib.o ldblib.o liolib.o lmathlib.o \
            loslib.o lstrlib.o ltablib.o lutf8lib.o loadlib.o linit.o
        ranlib liblua.a
        gcc -std=gnu99 -o lua lua.o liblua.a -lm -ldl -Wl,-E
    ) 2>&1 | tail -5

    # Install to user local bin
    mkdir -p "$HOME/.local/bin"
    cp "${BUILD_DIR}/lua-${LUA_VERSION}/src/lua" "$HOME/.local/bin/lua5.3"
    chmod 755 "$HOME/.local/bin/lua5.3"

    # Clean up
    rm -rf "$BUILD_DIR"

    # Verify
    if "$HOME/.local/bin/lua5.3" -e "
        package.path='/usr/share/lua/5.3/?.lua;/usr/share/lua/5.3/?/init.lua;'..package.path
        package.cpath='/usr/lib/x86_64-linux-gnu/lua/5.3/?.so;/usr/lib/x86_64-linux-gnu/lua/5.3/?/corelgilua51.so;'..package.cpath
        require('lgi')
    " &>/dev/null; then
        ok "Lua 5.3 compilado y LGI verificado: $HOME/.local/bin/lua5.3"
    else
        fail "No se pudo verificar LGI con Lua 5.3 compilado."
    fi
}

# ------------------------------------------------------------------
install_files() {
    info "Instalando archivos en ${INSTALL_DIR}..."

    sudo mkdir -p "${INSTALL_DIR}/bin"
    sudo mkdir -p "${INSTALL_DIR}/lib"
    sudo mkdir -p "${INSTALL_DIR}/assets"

    # Copy Lua modules
    sudo cp "${SCRIPT_DIR}/lib/"*.lua "${INSTALL_DIR}/lib/"
    ok "Módulos Lua copiados."

    # Copy launcher script
    sudo cp "${SCRIPT_DIR}/bin/qwen-widget" "${INSTALL_DIR}/bin/qwen-widget"
    sudo chmod 755 "${INSTALL_DIR}/bin/qwen-widget"
    ok "Launcher instalado."

    # Copy lua5.3 binary into install dir for portability
    local LUA_SRC=""
    for candidate in "$HOME/.local/bin/lua5.3" /usr/bin/lua5.3 /usr/local/bin/lua5.3; do
        if [ -x "$candidate" ]; then
            LUA_SRC="$candidate"
            break
        fi
    done
    if [ -n "$LUA_SRC" ]; then
        sudo cp "$LUA_SRC" "${INSTALL_DIR}/bin/lua5.3"
        sudo chmod 755 "${INSTALL_DIR}/bin/lua5.3"
        ok "Lua 5.3 bundled en ${INSTALL_DIR}/bin/lua5.3"
    fi

    # Copy assets
    if [ -d "${SCRIPT_DIR}/assets" ]; then
        sudo cp -r "${SCRIPT_DIR}/assets/"* "${INSTALL_DIR}/assets/" 2>/dev/null || true
        ok "Assets copiados."
    fi

    # Symlink for CLI
    sudo ln -sf "${INSTALL_DIR}/bin/qwen-widget" /usr/local/bin/qwen-widget 2>/dev/null || true
    ok "Symlink: /usr/local/bin/qwen-widget"

    # Permissions
    sudo chown -R root:root "${INSTALL_DIR}"
    sudo chmod -R 755 "${INSTALL_DIR}"
    sudo chmod 644 "${INSTALL_DIR}/lib/"*.lua
    sudo chmod 644 "${INSTALL_DIR}/assets/"* 2>/dev/null || true
}

# ------------------------------------------------------------------
setup_autostart() {
    info "Configurando autostart..."

    mkdir -p "${AUTOSTART_DIR}"

    cat > "${AUTOSTART_DIR}/qwen-widget.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Qwen Widget
Comment=Floating desktop widget with Ollama chat, weather, crypto & notifications
Exec=${INSTALL_DIR}/bin/qwen-widget
Icon=${INSTALL_DIR}/assets/avatar.jpg
Terminal=false
StartupNotify=false
Categories=Utility;
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=3
EOF

    ok "Autostart: ${AUTOSTART_DIR}/qwen-widget.desktop"
}

# ------------------------------------------------------------------
verify_install() {
    info "Verificando instalación..."
    local errors=0

    [ -x "${INSTALL_DIR}/bin/qwen-widget" ] || { warn "Falta bin/qwen-widget"; ((errors++)); }
    [ -x "${INSTALL_DIR}/bin/lua5.3" ]      || { warn "Falta bin/lua5.3"; ((errors++)); }
    [ -f "${INSTALL_DIR}/lib/main.lua" ]     || { warn "Falta lib/main.lua"; ((errors++)); }
    [ -f "${INSTALL_DIR}/lib/widget.lua" ]   || { warn "Falta lib/widget.lua"; ((errors++)); }
    [ -f "${INSTALL_DIR}/lib/chat.lua" ]     || { warn "Falta lib/chat.lua"; ((errors++)); }
    [ -f "${INSTALL_DIR}/lib/config.lua" ]   || { warn "Falta lib/config.lua"; ((errors++)); }
    [ -f "${INSTALL_DIR}/lib/fetchers.lua" ] || { warn "Falta lib/fetchers.lua"; ((errors++)); }
    [ -f "${INSTALL_DIR}/lib/ollama.lua" ]   || { warn "Falta lib/ollama.lua"; ((errors++)); }
    [ -f "${INSTALL_DIR}/lib/player.lua" ]   || { warn "Falta lib/player.lua"; ((errors++)); }
    [ -f "${INSTALL_DIR}/lib/lyrics.lua" ]   || { warn "Falta lib/lyrics.lua"; ((errors++)); }
    [ -f "${INSTALL_DIR}/lib/lyrics_bubble.lua" ] || { warn "Falta lib/lyrics_bubble.lua"; ((errors++)); }
    [ -f "${INSTALL_DIR}/lib/mpris.lua" ]    || { warn "Falta lib/mpris.lua"; ((errors++)); }
    [ -f "${INSTALL_DIR}/lib/openclaw_agent.lua" ] || { warn "Falta lib/openclaw_agent.lua"; ((errors++)); }
    [ -f "${INSTALL_DIR}/assets/avatar.jpg" ]|| { warn "Falta assets/avatar.jpg"; ((errors++)); }
    [ -f "${AUTOSTART_DIR}/qwen-widget.desktop" ] || { warn "Falta autostart .desktop"; ((errors++)); }

    if [ $errors -eq 0 ]; then
        ok "Verificación completa — 0 errores."
    else
        warn "Se encontraron ${errors} problema(s)."
    fi
}

# ------------------------------------------------------------------
print_summary() {
    echo ""
    echo -e "${GREEN}  ╔══════════════════════════════════════════════╗"
    echo -e "  ║        ✦  Instalación Completada  ✦          ║"
    echo -e "  ╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}Directorio:${NC}    ${INSTALL_DIR}/"
    echo -e "  ${CYAN}Ejecutable:${NC}    ${INSTALL_DIR}/bin/qwen-widget"
    echo -e "  ${CYAN}Lua 5.3:${NC}       ${INSTALL_DIR}/bin/lua5.3"
    echo -e "  ${CYAN}Autostart:${NC}     ${AUTOSTART_DIR}/qwen-widget.desktop"
    echo -e "  ${CYAN}Modelo:${NC}        ${QWEN_MODEL:-qwen3:0.6b}"
    echo ""
    echo -e "  ${BOLD}${YELLOW}Uso:${NC}"
    echo -e "    Ejecutar ahora:     ${GREEN}qwen-widget${NC}"
    echo -e "    O reiniciar sesión para autostart."
    echo ""
    echo -e "  ${BOLD}${YELLOW}Controles:${NC}"
    echo -e "    Click izquierdo     Abrir/cerrar chat OpenClaw"
    echo -e "    Click central       Desplegar reproductor YouTube Music"
    echo -e "    Arrastrar           Mover widget (snap a bordes de pantalla)"
    echo -e "    Click derecho       Cerrar widget"
    echo ""
    echo -e "  ${BOLD}${YELLOW}Ollama:${NC}"
    echo -e "    ollama serve"
    echo -e "    ollama pull qwen3:0.6b"
    echo -e "    QWEN_MODEL=qwen3:4b qwen-widget    ${CYAN}# modelo alternativo${NC}"
    echo ""
    echo -e "  ${BOLD}${YELLOW}Desinstalar:${NC}"
    echo -e "    sudo rm -rf ${INSTALL_DIR}"
    echo -e "    rm ${AUTOSTART_DIR}/qwen-widget.desktop"
    echo -e "    sudo rm /usr/local/bin/qwen-widget"
    echo ""
}

# ==================================================================
# Main
# ==================================================================
banner

if [ ! -f "${SCRIPT_DIR}/lib/main.lua" ]; then
    fail "No se encontró lib/main.lua. Ejecuta install.sh desde el directorio del proyecto."
fi

check_system_deps
ensure_lua53
install_files
setup_autostart
verify_install
print_summary

exit 0
