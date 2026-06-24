#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  lib/colors.sh — Sistema de temas visuales de Ghost-Kali
# ──────────────────────────────────────────────────────────────────────────────
#  Define 4 temas (ghost, midnight, forest, matrix) con paletas ANSI truecolor,
#  detección automática de capacidades del terminal (truecolor / 256 / sin color)
#  y soporte para --no-color y la convención NO_COLOR (https://no-color.org).
#
#  ⚖️  DISCLAIMER: Ghost-Kali es una herramienta 100% defensiva, solo para fines
#      educativos, auditorías autorizadas e investigación responsable. Esta
#      librería no realiza acciones de red; únicamente gestiona la presentación.
#
#  Esta es una LIBRERÍA: debe cargarse con `source`, no ejecutarse directamente.
#  Uso:   source lib/colors.sh && apply_theme ghost
# ──────────────────────────────────────────────────────────────────────────────

# ── Guarda de ejecución directa ───────────────────────────────────────────────
# POR QUÉ: si alguien ejecuta este archivo en lugar de cargarlo, no haría nada
# útil. Avisamos con un mensaje claro en lugar de fallar en silencio.
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    printf 'Este archivo es una librería y debe cargarse con «source», no ejecutarse.\n' >&2
    printf 'Uso: source lib/colors.sh && apply_theme ghost\n' >&2
    exit 1
fi

# ── Guarda de idempotencia ────────────────────────────────────────────────────
# POR QUÉ: las paletas se declaran como readonly. Cargar el archivo dos veces
# intentaría redeclararlas y provocaría un error. Esta guarda lo evita, de modo
# que `source` se puede invocar N veces sin romper nada.
[[ -n ${_GHOST_COLORS_LOADED:-} ]] && return 0
_GHOST_COLORS_LOADED=1

# ──────────────────────────────────────────────────────────────────────────────
#  PALETAS DE TEMAS (readonly, UPPER_CASE)
#  Cada clave guarda el color en HEX sin almohadilla. Los códigos de escape se
#  generan en tiempo de ejecución según el modo de color detectado.
# ──────────────────────────────────────────────────────────────────────────────

declare -grA THEME_GHOST=(
    [primary]=BD93F9   # morado
    [secondary]=8BE9FD # cyan
    [accent]=F8F8F2    # blanco
    [warning]=F1FA8C   # amarillo
    [error]=FF5555     # rojo
    [success]=50FA7B   # verde
    [muted]=6272A4     # gris
    [bg]=282A36        # fondo oscuro
    [fg]=F8F8F2        # texto
)

declare -grA THEME_MIDNIGHT=(
    [primary]=5B8DEE   # azul
    [secondary]=FFB86C # dorado
    [accent]=E0E0E0    # blanco
    [warning]=FF9E64   # naranja
    [error]=FF3333     # rojo
    [success]=3ECF8E   # verde
    [muted]=6B7B8D     # gris
    [bg]=0D1117        # negro
    [fg]=C9D1D9        # gris claro
)

declare -grA THEME_FOREST=(
    [primary]=00FF41   # verde
    [secondary]=FFB000 # ámbar
    [accent]=39FF14    # verde claro
    [warning]=FFD700   # amarillo
    [error]=FF4444     # rojo
    [success]=00CC00   # verde
    [muted]=003B00     # verde oscuro
    [bg]=0A0A0A        # negro
    [fg]=00FF41        # verde
)

declare -grA THEME_MATRIX=(
    [primary]=00FF00   # verde
    [secondary]=008F11 # verde oscuro
    [accent]=00FF41    # verde
    [warning]=FFFF00   # amarillo
    [error]=FF0000     # rojo
    [success]=00FF00   # verde
    [muted]=0A3D0A     # verde apagado
    [bg]=000000        # negro
    [fg]=00FF00        # verde
)

# Tema y modo de color activos. GHOST_COLOR_MODE puede ser: truecolor, 256, none.
GHOST_THEME=${GHOST_THEME:-ghost}
GHOST_COLOR_MODE=${GHOST_COLOR_MODE:-}

# ──────────────────────────────────────────────────────────────────────────────
#  HELPERS INTERNOS (prefijo _)
# ──────────────────────────────────────────────────────────────────────────────

# _hex_to_rgb HEX → imprime "R G B" en decimal (0-255).
# POR QUÉ: los escapes truecolor y el cálculo de 256 colores necesitan RGB.
_hex_to_rgb() {
    local hex=${1#\#}
    printf '%d %d %d' "0x${hex:0:2}" "0x${hex:2:2}" "0x${hex:4:2}"
}

# _to_cube VALOR → índice 0-5 del cubo de color xterm para un canal.
_to_cube() {
    local v=$1
    if [[ $v -lt 48 ]]; then
        printf '0'
    elif [[ $v -lt 115 ]]; then
        printf '1'
    else
        printf '%d' $(((v - 35) / 40))
    fi
}

# _rgb_to_256 R G B → índice de color en la paleta de 256 colores.
# POR QUÉ: terminales sin truecolor necesitan el mejor equivalente en 256 colores.
_rgb_to_256() {
    local r=$1 g=$2 b=$3
    # Rampa de grises: si los tres canales coinciden, usamos la escala 232-255.
    if [[ $r -eq $g && $g -eq $b ]]; then
        if [[ $r -lt 8 ]]; then
            printf '16'
            return
        fi
        if [[ $r -gt 248 ]]; then
            printf '231'
            return
        fi
        printf '%d' $(((r - 8) * 24 / 247 + 232))
        return
    fi
    local ri gi bi
    ri=$(_to_cube "$r")
    gi=$(_to_cube "$g")
    bi=$(_to_cube "$b")
    printf '%d' $((16 + 36 * ri + 6 * gi + bi))
}

# _color_code HEX LAYER → secuencia de escape ANSI (38=texto, 48=fondo).
# Respeta el modo de color activo; en modo «none» devuelve cadena vacía.
_color_code() {
    local hex=$1 layer=$2
    [[ ${GHOST_COLOR_MODE:-none} == none ]] && return 0
    local r g b
    read -r r g b <<<"$(_hex_to_rgb "$hex")"
    if [[ $GHOST_COLOR_MODE == truecolor ]]; then
        printf '\033[%s;2;%s;%s;%sm' "$layer" "$r" "$g" "$b"
    else
        printf '\033[%s;5;%sm' "$layer" "$(_rgb_to_256 "$r" "$g" "$b")"
    fi
}

# _detect_color_mode → imprime el modo de color soportado por el entorno actual.
# POR QUÉ: pintar truecolor en un terminal que no lo soporta produce basura; y
# escribir colores hacia un pipe o archivo ensucia los logs.
_detect_color_mode() {
    # Desactivación explícita (flag interno o convención NO_COLOR).
    if [[ ${GHOST_NO_COLOR:-0} == 1 || -n ${NO_COLOR:-} ]]; then
        printf 'none'
        return
    fi
    # Sin terminal interactivo (redirección a archivo/pipe) → sin color.
    if [[ ! -t 1 ]]; then
        printf 'none'
        return
    fi
    # Truecolor anunciado por el terminal.
    if [[ ${COLORTERM:-} == *truecolor* || ${COLORTERM:-} == *24bit* ]]; then
        printf 'truecolor'
        return
    fi
    # 256 colores según tput.
    local ncolors
    ncolors=$(tput colors 2>/dev/null || printf '0')
    if [[ $ncolors -ge 256 ]]; then
        printf '256'
        return
    fi
    printf 'none'
}

# _palette_get TEMA CLAVE → imprime el HEX de esa clave en el tema indicado,
# sin alterar el tema activo (se usa para las vistas previas).
_palette_get() {
    local -n _p="THEME_${1^^}"
    printf '%s' "${_p[$2]}"
}

# ──────────────────────────────────────────────────────────────────────────────
#  API PÚBLICA
# ──────────────────────────────────────────────────────────────────────────────

# theme_exists NOMBRE → 0 si el tema existe, 1 si no.
theme_exists() {
    case ${1,,} in
        ghost | midnight | forest | matrix) return 0 ;;
        *) return 1 ;;
    esac
}

# set_color_mode MODO → fuerza el modo de color y regenera la paleta activa.
# MODO: auto | truecolor | 256 | none|off
set_color_mode() {
    local mode=${1,,}
    case $mode in
        auto) GHOST_COLOR_MODE=$(_detect_color_mode) ;;
        truecolor) GHOST_COLOR_MODE=truecolor ;;
        256) GHOST_COLOR_MODE=256 ;;
        none | off) GHOST_COLOR_MODE=none ;;
        *)
            printf '[colors.sh] Modo de color inválido: «%s».\n' "$mode" >&2
            printf 'Valores válidos: auto, truecolor, 256, none.\n' >&2
            return 1
            ;;
    esac
    # Regeneramos los códigos con el nuevo modo manteniendo el tema actual.
    apply_theme "$GHOST_THEME"
}

# apply_theme [NOMBRE] → activa un tema y genera las variables C_* globales.
# Si no se pasa nombre, usa GHOST_THEME (o «ghost» por defecto).
apply_theme() {
    local requested=${1:-${GHOST_THEME:-ghost}}
    requested=${requested,,}

    if ! theme_exists "$requested"; then
        printf '%s[colors.sh] Error: tema desconocido «%s».%s\n' \
            "${C_ERROR:-}" "$requested" "${C_RESET:-}" >&2
        printf 'Temas válidos: ghost, midnight, forest, matrix.\n' >&2
        printf 'Sugerencia: ejecuta «list_themes» o usa «--theme ghost».\n' >&2
        return 1
    fi

    # Si aún no se detectó el modo de color, lo hacemos una sola vez. Usamos
    # := para NO sobrescribir un modo forzado previamente con set_color_mode.
    : "${GHOST_COLOR_MODE:=$(_detect_color_mode)}"

    # nameref a la paleta del tema solicitado (solo lectura).
    local -n _pal="THEME_${requested^^}"

    GHOST_THEME=$requested

    # Variables semánticas usadas por el resto de librerías. Declaramos -g para
    # garantizar alcance global aunque apply_theme se llame desde otra función.
    # POR QUÉ no son readonly: el dashboard permite cambiar de tema en caliente,
    # lo que exige reasignarlas en tiempo de ejecución.
    declare -g C_PRIMARY C_SECONDARY C_ACCENT C_WARNING C_ERROR C_SUCCESS C_MUTED
    declare -g C_BG FG_BASE C_RESET C_BOLD C_DIM C_ITALIC C_UNDERLINE

    C_PRIMARY=$(_color_code "${_pal[primary]}" 38)
    C_SECONDARY=$(_color_code "${_pal[secondary]}" 38)
    C_ACCENT=$(_color_code "${_pal[accent]}" 38)
    C_WARNING=$(_color_code "${_pal[warning]}" 38)
    C_ERROR=$(_color_code "${_pal[error]}" 38)
    C_SUCCESS=$(_color_code "${_pal[success]}" 38)
    C_MUTED=$(_color_code "${_pal[muted]}" 38)
    C_BG=$(_color_code "${_pal[bg]}" 48)
    FG_BASE=$(_color_code "${_pal[fg]}" 38)

    if [[ $GHOST_COLOR_MODE == none ]]; then
        C_RESET='' C_BOLD='' C_DIM='' C_ITALIC='' C_UNDERLINE=''
    else
        C_RESET=$'\033[0m'
        C_BOLD=$'\033[1m'
        C_DIM=$'\033[2m'
        C_ITALIC=$'\033[3m'
        C_UNDERLINE=$'\033[4m'
    fi

    return 0
}

# list_themes → muestra los temas disponibles con una vista previa de su paleta.
list_themes() {
    printf '\n%s%sTemas disponibles%s\n' "${C_BOLD}" "${C_PRIMARY}" "$C_RESET"
    printf '%s──────────────────────────────────────────────%s\n\n' \
        "$C_MUTED" "$C_RESET"

    local name key marker code
    for name in ghost midnight forest matrix; do
        marker='   '
        [[ $name == "${GHOST_THEME:-}" ]] && marker=" ${C_SUCCESS}▸${C_RESET} "
        printf '%s%s%-10s%s' "$marker" "$C_ACCENT" "$name" "$C_RESET"
        # Una muestra de fondo por cada color semántico del tema.
        for key in primary secondary accent success warning error; do
            code=$(_color_code "$(_palette_get "$name" "$key")" 48)
            printf '%s   %s' "$code" "$C_RESET"
        done
        printf '\n'
    done

    printf '\n%sActiva uno con:%s --theme <nombre>\n\n' "$C_MUTED" "$C_RESET"
}

# ghost_strip_ansi [TEXTO] → elimina secuencias de escape ANSI.
# Si no se pasa TEXTO, lee de stdin. Útil para escribir logs en texto plano.
ghost_strip_ansi() {
    if [[ $# -gt 0 ]]; then
        printf '%s' "$1" | sed -E 's/\x1b\[[0-9;]*m//g'
    else
        sed -E 's/\x1b\[[0-9;]*m//g'
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
#  INICIALIZACIÓN
#  Al cargar la librería dejamos un tema aplicado y listo para usar, de modo que
#  el resto del código pueda referenciar C_PRIMARY, C_ERROR, etc. de inmediato.
# ──────────────────────────────────────────────────────────────────────────────
GHOST_COLOR_MODE=$(_detect_color_mode)
apply_theme "${GHOST_THEME:-ghost}" || true
