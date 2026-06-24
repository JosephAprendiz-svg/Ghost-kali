#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  lib/logger.sh — Logging profesional de Ghost-Kali
# ──────────────────────────────────────────────────────────────────────────────
#  Niveles: TRACE · DEBUG · INFO · OK · WARN · ERROR · FATAL
#  Consola: [14:32:05] [WARN ] mensaje   (coloreado con el tema de colors.sh)
#  Archivo: [2026-06-20 14:32:05.123] [WARN ] [joseph-trio] mensaje  (texto plano)
#  Extras:  rotación de archivos (5 MB / 5 copias / gzip), modo JSON lines,
#           --quiet y --verbose, tablas y secciones.
#
#  ⚖️  DISCLAIMER: Ghost-Kali es una herramienta 100% defensiva, solo para fines
#      educativos, auditorías autorizadas e investigación responsable.
#
#  LIBRERÍA: cargar con `source`, no ejecutar. Depende de lib/colors.sh.
# ──────────────────────────────────────────────────────────────────────────────

# ── Guarda de ejecución directa ───────────────────────────────────────────────
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    printf 'Este archivo es una librería y debe cargarse con «source», no ejecutarse.\n' >&2
    printf 'Uso: source lib/logger.sh\n' >&2
    exit 1
fi

# ── Guarda de idempotencia ────────────────────────────────────────────────────
[[ -n ${_GHOST_LOGGER_LOADED:-} ]] && return 0
_GHOST_LOGGER_LOADED=1

# ── Dependencia: colors.sh ────────────────────────────────────────────────────
# POR QUÉ: el logger pinta con las variables del tema. Si colors.sh no está
# cargado intentamos cargarlo desde el mismo directorio. Si no se encuentra,
# definimos variables de color vacías para degradar a texto sin color.
if [[ -z ${_GHOST_COLORS_LOADED:-} ]]; then
    _ghost_lib_dir=${BASH_SOURCE[0]%/*}
    if [[ -f ${_ghost_lib_dir}/colors.sh ]]; then
        # shellcheck source=lib/colors.sh
        source "${_ghost_lib_dir}/colors.sh"
    fi
fi
: "${C_PRIMARY:=}" "${C_SECONDARY:=}" "${C_ACCENT:=}" "${C_WARNING:=}"
: "${C_ERROR:=}" "${C_SUCCESS:=}" "${C_MUTED:=}" "${C_RESET:=}" "${C_BOLD:=}"

# ── Niveles (readonly, valores numéricos para el filtrado por umbral) ──────────
readonly _LVL_TRACE=10
readonly _LVL_DEBUG=20
readonly _LVL_INFO=30
readonly _LVL_OK=35
readonly _LVL_WARN=40
readonly _LVL_ERROR=50
readonly _LVL_FATAL=60

# ── Estado configurable ───────────────────────────────────────────────────────
GHOST_LOG_LEVEL=${GHOST_LOG_LEVEL:-$_LVL_INFO}                   # umbral mínimo a emitir
GHOST_LOG_APP=${GHOST_LOG_APP:-joseph-trio}                      # etiqueta de componente en archivo
GHOST_LOG_FILE=${GHOST_LOG_FILE:-}                               # ruta del archivo de log
GHOST_LOG_ENABLED=${GHOST_LOG_ENABLED:-0}                        # 1 = escribir a archivo
GHOST_LOG_JSON=${GHOST_LOG_JSON:-0}                              # 1 = formato JSON lines
GHOST_LOG_MAX_BYTES=${GHOST_LOG_MAX_BYTES:-$((5 * 1024 * 1024))} # 5 MB
GHOST_LOG_KEEP=${GHOST_LOG_KEEP:-5}                              # nº de copias rotadas

# ──────────────────────────────────────────────────────────────────────────────
#  HELPERS INTERNOS
# ──────────────────────────────────────────────────────────────────────────────

# _repeat CHAR N → imprime CHAR repetido N veces (sin word-splitting ni seq).
_repeat() {
    local ch=$1 n=$2 out='' i
    for ((i = 0; i < n; i++)); do out+=$ch; done
    printf '%s' "$out"
}

# _json_escape TEXTO → escapa lo mínimo necesario para un string JSON válido.
_json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/\\r}
    s=${s//$'\n'/\\n}
    printf '%s' "$s"
}

# _json_line NIVEL MENSAJE → una entrada JSON de una sola línea.
_json_line() {
    local level=$1 msg=$2 ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
    printf '{"ts":"%s","level":"%s","app":"%s","msg":"%s"}' \
        "$ts" "$level" "$GHOST_LOG_APP" "$(_json_escape "$msg")"
}

# _strip_ansi TEXTO → quita escapes ANSI (usa colors.sh si está, si no, sed).
_strip_ansi() {
    if declare -F ghost_strip_ansi >/dev/null 2>&1; then
        ghost_strip_ansi "$1"
    else
        printf '%s' "$1" | sed -E 's/\x1b\[[0-9;]*m//g'
    fi
}

# _log_should NUM → 0 si el nivel NUM alcanza el umbral configurado.
_log_should() {
    [[ $1 -ge ${GHOST_LOG_LEVEL:-$_LVL_INFO} ]]
}

# log_rotate [ARCHIVO] → rota el log si supera el tamaño máximo.
# Esquema: archivo → archivo.1.gz → archivo.2.gz ... hasta GHOST_LOG_KEEP copias.
log_rotate() {
    local f=${1:-$GHOST_LOG_FILE}
    [[ -n $f && -f $f ]] || return 0

    local size
    size=$(stat -c%s "$f" 2>/dev/null || wc -c <"$f" 2>/dev/null || printf '0')
    [[ $size -lt ${GHOST_LOG_MAX_BYTES} ]] && return 0

    # Desplaza las copias existentes hacia un índice mayor (de la más vieja a la
    # más nueva, para no sobrescribir).
    local i
    for ((i = GHOST_LOG_KEEP - 1; i >= 1; i--)); do
        [[ -f ${f}.${i}.gz ]] && mv -f "${f}.${i}.gz" "${f}.$((i + 1)).gz"
    done

    mv -f "$f" "${f}.1"
    gzip -f "${f}.1" 2>/dev/null || rm -f "${f}.1"
    # Elimina lo que exceda el número de copias a conservar.
    [[ -f ${f}.$((GHOST_LOG_KEEP + 1)).gz ]] && rm -f "${f}.$((GHOST_LOG_KEEP + 1)).gz"
    : >"$f"
    return 0
}

# _log_to_file NIVEL MENSAJE → escribe en el archivo (si está habilitado).
_log_to_file() {
    [[ ${GHOST_LOG_ENABLED:-0} == 1 && -n ${GHOST_LOG_FILE:-} ]] || return 0
    local name=$1 msg=$2 dir ts

    dir=${GHOST_LOG_FILE%/*}
    [[ -d $dir ]] || mkdir -p "$dir" 2>/dev/null || return 0

    log_rotate "$GHOST_LOG_FILE"

    if [[ ${GHOST_LOG_JSON:-0} == 1 ]]; then
        printf '%s\n' "$(_json_line "$name" "$(_strip_ansi "$msg")")" \
            >>"$GHOST_LOG_FILE"
    else
        ts=$(date '+%Y-%m-%d %H:%M:%S.%3N')
        printf '[%s] [%-5s] [%s] %s\n' \
            "$ts" "$name" "$GHOST_LOG_APP" "$(_strip_ansi "$msg")" \
            >>"$GHOST_LOG_FILE"
    fi
}

# _log_emit NIVEL NUM COLOR MENSAJE → núcleo de emisión a consola + archivo.
_log_emit() {
    local name=$1 num=$2 color=$3 msg=$4
    _log_should "$num" || return 0

    # WARN y superiores van a stderr; el resto a stdout.
    local fd=1
    [[ $num -ge $_LVL_WARN ]] && fd=2

    if [[ ${GHOST_LOG_JSON:-0} == 1 ]]; then
        printf '%s\n' "$(_json_line "$name" "$(_strip_ansi "$msg")")" >&"$fd"
    else
        local ts
        ts=$(date '+%H:%M:%S')
        printf '%s[%s]%s %s[%-5s]%s %s\n' \
            "$C_MUTED" "$ts" "$C_RESET" \
            "$color" "$name" "$C_RESET" "$msg" >&"$fd"
    fi

    _log_to_file "$name" "$msg"
}

# ──────────────────────────────────────────────────────────────────────────────
#  API PÚBLICA — funciones de nivel
# ──────────────────────────────────────────────────────────────────────────────
log_trace() { _log_emit TRACE "$_LVL_TRACE" "$C_MUTED" "$*"; }
log_debug() { _log_emit DEBUG "$_LVL_DEBUG" "$C_SECONDARY" "$*"; }
log_info() { _log_emit INFO "$_LVL_INFO" "$C_ACCENT" "$*"; }
log_ok() { _log_emit OK "$_LVL_OK" "$C_SUCCESS" "$*"; }
log_warn() { _log_emit WARN "$_LVL_WARN" "$C_WARNING" "$*"; }
log_error() { _log_emit ERROR "$_LVL_ERROR" "$C_ERROR" "$*"; }
log_fatal() { _log_emit FATAL "$_LVL_FATAL" "${C_BOLD}${C_ERROR}" "$*"; }

# die [CÓDIGO] MENSAJE → registra un FATAL y termina el proceso.
# POR QUÉ: separar log_fatal (solo registra) de die (registra y sale) evita
# matar al proceso por sorpresa cuando solo se quiere dejar constancia.
die() {
    local code=1
    if [[ $1 =~ ^[0-9]+$ ]]; then
        code=$1
        shift
    fi
    log_fatal "$*"
    exit "$code"
}

# ──────────────────────────────────────────────────────────────────────────────
#  API PÚBLICA — presentación
# ──────────────────────────────────────────────────────────────────────────────

# log_section TÍTULO → imprime un encabezado de sección destacado.
log_section() {
    local title=$* line
    line=$(_repeat '─' 50)
    printf '\n%s%s%s\n' "$C_PRIMARY" "$line" "$C_RESET"
    printf '%s%s  %s%s\n' "$C_BOLD" "$C_PRIMARY" "$title" "$C_RESET"
    printf '%s%s%s\n\n' "$C_PRIMARY" "$line" "$C_RESET"
    _log_to_file SECTION "$title"
}

# log_table CLAVE VALOR [CLAVE VALOR ...] → imprime pares clave/valor alineados.
log_table() {
    local -a keys=() vals=()
    while [[ $# -ge 2 ]]; do
        keys+=("$1")
        vals+=("$2")
        shift 2
    done

    # Calcula el ancho máximo de clave para alinear la columna.
    local maxw=0 k
    for k in "${keys[@]}"; do
        [[ ${#k} -gt $maxw ]] && maxw=${#k}
    done

    local i
    for i in "${!keys[@]}"; do
        printf '  %s%-*s%s : %s%s%s\n' \
            "$C_MUTED" "$maxw" "${keys[$i]}" "$C_RESET" \
            "$C_ACCENT" "${vals[$i]}" "$C_RESET"
    done
}

# ──────────────────────────────────────────────────────────────────────────────
#  API PÚBLICA — configuración
# ──────────────────────────────────────────────────────────────────────────────

# log_set_level NOMBRE → fija el umbral de log por nombre.
log_set_level() {
    case ${1^^} in
        TRACE) GHOST_LOG_LEVEL=$_LVL_TRACE ;;
        DEBUG) GHOST_LOG_LEVEL=$_LVL_DEBUG ;;
        INFO) GHOST_LOG_LEVEL=$_LVL_INFO ;;
        OK | SUCCESS) GHOST_LOG_LEVEL=$_LVL_OK ;;
        WARN | WARNING) GHOST_LOG_LEVEL=$_LVL_WARN ;;
        ERROR) GHOST_LOG_LEVEL=$_LVL_ERROR ;;
        FATAL) GHOST_LOG_LEVEL=$_LVL_FATAL ;;
        *)
            printf '[logger.sh] Nivel inválido: «%s».\n' "$1" >&2
            printf 'Válidos: TRACE, DEBUG, INFO, OK, WARN, ERROR, FATAL.\n' >&2
            return 1
            ;;
    esac
}

log_set_verbose() { GHOST_LOG_LEVEL=$_LVL_DEBUG; } # --verbose
log_set_trace() { GHOST_LOG_LEVEL=$_LVL_TRACE; }   # --trace
log_set_quiet() { GHOST_LOG_LEVEL=$_LVL_WARN; }    # --quiet (solo WARN+)

# log_enable_file RUTA → activa el log a archivo en la ruta indicada.
log_enable_file() {
    GHOST_LOG_FILE=${1:?[logger.sh] Falta la ruta del archivo de log}
    GHOST_LOG_ENABLED=1
}

log_enable_json() { GHOST_LOG_JSON=1; } # --log-json
