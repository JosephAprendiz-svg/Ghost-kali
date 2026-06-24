#!/usr/bin/env bash
# shellcheck shell=bash

# ───────────────────────────────────────────────────────────────────────────
# GHOST-KALI v5.0 — lib/proxyctl.sh
# Módulo de gestión de Proxychains — PERFIL DEFENSIVO
# ───────────────────────────────────────────────────────────────────────────
#
# PROPÓSITO:
#   Administrar, auditar y endurecer cadenas de proxies (VPN → Tor → SOCKS/HTTP)
#   en el SISTEMA PROPIO del operador. Operaciones de SOLO LECTURA salvo las de
#   configuración, que siempre crean backup atómico previo y respetan --dry-run.
#
# ALCANCE:
#   Educación en seguridad, hardening de la pila de privacidad propia y
#   verificación de fugas del propio equipo. NO incluye emulación de adversario,
#   evasión de defensas, movimiento lateral, pivoteo ni anti-forense.
#
# INVARIANTES DE SEGURIDAD:
#   · Solo se carga con 'source' (nunca se ejecuta como script).
#   · Ninguna modificación de configuración sin backup atómico previo.
#   · Toda operación destructiva respeta --dry-run y pide confirmación.
#   · Nunca imprime ni registra credenciales, tokens ni datos sensibles.
#   · Prohibidos: rm -rf, mkfs, dd, iptables -F, killall, pkill, eval, exec.
#
# CARGA:   source lib/proxyctl.sh
# DEPENDE: lib/colors.sh, lib/logger.sh, lib/validators.sh (con fallbacks).
# LICENCIA: MIT
# AUTOR:   Joseph (JosephAprendiz-svg)
# ───────────────────────────────────────────────────────────────────────────

# Guarda de ejecución directa: solo se permite 'source'.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "[FATAL] lib/proxyctl.sh debe cargarse con 'source', no ejecutarse directamente." >&2
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

for _dep in colors.sh logger.sh validators.sh; do
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
GHOST_PROXYCHAINS_CONFS=(
    "/etc/proxychains4.conf"
    "/etc/proxychains.conf"
    "/etc/ghost-kali/proxychains.conf"
    "${HOME:-/root}/.proxychains/proxychains.conf"
)
readonly GHOST_PROXYCHAINS_CONFS

GHOST_PROXYCHAINS_BACKUP_DIR="/var/backups/ghost-kali/proxychains"
readonly GHOST_PROXYCHAINS_BACKUP_DIR

GHOST_TOR_SOCKS_HOST="127.0.0.1"
readonly GHOST_TOR_SOCKS_HOST

GHOST_TOR_SOCKS_PORT="9050"
readonly GHOST_TOR_SOCKS_PORT

GHOST_TOR_CONTROL_HOST="127.0.0.1"
readonly GHOST_TOR_CONTROL_HOST

GHOST_TOR_CONTROL_PORT="9051"
readonly GHOST_TOR_CONTROL_PORT

GHOST_PROXYCHAINS_TEST_URL="https://check.torproject.org/api/ip"
readonly GHOST_PROXYCHAINS_TEST_URL

GHOST_PROXYCHAINS_TEST_TIMEOUT="10"
readonly GHOST_PROXYCHAINS_TEST_TIMEOUT

# ───────────────────────────────────────────────────────────────────────────
# Estado interno (no readonly).
# ───────────────────────────────────────────────────────────────────────────
_GHOST_PROXYCTL_DRY_RUN=0         # 0 = real, 1 = simulación
_GHOST_PROXYCTL_NON_INTERACTIVE=0 # 0 = interactivo, 1 = automático

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

# Localiza el primer archivo de configuración legible. Imprime su ruta.
_proxyctl_find_config() {
    local conf
    for conf in "${GHOST_PROXYCHAINS_CONFS[@]}"; do
        if [[ -r "${conf}" ]]; then
            printf '%s' "${conf}"
            return 0
        fi
    done
    return 1
}

# Verifica la presencia de la sección [ProxyList].
_proxyctl_has_proxylist() {
    local conf="${1:-}"
    [[ -r "${conf}" ]] || return 1
    grep -Eiq '^[[:space:]]*\[ProxyList\]' "${conf}" && return 0
    return 1
}

# Detecta el tipo de proxy a partir de la primera palabra de una línea.
_proxyctl_detect_proxy_type() {
    local first="${1:-}"
    case "${first,,}" in
        socks5) printf '%s' "socks5" ;;
        socks4) printf '%s' "socks4" ;;
        http) printf '%s' "http" ;;
        https) printf '%s' "https" ;;
        raw) printf '%s' "raw" ;;
        *)
            printf '%s' "desconocido"
            return 1
            ;;
    esac
    return 0
}

# Imprime la configuración saneada: redacta usuario/clave en líneas de proxy.
_proxyctl_sanitize_config() {
    local conf="${1:-}"
    [[ -r "${conf}" ]] || return 1
    awk '
        /^[[:space:]]*\[ProxyList\]/ { inlist=1; print; next }
        /^[[:space:]]*\[/ { inlist=0 }
        {
            # Líneas de comentario: redactar credenciales en formato clave=valor
            # o clave: valor, alineado con la heurística de security_audit. No se
            # reconstruye el espaciado original solo en las líneas saneadas.
            if ($0 ~ /^[[:space:]]*#/) {
                line=$0
                low=tolower(line)
                if (low ~ /pass/ || low ~ /secret/ || low ~ /token/) {
                    gsub(/[Pp][Aa][Ss][Ss]([Ww][Oo][Rr][Dd])?[[:space:]]*[=:][[:space:]]*[^[:space:]]+/, "password=<REDACTADO>", line)
                    gsub(/[Ss][Ee][Cc][Rr][Ee][Tt][[:space:]]*[=:][[:space:]]*[^[:space:]]+/, "secret=<REDACTADO>", line)
                    gsub(/[Tt][Oo][Kk][Ee][Nn][[:space:]]*[=:][[:space:]]*[^[:space:]]+/, "token=<REDACTADO>", line)
                }
                print line
                next
            }
            if (inlist && NF>=5) {
                t=tolower($1)
                if (t=="socks4"||t=="socks5"||t=="http"||t=="https"||t=="raw") {
                    $4="<REDACTADO>"; $5="<REDACTADO>"
                }
            }
            print
        }
    ' "${conf}"
}

# Asegura el directorio de backups. Imprime su ruta.
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

# Retorna la ruta del backup más reciente para una configuración dada.
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
    if [[ -e "${target}" ]]; then
        proxyctl_backup_config "${target}" >/dev/null || {
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
_proxyctl_measure_latency() {
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

# ═══════════════════════════════════════════════════════════════════════════
# BLOQUE A — OPERACIONES DEFENSIVAS
# ═══════════════════════════════════════════════════════════════════════════

# A.01 — Retorna 0 si proxychains está instalado.
proxyctl_is_installed() {
    command -v proxychains4 >/dev/null 2>&1 && return 0
    command -v proxychains >/dev/null 2>&1 && return 0
    return 1
}

# A.13 — Extrae host:puerto del primer proxy en [ProxyList].
proxyctl_get_proxy_target() {
    local conf="${1:-}"
    [[ -r "${conf}" ]] || {
        log_error "No legible: ${conf}"
        return 1
    }
    local line host port
    line="$(awk '
        /^[[:space:]]*\[ProxyList\]/ { inlist=1; next }
        /^[[:space:]]*\[/ { inlist=0 }
        inlist && $1 !~ /^#/ && NF>=3 {
            t=tolower($1)
            if (t=="socks4"||t=="socks5"||t=="http"||t=="https"||t=="raw") { print $2" "$3; exit }
        }
    ' "${conf}")"
    [[ -n "${line}" ]] || {
        log_warn "Sin proxies en [ProxyList]"
        return 1
    }
    host="${line%% *}"
    port="${line##* }"
    printf '%s:%s' "${host}" "${port}"
    return 0
}

# A.07 — Extrae el modo de cadena activo: strict | dynamic | random | none.
proxyctl_get_chain_mode() {
    local conf="${1:-}"
    [[ -r "${conf}" ]] || {
        log_error "No legible: ${conf}"
        return 1
    }
    local mode="none"
    if grep -Eiq '^[[:space:]]*strict_chain' "${conf}"; then
        mode="strict"
    elif grep -Eiq '^[[:space:]]*dynamic_chain' "${conf}"; then
        mode="dynamic"
    elif grep -Eiq '^[[:space:]]*random_chain' "${conf}"; then
        mode="random"
    fi
    printf '%s' "${mode}"
    return 0
}

# A.04 — Valida integridad de un archivo de configuración.
proxyctl_validate_config() {
    local conf="${1:-}"
    [[ -n "${conf}" ]] || {
        log_error "Ruta requerida"
        return 2
    }
    if [[ ! -f "${conf}" ]]; then
        log_error "No existe: ${conf}"
        return 1
    fi
    if [[ ! -r "${conf}" ]]; then
        log_error "No legible: ${conf}"
        return 1
    fi
    if ! _proxyctl_has_proxylist "${conf}"; then
        log_error "Falta la sección [ProxyList]"
        return 1
    fi
    local proxies
    proxies="$(awk '
        /^[[:space:]]*\[ProxyList\]/ { inlist=1; next }
        /^[[:space:]]*\[/ { inlist=0 }
        inlist && $1 !~ /^#/ && NF>=3 {
            t=tolower($1)
            if (t=="socks4"||t=="socks5"||t=="http"||t=="https"||t=="raw") c++
        }
        END { print c+0 }
    ' "${conf}")"
    if ((proxies < 1)); then
        log_error "Sin entradas de proxy válidas en [ProxyList]"
        return 1
    fi
    log_info "Configuración válida: ${conf} (${proxies} proxy/proxies)"
    return 0
}

# A.03 — Lista archivos de configuración candidatos con existencia y permisos.
proxyctl_list_configs() {
    local conf perms estado
    printf '%b\n' "${C_INFO}Archivos de configuración candidatos:${C_RESET}"
    for conf in "${GHOST_PROXYCHAINS_CONFS[@]}"; do
        if [[ -e "${conf}" ]]; then
            perms="$(stat -c '%a' "${conf}" 2>/dev/null || printf '%s' '???')"
            estado="${C_SUCCESS}existe${C_RESET} (perms ${perms})"
        else
            estado="${C_DIM}ausente${C_RESET}"
        fi
        printf '  %b  %s\n' "${estado}" "${conf}"
    done
    return 0
}

# A.12 — Muestra configuración saneada; advierte sobre hosts no locales.
proxyctl_show_config() {
    local conf="${1:-}"
    [[ -r "${conf}" ]] || {
        log_error "No legible: ${conf}"
        return 1
    }
    printf '%b\n' "${C_INFO}Configuración (saneada): ${conf}${C_RESET}"
    _proxyctl_sanitize_config "${conf}"
    local nonlocal h
    nonlocal="$(awk '
        /^[[:space:]]*\[ProxyList\]/ { inlist=1; next }
        /^[[:space:]]*\[/ { inlist=0 }
        inlist && $1 !~ /^#/ && NF>=3 {
            t=tolower($1)
            if (t=="socks4"||t=="socks5"||t=="http"||t=="https"||t=="raw") {
                if ($2 !~ /^127\./ && $2 != "localhost") print $2
            }
        }
    ' "${conf}" | sort -u)"
    if [[ -n "${nonlocal}" ]]; then
        log_warn "Proxies con host no local detectados:"
        while IFS= read -r h; do
            [[ -n "${h}" ]] && log_warn "  host no local: ${h}"
        done <<<"${nonlocal}"
    fi
    return 0
}

# A.14 — Imprime tabla comparativa de modos de cadena.
proxyctl_chain_modes() {
    printf '%b\n' "${C_INFO}Modos de cadena de Proxychains:${C_RESET}"
    printf '  %-9s %s\n' "strict" "Usa todos los proxies en orden; si uno cae, falla. (Más seguro)"
    printf '  %-9s %s\n' "dynamic" "Usa los proxies vivos en orden; omite los caídos."
    printf '  %-9s %s\n' "random" "Elige un proxy aleatorio de la lista por conexión."
    printf '  %-9s %s\n' "none" "Sin modo explícito; comportamiento por defecto."
    return 0
}

# A.06 — Sugiere configuración óptima según el entorno.
proxyctl_recommend_config() {
    printf '%b\n' "${C_INFO}Recomendación de configuración:${C_RESET}"
    local tor_ok="no"
    if _proxyctl_measure_latency "${GHOST_TOR_SOCKS_HOST}" "${GHOST_TOR_SOCKS_PORT}" >/dev/null 2>&1; then
        tor_ok="sí"
    fi
    printf '  Tor SOCKS %s:%s respondiendo: %s\n' \
        "${GHOST_TOR_SOCKS_HOST}" "${GHOST_TOR_SOCKS_PORT}" "${tor_ok}"
    printf '%s\n' "  Configuración recomendada:"
    printf '%s\n' "    strict_chain            (cadena predecible y verificable)"
    printf '%s\n' "    proxy_dns               (evita fugas DNS)"
    printf '%s\n' "    remote_dns_subnet 224"
    printf '%s\n' "    tcp_read_time_out 15000"
    printf '%s\n' "    tcp_connect_time_out 8000"
    printf '%s\n' "    [ProxyList] socks5 127.0.0.1 9050   (Tor)"
    return 0
}

# A.09 — Crea backup con marca temporal ISO 8601 (UTC). Imprime la ruta.
proxyctl_backup_config() {
    local conf="${1:-}"
    [[ -n "${conf}" ]] || {
        log_error "Ruta requerida"
        return 2
    }
    [[ -e "${conf}" ]] || {
        log_error "No existe: ${conf}"
        return 1
    }
    local dir ts base dest
    dir="$(_proxyctl_create_backup_path)" || return 1
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    base="$(basename "${conf}")"
    dest="${dir}/${base}.${ts}.bak"
    if ((_GHOST_PROXYCTL_DRY_RUN)); then
        log_info "[dry-run] cp -p ${conf} ${dest}"
        return 0
    fi
    cp -p -- "${conf}" "${dest}" || {
        log_error "Backup falló"
        return 1
    }
    chmod 600 "${dest}" 2>/dev/null || true
    log_info "Backup creado: ${dest}"
    printf '%s' "${dest}"
    return 0
}

# A.10 — Restaura desde el backup más reciente (con confirmación).
proxyctl_restore_config() {
    local conf="${1:-}"
    [[ -n "${conf}" ]] || {
        log_error "Ruta requerida"
        return 2
    }
    local latest
    if ! latest="$(_proxyctl_latest_backup "${conf}")"; then
        log_error "No hay backups para $(basename "${conf}") en ${GHOST_PROXYCHAINS_BACKUP_DIR}"
        return 1
    fi
    log_info "Backup más reciente: ${latest}"
    _proxyctl_confirm_action "¿Restaurar ${conf} desde ${latest}?" || {
        log_warn "Restauración cancelada"
        return 1
    }
    if ((_GHOST_PROXYCTL_DRY_RUN)); then
        log_info "[dry-run] cp -p ${latest} ${conf}"
        return 0
    fi
    cp -p -- "${latest}" "${conf}" || {
        log_error "Restauración falló"
        return 1
    }
    log_info "Restaurado: ${conf}"
    return 0
}

# A.08 — Asigna el modo de cadena (backup atómico previo; respeta --dry-run).
proxyctl_set_chain_mode() {
    local conf="${1:-}" mode="${2:-}"
    [[ -n "${conf}" && -n "${mode}" ]] || {
        log_error "Uso: proxyctl_set_chain_mode <ruta> <strict|dynamic|random>"
        return 2
    }
    [[ -r "${conf}" ]] || {
        log_error "No legible: ${conf}"
        return 1
    }
    case "${mode}" in
        strict | dynamic | random) : ;;
        *)
            log_error "Modo inválido: ${mode}"
            return 2
            ;;
    esac
    local content
    content="$(awk -v want="${mode}_chain" '
        {
            if ($0 ~ /^[[:space:]]*#?[[:space:]]*(strict|dynamic|random)_chain[[:space:]]*$/) {
                key=$0; gsub(/[#[:space:]]/,"",key)
                if (key==want) print want; else print "#" key
                next
            }
            print
        }
    ' "${conf}")"
    if ! grep -Eq "^${mode}_chain$" <<<"${content}"; then
        content="${mode}_chain"$'\n'"${content}"
    fi
    log_info "Asignando modo de cadena: ${mode}"
    _proxyctl_safe_write "${conf}" "${content}"
}

# A.11 — Aplica plantilla segura predefinida (backup obligatorio).
proxyctl_apply_template() {
    local dry=0 arg conf=""
    for arg in "$@"; do
        case "${arg}" in
            --dry-run) dry=1 ;;
            *) [[ -z "${conf}" ]] && conf="${arg}" ;;
        esac
    done
    if [[ -z "${conf}" ]]; then
        conf="$(_proxyctl_find_config 2>/dev/null || printf '%s' '/etc/proxychains4.conf')"
    fi
    local template
    template="$(
        cat <<'TPL'
# Ghost-Kali :: plantilla segura de proxychains
strict_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000

[ProxyList]
socks5 127.0.0.1 9050
TPL
    )"
    if ((dry || _GHOST_PROXYCTL_DRY_RUN)); then
        log_info "[dry-run] Aplicaría plantilla segura a ${conf}:"
        printf '%s\n' "${template}"
        return 0
    fi
    _proxyctl_confirm_action "¿Sobrescribir ${conf} con la plantilla segura? (backup previo)" || {
        log_warn "Cancelado"
        return 1
    }
    _proxyctl_safe_write "${conf}" "${template}"
}

# A.15 — Auditoría de seguridad de la configuración propia.
proxyctl_security_audit() {
    local conf="${1:-}"
    if [[ -z "${conf}" ]]; then
        conf="$(_proxyctl_find_config)" || {
            log_error "No se encontró configuración"
            return 1
        }
    fi
    [[ -r "${conf}" ]] || {
        log_error "No legible: ${conf}"
        return 1
    }
    local http_count nonlocal_count proxy_dns creds_count perms risk="BAJO"
    read -r http_count nonlocal_count proxy_dns creds_count < <(awk '
        BEGIN { http=0; nonlocal=0; pdns=0; creds=0 }
        /^[[:space:]]*\[ProxyList\]/ { inlist=1 }
        /^[[:space:]]*\[/ { if ($0 !~ /ProxyList/) inlist=0 }
        /^[[:space:]]*proxy_dns([[:space:]]|$)/ { pdns=1 }
        {
            if (inlist && $1 !~ /^#/ && NF>=3) {
                t=tolower($1)
                if (t=="http") http++
                if ((t=="socks4"||t=="socks5"||t=="http"||t=="https") && $2 !~ /^127\./ && $2!="localhost") nonlocal++
            }
            low=tolower($0)
            if ($0 ~ /^[[:space:]]*#/ && (low ~ /pass/ || low ~ /passwd/ || low ~ /secret/ || low ~ /token/)) creds++
        }
        END { printf "%d %d %d %d\n", http, nonlocal, pdns, creds }
    ' "${conf}")
    perms="$(stat -c '%a' "${conf}" 2>/dev/null || printf '%s' '???')"

    printf '%b\n' "${C_INFO}Auditoría de seguridad: ${conf}${C_RESET}"
    printf '  %-32s %-9s %s\n' "CHECK" "RIESGO" "ESTADO"
    printf '  %s\n' "------------------------------------------------------------"

    if ((http_count > 0)); then
        printf '  %-32s %b %s\n' "Proxies HTTP en claro" "${C_DANGER}ALTO   ${C_RESET}" "${http_count} detectado(s)"
        risk="ALTO"
    else
        printf '  %-32s %b %s\n' "Proxies HTTP en claro" "${C_SUCCESS}ALTO   ${C_RESET}" "ninguno"
    fi

    if ((nonlocal_count > 0)); then
        printf '  %-32s %b %s\n' "IPs públicas fuera de Tor" "${C_DANGER}CRÍTICO${C_RESET}" "${nonlocal_count} host(s) no local(es)"
        risk="CRÍTICO"
    else
        printf '  %-32s %b %s\n' "IPs públicas fuera de Tor" "${C_SUCCESS}CRÍTICO${C_RESET}" "ninguna"
    fi

    if ((proxy_dns)); then
        printf '  %-32s %b %s\n' "proxy_dns activo" "${C_INFO}BAJO   ${C_RESET}" "activado"
    else
        printf '  %-32s %b %s\n' "proxy_dns activo" "${C_WARNING}BAJO   ${C_RESET}" "desactivado (posible fuga DNS)"
        [[ "${risk}" == "BAJO" ]] && risk="MEDIO"
    fi

    if ((creds_count > 0)); then
        printf '  %-32s %b %s\n' "Credenciales en comentarios" "${C_DANGER}CRÍTICO${C_RESET}" "${creds_count} línea(s) sospechosa(s)"
        risk="CRÍTICO"
    else
        printf '  %-32s %b %s\n' "Credenciales en comentarios" "${C_SUCCESS}CRÍTICO${C_RESET}" "ninguna"
    fi

    if [[ "${perms}" == "600" || "${perms}" == "640" ]]; then
        printf '  %-32s %b %s\n' "Permisos de archivo" "${C_INFO}MEDIO  ${C_RESET}" "${perms}"
    else
        printf '  %-32s %b %s\n' "Permisos de archivo" "${C_WARNING}MEDIO  ${C_RESET}" "${perms} (recomendado 600)"
        [[ "${risk}" == "BAJO" ]] && risk="MEDIO"
    fi

    printf '  %s\n' "------------------------------------------------------------"
    case "${risk}" in
        BAJO) printf '  %-32s %b\n' "RIESGO GLOBAL" "${C_SUCCESS}BAJO${C_RESET}" ;;
        MEDIO) printf '  %-32s %b\n' "RIESGO GLOBAL" "${C_WARNING}MEDIO${C_RESET}" ;;
        ALTO) printf '  %-32s %b\n' "RIESGO GLOBAL" "${C_WARNING}ALTO${C_RESET}" ;;
        CRÍTICO) printf '  %-32s %b\n' "RIESGO GLOBAL" "${C_DANGER}CRÍTICO${C_RESET}" ;;
        *) : ;;
    esac
    return 0
}

# A.16 — Hardening automático de la configuración propia (backup previo).
proxyctl_harden_config() {
    local conf="${1:-}"
    [[ -n "${conf}" ]] || {
        log_error "Ruta requerida"
        return 2
    }
    [[ -r "${conf}" ]] || {
        log_error "No legible: ${conf}"
        return 1
    }
    _proxyctl_confirm_action "¿Aplicar hardening a ${conf}? (se hará backup previo)" || {
        log_warn "Cancelado"
        return 1
    }
    local content
    content="$(awk '
        {
            line=$0
            if ($0 ~ /^[[:space:]]*\[ProxyList\]/) { inlist=1; print line; next }
            if ($0 ~ /^[[:space:]]*\[/) { inlist=0; print line; next }
            if ($0 ~ /^[[:space:]]*#?[[:space:]]*dynamic_chain[[:space:]]*$/) { print "#dynamic_chain"; next }
            if ($0 ~ /^[[:space:]]*#?[[:space:]]*random_chain[[:space:]]*$/)  { print "#random_chain"; next }
            if ($0 ~ /^[[:space:]]*#?[[:space:]]*strict_chain[[:space:]]*$/)  { print "strict_chain"; next }
            if ($0 ~ /^[[:space:]]*#?[[:space:]]*proxy_dns[[:space:]]*$/)     { print "proxy_dns"; had_pdns=1; next }
            if ($0 ~ /^[[:space:]]*#?[[:space:]]*remote_dns_subnet[[:space:]]+/) { print "remote_dns_subnet 224"; had_subnet=1; next }
            if ($0 ~ /^[[:space:]]*#?[[:space:]]*tcp_read_time_out[[:space:]]+/) { print "tcp_read_time_out 15000"; had_tcpr=1; next }
            if ($0 ~ /^[[:space:]]*#?[[:space:]]*tcp_connect_time_out[[:space:]]+/) { print "tcp_connect_time_out 8000"; had_tcpc=1; next }
            if (inlist && $1 !~ /^#/ && NF>=3 && tolower($1)=="http") {
                print "# [hardening] proxy http en claro deshabilitado: " line; next
            }
            print line
        }
        END {
            if (!had_pdns)   print "proxy_dns"
            if (!had_subnet) print "remote_dns_subnet 224"
            if (!had_tcpr)   print "tcp_read_time_out 15000"
            if (!had_tcpc)   print "tcp_connect_time_out 8000"
        }
    ' "${conf}")"
    if ! grep -Eq '^strict_chain$' <<<"${content}"; then
        content="strict_chain"$'\n'"${content}"
    fi
    log_info "Aplicando hardening defensivo a ${conf}"
    _proxyctl_safe_write "${conf}" "${content}"
}

# A.17 — Detección de fugas del propio sistema (DNS / IPv6 / WebRTC).
proxyctl_detect_leaks() {
    local deep=0 arg
    for arg in "$@"; do
        [[ "${arg}" == "--deep" ]] && deep=1
    done
    printf '%b\n' "${C_INFO}Detección de fugas (auto-test del sistema propio):${C_RESET}"

    if ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
        log_warn "IPv6 global presente: si la cadena no cubre IPv6, puede haber fuga. Considera forzar IPv4 o deshabilitar IPv6."
    else
        log_info "Sin direcciones IPv6 globales activas."
    fi

    local conf
    if conf="$(_proxyctl_find_config)"; then
        if grep -Eq '^[[:space:]]*proxy_dns([[:space:]]|$)' "${conf}"; then
            log_info "proxy_dns activado en ${conf} (mitiga fugas DNS)."
        else
            log_warn "proxy_dns NO activado en ${conf}: riesgo de fuga DNS."
        fi
    fi

    log_info "WebRTC: no evaluable desde la shell; verifícalo en el navegador (about:webrtc / ipleak.net)."

    if ((deep)); then
        _proxyctl_confirm_action "El modo --deep contactará ${GHOST_PROXYCHAINS_TEST_URL} a través de la cadena. ¿Continuar?" || {
            log_warn "Prueba profunda cancelada."
            return 0
        }
        _proxyctl_check_dependencies curl || return 1
        proxyctl_is_installed || {
            log_error "proxychains no instalado."
            return 1
        }
        local pc
        pc="$(command -v proxychains4 || command -v proxychains)"
        log_info "Consultando IP de egreso vía cadena..."
        "${pc}" -q curl -s --max-time "${GHOST_PROXYCHAINS_TEST_TIMEOUT}" "${GHOST_PROXYCHAINS_TEST_URL}" 2>/dev/null ||
            log_warn "No se obtuvo respuesta del endpoint de prueba."
        printf '\n'
    fi
    return 0
}

# A.05 — Prueba de conectividad de la cadena (real requiere confirmación).
proxyctl_test_chain() {
    local dry=0 arg
    for arg in "$@"; do
        [[ "${arg}" == "--dry-run" ]] && dry=1
    done
    proxyctl_is_installed || {
        log_error "proxychains no instalado."
        return 1
    }
    local pc
    pc="$(command -v proxychains4 || command -v proxychains)"
    local -a cmd=("${pc}" -q curl -s --max-time "${GHOST_PROXYCHAINS_TEST_TIMEOUT}" "${GHOST_PROXYCHAINS_TEST_URL}")
    if ((dry || _GHOST_PROXYCTL_DRY_RUN)); then
        log_info "[dry-run] Orden: ${cmd[*]}"
        return 0
    fi
    _proxyctl_confirm_action "¿Ejecutar prueba de conectividad a ${GHOST_PROXYCHAINS_TEST_URL} vía cadena?" || {
        log_warn "Cancelado."
        return 1
    }
    _proxyctl_check_dependencies curl || return 1
    log_info "Probando cadena..."
    if "${cmd[@]}"; then
        printf '\n'
        log_info "Cadena operativa."
        return 0
    fi
    log_error "La prueba de cadena falló."
    return 1
}

# A.18 — Verifica que el tráfico a UN destino egrese por la cadena (single-target).
proxyctl_verify_egress() {
    local target="${1:-}"
    [[ -n "${target}" ]] || {
        log_error "Uso: proxyctl_verify_egress <host:puerto>"
        return 2
    }
    local host="${target%:*}" port="${target##*:}"
    [[ -n "${host}" && "${port}" =~ ^[0-9]{1,5}$ ]] || {
        log_error "Formato inválido; se espera host:puerto"
        return 2
    }
    proxyctl_is_installed || {
        log_error "proxychains no instalado."
        return 1
    }
    _proxyctl_confirm_action "¿Verificar egreso hacia ${host}:${port} a través de la cadena?" || {
        log_warn "Cancelado."
        return 1
    }
    _proxyctl_check_dependencies nc || return 1
    local pc
    pc="$(command -v proxychains4 || command -v proxychains)"
    if "${pc}" -q nc -z -w "${GHOST_PROXYCHAINS_TEST_TIMEOUT}" "${host}" "${port}" >/dev/null 2>&1; then
        log_info "Conexión a ${host}:${port} exitosa por la cadena (egreso vía proxy confirmado)."
        return 0
    fi
    log_warn "No se pudo conectar a ${host}:${port} a través de la cadena."
    return 1
}

# A.19 — Fuerza un nuevo circuito Tor (NEWNYM).
proxyctl_rotate_circuit() {
    if declare -F torctl_newnym >/dev/null 2>&1; then
        torctl_newnym
        return $?
    fi
    if ! command -v nc >/dev/null 2>&1; then
        log_error "Se requiere 'nc' o lib/torctl.sh para rotar el circuito."
        return 1
    fi
    log_info "Solicitando nuevo circuito Tor (NEWNYM)..."
    local resp
    resp="$(printf 'AUTHENTICATE ""\r\nSIGNAL NEWNYM\r\nQUIT\r\n' |
        nc -w 3 "${GHOST_TOR_CONTROL_HOST}" "${GHOST_TOR_CONTROL_PORT}" 2>/dev/null || true)"
    if grep -q '250' <<<"${resp}"; then
        log_info "Nuevo circuito Tor solicitado."
        return 0
    fi
    log_warn "No se confirmó NEWNYM. ¿ControlPort ${GHOST_TOR_CONTROL_PORT} habilitado con auth por cookie/none?"
    return 1
}

# A.20 — Lanza una aplicación propia bajo proxychains.
proxyctl_isolate_app() {
    local bin="${1:-}"
    shift || true
    [[ -n "${bin}" ]] || {
        log_error "Uso: proxyctl_isolate_app <binario> [args...]"
        return 2
    }
    command -v "${bin}" >/dev/null 2>&1 || {
        log_error "Binario no encontrado: ${bin}"
        return 1
    }
    proxyctl_is_installed || {
        log_error "proxychains no instalado."
        return 1
    }
    local pc
    pc="$(command -v proxychains4 || command -v proxychains)"
    if ((_GHOST_PROXYCTL_DRY_RUN)); then
        log_info "[dry-run] ${pc} -q ${bin} $*"
        return 0
    fi
    log_info "Lanzando ${bin} bajo proxychains..."
    "${pc}" -q "${bin}" "$@"
}

# A.21 — Monitorea latencia y estado del SOCKS de Tor (--live = continuo).
proxyctl_monitor_chain() {
    local live=0 arg
    for arg in "$@"; do
        [[ "${arg}" == "--live" ]] && live=1
    done
    local iterations=1 i=0 ms
    ((live)) && iterations=0
    while :; do
        ms="$(_proxyctl_measure_latency "${GHOST_TOR_SOCKS_HOST}" "${GHOST_TOR_SOCKS_PORT}")" || ms="-1"
        if [[ "${ms}" == "-1" ]]; then
            printf '%b %s\n' "${C_DANGER}[CAÍDO]${C_RESET}" \
                "Tor SOCKS ${GHOST_TOR_SOCKS_HOST}:${GHOST_TOR_SOCKS_PORT} sin respuesta"
        else
            printf '%b %s\n' "${C_SUCCESS}[ OK ]${C_RESET}" \
                "Tor SOCKS ${GHOST_TOR_SOCKS_HOST}:${GHOST_TOR_SOCKS_PORT} — ${ms} ms"
        fi
        if ((iterations > 0)); then
            i=$((i + 1))
            ((i >= iterations)) && break
        fi
        sleep 2
    done
    return 0
}

# A.02 — Panel de estado operativo.
proxyctl_status_panel() {
    local installed="NO" version="-" conf="-" mode="-" target="-" tor="-" backup="-"
    if proxyctl_is_installed; then
        installed="SÍ"
        local pc
        pc="$(command -v proxychains4 || command -v proxychains)"
        version="$("${pc}" 2>&1 | grep -oiE 'proxychains[^0-9]*[0-9.]+' | head -n1 || true)"
        [[ -n "${version}" ]] || version="versión desconocida"
    fi
    if conf="$(_proxyctl_find_config 2>/dev/null)"; then
        mode="$(proxyctl_get_chain_mode "${conf}" 2>/dev/null || printf '%s' '-')"
        target="$(proxyctl_get_proxy_target "${conf}" 2>/dev/null || printf '%s' '-')"
    else
        conf="(ninguna)"
    fi
    local ms
    ms="$(_proxyctl_measure_latency "${GHOST_TOR_SOCKS_HOST}" "${GHOST_TOR_SOCKS_PORT}" 2>/dev/null)" || ms="-1"
    if [[ "${ms}" == "-1" ]]; then
        tor="SIN RESPUESTA"
    else
        tor="RESPONDIENDO (${ms} ms)"
    fi
    local latest
    latest="$(_proxyctl_latest_backup "${conf}" 2>/dev/null || true)"
    if [[ -n "${latest}" ]]; then
        backup="$(basename "${latest}")"
    else
        backup="(ninguno)"
    fi

    printf '%b\n' "${C_PRIMARY}┌──────────────────────────────────────────────┐${C_RESET}"
    printf '%b %b\n' "${C_PRIMARY}│${C_RESET}" "${C_BOLD}GHOST-KALI v5.0 — PROXYCTL STATUS${C_RESET}"
    printf '%b\n' "${C_PRIMARY}├──────────────────────────────────────────────┤${C_RESET}"
    printf '   Proxychains:    %s (%s)\n' "${installed}" "${version}"
    printf '   Config activa:  %s\n' "${conf}"
    printf '   Modo cadena:    %s\n' "${mode}"
    printf '   Proxy objetivo: %s\n' "${target}"
    printf '   Tor SOCKS:      %s\n' "${tor}"
    printf '   Último backup:  %s\n' "${backup}"
    printf '%b\n' "${C_PRIMARY}└──────────────────────────────────────────────┘${C_RESET}"
    return 0
}
