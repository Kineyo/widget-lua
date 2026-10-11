#!/usr/bin/env bash
# ======================================================================
#  run.sh  –  Instala y ejecuta Qwen-Widget en /opt/qwen-widget/
#
#  Uso:  ./run.sh          (instala + ejecuta)
#         ./run.sh --install (solo instalar)
#         ./run.sh --run     (solo ejecutar, ya instalado)
# ======================================================================
set -euo pipefail

RED='\033[0;31m';  GREEN='\033[0;32m';  YELLOW='\033[1;33m'
PURPLE='\033[0;35m';  CYAN='\033[0;36m';  BOLD='\033[1m';  NC='\033[0m'

INSTALL_DIR="/opt/qwen-widget"
AUTOSTART_DIR="${HOME}/.config/autostart"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LUA_VERSION="5.3.6"
LUA_URL="https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz"

info()  { echo -e "  ${CYAN}▸${NC} $*"; }
ok()    { echo -e "  ${GREEN}✓${NC} $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $*"; }
fail()  { echo -e "  ${RED}✗${NC} $*"; exit 1; }

banner() {
    echo ""
    echo -e "${PURPLE}${BOLD}  ╔══════════════════════════════════════╗"
    echo -e "  ║      ✦  Qwen-Widget  Installer  ✦    ║"
    echo -e "  ║     Pop!_OS 24.04 • Lua + GTK3       ║"
    echo -e "  ╚══════════════════════════════════════╝${NC}"
    echo ""
}

# ------------------------------------------------------------------
install_system_deps() {
    info "Verificando paquetes del sistema..."
    local PKGS=()
    dpkg -s lua-lgi              &>/dev/null || PKGS+=("lua-lgi")
    dpkg -s gir1.2-gtk-3.0       &>/dev/null || PKGS+=("gir1.2-gtk-3.0")
    dpkg -s gir1.2-gdkpixbuf-2.0 &>/dev/null || PKGS+=("gir1.2-gdkpixbuf-2.0")
    dpkg -s gir1.2-pango-1.0     &>/dev/null || PKGS+=("gir1.2-pango-1.0")
    command -v curl               &>/dev/null || PKGS+=("curl")
    command -v gcc                &>/dev/null || PKGS+=("gcc")
    dpkg -s make                  &>/dev/null || PKGS+=("make")

    if [ ${#PKGS[@]} -gt 0 ]; then
        info "Instalando: ${PKGS[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y -qq "${PKGS[@]}"
    fi
    ok "Dependencias del sistema listas"
}

# ------------------------------------------------------------------
build_lua53() {
    # Check if we already have a working lua5.3
    for candidate in "${INSTALL_DIR}/bin/lua5.3" "$HOME/.local/bin/lua5.3" /usr/bin/lua5.3; do
        if [ -x "$candidate" ]; then
            if "$candidate" -e "
                package.path='/usr/share/lua/5.3/?.lua;/usr/share/lua/5.3/?/init.lua;'..package.path
                package.cpath='/usr/lib/x86_64-linux-gnu/lua/5.3/?.so;/usr/lib/x86_64-linux-gnu/lua/5.3/?/corelgilua51.so;'..package.cpath
                require('lgi')
            " &>/dev/null; then
                ok "Lua 5.3 + LGI ya funcional: $candidate"
                LUA_BIN="$candidate"
                return 0
            fi
        fi
    done

    info "Compilando Lua ${LUA_VERSION} (necesario para LGI)..."
    local BUILD_DIR
    BUILD_DIR="$(mktemp -d)"

    cd "$BUILD_DIR"
    curl -sL "$LUA_URL" -o lua.tar.gz
    tar xzf lua.tar.gz
    cd "lua-${LUA_VERSION}/src"

    gcc -std=gnu99 -O2 -Wall -DLUA_COMPAT_5_2 -DLUA_USE_POSIX -DLUA_USE_DLOPEN -c \
        lapi.c lcode.c lctype.c ldebug.c ldo.c ldump.c lfunc.c lgc.c llex.c \
        lmem.c lobject.c lopcodes.c lparser.c lstate.c lstring.c ltable.c \
        ltm.c lundump.c lvm.c lzio.c lauxlib.c lbaselib.c lbitlib.c \
        lcorolib.c ldblib.c liolib.c lmathlib.c loslib.c lstrlib.c \
        ltablib.c lutf8lib.c loadlib.c linit.c lua.c 2>&1 | tail -2

    ar rcu liblua.a lapi.o lcode.o lctype.o ldebug.o ldo.o ldump.o lfunc.o \
        lgc.o llex.o lmem.o lobject.o lopcodes.o lparser.o lstate.o \
        lstring.o ltable.o ltm.o lundump.o lvm.o lzio.o lauxlib.o \
        lbaselib.o lbitlib.o lcorolib.o ldblib.o liolib.o lmathlib.o \
        loslib.o lstrlib.o ltablib.o lutf8lib.o loadlib.o linit.o
    ranlib liblua.a
    gcc -std=gnu99 -o lua lua.o liblua.a -lm -ldl -Wl,-E

    mkdir -p "$HOME/.local/bin"
    cp lua "$HOME/.local/bin/lua5.3"
    chmod 755 "$HOME/.local/bin/lua5.3"
    LUA_BIN="$HOME/.local/bin/lua5.3"

    cd /
    rm -rf "$BUILD_DIR"
    ok "Lua 5.3 compilado: $LUA_BIN"
}

# ------------------------------------------------------------------
install_to_opt() {
    info "Instalando en ${INSTALL_DIR}/..."

    sudo mkdir -p "${INSTALL_DIR}/bin" "${INSTALL_DIR}/lib" "${INSTALL_DIR}/assets"

    # Copy modules
    sudo cp "${SCRIPT_DIR}/lib/"*.lua "${INSTALL_DIR}/lib/"

    # Copy launcher
    sudo cp "${SCRIPT_DIR}/bin/qwen-widget" "${INSTALL_DIR}/bin/qwen-widget"
    sudo chmod 755 "${INSTALL_DIR}/bin/qwen-widget"

    # Bundle lua5.3
    if [ -n "${LUA_BIN:-}" ] && [ -x "${LUA_BIN:-}" ]; then
        if [ "$LUA_BIN" != "${INSTALL_DIR}/bin/lua5.3" ]; then
            sudo cp "$LUA_BIN" "${INSTALL_DIR}/bin/lua5.3"
        fi
        sudo chmod 755 "${INSTALL_DIR}/bin/lua5.3"
    fi

    # Copy assets
    if [ -d "${SCRIPT_DIR}/assets" ]; then
        sudo cp "${SCRIPT_DIR}/assets/"* "${INSTALL_DIR}/assets/" 2>/dev/null || true
    fi

    # Symlink
    sudo ln -sf "${INSTALL_DIR}/bin/qwen-widget" /usr/local/bin/qwen-widget 2>/dev/null || true

    # Permissions
    sudo chown -R root:root "${INSTALL_DIR}"
    sudo chmod -R 755 "${INSTALL_DIR}"
    sudo chmod 644 "${INSTALL_DIR}/lib/"*.lua
    sudo chmod 644 "${INSTALL_DIR}/assets/"* 2>/dev/null || true

    ok "Archivos instalados en ${INSTALL_DIR}/"
}

# ------------------------------------------------------------------
setup_autostart() {
    mkdir -p "${AUTOSTART_DIR}"
    cat > "${AUTOSTART_DIR}/qwen-widget.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Qwen Widget
Comment=Floating bubble widget with Ollama chat
Exec=${INSTALL_DIR}/bin/qwen-widget
Icon=${INSTALL_DIR}/assets/avatar.jpg
Terminal=false
StartupNotify=false
Categories=Utility;
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=3
EOF
    ok "Autostart configurado"
}

# ------------------------------------------------------------------
run_widget() {
    # Kill existing
    pkill -f "lua.*qwen-widget.*main.lua" 2>/dev/null || true
    sleep 0.3

    local LUA="${INSTALL_DIR}/bin/lua5.3"
    [ -x "$LUA" ] || LUA="$HOME/.local/bin/lua5.3"
    [ -x "$LUA" ] || fail "No se encuentra lua5.3"

    export LUA_PATH="/usr/share/lua/5.3/?.lua;/usr/share/lua/5.3/?/init.lua;${INSTALL_DIR}/lib/?.lua;;"
    export LUA_CPATH="/usr/lib/x86_64-linux-gnu/lua/5.3/?.so;/usr/lib/x86_64-linux-gnu/lua/5.3/?/corelgilua51.so;;"
    export QWEN_WIDGET_DIR="${INSTALL_DIR}"
    export GDK_BACKEND=x11

    echo ""
    echo -e "  ${GREEN}${BOLD}OpenClaw Qwen-Widget iniciando...${NC}"
    echo -e "  ${CYAN}Click izquierdo${NC}   → Abrir/cerrar chat OpenClaw"
    echo -e "  ${CYAN}Click central${NC}     → Reproductor YouTube Music"
    echo -e "  ${CYAN}Arrastrar${NC}         → Mover (snap a bordes)"
    echo -e "  ${CYAN}Click derecho${NC}     → Cerrar"
    echo ""

    exec "$LUA" "${INSTALL_DIR}/lib/main.lua" 2>/dev/null &
    disown
    ok "Widget lanzado en segundo plano (PID: $!)"
}

# ------------------------------------------------------------------
verify() {
    local errs=0
    [ -x "${INSTALL_DIR}/bin/qwen-widget" ] || { warn "Falta bin/qwen-widget"; ((errs++)); }
    [ -x "${INSTALL_DIR}/bin/lua5.3" ]      || { warn "Falta bin/lua5.3"; ((errs++)); }
    [ -f "${INSTALL_DIR}/lib/main.lua" ]     || { warn "Falta lib/main.lua"; ((errs++)); }
    [ -f "${INSTALL_DIR}/lib/widget.lua" ]   || { warn "Falta lib/widget.lua"; ((errs++)); }
    [ -f "${INSTALL_DIR}/lib/bubbles.lua" ]  || { warn "Falta lib/bubbles.lua"; ((errs++)); }
    [ -f "${INSTALL_DIR}/lib/player.lua" ]   || { warn "Falta lib/player.lua"; ((errs++)); }
    [ -f "${INSTALL_DIR}/lib/lyrics.lua" ]   || { warn "Falta lib/lyrics.lua"; ((errs++)); }
    [ -f "${INSTALL_DIR}/lib/lyrics_bubble.lua" ] || { warn "Falta lib/lyrics_bubble.lua"; ((errs++)); }
    [ -f "${INSTALL_DIR}/lib/mpris.lua" ]    || { warn "Falta lib/mpris.lua"; ((errs++)); }
    [ -f "${INSTALL_DIR}/lib/openclaw_agent.lua" ] || { warn "Falta lib/openclaw_agent.lua"; ((errs++)); }
    [ -f "${INSTALL_DIR}/assets/avatar.jpg" ]|| { warn "Falta assets/avatar.jpg"; ((errs++)); }
    [ $errs -eq 0 ] && ok "Verificación: ${GREEN}todo OK${NC}" || warn "$errs problemas"
}

# ==================================================================
banner

case "${1:-}" in
    --run)
        run_widget
        ;;
    --install)
        echo -e "  ${YELLOW}Se necesita contraseña de administrador para /opt/${NC}"
        sudo -v || fail "Se necesita sudo"
        install_system_deps
        build_lua53
        install_to_opt
        setup_autostart
        verify
        ;;
    *)
        echo -e "  ${YELLOW}Se necesita contraseña de administrador para /opt/${NC}"
        sudo -v || fail "Se necesita sudo"
        install_system_deps
        build_lua53
        install_to_opt
        setup_autostart
        verify
        run_widget
        ;;
esac

echo ""
echo -e "  ${PURPLE}¡Listo!${NC} Modelo: ${CYAN}${QWEN_MODEL:-qwen3:0.6b}${NC}"
echo -e "  Cambiar modelo: ${CYAN}QWEN_MODEL=qwen3:4b qwen-widget${NC}"
echo ""
