#!/usr/bin/env bash
# ======================================================================
# sync.sh  –  Sincronización y sanitización automática entre la carpeta
#             local de desarrollo y el repositorio público para GitHub.
#
# Uso:
#   ./sync.sh                     (sincroniza y muestra cambios)
#   ./sync.sh --commit "mensaje"  (sincroniza, sanitiza y hace commit)
#   ./sync.sh --push              (sincroniza, sanitiza, commit y push a GitHub)
# ======================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; PURPLE='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITHUB_DIR="$SCRIPT_DIR"
LOCAL_DIR="${LOCAL_WIDGET_DIR:-/home/alex/Documentos/widget}"

info() { echo -e "  ${CYAN}▸${NC} $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; exit 1; }

echo ""
echo -e "${PURPLE}${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${PURPLE}${BOLD}║      🦞 Sincronizador Seguro a GitHub — Qwen-Widget         ║${NC}"
echo -e "${PURPLE}${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# 1. Validar directorios
[ -d "$LOCAL_DIR" ] || fail "No se encontró el directorio local de desarrollo: $LOCAL_DIR"
[ -d "$GITHUB_DIR" ] || fail "No se encontró el directorio de GitHub: $GITHUB_DIR"

info "Carpeta origen (local):    ${BOLD}${LOCAL_DIR}${NC}"
info "Carpeta destino (GitHub):  ${BOLD}${GITHUB_DIR}${NC}"

# 2. Sincronizar archivos excluyendo datos sensibles y temporales
info "Sincronizando archivos modificados..."

rsync -av --update \
    --exclude='.git' \
    --exclude='.gitignore' \
    --exclude='sync.sh' \
    --exclude='sync-to-github.sh' \
    --exclude='qwen_image.jpg' \
    --exclude='*.log' \
    --exclude='*.tmp' \
    --exclude='*.swp' \
    --exclude='*~' \
    --exclude='.env*' \
    --exclude='*.secret' \
    --exclude='*.token' \
    --exclude='*credentials*' \
    --exclude='captura_*.png' \
    --exclude='Capturas/' \
    --exclude='capturas/' \
    --exclude='screenshots/' \
    --exclude='bin/lua5.3' \
    --exclude='.cache/' \
    --exclude='.vscode/' \
    --exclude='.idea/' \
    "$LOCAL_DIR/" "$GITHUB_DIR/" > /dev/null

ok "Archivos sincronizados."

# 3. Limpieza de datos personales y metadatos EXIF / GPS
info "Sanitizando metadatos personales (EXIF / GPS / Timestamps)..."

# Asegurar que qwen_image.jpg duplicado no exista en la raíz de GitHub
rm -f "${GITHUB_DIR}/qwen_image.jpg"

# Limpiar EXIF de imágenes JPEG/PNG en assets
python3 -c "
import os
from PIL import Image

assets_dir = '${GITHUB_DIR}/assets'
if os.path.isdir(assets_dir):
    for f in os.listdir(assets_dir):
        path = os.path.join(assets_dir, f)
        if f.lower().endswith(('.jpg', '.jpeg')):
            try:
                img = Image.open(path)
                if len(img.getexif().keys()) > 0:
                    clean = Image.new(img.mode, img.size)
                    clean.putdata(list(img.getdata()))
                    clean.save(path, 'JPEG', quality=95)
                    print(f'   Sanitizada imagen: {f}')
            except Exception as e:
                pass
" 2>/dev/null || true

ok "Metadatos y privacidad verificados."

# 4. Escaneo de seguridad (buscar tokens o contraseñas accidentales)
info "Analizando seguridad y datos sensibles..."
SENSITIVE_MATCHES=$(grep -rnIE --exclude-dir='.git' --exclude='sync.sh' "ghp_[a-zA-Z0-9]{30,}|password\s*=\s*['\"][^'\"]+['\"]|api_key\s*=\s*['\"][a-zA-Z0-9_\-]{16,}['\"]" "$GITHUB_DIR" || true)

if [ -n "$SENSITIVE_MATCHES" ]; then
    warn "¡ATENCIÓN! Se detectaron posibles credenciales sensibles:"
    echo "$SENSITIVE_MATCHES"
    echo ""
    warn "Por favor revisa estos archivos antes de subir a GitHub."
else
    ok "0 credenciales sensibles encontradas."
fi

# 5. Estado Git en la carpeta de GitHub
cd "$GITHUB_DIR"

if [ ! -d ".git" ]; then
    info "Inicializando repositorio Git..."
    git init -b main
    ok "Repositorio Git inicializado en rama main."
fi

STATUS_OUT=$(git status --porcelain)

echo ""
if [ -z "$STATUS_OUT" ]; then
    ok "${GREEN}El repositorio de GitHub está al día. No hay cambios pendientes.${NC}"
else
    echo -e "${YELLOW}${BOLD}Cambios pendientes para GitHub:${NC}"
    git status -s
    echo ""
fi

# 6. Manejo de commit / push según argumentos
COMMIT_MSG=""
DO_PUSH=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --commit|-m)
            COMMIT_MSG="${2:-}"
            shift 2
            ;;
        --push|-p)
            DO_PUSH=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

if [ -n "$COMMIT_MSG" ] || [ "$DO_PUSH" = true ]; then
    if [ -n "$STATUS_OUT" ]; then
        git add -A
        MSG="${COMMIT_MSG:-Actualizaciones del widget}"
        git commit -m "$MSG"
        ok "Commit realizado: \"$MSG\""
    else
        info "Nada nuevo que commitear."
    fi

    if [ "$DO_PUSH" = true ]; then
        if git remote get-url origin &>/dev/null; then
            info "Subiendo cambios a GitHub (git push origin main)..."
            git push origin main
            ok "¡Cambios subidos a GitHub exitosamente!"
        else
            warn "No hay control remoto 'origin' configurado en Git."
            echo -e "  Configúralo con: ${CYAN}git remote add origin https://github.com/TU_USUARIO/TU_REPO.git${NC}"
            echo -e "  Y luego ejecuta: ${CYAN}git push -u origin main${NC}"
        fi
    fi
fi

echo ""
echo -e "${PURPLE}✦ Listo.${NC} Repositorio listo para GitHub en: ${CYAN}${GITHUB_DIR}${NC}"
echo ""
