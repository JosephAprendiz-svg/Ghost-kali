#!/usr/bin/env bash
# shellcheck shell=bash

# ───────────────────────────────────────────────────────────────────────────
# GHOST-KALI v5.0 — lib/torctl.sh
# Módulo de control del daemon Tor — PERFIL DE ANONIMATO
# ───────────────────────────────────────────────────────────────────────────
#
# PROPÓSITO:
#   Controlar el servicio Tor del PROPIO equipo del operador y administrar el
#   anonimato del tráfico propio: estado del servicio, circuitos, selección de
#   país de salida, rotación de identidad, aislamiento de streams, detección de
#   fugas y endurecimiento de /etc/tor/torrc.
#
# ALCANCE:
#   Educación en seguridad y privacidad, hardening de la pila de anonimato
#   propia y verificación de fugas del propio equipo. TODAS las operaciones
#   configuran cómo egresa el tráfico PROPIO a través de Tor; ninguna explora,
#   ataca, pivotea hacia, ni evade las defensas de sistemas de terceros.
#
# NOTA SOBRE "SIMULACIÓN":
#   Las funciones de anonimato avanzado (selección de salida, rotación de
#   identidad, circuitos personalizados, aislamiento de streams) son
#   capacidades estándar y documentadas del cliente Tor. Se implementan como
#   lo que son —operaciones de privacidad sobre el tráfico propio— sin marco
#   de evasión, anti-forense ni acción contra objetivos externos.
#
# INVARIANTES DE SEGURIDAD:
#   · Solo se carga con 'source' (nunca se ejecuta como script).
#   · Ninguna modificación de torrc sin backup atómico previo.
#   · Toda operación destructiva respeta --dry-run y pide confirmación.
#   · Nunca imprime ni registra contraseñas, cookies, hashes ni datos sensibles.
#   · El módulo NO maneja contraseñas del ControlPort por diseño.
#   · Prohibidos: rm -rf, mkfs, dd, iptables -F, killall, pkill, eval, exec.
#
# CARGA:   source lib/torctl.sh
# DEPENDE: lib/colors.sh, lib/logger.sh, lib/validators.sh (con fallbacks).
# LICENCIA: MIT
# AUTOR:   Joseph (JosephAprendiz-svg)
# ───────────────────────────────────────────────────────────────────────────

# Guarda de ejecución directa: solo se permite 'source'.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "[FATAL] lib/torctl.sh debe cargarse con 'source', no ejecutarse directamente." >&2
    exit 1
fi

# Guarda de idempotencia: evitar carga múltiple.
if [[ -n "${_GHOST_TORCTL_LOADED:-}" ]]; then
    return 0
fi
readonly _GHOST_TORCTL_LOADED=1

# Modo estricto.
set -euo pipefail

# ───────────────────────────────────────────────────────────────────────────
# Carga de dependencias (módulos hermanos) con fallbacks inline.
# ───────────────────────────────────────────────────────────────────────────
_GHOST_TORCTL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)" ||
    _GHOST_TORCTL_DIR="."

for _dep in colors.sh logger.sh validators.sh; do
    if [[ -r "${_GHOST_TORCTL_DIR}/${_dep}" ]]; then
        # shellcheck source=/dev/null
        source "${_GHOST_TORCTL_DIR}/${_dep}"
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
    _ghost_torctl_log() {
        local level="$1"
        shift
        local threshold="${GHOST_LOG_LEVEL:-20}"
        ((level < threshold)) && return 0
        printf '%b\n' "$*" >&2
    }
    log_debug() { _ghost_torctl_log 10 "[DEBUG] $*"; }
    log_info() { _ghost_torctl_log 20 "[INFO ] $*"; }
    log_warn() { _ghost_torctl_log 30 "[WARN ] $*"; }
    log_error() { _ghost_torctl_log 40 "[ERROR] $*"; }
fi

# ───────────────────────────────────────────────────────────────────────────
# Constantes de configuración (readonly).
# ───────────────────────────────────────────────────────────────────────────
GHOST_TOR_SERVICE="tor"
readonly GHOST_TOR_SERVICE

GHOST_TORRC="/etc/tor/torrc"
readonly GHOST_TORRC

GHOST_TORRC_BACKUP_DIR="/var/backups/ghost-kali/tor"
readonly GHOST_TORRC_BACKUP_DIR

GHOST_TOR_SOCKS_HOST="127.0.0.1"
readonly GHOST_TOR_SOCKS_HOST

GHOST_TOR_SOCKS_PORT="9050"
readonly GHOST_TOR_SOCKS_PORT

GHOST_TOR_CONTROL_HOST="127.0.0.1"
readonly GHOST_TOR_CONTROL_HOST

GHOST_TOR_CONTROL_PORT="9051"
readonly GHOST_TOR_CONTROL_PORT

GHOST_TOR_CHECK_URL="https://check.torproject.org/api/ip"
readonly GHOST_TOR_CHECK_URL

GHOST_TOR_TIMEOUT="10"
readonly GHOST_TOR_TIMEOUT

# ───────────────────────────────────────────────────────────────────────────
# Estado interno (no readonly).
# ───────────────────────────────────────────────────────────────────────────
_GHOST_TORCTL_DRY_RUN=0         # 0 = real, 1 = simulación
_GHOST_TORCTL_NON_INTERACTIVE=0 # 0 = interactivo, 1 = automático
_GHOST_TORCTL_GHOST_BACKUP=""   # ruta del backup tomado por ghost_circuit --on
_GHOST_TORCTL_OPLOG=()          # bitácora de operaciones de la sesión

# ═══════════════════════════════════════════════════════════════════════════
# FUNCIONES PRIVADAS (_torctl_)
# ═══════════════════════════════════════════════════════════════════════════

# Verifica que estén disponibles las dependencias indicadas.
_torctl_check_dependencies() {
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
_torctl_is_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] && return 0
    return 1
}

# Registra una operación en la bitácora de la sesión (UTC|acción|resultado).
_torctl_log_op() {
    local action="${1:-?}"
    local result="${2:-?}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' '-')"
    _GHOST_TORCTL_OPLOG+=("${ts}|${action}|${result}")
    return 0
}

# Crea el directorio de backups con permisos 700. Imprime su ruta.
_torctl_create_backup_path() {
    local dir="${GHOST_TORRC_BACKUP_DIR}"
    if [[ ! -d "${dir}" ]]; then
        if ((_GHOST_TORCTL_DRY_RUN)); then
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
_torctl_latest_backup() {
    local base="${1:-${GHOST_TORRC}}"
    local dir="${GHOST_TORRC_BACKUP_DIR}"
    [[ -d "${dir}" ]] || return 1
    local name latest
    name="$(basename "${base}")"
    latest="$(find "${dir}" -maxdepth 1 -type f -name "${name}.*.bak" -printf '%T@ %p\n' 2>/dev/null |
        sort -rn | head -n1 | cut -d' ' -f2- || true)"
    [[ -n "${latest}" ]] || return 1
    printf '%s' "${latest}"
    return 0
}

# Crea backup con marca temporal ISO 8601 UTC. Imprime la ruta del backup.
_torctl_backup_config() {
    local ruta="${1:-${GHOST_TORRC}}"
    [[ -r "${ruta}" ]] || {
        log_error "No se puede leer para backup: ${ruta}"
        return 1
    }
    local dir ts name dest
    dir="$(_torctl_create_backup_path)" || return 1
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    name="$(basename "${ruta}")"
    dest="${dir}/${name}.${ts}.bak"
    if ((_GHOST_TORCTL_DRY_RUN)); then
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
_torctl_safe_write() {
    local target="${1:-}"
    local content="${2:-}"
    [[ -n "${target}" ]] || {
        log_error "safe_write: destino vacío"
        return 1
    }
    if ((_GHOST_TORCTL_DRY_RUN)); then
        log_info "[dry-run] Escribiría $((${#content})) bytes en ${target} (con backup previo)"
        return 0
    fi
    if [[ -e "${target}" ]]; then
        _torctl_backup_config "${target}" >/dev/null || {
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
_torctl_confirm_action() {
    local prompt="${1:-¿Continuar?}"
    if ((_GHOST_TORCTL_NON_INTERACTIVE)); then
        log_warn "Modo no interactivo: acción destructiva no confirmada; se aborta por seguridad."
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

# Mide la latencia (ms) de conexión TCP a un host:puerto LOCAL propio.
_torctl_measure_latency() {
    local host="${1:-${GHOST_TOR_SOCKS_HOST}}"
    local port="${2:-${GHOST_TOR_SOCKS_PORT}}"
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

# Comprueba conectividad TCP al puerto SOCKS local. Retorna 0 si responde.
_torctl_check_socks_port() {
    _torctl_measure_latency "${GHOST_TOR_SOCKS_HOST}" "${GHOST_TOR_SOCKS_PORT}" >/dev/null 2>&1
}

# Comprueba conectividad TCP al ControlPort local. Retorna 0 si responde.
_torctl_check_control_port() {
    _torctl_measure_latency "${GHOST_TOR_CONTROL_HOST}" "${GHOST_TOR_CONTROL_PORT}" >/dev/null 2>&1
}

# Envía un comando al ControlPort vía nc. Autentica con cookie/clave vacía
# (null auth). NO maneja contraseñas: si el ControlPort exige autenticación
# con secreto, se reporta el fallo y el operador debe autenticar por su cuenta.
_torctl_control_cmd() {
    local cmd="${1:-}"
    [[ -n "${cmd}" ]] || return 1
    command -v nc >/dev/null 2>&1 || {
        log_error "nc no disponible para hablar con el ControlPort"
        return 1
    }
    _torctl_check_control_port || {
        log_error "ControlPort ${GHOST_TOR_CONTROL_HOST}:${GHOST_TOR_CONTROL_PORT} no responde"
        return 1
    }
    local resp
    resp="$(printf 'AUTHENTICATE\r\n%s\r\nQUIT\r\n' "${cmd}" |
        nc -w "${GHOST_TOR_TIMEOUT}" "${GHOST_TOR_CONTROL_HOST}" "${GHOST_TOR_CONTROL_PORT}" 2>/dev/null || true)"
    if [[ -z "${resp}" ]]; then
        log_error "Sin respuesta del ControlPort"
        return 1
    fi
    if printf '%s' "${resp}" | grep -Eq '^5[0-9][0-9]|Authentication'; then
        log_error "Autenticación del ControlPort rechazada. Configure 'CookieAuthentication 1' y los permisos del grupo tor/debian-tor, o autentique manualmente. El módulo no maneja contraseñas por diseño."
        return 1
    fi
    printf '%s' "${resp}"
    return 0
}

# Normaliza un valor booleano: 1/yes/true/on -> 0; el resto -> 1.
_torctl_parse_bool() {
    case "${1,,}" in
        1 | yes | sí | si | true | on) return 0 ;;
        *) return 1 ;;
    esac
}

# Imprime torrc saneado: redacta hashes de control, cookies y secretos.
_torctl_sanitize_output() {
    local ruta="${1:-}"
    [[ -r "${ruta}" ]] || return 1
    awk '
        {
            line=$0
            low=tolower(line)
            if (low ~ /hashedcontrolpassword/) { print "HashedControlPassword <REDACTADO>"; next }
            if (low ~ /^[[:space:]]*bridge[[:space:]]/) {
                gsub(/cert=[^[:space:]]+/, "cert=<REDACTADO>", line)
                print line; next
            }
            if (line ~ /^[[:space:]]*#/) {
                if (low ~ /pass/ || low ~ /secret/ || low ~ /token/) {
                    gsub(/[Pp][Aa][Ss][Ss]([Ww][Oo][Rr][Dd])?[[:space:]]*[=:][[:space:]]*[^[:space:]]+/, "password=<REDACTADO>", line)
                    gsub(/[Ss][Ee][Cc][Rr][Ee][Tt][[:space:]]*[=:][[:space:]]*[^[:space:]]+/, "secret=<REDACTADO>", line)
                    gsub(/[Tt][Oo][Kk][Ee][Nn][[:space:]]*[=:][[:space:]]*[^[:space:]]+/, "token=<REDACTADO>", line)
                }
                print line; next
            }
            if (low ~ /password|secret|token|authcookie|controlsocket/) {
                n=split(line, a, /[[:space:]]+/)
                if (n>=1 && a[1] !~ /^#/) { printf "%s <REDACTADO>\n", a[1]; next }
            }
            print line
        }
    ' "${ruta}"
}

# Establece (o reemplaza la primera ocurrencia de) una directiva en torrc de
# forma idempotente. Si no existe, la añade al final. Backup atómico previo.
_torctl_torrc_set() {
    local ruta="${1:-}"
    local directive="${2:-}"
    local value="${3:-}"
    [[ -r "${ruta}" ]] || {
        log_error "No se puede leer torrc: ${ruta}"
        return 1
    }
    [[ -n "${directive}" ]] || return 1
    local newcontent
    newcontent="$(awk -v d="${directive}" -v v="${value}" '
        BEGIN { done=0 }
        {
            line=$0
            tmp=line
            sub(/^[[:space:]]+/, "", tmp)
            sub(/^#[[:space:]]*/, "", tmp)
            n=split(tmp, a, /[[:space:]]+/)
            if (!done && n>=1 && a[1]==d) {
                if (v=="") { print d } else { print d" "v }
                done=1
                next
            }
            print line
        }
        END {
            if (!done) {
                if (v=="") { print d } else { print d" "v }
            }
        }
    ' "${ruta}")"
    _torctl_safe_write "${ruta}" "${newcontent}"
}

# Comenta todas las líneas activas de una directiva. Backup atómico previo.
_torctl_torrc_comment() {
    local ruta="${1:-}"
    local directive="${2:-}"
    [[ -r "${ruta}" ]] || return 1
    [[ -n "${directive}" ]] || return 1
    local newcontent
    newcontent="$(awk -v d="${directive}" '
        {
            line=$0
            tmp=line
            sub(/^[[:space:]]+/, "", tmp)
            n=split(tmp, a, /[[:space:]]+/)
            if (n>=1 && a[1]==d && line !~ /^[[:space:]]*#/) {
                print "#"line
            } else {
                print line
            }
        }
    ' "${ruta}")"
    _torctl_safe_write "${ruta}" "${newcontent}"
}

# Consulta la IP de egreso a través del SOCKS de Tor. Imprime la IP.
_torctl_egress_ip() {
    command -v curl >/dev/null 2>&1 || return 1
    local out ip
    out="$(curl -s --socks5-hostname "${GHOST_TOR_SOCKS_HOST}:${GHOST_TOR_SOCKS_PORT}" \
        --max-time "${GHOST_TOR_TIMEOUT}" "${GHOST_TOR_CHECK_URL}" 2>/dev/null || true)"
    [[ -n "${out}" ]] || return 1
    ip="$(printf '%s' "${out}" |
        grep -oE '"IP"[[:space:]]*:[[:space:]]*"[^"]+"' |
        sed -E 's/.*"([0-9a-fA-F:.]+)".*/\1/' | head -n1 || true)"
    [[ -n "${ip}" ]] || return 1
    printf '%s' "${ip}"
    return 0
}

# Retorna 0 si la IP de egreso es reconocida como nodo Tor.
_torctl_egress_is_tor() {
    command -v curl >/dev/null 2>&1 || return 1
    local out
    out="$(curl -s --socks5-hostname "${GHOST_TOR_SOCKS_HOST}:${GHOST_TOR_SOCKS_PORT}" \
        --max-time "${GHOST_TOR_TIMEOUT}" "${GHOST_TOR_CHECK_URL}" 2>/dev/null || true)"
    [[ -n "${out}" ]] || return 1
    printf '%s' "${out}" | grep -qiE '"IsTor"[[:space:]]*:[[:space:]]*true' && return 0
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════
# BLOQUE A — OPERACIONES DEFENSIVAS / DE PRIVACIDAD
# ═══════════════════════════════════════════════════════════════════════════

# A.01 — Retorna 0 si tor y systemctl están disponibles.
torctl_is_installed() {
    command -v tor >/dev/null 2>&1 || return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    return 0
}

# A.03 — Imprime la versión del binario tor.
torctl_get_version() {
    command -v tor >/dev/null 2>&1 || {
        printf '%s' "no instalado"
        return 1
    }
    local v
    v="$(tor --version 2>/dev/null | grep -oiE 'version[^0-9]*[0-9][0-9a-z.\-]*' | head -n1 || true)"
    [[ -n "${v}" ]] || v="versión desconocida"
    printf '%s' "${v}"
    return 0
}

# A.04 — Retorna 0 si el servicio tor está activo.
torctl_is_running() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl is-active --quiet "${GHOST_TOR_SERVICE}" && return 0
    return 1
}

# A.10 — Imprime host:puerto del SOCKS de Tor.
torctl_get_socks() {
    printf '%s:%s' "${GHOST_TOR_SOCKS_HOST}" "${GHOST_TOR_SOCKS_PORT}"
    return 0
}

# A.11 — Imprime host:puerto del ControlPort de Tor.
torctl_get_control() {
    printf '%s:%s' "${GHOST_TOR_CONTROL_HOST}" "${GHOST_TOR_CONTROL_PORT}"
    return 0
}

# A.12 — Prueba conectividad TCP al puerto SOCKS de Tor.
torctl_check_socks() {
    if _torctl_check_socks_port; then
        log_info "SOCKS ${GHOST_TOR_SOCKS_HOST}:${GHOST_TOR_SOCKS_PORT} responde."
        return 0
    fi
    log_warn "SOCKS ${GHOST_TOR_SOCKS_HOST}:${GHOST_TOR_SOCKS_PORT} no responde."
    return 1
}

# A.13 — Prueba conectividad TCP al ControlPort de Tor.
torctl_check_control() {
    if _torctl_check_control_port; then
        log_info "ControlPort ${GHOST_TOR_CONTROL_HOST}:${GHOST_TOR_CONTROL_PORT} responde."
        return 0
    fi
    log_warn "ControlPort ${GHOST_TOR_CONTROL_HOST}:${GHOST_TOR_CONTROL_PORT} no responde."
    return 1
}

# A.05 — Inicia el servicio tor. Respeta --dry-run y pide confirmación.
torctl_start() {
    torctl_is_installed || {
        log_error "Tor no está instalado."
        return 1
    }
    if ((_GHOST_TORCTL_DRY_RUN)); then
        log_info "[dry-run] systemctl start ${GHOST_TOR_SERVICE}"
        return 0
    fi
    _torctl_is_root || {
        log_error "Se requieren privilegios root (use sudo) para gestionar el servicio."
        return 1
    }
    _torctl_confirm_action "¿Iniciar el servicio ${GHOST_TOR_SERVICE}?" || {
        log_warn "Operación cancelada."
        return 1
    }
    systemctl start "${GHOST_TOR_SERVICE}" || {
        log_error "No se pudo iniciar ${GHOST_TOR_SERVICE}."
        return 1
    }
    log_info "Servicio ${GHOST_TOR_SERVICE} iniciado."
    _torctl_log_op "start" "ok"
    return 0
}

# A.06 — Detiene el servicio tor. Respeta --dry-run y pide confirmación.
torctl_stop() {
    torctl_is_installed || {
        log_error "Tor no está instalado."
        return 1
    }
    if ((_GHOST_TORCTL_DRY_RUN)); then
        log_info "[dry-run] systemctl stop ${GHOST_TOR_SERVICE}"
        return 0
    fi
    _torctl_is_root || {
        log_error "Se requieren privilegios root (use sudo) para gestionar el servicio."
        return 1
    }
    _torctl_confirm_action "¿Detener el servicio ${GHOST_TOR_SERVICE}? Perderá el anonimato Tor." || {
        log_warn "Operación cancelada."
        return 1
    }
    systemctl stop "${GHOST_TOR_SERVICE}" || {
        log_error "No se pudo detener ${GHOST_TOR_SERVICE}."
        return 1
    }
    log_info "Servicio ${GHOST_TOR_SERVICE} detenido."
    _torctl_log_op "stop" "ok"
    return 0
}

# A.07 — Reinicia el servicio tor. Respeta --dry-run y pide confirmación.
torctl_restart() {
    torctl_is_installed || {
        log_error "Tor no está instalado."
        return 1
    }
    if ((_GHOST_TORCTL_DRY_RUN)); then
        log_info "[dry-run] systemctl restart ${GHOST_TOR_SERVICE}"
        return 0
    fi
    _torctl_is_root || {
        log_error "Se requieren privilegios root (use sudo) para gestionar el servicio."
        return 1
    }
    _torctl_confirm_action "¿Reiniciar el servicio ${GHOST_TOR_SERVICE}?" || {
        log_warn "Operación cancelada."
        return 1
    }
    systemctl restart "${GHOST_TOR_SERVICE}" || {
        log_error "No se pudo reiniciar ${GHOST_TOR_SERVICE}."
        return 1
    }
    log_info "Servicio ${GHOST_TOR_SERVICE} reiniciado."
    _torctl_log_op "restart" "ok"
    return 0
}

# A.08 — Habilita el inicio automático de tor. Respeta --dry-run.
torctl_enable() {
    torctl_is_installed || {
        log_error "Tor no está instalado."
        return 1
    }
    if ((_GHOST_TORCTL_DRY_RUN)); then
        log_info "[dry-run] systemctl enable ${GHOST_TOR_SERVICE}"
        return 0
    fi
    _torctl_is_root || {
        log_error "Se requieren privilegios root (use sudo)."
        return 1
    }
    systemctl enable "${GHOST_TOR_SERVICE}" >/dev/null 2>&1 || {
        log_error "No se pudo habilitar ${GHOST_TOR_SERVICE}."
        return 1
    }
    log_info "Inicio automático de ${GHOST_TOR_SERVICE} habilitado."
    _torctl_log_op "enable" "ok"
    return 0
}

# A.09 — Deshabilita el inicio automático de tor. Respeta --dry-run.
torctl_disable() {
    torctl_is_installed || {
        log_error "Tor no está instalado."
        return 1
    }
    if ((_GHOST_TORCTL_DRY_RUN)); then
        log_info "[dry-run] systemctl disable ${GHOST_TOR_SERVICE}"
        return 0
    fi
    _torctl_is_root || {
        log_error "Se requieren privilegios root (use sudo)."
        return 1
    }
    systemctl disable "${GHOST_TOR_SERVICE}" >/dev/null 2>&1 || {
        log_error "No se pudo deshabilitar ${GHOST_TOR_SERVICE}."
        return 1
    }
    log_info "Inicio automático de ${GHOST_TOR_SERVICE} deshabilitado."
    _torctl_log_op "disable" "ok"
    return 0
}

# A.14 — Fuerza un nuevo circuito Tor (SIGNAL NEWNYM) vía ControlPort.
torctl_newnym() {
    if ((_GHOST_TORCTL_DRY_RUN)); then
        log_info "[dry-run] SIGNAL NEWNYM al ControlPort"
        return 0
    fi
    if _torctl_control_cmd "SIGNAL NEWNYM" >/dev/null; then
        log_info "Nuevo circuito solicitado (NEWNYM)."
        _torctl_log_op "newnym" "ok"
        return 0
    fi
    log_error "No se pudo enviar NEWNYM."
    _torctl_log_op "newnym" "fallo"
    return 1
}

# A.15 — Obtiene información del circuito actual (GETINFO circuit-status).
torctl_get_circuit_info() {
    local resp
    resp="$(_torctl_control_cmd "GETINFO circuit-status" || true)"
    if [[ -z "${resp}" ]]; then
        log_warn "Sin información de circuitos (ControlPort no disponible o sin autenticación)."
        return 1
    fi
    printf '%s\n' "${resp}" | grep -vE '^250 OK|^250\+circuit-status=|^\.$' || true
    return 0
}

# A.16 — Verifica que la IP de egreso sea un nodo Tor consultando el servicio
# oficial de Tor a través del propio SOCKS.
torctl_is_exit_reachable() {
    _torctl_check_socks_port || {
        log_warn "SOCKS local no responde; no se puede verificar el egreso."
        return 1
    }
    local ip
    ip="$(_torctl_egress_ip || true)"
    if [[ -z "${ip}" ]]; then
        log_warn "No se obtuvo IP de egreso."
        return 1
    fi
    if _torctl_egress_is_tor; then
        log_info "Egreso por Tor confirmado. IP: ${ip}"
        return 0
    fi
    log_warn "La IP de egreso (${ip}) NO se reconoce como nodo Tor."
    return 1
}

# A.17 — Muestra torrc saneado (sin secretos).
torctl_show_config() {
    local ruta="${1:-${GHOST_TORRC}}"
    [[ -r "${ruta}" ]] || {
        log_error "No se puede leer: ${ruta}"
        return 1
    }
    printf '%b\n' "${C_INFO}Configuración Tor (saneada): ${ruta}${C_RESET}"
    _torctl_sanitize_output "${ruta}"
    return 0
}

# A.18 — Valida que torrc exista, sea legible y defina SocksPort o ControlPort.
torctl_validate_config() {
    local ruta="${1:-${GHOST_TORRC}}"
    [[ -e "${ruta}" ]] || {
        log_error "No existe: ${ruta}"
        return 1
    }
    [[ -r "${ruta}" ]] || {
        log_error "No legible: ${ruta}"
        return 1
    }
    if grep -Eiq '^[[:space:]]*(SocksPort|ControlPort)\b' "${ruta}"; then
        log_info "torrc válido: define SocksPort o ControlPort."
        return 0
    fi
    log_warn "torrc no define SocksPort ni ControlPort explícitos (Tor usará valores por defecto)."
    return 1
}

# A.19 — Crea backup de torrc con marca temporal ISO 8601 UTC.
torctl_backup_config() {
    local ruta="${1:-${GHOST_TORRC}}"
    local dest
    dest="$(_torctl_backup_config "${ruta}")" || {
        log_error "Backup falló."
        return 1
    }
    log_info "Backup creado: ${dest}"
    _torctl_log_op "backup_config" "ok:${dest}"
    return 0
}

# A.20 — Lista backups y restaura el más reciente, previa confirmación.
torctl_restore_config() {
    local ruta="${1:-${GHOST_TORRC}}"
    local latest
    latest="$(_torctl_latest_backup "${ruta}" || true)"
    if [[ -z "${latest}" ]]; then
        log_error "No hay backups para $(basename "${ruta}")."
        return 1
    fi
    log_info "Backups disponibles para $(basename "${ruta}"):"
    find "${GHOST_TORRC_BACKUP_DIR}" -maxdepth 1 -type f \
        -name "$(basename "${ruta}").*.bak" 2>/dev/null | sort -r | sed 's/^/  /' >&2 || true
    log_info "Más reciente: ${latest}"
    if ((_GHOST_TORCTL_DRY_RUN)); then
        log_info "[dry-run] Restauraría ${latest} -> ${ruta}"
        return 0
    fi
    _torctl_confirm_action "¿Restaurar ${ruta} desde el backup más reciente?" || {
        log_warn "Restauración cancelada."
        return 1
    }
    _torctl_backup_config "${ruta}" >/dev/null 2>&1 || true
    cat "${latest}" >"${ruta}" || {
        log_error "Restauración falló."
        return 1
    }
    log_info "Configuración restaurada desde ${latest}"
    _torctl_log_op "restore_config" "ok:${latest}"
    return 0
}

# A.21 — Habilita o modifica ControlPort en torrc (idempotente). Backup previo.
torctl_set_control_port() {
    local ruta="${1:-${GHOST_TORRC}}"
    local host="${2:-${GHOST_TOR_CONTROL_HOST}}"
    local port="${3:-${GHOST_TOR_CONTROL_PORT}}"
    if ! [[ "${port}" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
        log_error "Puerto inválido: ${port}"
        return 1
    fi
    log_info "Estableciendo ControlPort ${host}:${port} en ${ruta}"
    _torctl_torrc_set "${ruta}" "ControlPort" "${host}:${port}" || return 1
    _torctl_log_op "set_control_port" "${host}:${port}"
    return 0
}

# A.22 — Habilita o modifica SocksPort en torrc (idempotente). Backup previo.
torctl_set_socks_port() {
    local ruta="${1:-${GHOST_TORRC}}"
    local host="${2:-${GHOST_TOR_SOCKS_HOST}}"
    local port="${3:-${GHOST_TOR_SOCKS_PORT}}"
    if ! [[ "${port}" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
        log_error "Puerto inválido: ${port}"
        return 1
    fi
    log_info "Estableciendo SocksPort ${host}:${port} en ${ruta}"
    _torctl_torrc_set "${ruta}" "SocksPort" "${host}:${port}" || return 1
    _torctl_log_op "set_socks_port" "${host}:${port}"
    return 0
}

# A.23 — Habilita el mecanismo de bridges obfs4 (idempotente). Backup previo.
# No inserta líneas Bridge concretas: el operador debe añadir sus propios
# bridges (p. ej. desde bridges.torproject.org).
torctl_enable_bridges() {
    local ruta="${1:-${GHOST_TORRC}}"
    log_info "Habilitando mecanismo de bridges obfs4 en ${ruta}"
    _torctl_torrc_set "${ruta}" "UseBridges" "1" || return 1
    _torctl_torrc_set "${ruta}" "ClientTransportPlugin" "obfs4 exec /usr/bin/obfs4proxy" || return 1
    log_warn "Añada sus propias líneas 'Bridge obfs4 ...' obtenidas de fuentes oficiales."
    _torctl_log_op "enable_bridges" "ok"
    return 0
}

# A.24 — Deshabilita el mecanismo de bridges (comenta directivas). Backup previo.
torctl_disable_bridges() {
    local ruta="${1:-${GHOST_TORRC}}"
    log_info "Deshabilitando bridges en ${ruta}"
    _torctl_torrc_comment "${ruta}" "UseBridges" || return 1
    _torctl_torrc_comment "${ruta}" "ClientTransportPlugin" || return 1
    _torctl_log_op "disable_bridges" "ok"
    return 0
}

# A.25 — Detecta fugas locales: IPv6 global, DNS no local, aviso WebRTC.
torctl_detect_leaks() {
    local issues=0

    # a) IPv6 global activo (scope 00 en /proc/net/if_inet6).
    if [[ -r /proc/net/if_inet6 ]]; then
        if awk '$4=="00"{f=1} END{exit !f}' /proc/net/if_inet6 2>/dev/null; then
            log_warn "[IPv6] Hay direcciones IPv6 globales activas; Tor puede no enrutarlas. Considere deshabilitar IPv6 o forzar su paso por Tor."
            issues=$((issues + 1))
        else
            log_info "[IPv6] Sin direcciones IPv6 globales activas."
        fi
    else
        log_info "[IPv6] /proc/net/if_inet6 no disponible; omitido."
    fi

    # b) DNS no local en /etc/resolv.conf.
    if [[ -r /etc/resolv.conf ]]; then
        local bad_dns
        bad_dns="$(grep -E '^[[:space:]]*nameserver' /etc/resolv.conf 2>/dev/null |
            awk '{print $2}' |
            grep -vE '^(127\.|::1$)' || true)"
        if [[ -n "${bad_dns}" ]]; then
            log_warn "[DNS] Resolvers no locales detectados (posible fuga): $(printf '%s' "${bad_dns}" | tr '\n' ' ')"
            issues=$((issues + 1))
        else
            log_info "[DNS] Solo resolvers locales en resolv.conf."
        fi
    fi

    # c) WebRTC: aviso (no verificable desde shell).
    log_info "[WebRTC] Si usa navegador, verifique que WebRTC esté deshabilitado para evitar exposición de IP local."

    if ((issues > 0)); then
        log_warn "Detección de fugas: ${issues} hallazgo(s) que requieren atención."
        return 1
    fi
    log_info "Detección de fugas: sin hallazgos locales."
    return 0
}

# A.26 — Imprime una configuración hardening recomendada (no escribe nada).
torctl_recommend_config() {
    cat <<'EOF'
# ── Configuración Tor recomendada (hardening de privacidad) ──
SocksPort 127.0.0.1:9050
ControlPort 127.0.0.1:9051
CookieAuthentication 1
SafeSocks 1
TestSocks 1
WarnUnsafeSocks 1
StrictNodes 0
EnforceDistinctSubnets 1
# Aislamiento de streams (mejora la imposibilidad de correlación):
SocksPort 127.0.0.1:9050 IsolateDestAddr IsolateDestPort
# Minimiza el registro local:
Log notice file /dev/null
# Bridges (opcional, si su red censura Tor):
# UseBridges 1
# ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy
# Bridge obfs4 <obtenga el suyo en bridges.torproject.org>
EOF
    return 0
}

# A.27 — Monitorea la latencia del SOCKS de Tor (--live = continuo).
torctl_monitor_socks() {
    local live=0 arg
    for arg in "$@"; do
        [[ "${arg}" == "--live" ]] && live=1
    done
    local iterations=1 i=0 ms
    ((live)) && iterations=0
    while :; do
        ms="$(_torctl_measure_latency "${GHOST_TOR_SOCKS_HOST}" "${GHOST_TOR_SOCKS_PORT}" 2>/dev/null)" || ms="-1"
        if [[ "${ms}" == "-1" ]]; then
            printf '%b %s\n' "${C_DANGER}[CAÍDO]${C_RESET}" \
                "SOCKS ${GHOST_TOR_SOCKS_HOST}:${GHOST_TOR_SOCKS_PORT} sin respuesta"
        else
            printf '%b %s\n' "${C_SUCCESS}[ OK ]${C_RESET}" \
                "SOCKS ${GHOST_TOR_SOCKS_HOST}:${GHOST_TOR_SOCKS_PORT} — ${ms} ms"
        fi
        if ((iterations > 0)); then
            i=$((i + 1))
            ((i >= iterations)) && break
        fi
        sleep 2
    done
    return 0
}

# A.02 — Panel de estado operativo de Tor.
torctl_status_panel() {
    local installed="NO" version="-" running="DETENIDO" socks="-" control="-"
    local egress="-" bridges="DESACTIVADOS" backup="-" leaks="-"

    if torctl_is_installed; then
        installed="SÍ"
        version="$(torctl_get_version 2>/dev/null || printf '%s' '-')"
    fi
    torctl_is_running && running="ACTIVO"
    _torctl_check_socks_port && socks="${GHOST_TOR_SOCKS_HOST}:${GHOST_TOR_SOCKS_PORT} (OK)" ||
        socks="${GHOST_TOR_SOCKS_HOST}:${GHOST_TOR_SOCKS_PORT} (sin respuesta)"
    _torctl_check_control_port && control="${GHOST_TOR_CONTROL_HOST}:${GHOST_TOR_CONTROL_PORT} (OK)" ||
        control="${GHOST_TOR_CONTROL_HOST}:${GHOST_TOR_CONTROL_PORT} (sin respuesta)"

    if _torctl_check_socks_port; then
        local ip
        ip="$(_torctl_egress_ip 2>/dev/null || true)"
        [[ -n "${ip}" ]] && egress="${ip}"
    fi

    if [[ -r "${GHOST_TORRC}" ]] && grep -Eiq '^[[:space:]]*UseBridges[[:space:]]+1' "${GHOST_TORRC}"; then
        bridges="ACTIVADOS"
    fi

    local latest
    latest="$(_torctl_latest_backup "${GHOST_TORRC}" 2>/dev/null || true)"
    [[ -n "${latest}" ]] && backup="$(basename "${latest}")"

    printf '%b\n' "${C_PRIMARY}${C_BOLD}GHOST-KALI v5.0 — TORCTL STATUS${C_RESET}"
    printf '%b\n' "${C_DIM}──────────────────────────────────────────────${C_RESET}"
    printf '   %-18s %b\n' "Servicio Tor:" "${running} (${version})"
    printf '   %-18s %s\n' "Instalado:" "${installed}"
    printf '   %-18s %s\n' "SocksPort:" "${socks}"
    printf '   %-18s %s\n' "ControlPort:" "${control}"
    printf '   %-18s %s\n' "IP de Egreso:" "${egress}"
    printf '   %-18s %s\n' "Bridges:" "${bridges}"
    printf '   %-18s %s\n' "Último Backup:" "${backup}"
    printf '%b\n' "${C_DIM}──────────────────────────────────────────────${C_RESET}"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# BLOQUE B — ANONIMATO AVANZADO (operaciones sobre el tráfico PROPIO)
# ───────────────────────────────────────────────────────────────────────────
# Estas funciones configuran cómo egresa el tráfico propio a través de Tor.
# Son capacidades estándar del cliente Tor (selección de salida, rotación de
# identidad, circuitos personalizados, aislamiento de streams). No actúan
# contra objetivos externos ni evaden defensas de terceros.
# ═══════════════════════════════════════════════════════════════════════════

# B.01 — Selecciona el país del nodo de salida Tor (ExitNodes {cc}).
# Afecta únicamente por dónde egresa el tráfico propio. Backup + confirmación.
torctl_spoof_exit() {
    local country="${1:-}"
    local ruta="${2:-${GHOST_TORRC}}"
    if ! [[ "${country}" =~ ^[A-Za-z]{2}$ ]]; then
        log_error "Código de país inválido (use ISO de 2 letras, p. ej. 'de', 'ch')."
        return 1
    fi
    country="${country,,}"
    log_info "Configurando ExitNodes {${country}} con StrictNodes."
    if ((_GHOST_TORCTL_DRY_RUN == 0)); then
        _torctl_confirm_action "¿Fijar el país de salida a '${country}'? (reduce el anonimato)" || {
            log_warn "Operación cancelada."
            return 1
        }
    fi
    _torctl_torrc_set "${ruta}" "ExitNodes" "{${country}}" || return 1
    _torctl_torrc_set "${ruta}" "StrictNodes" "1" || return 1
    log_info "Recargue Tor (torctl_restart) para aplicar. Verifique con torctl_is_exit_reachable."
    _torctl_log_op "set_exit_country" "${country}"
    return 0
}

# B.02 — Rota el circuito (NEWNYM) cada N segundos para reducir correlación.
# Bucle hasta interrupción (Ctrl-C). No fija país; mantiene selección de Tor.
torctl_randomize_exit() {
    local interval=60 arg next
    local args=("$@")
    local idx=0
    while ((idx < ${#args[@]})); do
        arg="${args[idx]}"
        if [[ "${arg}" == "--pool" ]]; then
            next=$((idx + 1))
            if ((next < ${#args[@]})) && [[ "${args[next]}" =~ ^[0-9]+$ ]]; then
                interval="${args[next]}"
                idx=$((idx + 2))
                continue
            fi
        fi
        idx=$((idx + 1))
    done
    ((interval < 10)) && interval=10
    if ((_GHOST_TORCTL_DRY_RUN)); then
        log_info "[dry-run] Rotaría el circuito cada ${interval}s (NEWNYM)."
        return 0
    fi
    log_info "Rotando circuito cada ${interval}s. Ctrl-C para detener."
    while :; do
        torctl_newnym || log_warn "NEWNYM falló en esta iteración."
        sleep "${interval}"
    done
}

# B.03 — Construye un circuito con nodos preferidos (EntryNodes/ExitNodes).
# NODOS: "entrada,salida" como códigos de país de 2 letras o fingerprints.
# Vía torrc con StrictNodes. Backup + confirmación.
torctl_build_custom_circuit() {
    local nodos="${1:-}"
    local ruta="${2:-${GHOST_TORRC}}"
    [[ -n "${nodos}" ]] || {
        log_error "Indique nodos: 'entrada,salida' (códigos de país o fingerprints)."
        return 1
    }
    local entry exit_node
    entry="$(printf '%s' "${nodos}" | cut -d',' -f1)"
    exit_node="$(printf '%s' "${nodos}" | cut -d',' -f2)"
    [[ -n "${entry}" && -n "${exit_node}" ]] || {
        log_error "Formato inválido. Use 'entrada,salida'."
        return 1
    }
    # Normaliza códigos de país a {cc}; deja fingerprints tal cual.
    [[ "${entry}" =~ ^[A-Za-z]{2}$ ]] && entry="{${entry,,}}"
    [[ "${exit_node}" =~ ^[A-Za-z]{2}$ ]] && exit_node="{${exit_node,,}}"
    if ((_GHOST_TORCTL_DRY_RUN == 0)); then
        _torctl_confirm_action "¿Fijar EntryNodes=${entry} ExitNodes=${exit_node}? (reduce el anonimato)" || {
            log_warn "Operación cancelada."
            return 1
        }
    fi
    _torctl_torrc_set "${ruta}" "EntryNodes" "${entry}" || return 1
    _torctl_torrc_set "${ruta}" "ExitNodes" "${exit_node}" || return 1
    _torctl_torrc_set "${ruta}" "StrictNodes" "1" || return 1
    log_info "Recargue Tor para aplicar. Para fijar el nodo intermedio exacto use el ControlPort (EXTENDCIRCUIT)."
    _torctl_log_op "build_custom_circuit" "${entry}->${exit_node}"
    return 0
}

# B.04 — Cambia la identidad de salida: NEWNYM y verifica nueva IP de egreso.
# Equivale a "Nueva identidad" del Tor Browser.
torctl_rotate_identity() {
    local force=0 arg
    for arg in "$@"; do
        [[ "${arg}" == "--force" ]] && force=1
    done
    if ((_GHOST_TORCTL_DRY_RUN)); then
        log_info "[dry-run] NEWNYM + verificación de nueva IP de egreso."
        return 0
    fi
    local before after
    before="$(_torctl_egress_ip 2>/dev/null || true)"
    torctl_newnym || {
        log_error "No se pudo rotar la identidad."
        return 1
    }
    ((force)) && _torctl_control_cmd "SIGNAL CLEARDNSCACHE" >/dev/null 2>&1 || true
    sleep 5
    after="$(_torctl_egress_ip 2>/dev/null || true)"
    if [[ -n "${after}" && "${before}" != "${after}" ]]; then
        log_info "Identidad rotada. IP de egreso: ${before:-?} -> ${after}"
    else
        log_warn "Identidad solicitada; la IP de egreso no cambió aún (puede tardar) o no se pudo verificar."
    fi
    _torctl_log_op "rotate_identity" "${before:-?}->${after:-?}"
    return 0
}

# B.05 — Perfil efímero de máxima privacidad sobre el propio cliente Tor.
# --on aplica nodos estrictos, aislamiento de streams y registro local mínimo;
# --off restaura la configuración previa. NO es anti-forense ni evasión: solo
# reduce la huella de registro del propio equipo y endurece el anonimato.
torctl_ghost_circuit() {
    local action="${1:-}"
    local ruta="${2:-${GHOST_TORRC}}"
    case "${action}" in
        --on)
            log_info "Activando perfil efímero de privacidad en ${ruta}"
            if ((_GHOST_TORCTL_DRY_RUN == 0)); then
                _torctl_confirm_action "¿Aplicar perfil de máxima privacidad (registro local mínimo)?" || {
                    log_warn "Operación cancelada."
                    return 1
                }
                _GHOST_TORCTL_GHOST_BACKUP="$(_torctl_backup_config "${ruta}" 2>/dev/null || true)"
            fi
            _torctl_torrc_set "${ruta}" "StrictNodes" "1" || return 1
            _torctl_torrc_set "${ruta}" "EnforceDistinctSubnets" "1" || return 1
            _torctl_torrc_set "${ruta}" "SocksPort" \
                "${GHOST_TOR_SOCKS_HOST}:${GHOST_TOR_SOCKS_PORT} IsolateDestAddr IsolateDestPort" || return 1
            _torctl_torrc_set "${ruta}" "Log" "notice file /dev/null" || return 1
            torctl_newnym >/dev/null 2>&1 || true
            log_info "Perfil aplicado. Recargue Tor para que surta efecto. Use '--off' para restaurar."
            _torctl_log_op "ghost_circuit" "on"
            ;;
        --off)
            if [[ -n "${_GHOST_TORCTL_GHOST_BACKUP}" && -r "${_GHOST_TORCTL_GHOST_BACKUP}" ]]; then
                if ((_GHOST_TORCTL_DRY_RUN)); then
                    log_info "[dry-run] Restauraría ${_GHOST_TORCTL_GHOST_BACKUP} -> ${ruta}"
                    return 0
                fi
                cat "${_GHOST_TORCTL_GHOST_BACKUP}" >"${ruta}" || {
                    log_error "No se pudo restaurar el perfil previo."
                    return 1
                }
                log_info "Configuración previa restaurada."
                _GHOST_TORCTL_GHOST_BACKUP=""
            else
                log_warn "No hay backup de sesión; use torctl_restore_config para restaurar manualmente."
            fi
            torctl_newnym >/dev/null 2>&1 || true
            _torctl_log_op "ghost_circuit" "off"
            ;;
        *)
            log_error "Uso: torctl_ghost_circuit --on|--off [ruta]"
            return 1
            ;;
    esac
    return 0
}

# B.06 — Aísla streams por destino (IsolateDestAddr/IsolateDestPort).
# Función de privacidad: dificulta la correlación entre conexiones.
torctl_isolate_streams() {
    local ruta="${1:-${GHOST_TORRC}}"
    log_info "Aplicando aislamiento de streams en ${ruta}"
    _torctl_torrc_set "${ruta}" "SocksPort" \
        "${GHOST_TOR_SOCKS_HOST}:${GHOST_TOR_SOCKS_PORT} IsolateDestAddr IsolateDestPort" || return 1
    log_info "Recargue Tor para aplicar el aislamiento de streams."
    _torctl_log_op "isolate_streams" "ok"
    return 0
}

# B.07 — Destruye el circuito actual y solicita uno nuevo (NEWNYM + limpieza DNS).
torctl_burn_circuit() {
    if ((_GHOST_TORCTL_DRY_RUN)); then
        log_info "[dry-run] NEWNYM + CLEARDNSCACHE"
        return 0
    fi
    local ok=0
    torctl_newnym && ok=1
    _torctl_control_cmd "SIGNAL CLEARDNSCACHE" >/dev/null 2>&1 || true
    if ((ok)); then
        log_info "Circuito regenerado y caché DNS de Tor limpiada."
        _torctl_log_op "burn_circuit" "ok"
        return 0
    fi
    log_warn "No se pudo regenerar el circuito (ControlPort no disponible)."
    _torctl_log_op "burn_circuit" "fallo"
    return 1
}

# B.08 — Exporta la bitácora de operaciones de la sesión (UTC|acción|resultado).
# --export json|csv imprime en el formato indicado; por defecto, legible.
torctl_engagement_log() {
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

    local n="${#_GHOST_TORCTL_OPLOG[@]}"
    if ((n == 0)); then
        log_info "Bitácora de sesión vacía."
        return 0
    fi

    local entry ts action result
    case "${fmt}" in
        json)
            printf '['
            local first=1
            for entry in "${_GHOST_TORCTL_OPLOG[@]}"; do
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
            for entry in "${_GHOST_TORCTL_OPLOG[@]}"; do
                ts="${entry%%|*}"
                result="${entry##*|}"
                action="${entry#*|}"
                action="${action%|*}"
                printf '%s,%s,%s\n' "${ts}" "${action}" "${result}"
            done
            ;;
        *)
            for entry in "${_GHOST_TORCTL_OPLOG[@]}"; do
                printf '  %s\n' "${entry}"
            done
            ;;
    esac
    return 0
}

# ───────────────────────────────────────────────────────────────────────────
# Fin de lib/torctl.sh
# ───────────────────────────────────────────────────────────────────────────
