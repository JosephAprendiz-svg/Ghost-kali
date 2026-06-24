#!/usr/bin/env bash
# shellcheck shell=bash

# ───────────────────────────────────────────────────────────────────────────
# GHOST-KALI v5.0 — lib/proxyctl.sh
# Módulo de gestión de Proxychains — PERFIL DE ANONIMATO / DEFENSA
# ───────────────────────────────────────────────────────────────────────────
#
# PROPÓSITO:
#   Administrar la configuración de Proxychains del PROPIO equipo del operador:
#   modo de cadena, proxy_dns, lista de proxies, plantilla segura, y ejecución
#   de los PROPIOS comandos del operador a través de la cadena (anonimato).
#
# ALCANCE:
#   Educación en seguridad y privacidad, y hardening de la pila de anonimato
#   propia. Todas las funciones configuran cómo egresa el tráfico PROPIO o lo
#   diagnostican. NO incluye movimiento lateral, pivoteo hacia redes ajenas,
#   evasión de defensas de terceros, anti-forense, suplantación de huella ni
#   sondeo de objetivos. Esas capacidades quedan deliberadamente fuera.
#
# INVARIANTES DE SEGURIDAD:
#   · Solo se carga con 'source' (nunca se ejecuta como script).
#   · Ninguna modificación de configuración sin backup atómico previo.
#   · Toda operación destructiva respeta --dry-run y pide confirmación.
#   · Nunca imprime ni registra credenciales, tokens ni datos sensibles.
#   · Prohibidos: rm -rf, mkfs, dd, iptables -F, killall, pkill, eval, exec.
#
# CARGA:   source lib/proxyctl.sh
# DEPENDE: lib/colors.sh, lib/logger.sh, lib/validators.sh, lib/torctl.sh
#          (todas opcionales, con fallbacks o delegación condicional).
# LICENCIA: MIT
# AUTOR:   Joseph (JosephAprendiz-svg)
# ───────────────────────────────────────────────────────────────────────────

# Guarda de ejecución directa: solo se permite 'source'.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf '%b\n' "[FATAL] lib/proxyctl.sh debe cargarse con 'source', no ejecutarse." >&2
    exit 1
fi

# Guarda de idempotencia: evitar carga múltiple.
if [[ -n "${_GHOST_PROXYCTL_LOADED:-}" ]]; then
    return 0
fi
readonly _GHOST_PROXYCTL_LOADED=1

# Modo estricto.
set -euo pipefail

# ───────────────────────────────────────────────────────────────────────────
# Carga de dependencias (módulos hermanos) con fallbacks inline.
# ───────────────────────────────────────────────────────────────────────────
_GHOST_PROXYCTL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)" ||
    _GHOST_PROXYCTL_DIR="."

for _dep in colors.sh logger.sh validators.sh torctl.sh; do
    if [[ -r "${_GHOST_PROXYCTL_DIR}/${_dep}" ]]; then
        # shellcheck source=/dev/null
        source "${_GHOST_PROXYCTL_DIR}/${_dep}"
    fi
done
unset _dep

# Fallbacks de color (se interpretan con printf '%b'). Solo si no existen.
: "${C_RESET:=\033[0m}"
: "${C_BOLD:=\033[1m}"
: "${C_DIM:=\033[2m}"
: "${C_PRIMARY:=\033[0;36m}"
: "${C_SUCCESS:=\033[0;32m}"
: "${C_WARNING:=\033[0;33m}"
: "${C_DANGER:=\033[0;31m}"
: "${C_INFO:=\033[0;34m}"

# Nivel de log y fallbacks de logging (escriben a stderr).
: "${GHOST_LOG_LEVEL:=20}"
if ! declare -F log_info >/dev/null 2>&1; then
    _ghost_proxyctl_log() {
        local level="$1"
        shift
        local threshold="${GHOST_LOG_LEVEL:-20}"
        ((level < threshold)) && return 0
        printf '%b\n' "$*" >&2
    }
    log_debug() { _ghost_proxyctl_log 10 "[DEBUG] $*"; }
    log_info() { _ghost_proxyctl_log 20 "[INFO ] $*"; }
    log_warn() { _ghost_proxyctl_log 30 "[WARN ] $*"; }
    log_error() { _ghost_proxyctl_log 40 "[ERROR] $*"; }
fi

# ───────────────────────────────────────────────────────────────────────────
# Constantes de configuración (readonly).
# ───────────────────────────────────────────────────────────────────────────
GHOST_PROXYCHAINS_BIN="proxychains4"
readonly GHOST_PROXYCHAINS_BIN

GHOST_PROXYCHAINS_CONF_SYSTEM="/etc/proxychains4.conf"
readonly GHOST_PROXYCHAINS_CONF_SYSTEM

GHOST_PROXYCHAINS_CONF_USER="${HOME:-/root}/.proxychains/proxychains.conf"
readonly GHOST_PROXYCHAINS_CONF_USER

GHOST_PROXYCHAINS_BACKUP_DIR="/var/backups/ghost-kali/proxychains"
readonly GHOST_PROXYCHAINS_BACKUP_DIR

GHOST_PROXYCHAINS_DEFAULT_MODE="dynamic_chain"
readonly GHOST_PROXYCHAINS_DEFAULT_MODE

GHOST_PROXYCHAINS_DEFAULT_PROXY_HOST="127.0.0.1"
readonly GHOST_PROXYCHAINS_DEFAULT_PROXY_HOST

GHOST_PROXYCHAINS_DEFAULT_PROXY_PORT="9050"
readonly GHOST_PROXYCHAINS_DEFAULT_PROXY_PORT

GHOST_PROXYCHAINS_TIMEOUT="10"
readonly GHOST_PROXYCHAINS_TIMEOUT

GHOST_PROXYCHAINS_CHECK_URL="https://check.torproject.org/api/ip"
readonly GHOST_PROXYCHAINS_CHECK_URL

# ───────────────────────────────────────────────────────────────────────────
# Estado interno (no readonly).
# ───────────────────────────────────────────────────────────────────────────
_GHOST_PROXYCTL_DRY_RUN=0         # 0 = real, 1 = simulación
_GHOST_PROXYCTL_NON_INTERACTIVE=0 # 0 = interactivo, 1 = automático
_GHOST_PROXYCTL_OPLOG=()          # bitácora de operaciones de la sesión

# ═══════════════════════════════════════════════════════════════════════════
# FUNCIONES PRIVADAS (_proxyctl_)
# ═══════════════════════════════════════════════════════════════════════════

# Verifica que estén disponibles las dependencias indicadas.
_proxyctl_check_dependencies() {
    local -a needed=("$@")
    local -a missing=()
    local cmd
    for cmd in "${needed[@]}"; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done
    if ((${#missing[@]} > 0)); then
        log_error "Dependencias ausentes: ${missing[*]}"
        return 1
    fi
    return 0
}

# Retorna 0 si el usuario efectivo es root.
_proxyctl_is_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] && return 0
    return 1
}

# Registra una operación en la bitácora de la sesión (UTC|acción|resultado).
_proxyctl_log_op() {
    local action="${1:-?}"
    local result="${2:-?}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' '-')"
    _GHOST_PROXYCTL_OPLOG+=("${ts}|${action}|${result}")
    return 0
}

# Crea el directorio de backups con permisos 700. Imprime su ruta.
_proxyctl_create_backup_path() {
    local dir="${GHOST_PROXYCHAINS_BACKUP_DIR}"
    if [[ ! -d "${dir}" ]]; then
        if ((_GHOST_PROXYCTL_DRY_RUN)); then
            log_info "[dry-run] mkdir -p ${dir}"
        else
            mkdir -p "${dir}" || {
                log_error "No se pudo crear ${dir}"
                return 1
            }
            chmod 700 "${dir}" 2>/dev/null || true
        fi
    fi
    printf '%s' "${dir}"
    return 0
}

# Retorna la ruta del backup más reciente para un archivo base dado.
_proxyctl_latest_backup() {
    local base="${1:-}"
    local dir="${GHOST_PROXYCHAINS_BACKUP_DIR}"
    [[ -n "${base}" && -d "${dir}" ]] || return 1
    local name latest
    name="$(basename "${base}")"
    latest="$(find "${dir}" -maxdepth 1 -type f -name "${name}.*.bak" -printf '%T@ %p\n' 2>/dev/null |
        sort -rn | head -n1 | cut -d' ' -f2- || true)"
    [[ -n "${latest}" ]] || return 1
    printf '%s' "${latest}"
    return 0
}

# Crea backup con marca temporal ISO 8601 UTC. Imprime la ruta del backup.
_proxyctl_backup_config() {
    local ruta="${1:-}"
    [[ -r "${ruta}" ]] || {
        log_error "No se puede leer para backup: ${ruta}"
        return 1
    }
    local dir ts name dest
    dir="$(_proxyctl_create_backup_path)" || return 1
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    name="$(basename "${ruta}")"
    dest="${dir}/${name}.${ts}.bak"
    if ((_GHOST_PROXYCTL_DRY_RUN)); then
        log_info "[dry-run] Copiaría ${ruta} -> ${dest}"
        printf '%s' "${dest}"
        return 0
    fi
    cat "${ruta}" >"${dest}" || {
        log_error "Backup falló"
        return 1
    }
    chmod 600 "${dest}" 2>/dev/null || true
    printf '%s' "${dest}"
    return 0
}

# Escritura atómica con backup previo. Respeta --dry-run.
_proxyctl_safe_write() {
    local target="${1:-}"
    local content="${2:-}"
    [[ -n "${target}" ]] || {
        log_error "safe_write: destino vacío"
        return 1
    }
    if ((_GHOST_PROXYCTL_DRY_RUN)); then
        log_info "[dry-run] Escribiría $((${#content})) bytes en ${target} (con backup previo)"
        return 0
    fi
    local dir
    dir="$(dirname -- "${target}")"
    [[ -d "${dir}" ]] || mkdir -p "${dir}" 2>/dev/null || true
    if [[ -e "${target}" ]]; then
        _proxyctl_backup_config "${target}" >/dev/null || {
            log_error "Backup falló; se aborta la escritura"
            return 1
        }
    fi
    local tmp
    tmp="$(mktemp "${target}.XXXXXX.tmp")" || {
        log_error "mktemp falló"
        return 1
    }
    printf '%s\n' "${content}" >"${tmp}" || {
        rm -f "${tmp}"
        return 1
    }
    chmod --reference="${target}" "${tmp}" 2>/dev/null || chmod 600 "${tmp}" 2>/dev/null || true
    mv -f "${tmp}" "${target}" || {
        rm -f "${tmp}"
        log_error "Movimiento atómico falló"
        return 1
    }
    log_info "Escritura atómica completada: ${target}"
    return 0
}

# Solicita confirmación interactiva. En modo no interactivo, aborta por seguridad.
_proxyctl_confirm_action() {
    local prompt="${1:-¿Continuar?}"
    if ((_GHOST_PROXYCTL_NON_INTERACTIVE)); then
        log_warn "Modo no interactivo: acción no confirmada; se aborta por seguridad."
        return 1
    fi
    local reply=""
    printf '%b' "${C_WARNING}${prompt} [s/N]: ${C_RESET}" >&2
    read -r reply || true
    case "${reply,,}" in
        s | si | sí | y | yes) return 0 ;;
        *) return 1 ;;
    esac
}

# Normaliza un valor booleano: 1/yes/true/on -> 0; el resto -> 1.
_proxyctl_parse_bool() {
    case "${1,,}" in
        1 | yes | sí | si | true | on) return 0 ;;
        *) return 1 ;;
    esac
}

# Localiza el primer archivo de configuración legible. Imprime su ruta.
_proxyctl_detect_conf_path() {
    local c
    for c in "${GHOST_PROXYCHAINS_CONF_SYSTEM}" "${GHOST_PROXYCHAINS_CONF_USER}"; do
        if [[ -r "${c}" ]]; then
            printf '%s' "${c}"
            return 0
        fi
    done
    return 1
}

# Imprime la configuración saneada: redacta usuario/clave de proxies y de
# comentarios con secretos. Nunca expone credenciales.
_proxyctl_sanitize_output() {
    local conf="${1:-}"
    [[ -r "${conf}" ]] || return 1
    awk '
        /^[[:space:]]*\[ProxyList\]/ { inlist=1; print; next }
        /^[[:space:]]*\[/ { inlist=0 }
        {
            line=$0
            low=tolower(line)
            if (line ~ /^[[:space:]]*#/) {
                if (low ~ /pass/ || low ~ /secret/ || low ~ /token/) {
                    gsub(/[Pp][Aa][Ss][Ss]([Ww][Oo][Rr][Dd])?[[:space:]]*[=:][[:space:]]*[^[:space:]]+/, "password=<REDACTADO>", line)
                    gsub(/[Ss][Ee][Cc][Rr][Ee][Tt][[:space:]]*[=:][[:space:]]*[^[:space:]]+/, "secret=<REDACTADO>", line)
                    gsub(/[Tt][Oo][Kk][Ee][Nn][[:space:]]*[=:][[:space:]]*[^[:space:]]+/, "token=<REDACTADO>", line)
                }
                print line
                next
            }
            if (inlist && NF >= 5) {
                t = tolower($1)
                if (t == "socks4" || t == "socks5" || t == "http" || t == "https" || t == "raw") {
                    $4 = "<REDACTADO>"
                    $5 = "<REDACTADO>"
                }
            }
            print
        }
    ' "${conf}"
}

# Establece (o reemplaza la primera ocurrencia de) una directiva clave-valor de
# forma idempotente. Si no existe, la añade. Backup atómico previo.
_proxyctl_set_directive() {
    local conf="${1:-}"
    local directive="${2:-}"
    local value="${3:-}"
    [[ -r "${conf}" ]] || {
        log_error "No se puede leer: ${conf}"
        return 1
    }
    [[ -n "${directive}" ]] || return 1
    local newcontent
    newcontent="$(awk -v d="${directive}" -v v="${value}" '
        BEGIN { done=0 }
        {
            line=$0; tmp=line
            sub(/^[[:space:]]+/, "", tmp); sub(/^#[[:space:]]*/, "", tmp)
            n=split(tmp, a, /[[:space:]]+/)
            if (!done && n>=1 && a[1]==d) {
                if (v=="") { print d } else { print d" "v }
                done=1; next
            }
            print line
        }
        END { if (!done) { if (v=="") { print d } else { print d" "v } } }
    ' "${conf}")"
    _proxyctl_safe_write "${conf}" "${newcontent}"
}

# Comenta todas las líneas activas de una directiva. Backup atómico previo.
_proxyctl_comment_directive() {
    local conf="${1:-}"
    local directive="${2:-}"
    [[ -r "${conf}" ]] || return 1
    [[ -n "${directive}" ]] || return 1
    local newcontent
    newcontent="$(awk -v d="${directive}" '
        {
            line=$0; tmp=line; sub(/^[[:space:]]+/, "", tmp)
            n=split(tmp, a, /[[:space:]]+/)
            if (n>=1 && a[1]==d && line !~ /^[[:space:]]*#/) { print "#"line }
            else { print line }
        }
    ' "${conf}")"
    _proxyctl_safe_write "${conf}" "${newcontent}"
}

# Imprime el modo de cadena activo (dynamic_chain|strict_chain|random_chain).
_proxyctl_active_mode() {
    local conf="${1:-}"
    [[ -r "${conf}" ]] || return 1
    local m
    m="$(grep -aoE '^[[:space:]]*(dynamic_chain|strict_chain|random_chain)' "${conf}" 2>/dev/null |
        head -n1 | tr -d '[:space:]' || true)"
    [[ -n "${m}" ]] || return 1
    printf '%s' "${m}"
    return 0
}

# Imprime el primer proxy de [ProxyList] como 'host:puerto (tipo)'.
_proxyctl_first_proxy() {
    local conf="${1:-}"
    [[ -r "${conf}" ]] || return 1
    awk '
        /^[[:space:]]*\[ProxyList\]/ { inlist=1; next }
        /^[[:space:]]*\[/ { inlist=0 }
        inlist && $0 !~ /^[[:space:]]*#/ && NF>=3 {
            print $2":"$3" ("$1")"; exit
        }
    ' "${conf}"
}

# Cuenta entradas activas en [ProxyList].
_proxyctl_count_proxies() {
    local conf="${1:-}"
    [[ -r "${conf}" ]] || {
        printf '%s' "0"
        return 0
    }
    awk '
        /^[[:space:]]*\[ProxyList\]/ { inlist=1; next }
        /^[[:space:]]*\[/ { inlist=0 }
        inlist && $0 !~ /^[[:space:]]*#/ && NF>=3 { c++ }
        END { print c+0 }
    ' "${conf}"
}

# Valida una entrada de proxy: tipo soportado, host no vacío, puerto válido.
_proxyctl_validate_proxy_entry() {
    local type="${1:-}" host="${2:-}" port="${3:-}"
    case "${type,,}" in
        socks4 | socks5 | http) : ;;
        *)
            log_error "Tipo de proxy no soportado: ${type} (use socks4|socks5|http)"
            return 1
            ;;
    esac
    [[ -n "${host}" ]] || {
        log_error "Host vacío."
        return 1
    }
    if ! [[ "${port}" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
        log_error "Puerto inválido: ${port}"
        return 1
    fi
    return 0
}

# Imprime la plantilla segura por defecto.
_proxyctl_render_default_conf() {
    cat <<EOF
# Ghost-Kali v5.0 — Plantilla Segura de Proxychains
${GHOST_PROXYCHAINS_DEFAULT_MODE}
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000

[ProxyList]
socks5 ${GHOST_PROXYCHAINS_DEFAULT_PROXY_HOST} ${GHOST_PROXYCHAINS_DEFAULT_PROXY_PORT}
EOF
}

# Mide la latencia (ms) de conexión TCP a un host:puerto LOCAL propio.
_proxyctl_measure_latency() {
    local host="${1:-${GHOST_PROXYCHAINS_DEFAULT_PROXY_HOST}}"
    local port="${2:-${GHOST_PROXYCHAINS_DEFAULT_PROXY_PORT}}"
    local start end
    start="$(date +%s%3N)"
    if command -v nc >/dev/null 2>&1; then
        nc -z -w 3 "${host}" "${port}" >/dev/null 2>&1 || {
            printf '%s' "-1"
            return 1
        }
    else
        (exec 3<>"/dev/tcp/${host}/${port}") >/dev/null 2>&1 || {
            printf '%s' "-1"
            return 1
        }
    fi
    end="$(date +%s%3N)"
    printf '%s' "$((end - start))"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# BLOQUE A — OPERACIONES DEFENSIVAS / DE CONFIGURACIÓN
# ═══════════════════════════════════════════════════════════════════════════

# A.01 — Retorna 0 si proxychains está instalado.
proxyctl_is_installed() {
    command -v "${GHOST_PROXYCHAINS_BIN}" >/dev/null 2>&1 && return 0
    command -v proxychains >/dev/null 2>&1 && return 0
    return 1
}

# A.03 — Imprime la versión de proxychains.
proxyctl_get_version() {
    proxyctl_is_installed || {
        printf '%s' "no instalado"
        return 1
    }
    local bin v
    bin="$(command -v "${GHOST_PROXYCHAINS_BIN}" || command -v proxychains)"
    v="$("${bin}" 2>&1 | grep -aoiE 'proxychains[^0-9]*[0-9][0-9a-z.\-]*' | head -n1 || true)"
    [[ -n "${v}" ]] || v="versión desconocida"
    printf '%s' "${v}"
    return 0
}

# A.04 — Imprime la ruta del archivo de configuración activo.
proxyctl_get_config_path() {
    local c
    c="$(_proxyctl_detect_conf_path || true)"
    if [[ -z "${c}" ]]; then
        log_warn "No se encontró configuración legible de proxychains."
        return 1
    fi
    printf '%s' "${c}"
    return 0
}

# A.05 — Muestra la configuración saneada (sin credenciales).
proxyctl_show_config() {
    local conf="${1:-}"
    [[ -n "${conf}" ]] || conf="$(_proxyctl_detect_conf_path || true)"
    [[ -r "${conf}" ]] || {
        log_error "No se puede leer la configuración: ${conf:-<ninguna>}"
        return 1
    }
    printf '%b\n' "${C_INFO}Configuración (saneada): ${conf}${C_RESET}"
    _proxyctl_sanitize_output "${conf}"
    return 0
}

# A.06 — Valida la configuración: existencia, modo y sección [ProxyList].
proxyctl_validate_config() {
    local conf="${1:-}"
    [[ -n "${conf}" ]] || conf="$(_proxyctl_detect_conf_path || true)"
    [[ -e "${conf}" ]] || {
        log_error "No existe: ${conf:-<ninguna>}"
        return 1
    }
    [[ -r "${conf}" ]] || {
        log_error "No legible: ${conf}"
        return 1
    }
    if ! grep -aqE '^[[:space:]]*\[ProxyList\]' "${conf}"; then
        log_error "Falta la sección [ProxyList]."
        return 1
    fi
    if [[ "$(_proxyctl_count_proxies "${conf}")" -lt 1 ]]; then
        log_warn "[ProxyList] no tiene proxies activos."
        return 1
    fi
    log_info "Configuración válida: ${conf}"
    return 0
}

# A.07 — Crea backup con marca temporal ISO 8601 UTC.
proxyctl_backup_config() {
    local conf="${1:-}"
    [[ -n "${conf}" ]] || conf="$(_proxyctl_detect_conf_path || true)"
    local dest
    dest="$(_proxyctl_backup_config "${conf}")" || {
        log_error "Backup falló."
        return 1
    }
    log_info "Backup creado: ${dest}"
    _proxyctl_log_op "backup_config" "ok:${dest}"
    return 0
}

# A.08 — Restaura desde el backup más reciente, previa confirmación.
proxyctl_restore_config() {
    local conf="${1:-}"
    [[ -n "${conf}" ]] || conf="$(_proxyctl_detect_conf_path || true)"
    [[ -n "${conf}" ]] || {
        log_error "Sin configuración objetivo."
        return 1
    }
    local latest
    latest="$(_proxyctl_latest_backup "${conf}" || true)"
    [[ -n "${latest}" ]] || {
        log_error "No hay backups para $(basename "${conf}")."
        return 1
    }
    log_info "Más reciente: ${latest}"
    if ((_GHOST_PROXYCTL_DRY_RUN)); then
        log_info "[dry-run] Restauraría ${latest} -> ${conf}"
        return 0
    fi
    _proxyctl_confirm_action "¿Restaurar ${conf} desde el backup más reciente?" || {
        log_warn "Restauración cancelada."
        return 1
    }
    _proxyctl_backup_config "${conf}" >/dev/null 2>&1 || true
    cat "${latest}" >"${conf}" || {
        log_error "Restauración falló."
        return 1
    }
    log_info "Configuración restaurada desde ${latest}"
    _proxyctl_log_op "restore_config" "ok:${latest}"
    return 0
}

# A.09 — Fija el modo de cadena (dynamic_chain|strict_chain|random_chain).
proxyctl_set_mode() {
    local mode="${1:-}"
    local conf="${2:-}"
    [[ -n "${conf}" ]] || conf="$(_proxyctl_detect_conf_path || true)"
    [[ -r "${conf}" ]] || {
        log_error "Sin configuración legible."
        return 1
    }
    case "${mode}" in
        dynamic_chain | strict_chain | random_chain) : ;;
        *)
            log_error "Modo inválido: ${mode} (use dynamic_chain|strict_chain|random_chain)"
            return 1
            ;;
    esac
    local current
    current="$(_proxyctl_active_mode "${conf}" || true)"
    if [[ "${current}" == "${mode}" ]]; then
        log_info "El modo ${mode} ya está activo; sin cambios."
        return 0
    fi
    local newcontent
    newcontent="$(awk -v sel="${mode}" '
        BEGIN {
            modes["dynamic_chain"]=1; modes["strict_chain"]=1; modes["random_chain"]=1
            print sel
        }
        {
            line=$0; tmp=line
            sub(/^[[:space:]]+/, "", tmp); sub(/^#[[:space:]]*/, "", tmp)
            split(tmp, a, /[[:space:]]+/)
            if (a[1] in modes) {
                if (line ~ /^[[:space:]]*#/) { print line } else { print "#"line }
                next
            }
            print line
        }
    ' "${conf}")"
    _proxyctl_safe_write "${conf}" "${newcontent}" || return 1
    log_info "Modo de cadena establecido: ${mode}"
    _proxyctl_log_op "set_mode" "${mode}"
    return 0
}

# A.10 — Activa proxy_dns (evita fugas DNS). Backup previo.
proxyctl_enable_proxy_dns() {
    local conf="${1:-}"
    [[ -n "${conf}" ]] || conf="$(_proxyctl_detect_conf_path || true)"
    [[ -r "${conf}" ]] || {
        log_error "Sin configuración legible."
        return 1
    }
    if grep -aqE '^[[:space:]]*proxy_dns\b' "${conf}"; then
        log_info "proxy_dns ya está activo."
        return 0
    fi
    _proxyctl_set_directive "${conf}" "proxy_dns" "" || return 1
    log_info "proxy_dns activado."
    _proxyctl_log_op "enable_proxy_dns" "ok"
    return 0
}

# A.11 — Desactiva proxy_dns (comenta la directiva). Backup previo.
proxyctl_disable_proxy_dns() {
    local conf="${1:-}"
    [[ -n "${conf}" ]] || conf="$(_proxyctl_detect_conf_path || true)"
    [[ -r "${conf}" ]] || {
        log_error "Sin configuración legible."
        return 1
    }
    _proxyctl_comment_directive "${conf}" "proxy_dns" || return 1
    log_warn "proxy_dns desactivado: riesgo de fuga DNS."
    _proxyctl_log_op "disable_proxy_dns" "ok"
    return 0
}

# A.12 — Añade un proxy a [ProxyList]. Idempotente. Backup previo.
# USER/PASS son opcionales; si se usan, quedan en texto plano en el archivo.
proxyctl_add_proxy() {
    local type="${1:-}" host="${2:-}" port="${3:-}" user="${4:-}" pass="${5:-}"
    _proxyctl_validate_proxy_entry "${type}" "${host}" "${port}" || return 1
    local conf
    conf="$(_proxyctl_detect_conf_path || true)"
    [[ -r "${conf}" ]] || {
        log_error "Sin configuración legible."
        return 1
    }
    # Idempotencia: no duplica una entrada con el mismo tipo/host/puerto.
    if awk -v ty="${type,,}" -v h="${host}" -v p="${port}" '
        /^[[:space:]]*\[ProxyList\]/ { inlist=1; next }
        /^[[:space:]]*\[/ { inlist=0 }
        inlist && $0 !~ /^[[:space:]]*#/ && tolower($1)==ty && $2==h && $3==p { found=1 }
        END { exit !found }
    ' "${conf}"; then
        log_info "El proxy ${type} ${host}:${port} ya existe; sin cambios."
        return 0
    fi
    [[ -n "${user}" || -n "${pass}" ]] &&
        log_warn "Credenciales de proxy quedarán en texto plano en ${conf} (chmod 600 recomendado)."
    local entry="${type,,} ${host} ${port}"
    [[ -n "${user}" ]] && entry+=" ${user}"
    [[ -n "${pass}" ]] && entry+=" ${pass}"
    local newcontent
    if grep -aqE '^[[:space:]]*\[ProxyList\]' "${conf}"; then
        newcontent="$(awk -v e="${entry}" '
            { print }
            /^[[:space:]]*\[ProxyList\]/ && !done { print e; done=1 }
        ' "${conf}")"
    else
        newcontent="$(
            cat "${conf}"
            printf '\n[ProxyList]\n%s\n' "${entry}"
        )"
    fi
    _proxyctl_safe_write "${conf}" "${newcontent}" || return 1
    log_info "Proxy añadido: ${type} ${host}:${port}"
    _proxyctl_log_op "add_proxy" "${type}:${host}:${port}"
    return 0
}

# A.13 — Elimina entradas de proxy que coincidan con host y puerto. Backup previo.
proxyctl_remove_proxy() {
    local host="${1:-}" port="${2:-}"
    [[ -n "${host}" && -n "${port}" ]] || {
        log_error "Uso: proxyctl_remove_proxy <host> <puerto>"
        return 1
    }
    local conf
    conf="$(_proxyctl_detect_conf_path || true)"
    [[ -r "${conf}" ]] || {
        log_error "Sin configuración legible."
        return 1
    }
    local newcontent
    newcontent="$(awk -v h="${host}" -v p="${port}" '
        /^[[:space:]]*\[ProxyList\]/ { inlist=1; print; next }
        /^[[:space:]]*\[/ { inlist=0 }
        {
            if (inlist && $0 !~ /^[[:space:]]*#/ && $2==h && $3==p) { next }
            print
        }
    ' "${conf}")"
    _proxyctl_safe_write "${conf}" "${newcontent}" || return 1
    log_info "Entradas de ${host}:${port} eliminadas (si existían)."
    _proxyctl_log_op "remove_proxy" "${host}:${port}"
    return 0
}

# A.14 — Elimina todas las entradas de [ProxyList] (conserva la sección).
proxyctl_clear_proxies() {
    local conf
    conf="$(_proxyctl_detect_conf_path || true)"
    [[ -r "${conf}" ]] || {
        log_error "Sin configuración legible."
        return 1
    }
    if ((_GHOST_PROXYCTL_DRY_RUN == 0)); then
        _proxyctl_confirm_action "¿Vaciar todos los proxies de [ProxyList]?" || {
            log_warn "Operación cancelada."
            return 1
        }
    fi
    local newcontent
    newcontent="$(awk '
        /^[[:space:]]*\[ProxyList\]/ { inlist=1; print; next }
        /^[[:space:]]*\[/ { inlist=0 }
        {
            if (inlist && $0 !~ /^[[:space:]]*#/ && NF>=3) { next }
            print
        }
    ' "${conf}")"
    _proxyctl_safe_write "${conf}" "${newcontent}" || return 1
    log_info "Lista de proxies vaciada."
    _proxyctl_log_op "clear_proxies" "ok"
    return 0
}

# A.15 — Configura la cadena por defecto hacia Tor (socks5 127.0.0.1:9050).
proxyctl_set_tor_defaults() {
    local conf
    conf="$(_proxyctl_detect_conf_path || true)"
    [[ -r "${conf}" ]] || {
        log_error "Sin configuración legible."
        return 1
    }
    proxyctl_set_mode "${GHOST_PROXYCHAINS_DEFAULT_MODE}" "${conf}" || true
    proxyctl_enable_proxy_dns "${conf}" || true
    proxyctl_clear_proxies "${conf}" >/dev/null 2>&1 || true
    proxyctl_add_proxy "socks5" "${GHOST_PROXYCHAINS_DEFAULT_PROXY_HOST}" \
        "${GHOST_PROXYCHAINS_DEFAULT_PROXY_PORT}" || return 1
    log_info "Cadena por defecto hacia Tor configurada."
    _proxyctl_log_op "set_tor_defaults" "ok"
    return 0
}

# A.16 — Restablece la configuración a la plantilla segura. Backup + confirmación.
proxyctl_reset_to_defaults() {
    local conf
    conf="$(_proxyctl_detect_conf_path || printf '%s' "${GHOST_PROXYCHAINS_CONF_SYSTEM}")"
    if ((_GHOST_PROXYCTL_DRY_RUN == 0)); then
        _proxyctl_confirm_action "¿Sobrescribir ${conf} con la plantilla segura?" || {
            log_warn "Operación cancelada."
            return 1
        }
    fi
    local content
    content="$(_proxyctl_render_default_conf)"
    _proxyctl_safe_write "${conf}" "${content}" || return 1
    log_info "Configuración restablecida a la plantilla segura."
    _proxyctl_log_op "reset_to_defaults" "ok"
    return 0
}

# A.17 — Imprime la plantilla de configuración recomendada (no escribe nada).
proxyctl_recommend_config() {
    _proxyctl_render_default_conf
    return 0
}

# A.18 — Ejecuta un comando PROPIO del operador a través de la cadena.
proxyctl_run() {
    proxyctl_is_installed || {
        log_error "proxychains no instalado."
        return 1
    }
    (($# > 0)) || {
        log_error "Uso: proxyctl_run <comando...>"
        return 1
    }
    local conf bin
    conf="$(_proxyctl_detect_conf_path || true)"
    [[ -r "${conf}" ]] || {
        log_error "Sin configuración legible."
        return 1
    }
    bin="$(command -v "${GHOST_PROXYCHAINS_BIN}" || command -v proxychains)"
    if ((_GHOST_PROXYCTL_DRY_RUN)); then
        log_info "[dry-run] ${bin} -f ${conf} $*"
        return 0
    fi
    _proxyctl_log_op "run" "$1"
    "${bin}" -f "${conf}" "$@"
}

# A.19 — Prueba la conectividad de extremo a extremo a través de la cadena.
proxyctl_test_connection() {
    proxyctl_is_installed || {
        log_error "proxychains no instalado."
        return 1
    }
    command -v curl >/dev/null 2>&1 || {
        log_error "curl no disponible."
        return 1
    }
    local conf bin out ip
    conf="$(_proxyctl_detect_conf_path || true)"
    [[ -r "${conf}" ]] || {
        log_error "Sin configuración legible."
        return 1
    }
    bin="$(command -v "${GHOST_PROXYCHAINS_BIN}" || command -v proxychains)"
    log_info "Probando egreso por la cadena (puede tardar)..."
    out="$("${bin}" -f "${conf}" curl -s --max-time "${GHOST_PROXYCHAINS_TIMEOUT}" \
        "${GHOST_PROXYCHAINS_CHECK_URL}" 2>/dev/null || true)"
    if [[ -z "${out}" ]]; then
        log_warn "Sin respuesta a través de la cadena."
        return 1
    fi
    ip="$(printf '%s' "${out}" | grep -oE '"IP"[[:space:]]*:[[:space:]]*"[^"]+"' |
        sed -E 's/.*"([0-9a-fA-F:.]+)".*/\1/' | head -n1 || true)"
    log_info "Egreso OK. IP: ${ip:-desconocida}"
    printf '%s' "${out}" | grep -qiE '"IsTor"[[:space:]]*:[[:space:]]*true' &&
        log_info "Egreso por Tor confirmado."
    _proxyctl_log_op "test_connection" "${ip:-?}"
    return 0
}

# A.20 — Verifica que la resolución DNS pase por la cadena (anti-fuga).
proxyctl_test_dns() {
    local conf
    conf="$(_proxyctl_detect_conf_path || true)"
    [[ -r "${conf}" ]] || {
        log_error "Sin configuración legible."
        return 1
    }
    if grep -aqE '^[[:space:]]*proxy_dns\b' "${conf}"; then
        log_info "proxy_dns activo: las consultas DNS se enrutan por la cadena."
    else
        log_warn "proxy_dns NO activo: riesgo de fuga DNS. Active con proxyctl_enable_proxy_dns."
        return 1
    fi
    if proxyctl_is_installed && command -v curl >/dev/null 2>&1; then
        local bin out
        bin="$(command -v "${GHOST_PROXYCHAINS_BIN}" || command -v proxychains)"
        out="$("${bin}" -f "${conf}" curl -s --max-time "${GHOST_PROXYCHAINS_TIMEOUT}" \
            "${GHOST_PROXYCHAINS_CHECK_URL}" 2>/dev/null || true)"
        [[ -n "${out}" ]] && log_info "Resolución por nombre a través de la cadena: OK." ||
            log_warn "No se pudo resolver por nombre a través de la cadena (¿Tor activo?)."
    fi
    _proxyctl_log_op "test_dns" "ok"
    return 0
}

# A.21 — Resumen del estado de la cadena (solo lectura).
proxyctl_chain_status() {
    local conf mode dns first count
    conf="$(_proxyctl_detect_conf_path || true)"
    [[ -r "${conf}" ]] || {
        log_warn "Sin configuración legible."
        return 1
    }
    mode="$(_proxyctl_active_mode "${conf}" || printf '%s' '-')"
    if grep -aqE '^[[:space:]]*proxy_dns\b' "${conf}"; then dns="activado"; else dns="desactivado"; fi
    first="$(_proxyctl_first_proxy "${conf}" || printf '%s' '-')"
    [[ -n "${first}" ]] || first="-"
    count="$(_proxyctl_count_proxies "${conf}")"
    printf '%b\n' "${C_INFO}${C_BOLD}Estado de la cadena${C_RESET}"
    printf '   %-12s %s\n' "Config:" "${conf}"
    printf '   %-12s %s\n' "Modo:" "${mode}"
    printf '   %-12s %s\n' "proxy_dns:" "${dns}"
    printf '   %-12s %s\n' "1er proxy:" "${first}"
    printf '   %-12s %s\n' "Proxies:" "${count}"
    return 0
}

# A.02 — Panel de estado operativo de Proxychains.
proxyctl_status_panel() {
    local installed="NO" version="-" conf="-" mode="-" target="-" dns="-" backup="-"
    if proxyctl_is_installed; then
        installed="SÍ"
        version="$(proxyctl_get_version 2>/dev/null || printf '%s' '-')"
    fi
    local c
    c="$(_proxyctl_detect_conf_path || true)"
    if [[ -n "${c}" ]]; then
        conf="${c}"
        mode="$(_proxyctl_active_mode "${c}" || printf '%s' '-')"
        target="$(_proxyctl_first_proxy "${c}" || printf '%s' '-')"
        [[ -n "${target}" ]] || target="-"
        if grep -aqE '^[[:space:]]*proxy_dns\b' "${c}"; then dns="ACTIVADO"; else dns="DESACTIVADO"; fi
        local latest
        latest="$(_proxyctl_latest_backup "${c}" 2>/dev/null || true)"
        [[ -n "${latest}" ]] && backup="$(basename "${latest}")"
    else
        conf="(ninguna)"
    fi
    printf '%b\n' "${C_PRIMARY}${C_BOLD}GHOST-KALI v5.0 — PROXYCTL STATUS${C_RESET}"
    printf '%b\n' "${C_DIM}──────────────────────────────────────────────${C_RESET}"
    printf '   %-18s %s\n' "Proxychains:" "${installed} (${version})"
    printf '   %-18s %s\n' "Config Activa:" "${conf}"
    printf '   %-18s %s\n' "Modo Cadena:" "${mode}"
    printf '   %-18s %s\n' "Proxy Objetivo:" "${target}"
    printf '   %-18s %s\n' "proxy_dns:" "${dns}"
    printf '   %-18s %s\n' "Último Backup:" "${backup}"
    printf '%b\n' "${C_DIM}──────────────────────────────────────────────${C_RESET}"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# BLOQUE B — ANONIMATO AVANZADO (operaciones sobre el tráfico PROPIO)
# ───────────────────────────────────────────────────────────────────────────
# Construcción de cadenas propias y operaciones de capa Tor (estas últimas se
# delegan a lib/torctl.sh, su módulo natural). No actúan contra terceros.
# ═══════════════════════════════════════════════════════════════════════════

# B.01 — Construye la cadena de proxies de [ProxyList] desde una lista.
# LISTA: entradas separadas por coma con formato 'tipo:host:puerto'.
# Reemplaza la lista actual (backup + confirmación).
proxyctl_chain_proxies() {
    local list="${1:-}"
    [[ -n "${list}" ]] || {
        log_error "Uso: proxyctl_chain_proxies 'socks5:127.0.0.1:9050,http:10.0.0.2:8080'"
        return 1
    }
    local conf
    conf="$(_proxyctl_detect_conf_path || printf '%s' "${GHOST_PROXYCHAINS_CONF_SYSTEM}")"
    local -a entries=()
    local item type host port
    local IFS_OLD="${IFS}"
    IFS=','
    read -r -a _raw <<<"${list}"
    IFS="${IFS_OLD}"
    for item in "${_raw[@]}"; do
        item="${item//[[:space:]]/}"
        [[ -n "${item}" ]] || continue
        type="${item%%:*}"
        host="${item#*:}"
        port="${host##*:}"
        host="${host%:*}"
        _proxyctl_validate_proxy_entry "${type}" "${host}" "${port}" || return 1
        entries+=("${type,,} ${host} ${port}")
    done
    ((${#entries[@]} > 0)) || {
        log_error "No se obtuvieron entradas válidas."
        return 1
    }
    if ((_GHOST_PROXYCTL_DRY_RUN == 0)); then
        _proxyctl_confirm_action "¿Reemplazar [ProxyList] con ${#entries[@]} proxy(s)?" || {
            log_warn "Operación cancelada."
            return 1
        }
    fi
    local body
    body="$(printf '%s\n' "${entries[@]}")"
    local newcontent
    if grep -aqE '^[[:space:]]*\[ProxyList\]' "${conf}" 2>/dev/null; then
        newcontent="$(awk '/^[[:space:]]*\[ProxyList\]/{exit} {print}' "${conf}")"
    else
        newcontent="$(_proxyctl_render_default_conf | awk '/^[[:space:]]*\[ProxyList\]/{exit} {print}')"
    fi
    newcontent+=$'\n'"[ProxyList]"$'\n'"${body}"
    _proxyctl_safe_write "${conf}" "${newcontent}" || return 1
    log_info "Cadena de ${#entries[@]} proxy(s) aplicada."
    _proxyctl_log_op "chain_proxies" "${#entries[@]}"
    return 0
}

# B.04 — Construye la cadena de proxychains desde un perfil JSON.
# Solo escribe capas de proxy (socks4/socks5/http); las capas 'vpn' se
# gestionan con lib/vpnctl.sh. No escribe credenciales en texto plano.
proxyctl_cascade_build() {
    local profile="${1:-}"
    [[ -r "${profile}" ]] || {
        log_error "Perfil no legible: ${profile:-<vacío>}"
        return 1
    }
    command -v jq >/dev/null 2>&1 || {
        log_error "cascade_build requiere 'jq' (apt install jq)."
        return 1
    }
    local conf mode dns t_read t_conn lines
    conf="$(_proxyctl_detect_conf_path || printf '%s' "${GHOST_PROXYCHAINS_CONF_SYSTEM}")"
    case "$(jq -r '.mode // "dynamic"' "${profile}")" in
        strict) mode="strict_chain" ;;
        random) mode="random_chain" ;;
        *) mode="dynamic_chain" ;;
    esac
    dns="$(jq -r '.dns // "proxy"' "${profile}")"
    t_read="$(jq -r '.timeout_read_ms // 15000' "${profile}")"
    t_conn="$(jq -r '.timeout_connect_ms // 8000' "${profile}")"
    lines="$(jq -r '.layers[]
        | select(.type=="socks4" or .type=="socks5" or .type=="http")
        | "\(.type) \(.host) \(.port)"' "${profile}" 2>/dev/null || true)"
    [[ -n "${lines}" ]] || {
        log_error "El perfil no define capas de proxy (socks4/socks5/http)."
        return 1
    }
    local content="# Ghost-Kali v5.0 — cascada generada desde $(basename "${profile}")"$'\n'
    content+="${mode}"$'\n'
    if [[ "${dns}" == "proxy" ]]; then
        content+="proxy_dns"$'\n'"remote_dns_subnet 224"$'\n'
    fi
    content+="tcp_read_time_out ${t_read}"$'\n'"tcp_connect_time_out ${t_conn}"$'\n\n'
    content+="[ProxyList]"$'\n'"${lines}"
    if ((_GHOST_PROXYCTL_DRY_RUN == 0)); then
        _proxyctl_confirm_action "¿Aplicar la cascada a ${conf}?" || {
            log_warn "Operación cancelada."
            return 1
        }
    fi
    _proxyctl_safe_write "${conf}" "${content}" || return 1
    log_warn "Capas 'vpn' del perfil se gestionan con lib/vpnctl.sh."
    log_warn "Proxies autenticados: añádalos con proxyctl_add_proxy; nunca ponga secretos en el perfil."
    _proxyctl_log_op "cascade_build" "$(basename "${profile}")"
    return 0
}

# B.02 — Selecciona el país del nodo de salida Tor. Operación de capa Tor:
# se delega a lib/torctl.sh. Afecta solo el egreso del tráfico propio.
proxyctl_spoof_geo() {
    if declare -F torctl_spoof_exit >/dev/null 2>&1; then
        torctl_spoof_exit "$@"
        return $?
    fi
    log_warn "Requiere lib/torctl.sh (capa Tor). Cárguelo y use torctl_spoof_exit <país>."
    return 1
}

# B.03 — Rota el nodo de salida periódicamente. Operación de capa Tor:
# se delega a lib/torctl.sh.
proxyctl_randomize_exit() {
    if declare -F torctl_randomize_exit >/dev/null 2>&1; then
        torctl_randomize_exit "$@"
        return $?
    fi
    log_warn "Requiere lib/torctl.sh (capa Tor). Cárguelo y use torctl_randomize_exit."
    return 1
}

# B.08 — Cambia la identidad de salida (NEWNYM + verificación). Capa Tor:
# se delega a lib/torctl.sh.
proxyctl_rotate_identity() {
    if declare -F torctl_rotate_identity >/dev/null 2>&1; then
        torctl_rotate_identity "$@"
        return $?
    fi
    log_warn "Requiere lib/torctl.sh (capa Tor). Cárguelo y use torctl_rotate_identity."
    return 1
}

# B.13 — Regenera el circuito Tor de la cadena. Capa Tor: se delega a torctl.
proxyctl_burn_chain() {
    if declare -F torctl_burn_circuit >/dev/null 2>&1; then
        torctl_burn_circuit "$@"
        return $?
    fi
    log_warn "Requiere lib/torctl.sh (capa Tor). Cárguelo y use torctl_burn_circuit."
    return 1
}

# B.16 — Exporta la bitácora de operaciones de la sesión (UTC|acción|resultado).
# --export json|csv imprime en el formato indicado; por defecto, legible.
proxyctl_engagement_log() {
    local fmt="texto" arg next
    local args=("$@")
    local idx=0
    while ((idx < ${#args[@]})); do
        arg="${args[idx]}"
        if [[ "${arg}" == "--export" ]]; then
            next=$((idx + 1))
            ((next < ${#args[@]})) && fmt="${args[next]}"
            idx=$((idx + 2))
            continue
        fi
        idx=$((idx + 1))
    done
    local n="${#_GHOST_PROXYCTL_OPLOG[@]}"
    if ((n == 0)); then
        log_info "Bitácora de sesión vacía."
        return 0
    fi
    local entry ts action result
    case "${fmt}" in
        json)
            printf '['
            local first=1
            for entry in "${_GHOST_PROXYCTL_OPLOG[@]}"; do
                ts="${entry%%|*}"
                result="${entry##*|}"
                action="${entry#*|}"
                action="${action%|*}"
                ((first)) || printf ','
                first=0
                printf '{"ts":"%s","action":"%s","result":"%s"}' "${ts}" "${action}" "${result}"
            done
            printf ']\n'
            ;;
        csv)
            printf 'ts,action,result\n'
            for entry in "${_GHOST_PROXYCTL_OPLOG[@]}"; do
                ts="${entry%%|*}"
                result="${entry##*|}"
                action="${entry#*|}"
                action="${action%|*}"
                printf '%s,%s,%s\n' "${ts}" "${action}" "${result}"
            done
            ;;
        *)
            for entry in "${_GHOST_PROXYCTL_OPLOG[@]}"; do
                printf '  %s\n' "${entry}"
            done
            ;;
    esac
    return 0
}

# ───────────────────────────────────────────────────────────────────────────
# Fin de lib/proxyctl.sh
# ───────────────────────────────────────────────────────────────────────────
