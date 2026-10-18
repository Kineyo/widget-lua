#!/usr/bin/env bash
# ======================================================================
#  run.sh  –  Instala, compila y ejecuta Qwen-Widget v2.0
#
#  Uso:  ./run.sh          (instala + ejecuta)
#        ./run.sh --install (solo instalar)
#        ./run.sh --run     (solo ejecutar)
# ======================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${QWEN_INSTALL_DIR:-/opt/qwen-widget}"
export PATH="$HOME/.local/bin:$PATH"

run_widget() {
    local TARGET_DIR="$SCRIPT_DIR"
    if [ ! -f "${TARGET_DIR}/lib/main.lua" ] && [ -d "$INSTALL_DIR" ]; then
        TARGET_DIR="$INSTALL_DIR"
    fi

    pkill -f "lua.*main.lua" 2>/dev/null || true
    sleep 0.25

    export QWEN_WIDGET_DIR="$TARGET_DIR"
    export QWEN_WIDGET_ROOT="$TARGET_DIR"
    export GDK_BACKEND=x11
    export LD_LIBRARY_PATH="${TARGET_DIR}/lib/native:${TARGET_DIR}/lib:$HOME/.local/lib:${LD_LIBRARY_PATH:-}"

    nohup "${TARGET_DIR}/bin/qwen-widget" >/tmp/qwen-widget.log 2>&1 &
    disown
    echo "  [OK] Qwen-Widget v2.0 iniciado en segundo plano (PID: $!)"
}

case "${1:-}" in
    --run)
        run_widget
        ;;
    --install)
        "${SCRIPT_DIR}/install.sh"
        ;;
    *)
        "${SCRIPT_DIR}/install.sh"
        run_widget
        ;;
esac
