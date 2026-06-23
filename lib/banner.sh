#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  lib/banner.sh — Motor de banners ASCII de Ghost-Kali
# ──────────────────────────────────────────────────────────────────────────────
#  Imprime arte ASCII (y NADA más) en 4 modos: full · minimal · classic · retro,
#  con un efecto opcional de fade-in (línea a línea) solo cuando la salida es TTY.
#
#  ⚖️  DISCLAIMER ÉTICO/LEGAL: este archivo es 100% INOFENSIVO: solo imprime
#      texto. Ghost-Kali es una herramienta defensiva de privacidad de uso
#      educativo y ético; protege la privacidad legítima, no facilita abusos.
#
#  🔐 INVARIANTES:
#      · Solo imprime texto; NUNCA modifica archivos ni servicios.
#      · NUNCA usa rm -rf, iptables -F, killall, pkill, systemctl stop.
#      · NUNCA imprime credenciales ni datos sensibles.
#
#  LIBRERÍA: cargar con `source lib/banner.sh`, NO ejecutar. Depende de colors.sh.
# ──────────────────────────────────────────────────────────────────────────────

# ── Guarda de ejecución directa ───────────────────────────────────────────────
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    printf 'Este archivo es una librería y debe cargarse con «source», no ejecutarse.\n' >&2
    printf 'Uso: source lib/banner.sh\n' >&2
    exit 1
fi

# ── Guarda de idempotencia ────────────────────────────────────────────────────
[[ -n ${_GHOST_BANNER_LOADED:-} ]] && return 0
_GHOST_BANNER_LOADED=1

_ghost_lib_dir=${BASH_SOURCE[0]%/*}

# ── Constantes configurables ──────────────────────────────────────────────────
GHOST_VERSION=${GHOST_VERSION:-v5.0-elite}
GHOST_BANNER_MODE=${GHOST_BANNER_MODE:-full}
GHOST_BANNER_NO_FADE=${GHOST_BANNER_NO_FADE:-0}
GHOST_BANNER_NO_COLOR=${GHOST_BANNER_NO_COLOR:-0}

# Color activo de impresión (lo fijan los renderizadores; vacío = sin color).
_BANNER_COLOR=""
_BANNER_RESET=""

# ──────────────────────────────────────────────────────────────────────────────
#  HELPERS PRIVADOS
# ──────────────────────────────────────────────────────────────────────────────

# _banner_load_colors → carga colors.sh si hace falta; si no, deja colores vacíos.
# POR QUÉ defaults vacíos: el banner debe imprimirse aunque colors.sh no exista,
# simplemente sin color (degradación elegante, nunca un error).
_banner_load_colors() {
    if [[ -z ${_GHOST_COLORS_LOADED:-} && -f ${_ghost_lib_dir}/colors.sh ]]; then
        # shellcheck source=lib/colors.sh
        source "${_ghost_lib_dir}/colors.sh"
    fi
    : "${C_PRIMARY:=}" "${C_SECONDARY:=}" "${C_ACCENT:=}" "${C_SUCCESS:=}"
    : "${C_WARNING:=}" "${C_ERROR:=}" "${C_MUTED:=}" "${C_RESET:=}" "${C_BOLD:=}"
}

# _banner_cols → ancho del terminal (por defecto 80 si no se puede determinar).
_banner_cols() {
    local c
    c=$(tput cols 2>/dev/null || printf '80')
    [[ $c =~ ^[0-9]+$ ]] || c=80
    printf '%d' "$c"
}

# _banner_strwidth TEXTO → nº de caracteres (independiente del locale).
# POR QUÉ: con locale C, ${#cadena} cuenta BYTES; los glifos multibyte de los
# banners descuadrarían el centrado. Contamos bytes que no son de continuación.
_banner_strwidth() {
    local LC_ALL=C s=$1 stripped
    stripped=${s//[$'\x80'-$'\xbf']/}
    printf '%d' "${#stripped}"
}

# _banner_safe_sleep MS → duerme MS milisegundos de forma portable (best effort).
# POR QUÉ tolerante a fallos: si `sleep` no admite fracciones, no pasa nada;
# simplemente no hay animación (el banner se sigue imprimiendo).
_banner_safe_sleep() {
    local ms=${1:-0}
    [[ $ms =~ ^[0-9]+$ ]] || return 0
    [[ $ms -eq 0 ]] && return 0
    local s=$((ms / 1000)) rem=$((ms % 1000))
    sleep "$(printf '%d.%03d' "$s" "$rem")" 2>/dev/null || true
}

# _banner_center TEXTO [ANCHO] → imprime el texto centrado (mide sin ANSI).
_banner_center() {
    local text=$1 width=${2:-} plain w pad
    [[ -z $width ]] && width=$(_banner_cols)
    if declare -F ghost_strip_ansi >/dev/null 2>&1; then
        plain=$(ghost_strip_ansi "$text")
    else
        plain=$text
    fi
    w=$(_banner_strwidth "$plain")
    pad=$(((width - w) / 2))
    [[ $pad -lt 0 ]] && pad=0
    printf '%*s%s\n' "$pad" "" "$text"
}

# _banner_print_lines TEXTO [--no-color] → imprime cada línea con el color activo.
_banner_print_lines() {
    local text=$1 color=${_BANNER_COLOR} reset=${_BANNER_RESET} a
    shift || true
    for a in "$@"; do [[ $a == --no-color ]] && {
        color=""
        reset=""
    }; done
    local line
    while IFS= read -r line; do
        printf '%s%s%s\n' "$color" "$line" "$reset"
    done <<<"$text"
}

# _banner_fade_lines TEXTO [DELAY_MS] → imprime línea a línea con un pequeño delay.
_banner_fade_lines() {
    local text=$1 delay=${2:-22} color=${_BANNER_COLOR} reset=${_BANNER_RESET} line
    while IFS= read -r line; do
        printf '%s%s%s\n' "$color" "$line" "$reset"
        _banner_safe_sleep "$delay"
    done <<<"$text"
}

# _banner_render TEXTO COLOR NOFADE NOCOLOR → decide color/fade e imprime.
# El fade-in solo se aplica si: se pidió, no está desactivado globalmente y la
# salida es una terminal (no tiene sentido animar hacia un pipe o un archivo).
_banner_render() {
    local text=$1 colorval=$2 nofade=$3 nocolor=$4
    local color=$colorval reset=${C_RESET}
    if [[ $nocolor == 1 || ${GHOST_BANNER_NO_COLOR:-0} == 1 ]]; then
        color=""
        reset=""
    fi
    _BANNER_COLOR=$color
    _BANNER_RESET=$reset

    local fade=1
    if [[ $nofade == 1 || ${GHOST_BANNER_NO_FADE:-0} == 1 || ! -t 1 ]]; then
        fade=0
    fi
    if [[ $fade == 1 ]]; then
        _banner_fade_lines "$text"
    else
        _banner_print_lines "$text"
    fi

    _BANNER_COLOR=""
    _BANNER_RESET=""
}

# ──────────────────────────────────────────────────────────────────────────────
#  API PÚBLICA
# ──────────────────────────────────────────────────────────────────────────────

# banner_version_line → línea(s) compactas con versión y disclaimer ético.
banner_version_line() {
    _banner_load_colors
    local nocolor=${GHOST_BANNER_NO_COLOR:-0} a
    for a in "$@"; do [[ $a == --no-color ]] && nocolor=1; done
    local c1=${C_ACCENT} c2=${C_MUTED} r=${C_RESET}
    [[ $nocolor == 1 ]] && {
        c1=""
        c2=""
        r=""
    }
    printf '%s   Ghost-Kali %s · Toolkit defensivo de anonimato%s\n' "$c1" "$GHOST_VERSION" "$r"
    printf '%s   Uso educativo y ético: protege la privacidad legítima; no facilita abusos.%s\n' "$c2" "$r"
}

# banner_full [--no-fade] [--no-color] → banner grande con arte ASCII completo.
banner_full() {
    _banner_load_colors
    local nofade=${GHOST_BANNER_NO_FADE:-0} nocolor=${GHOST_BANNER_NO_COLOR:-0} a
    for a in "$@"; do
        case $a in
            --no-fade) nofade=1 ;;
            --no-color) nocolor=1 ;;
        esac
    done

    # Adaptación a terminales estrechas: si no caben ~74 columnas, usamos minimal.
    local cols
    cols=$(_banner_cols)
    if [[ $cols -lt 74 ]]; then
        if [[ $nocolor == 1 ]]; then banner_minimal --no-color; else banner_minimal; fi
        return 0
    fi

    local art
    art=$(
        cat <<'EOF'
 ██████╗ ██╗  ██╗ ██████╗ ███████╗████████╗   ██╗  ██╗ █████╗ ██╗     ██╗
██╔════╝ ██║  ██║██╔═══██╗██╔════╝╚══██╔══╝   ██║ ██╔╝██╔══██╗██║     ██║
██║  ███╗███████║██║   ██║███████╗   ██║      █████╔╝ ███████║██║     ██║
██║   ██║██╔══██║██║   ██║╚════██║   ██║      ██╔═██╗ ██╔══██║██║     ██║
╚██████╔╝██║  ██║╚██████╔╝███████║   ██║      ██║  ██╗██║  ██║███████╗██║
 ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝      ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝
EOF
    )
    printf '\n'
    _banner_render "$art" "${C_PRIMARY}" "$nofade" "$nocolor"
    local tag="· TOR + MULLVAD + PROXYCHAINS · anonimato multicapa ·"
    if [[ $nocolor == 1 ]]; then
        _banner_center "$tag" "$cols"
    else
        _banner_center "${C_SECONDARY}${tag}${C_RESET}" "$cols"
    fi
    printf '\n'
    local -a _vflag=()
    [[ $nocolor == 1 ]] && _vflag+=(--no-color)
    banner_version_line "${_vflag[@]}"
    printf '\n'
}

# banner_minimal [--no-color] → banner reducido (sin animación).
banner_minimal() {
    _banner_load_colors
    local nocolor=${GHOST_BANNER_NO_COLOR:-0} a
    for a in "$@"; do [[ $a == --no-color ]] && nocolor=1; done

    local art
    art=$(
        cat <<'EOF'
  ╔═╗╦ ╦╔═╗╔═╗╔╦╗  ╦╔═╔═╗╦  ╦
  ║ ╦╠═╣║ ║╚═╗ ║───╠╩╗╠═╣║  ║
  ╚═╝╩ ╩╚═╝╚═╝ ╩   ╩ ╩╩ ╩╩═╝╩
EOF
    )
    printf '\n'
    _banner_render "$art" "${C_SECONDARY}" 1 "$nocolor" # minimal nunca hace fade
    local -a _vflag=()
    [[ $nocolor == 1 ]] && _vflag+=(--no-color)
    banner_version_line "${_vflag[@]}"
    printf '\n'
}

# banner_classic [--no-color] → banner estilo retro/hacker (sin animación).
banner_classic() {
    _banner_load_colors
    local nocolor=${GHOST_BANNER_NO_COLOR:-0} a
    for a in "$@"; do [[ $a == --no-color ]] && nocolor=1; done

    local art
    art=$(
        cat <<'EOF'
   _____ _               _        _  __     _ _
  / ____| |             | |      | |/ /    | (_)
 | |  __| |__   ___  ___| |_     | ' / __ _| |_
 | | |_ | '_ \ / _ \/ __| __|    |  < / _` | | |
 | |__| | | | | (_) \__ \ |_     | . \ (_| | | |
  \_____|_| |_|\___/|___/\__|    |_|\_\__,_|_|_|
EOF
    )
    printf '\n'
    _banner_render "$art" "${C_SUCCESS}" 1 "$nocolor" # verde fósforo, vibe hacker
    local -a _vflag=()
    [[ $nocolor == 1 ]] && _vflag+=(--no-color)
    banner_version_line "${_vflag[@]}"
    printf '\n'
}

# banner_retro [--no-color] → banner estilo terminal antigua (sin animación).
banner_retro() {
    _banner_load_colors
    local nocolor=${GHOST_BANNER_NO_COLOR:-0} a
    for a in "$@"; do [[ $a == --no-color ]] && nocolor=1; done

    local art
    art=$(
        cat <<'EOF'
 ░▒▓███████████████████████████████████████████▓▒░
 ░▒▓█   G H O S T - K A L I   ·   anonimato op.  █▓▒░
 ░▒▓███████████████████████████████████████████▓▒░
EOF
    )
    printf '\n'
    _banner_render "$art" "${C_WARNING}" 1 "$nocolor" # ámbar, estética CRT antigua
    local -a _vflag=()
    [[ $nocolor == 1 ]] && _vflag+=(--no-color)
    banner_version_line "${_vflag[@]}"
    printf '\n'
}

# banner_fade_in TEXTO [--no-color] → imprime el texto línea por línea con delay.
banner_fade_in() {
    _banner_load_colors
    local text=${1:-} nocolor=${GHOST_BANNER_NO_COLOR:-0} a
    shift || true
    for a in "$@"; do [[ $a == --no-color ]] && nocolor=1; done

    local color=${C_PRIMARY} reset=${C_RESET}
    [[ $nocolor == 1 ]] && {
        color=""
        reset=""
    }
    _BANNER_COLOR=$color
    _BANNER_RESET=$reset
    # Solo animamos si la salida es una terminal y el fade no está desactivado.
    if [[ ${GHOST_BANNER_NO_FADE:-0} == 1 || ! -t 1 ]]; then
        _banner_print_lines "$text"
    else
        _banner_fade_lines "$text"
    fi
    _BANNER_COLOR=""
    _BANNER_RESET=""
}

# banner_random [--no-fade] [--no-color] → elige un modo de banner al azar.
banner_random() {
    local -a modes=(full minimal classic retro)
    local idx=$((RANDOM % ${#modes[@]}))
    banner_show "${modes[$idx]}" "$@"
}

# banner_show [modo] [--no-fade] [--no-color] → muestra el banner indicado.
banner_show() {
    _banner_load_colors
    local mode=${GHOST_BANNER_MODE:-full} nofade=0 nocolor=0 a
    for a in "$@"; do
        case $a in
            --no-fade) nofade=1 ;;
            --no-color) nocolor=1 ;;
            full | minimal | classic | retro | random) mode=$a ;;
        esac
    done

    local -a flags=()
    [[ $nofade == 1 ]] && flags+=(--no-fade)
    [[ $nocolor == 1 ]] && flags+=(--no-color)

    case $mode in
        full) banner_full "${flags[@]}" ;;
        minimal) banner_minimal "${flags[@]}" ;;
        classic) banner_classic "${flags[@]}" ;;
        retro) banner_retro "${flags[@]}" ;;
        random) banner_random "${flags[@]}" ;;
        *) banner_full "${flags[@]}" ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────────
#  API EXPUESTA (recordatorio)
#  Esto es una librería: `source lib/banner.sh` expone las funciones banner_*.
#  NO se ejecuta nada automáticamente ni hay main(): el orquestador (joseph-trio)
#  decide cuándo mostrar el banner. Solo imprime arte ASCII; el fade-in se puede
#  desactivar con --no-fade o GHOST_BANNER_NO_FADE=1 y los colores con --no-color.
# ──────────────────────────────────────────────────────────────────────────────
