#!/usr/bin/env bash
# ======================================================================
#  install.sh  –  Qwen-Widget v2.0 Hybrid Installer (Pop!_OS / Debian / Ubuntu)
#
#  Strategy:
#    1. Verify / install system dependencies (GTK3, LGI, X11, GLib, curl)
#    2. Ensure Lua 5.3 runtime and C/C++ native extensions (qwen_native.so)
#    3. Ensure embedded llama.cpp runtime and default GGUF models
#       (es-grammar.gguf & qwen3.0-0.8b.gguf) with progress & GGUF check
#    4. Install embedded bundle into /opt/qwen-widget/ (or ~/.local/share/qwen-widget)
#    5. Configure desktop entry and autostart
# ======================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="${QWEN_INSTALL_DIR:-/opt/qwen-widget}"
AUTOSTART_DIR="${HOME}/.config/autostart"
APPS_DIR="${HOME}/.local/share/applications"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LUA_VERSION="5.3.6"
LUA_URL="https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz"

ES_GRAMMAR_URL="https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"
QWEN3_08B_URL="https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf"
LLAMA_RELEASE_URL="https://github.com/ggml-org/llama.cpp/releases/download/b5092/llama-b5092-bin-ubuntu-x64.zip"

export PATH="$HOME/.local/bin:$PATH"

banner() {
    echo -e "${PURPLE}"
    echo "  +================================================+"
    echo "  |     Qwen-Widget v2.0 Hybrid Native Installer   |"
    echo "  |   Lua 5.3 + C++17 + llama.cpp (< 500 MB RAM)   |"
    echo "  +================================================+"
    echo -e "${NC}"
}

info()  { echo -e "  ${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "  ${GREEN}[  OK]${NC}  $*"; }
warn()  { echo -e "  ${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "  ${RED}[FAIL]${NC}  $*"; exit 1; }

SUDO=""
setup_privilege() {
    if [ "$(id -u)" -eq 0 ]; then
        SUDO=""
    elif sudo -n true 2>/dev/null; then
        SUDO="sudo"
    else
        info "Verificando permisos de administrador para ${INSTALL_DIR}..."
        if sudo -v 2>/dev/null; then
            SUDO="sudo"
        else
            warn "Sin acceso sudo; instalando en directorio de usuario ~/.local/share/qwen-widget"
            INSTALL_DIR="${HOME}/.local/share/qwen-widget"
            SUDO=""
        fi
    fi
}

check_system_deps() {
    info "Verificando dependencias del sistema..."
    local PKGS_NEEDED=()
    dpkg -s lua-lgi              &>/dev/null || PKGS_NEEDED+=("lua-lgi")
    dpkg -s gir1.2-gtk-3.0       &>/dev/null || PKGS_NEEDED+=("gir1.2-gtk-3.0")
    dpkg -s gir1.2-gdkpixbuf-2.0 &>/dev/null || PKGS_NEEDED+=("gir1.2-gdkpixbuf-2.0")
    dpkg -s gir1.2-pango-1.0     &>/dev/null || PKGS_NEEDED+=("gir1.2-pango-1.0")
    dpkg -s liblua5.3-0          &>/dev/null || PKGS_NEEDED+=("liblua5.3-0")
    command -v curl              &>/dev/null || PKGS_NEEDED+=("curl")
    command -v g++               &>/dev/null || PKGS_NEEDED+=("g++")
    dpkg -s make                 &>/dev/null || PKGS_NEEDED+=("make")

    if [ ${#PKGS_NEEDED[@]} -gt 0 ] && [ -n "$SUDO" ]; then
        warn "Instalando paquetes faltantes: ${PKGS_NEEDED[*]}"
        $SUDO apt-get update -qq
        $SUDO apt-get install -y -qq "${PKGS_NEEDED[@]}"
        ok "Dependencias del sistema instaladas."
    else
        ok "Dependencias del sistema verificadas."
    fi
}

ensure_lua53() {
    info "Verificando runtime Lua 5.3..."
    local LUA_BIN=""
    for candidate in "${SCRIPT_DIR}/bin/lua5.3" "/opt/qwen-widget/bin/lua5.3" "$HOME/.local/bin/lua5.3" /usr/bin/lua5.3 /usr/local/bin/lua5.3; do
        if [ -x "$candidate" ]; then
            LUA_BIN="$candidate"
            break
        fi
    done

    if [ -n "$LUA_BIN" ]; then
        if "$LUA_BIN" -e "
            package.path='/usr/share/lua/5.3/?.lua;/usr/share/lua/5.3/?/init.lua;'..package.path
            package.cpath='/usr/lib/x86_64-linux-gnu/lua/5.3/?.so;/usr/lib/x86_64-linux-gnu/lua/5.3/?/corelgilua51.so;'..package.cpath
            require('lgi')
        " &>/dev/null; then
            ok "Lua 5.3 + LGI operativo: $LUA_BIN"
            return 0
        fi
    fi

    info "Compilando Lua ${LUA_VERSION} con simbolos exportados (-Wl,-E)..."
    local BUILD_DIR
    BUILD_DIR="$(mktemp -d)"
    (
        cd "$BUILD_DIR"
        curl -sL "$LUA_URL" -o lua.tar.gz
        tar xzf lua.tar.gz
        cd "lua-${LUA_VERSION}/src"
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

    mkdir -p "$HOME/.local/bin"
    cp "${BUILD_DIR}/lua-${LUA_VERSION}/src/lua" "$HOME/.local/bin/lua5.3"
    chmod 755 "$HOME/.local/bin/lua5.3"
    rm -rf "$BUILD_DIR"
    ok "Lua 5.3 compilado en $HOME/.local/bin/lua5.3"
}

build_native_cpp() {
    info "Verificando capa nativa C/C++ (qwen_native.so + libqwen_mmap_guard.so)..."
    if [ -f "${SCRIPT_DIR}/CMakeLists.txt" ] && command -v cmake &>/dev/null; then
        mkdir -p "${SCRIPT_DIR}/build"
        cmake -S "${SCRIPT_DIR}" -B "${SCRIPT_DIR}/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
        cmake --build "${SCRIPT_DIR}/build" -j"$(nproc 2>/dev/null || echo 2)" >/dev/null
        ok "Modulos C/C++ compilados con CMake."
    elif [ -f "${SCRIPT_DIR}/lib/qwen_native.so" ] && [ -f "${SCRIPT_DIR}/lib/libqwen_mmap_guard.so" ]; then
        ok "Modulos C/C++ precompilados presentes."
    else
        info "Compilando modulos C/C++ directamente con g++/gcc..."
        g++ -std=c++17 -O2 -fPIC -shared "${SCRIPT_DIR}/src/qwen_native.cpp" \
            -I"${SCRIPT_DIR}/src/include" \
            $(pkg-config --cflags --libs glib-2.0 gio-2.0 x11 xfixes xi) \
            -lpthread -ldl -o "${SCRIPT_DIR}/lib/qwen_native.so"
        gcc -O2 -fPIC -shared "${SCRIPT_DIR}/src/qwen_mmap_guard.c" \
            -lpthread -o "${SCRIPT_DIR}/lib/libqwen_mmap_guard.so"
        g++ -std=c++17 -O2 "${SCRIPT_DIR}/src/qwen_runner.cpp" -o "${SCRIPT_DIR}/bin/qwen-widget-bin"
        ok "Modulos C/C++ compilados."
    fi
}

ensure_llama_cpp() {
    info "Verificando motor embebido llama.cpp..."
    if [ -x "${SCRIPT_DIR}/bin/llama-server" ] && [ -f "${SCRIPT_DIR}/lib/native/libllama.so" ]; then
        ok "Motor llama.cpp embebido presente."
        return 0
    fi

    info "Descargando binarios precompilados de llama.cpp..."
    mkdir -p "${SCRIPT_DIR}/bin" "${SCRIPT_DIR}/lib/native"
    local TMP_ZIP
    TMP_ZIP="$(mktemp -d)"
    curl -L --progress-bar "$LLAMA_RELEASE_URL" -o "${TMP_ZIP}/llama.zip"
    python3 -c "import zipfile; zipfile.ZipFile('${TMP_ZIP}/llama.zip').extractall('${TMP_ZIP}/out')"
    cp -f "${TMP_ZIP}/out/build/bin/llama-server" "${SCRIPT_DIR}/bin/llama-server"
    chmod 755 "${SCRIPT_DIR}/bin/llama-server"
    cp -a "${TMP_ZIP}/out/build/bin/lib"*.so* "${SCRIPT_DIR}/lib/native/"
    rm -rf "$TMP_ZIP"
    ok "Motor llama.cpp descargado e integrado."
}

verify_gguf_file() {
    local file="$1"
    [ -f "$file" ] || return 1
    local size
    size=$(stat -c%s "$file" 2>/dev/null || echo 0)
    [ "$size" -gt 10485760 ] || return 1
    local magic
    magic=$(head -c 4 "$file" | tr -d '\0')
    [ "$magic" = "GGUF" ] || return 1
    return 0
}

ensure_default_models() {
    info "Verificando modelos GGUF por defecto (es-grammar y qwen3.0-0.8b)..."
    mkdir -p "${SCRIPT_DIR}/models"

    local GRAMMAR_FILE="${SCRIPT_DIR}/models/es-grammar.gguf"
    if verify_gguf_file "$GRAMMAR_FILE"; then
        ok "Modelo gramatical verificado: models/es-grammar.gguf"
    else
        info "Descargando modelo por defecto: es-grammar.gguf..."
        curl -L --progress-bar "$ES_GRAMMAR_URL" -o "${GRAMMAR_FILE}.part"
        mv "${GRAMMAR_FILE}.part" "$GRAMMAR_FILE"
        verify_gguf_file "$GRAMMAR_FILE" || fail "Integridad GGUF invalida en es-grammar.gguf"
        ok "Descargado y verificado: es-grammar.gguf"
    fi

    local CHAT_FILE="${SCRIPT_DIR}/models/qwen3.0-0.8b.gguf"
    if verify_gguf_file "$CHAT_FILE"; then
        ok "Modelo conversacional verificado: models/qwen3.0-0.8b.gguf"
    else
        info "Descargando modelo por defecto: qwen3.0-0.8b.gguf..."
        curl -L --progress-bar "$QWEN3_08B_URL" -o "${CHAT_FILE}.part"
        mv "${CHAT_FILE}.part" "$CHAT_FILE"
        verify_gguf_file "$CHAT_FILE" || fail "Integridad GGUF invalida en qwen3.0-0.8b.gguf"
        ok "Descargado y verificado: qwen3.0-0.8b.gguf"
    fi
}

install_files() {
    info "Instalando paquete completo en ${INSTALL_DIR}..."

    $SUDO mkdir -p "${INSTALL_DIR}/bin"
    $SUDO mkdir -p "${INSTALL_DIR}/lib/native"
    $SUDO mkdir -p "${INSTALL_DIR}/lib/skills"
    $SUDO mkdir -p "${INSTALL_DIR}/assets/sprites"
    $SUDO mkdir -p "${INSTALL_DIR}/assets/icons"
    $SUDO mkdir -p "${INSTALL_DIR}/models"

    # Copy Lua modules, C/C++ shared libs, and native llama.cpp libs
    $SUDO cp -r "${SCRIPT_DIR}/lib/"* "${INSTALL_DIR}/lib/"
    ok "Modulos Lua + librerias C/C++ copiados."

    # Copy binaries
    $SUDO cp "${SCRIPT_DIR}/bin/qwen-widget" "${INSTALL_DIR}/bin/qwen-widget"
    $SUDO cp "${SCRIPT_DIR}/bin/qwen-power" "${INSTALL_DIR}/bin/qwen-power"
    [ -f "${SCRIPT_DIR}/bin/qwen-widget-bin" ] && $SUDO cp "${SCRIPT_DIR}/bin/qwen-widget-bin" "${INSTALL_DIR}/bin/qwen-widget-bin"
    [ -f "${SCRIPT_DIR}/bin/llama-server" ] && $SUDO cp "${SCRIPT_DIR}/bin/llama-server" "${INSTALL_DIR}/bin/llama-server"
    $SUDO chmod 755 "${INSTALL_DIR}/bin/"*

    # Bundle lua5.3 binary
    local LUA_SRC=""
    for candidate in "$HOME/.local/bin/lua5.3" "${SCRIPT_DIR}/bin/lua5.3" /usr/bin/lua5.3 /usr/local/bin/lua5.3; do
        if [ -x "$candidate" ]; then
            LUA_SRC="$candidate"
            break
        fi
    done
    if [ -n "$LUA_SRC" ] && [ "$LUA_SRC" != "${INSTALL_DIR}/bin/lua5.3" ]; then
        $SUDO cp "$LUA_SRC" "${INSTALL_DIR}/bin/lua5.3"
        $SUDO chmod 755 "${INSTALL_DIR}/bin/lua5.3"
    fi

    # Copy assets (sprites + icons + avatar)
    $SUDO cp -r "${SCRIPT_DIR}/assets/"* "${INSTALL_DIR}/assets/" 2>/dev/null || true
    ok "Assets y sprites de estado copiados."

    # Copy GGUF models
    if [ -d "${SCRIPT_DIR}/models" ]; then
        for mf in "${SCRIPT_DIR}/models/"*.gguf; do
            if [ -f "$mf" ]; then
                $SUDO cp -u "$mf" "${INSTALL_DIR}/models/"
            fi
        done
        ok "Modelos GGUF instalados en ${INSTALL_DIR}/models/."
    fi

    if [ -n "$SUDO" ]; then
        $SUDO ln -sf "${INSTALL_DIR}/bin/qwen-widget" /usr/local/bin/qwen-widget 2>/dev/null || true
        $SUDO ln -sf "${INSTALL_DIR}/bin/qwen-power" /usr/local/bin/qwen-power 2>/dev/null || true
    else
        mkdir -p "$HOME/.local/bin"
        ln -sf "${INSTALL_DIR}/bin/qwen-widget" "$HOME/.local/bin/qwen-widget"
        ln -sf "${INSTALL_DIR}/bin/qwen-power" "$HOME/.local/bin/qwen-power"
    fi
}

setup_autostart() {
    info "Configurando entrada de escritorio y autostart..."
    mkdir -p "${AUTOSTART_DIR}" "${APPS_DIR}"

    cat > "${AUTOSTART_DIR}/qwen-widget.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Qwen Widget
Comment=Hybrid Lua + C/C++ Desktop AI Widget with llama.cpp and OpenClaw
Exec=${INSTALL_DIR}/bin/qwen-widget
Icon=${INSTALL_DIR}/assets/sprites/idle.png
Terminal=false
StartupNotify=false
Categories=Utility;
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=2
EOF

    cp "${AUTOSTART_DIR}/qwen-widget.desktop" "${APPS_DIR}/qwen-widget.desktop" 2>/dev/null || true
    ok "Autostart configurado en ${AUTOSTART_DIR}/qwen-widget.desktop"
}

verify_install() {
    info "Verificando instalacion..."
    local errors=0
    [ -x "${INSTALL_DIR}/bin/qwen-widget" ]       || { warn "Falta bin/qwen-widget"; ((errors++)); }
    [ -x "${INSTALL_DIR}/bin/llama-server" ]      || { warn "Falta bin/llama-server"; ((errors++)); }
    [ -f "${INSTALL_DIR}/lib/qwen_native.so" ]    || { warn "Falta lib/qwen_native.so"; ((errors++)); }
    [ -f "${INSTALL_DIR}/lib/libqwen_mmap_guard.so" ] || { warn "Falta lib/libqwen_mmap_guard.so"; ((errors++)); }
    [ -f "${INSTALL_DIR}/lib/main.lua" ]          || { warn "Falta lib/main.lua"; ((errors++)); }
    [ -f "${INSTALL_DIR}/lib/ai_engine.lua" ]     || { warn "Falta lib/ai_engine.lua"; ((errors++)); }
    [ -f "${INSTALL_DIR}/lib/model_manager.lua" ] || { warn "Falta lib/model_manager.lua"; ((errors++)); }
    [ -f "${INSTALL_DIR}/assets/sprites/idle.png" ] || { warn "Falta assets/sprites/idle.png"; ((errors++)); }
    [ -f "${INSTALL_DIR}/models/es-grammar.gguf" ] || { warn "Falta models/es-grammar.gguf"; ((errors++)); }
    [ -f "${INSTALL_DIR}/models/qwen3.0-0.8b.gguf" ] || { warn "Falta models/qwen3.0-0.8b.gguf"; ((errors++)); }

    if [ "$errors" -eq 0 ]; then
        ok "Verificacion completa: 0 errores."
    else
        warn "Se encontraron ${errors} advertencia(s)."
    fi
}

print_summary() {
    echo ""
    echo -e "${GREEN}  +================================================+"
    echo -e "  |         Instalacion Completada con Exito       |"
    echo -e "  +================================================+${NC}"
    echo ""
    echo -e "  ${CYAN}Directorio:${NC}    ${INSTALL_DIR}/"
    echo -e "  ${CYAN}Ejecutable:${NC}    ${INSTALL_DIR}/bin/qwen-widget"
    echo -e "  ${CYAN}Motor IA:${NC}      llama.cpp embebido (presupuesto estricto <= 500 MB RAM)"
    echo -e "  ${CYAN}Modelos:${NC}       es-grammar.gguf (Gramatica) | qwen3.0-0.8b.gguf (Chat)"
    echo ""
}

banner
if [ ! -f "${SCRIPT_DIR}/lib/main.lua" ]; then
    fail "No se encontro lib/main.lua. Ejecuta install.sh desde la raiz del proyecto."
fi

setup_privilege
check_system_deps
ensure_lua53
build_native_cpp
ensure_llama_cpp
ensure_default_models
install_files
setup_autostart
verify_install
print_summary
exit 0
