#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  lib/validators.sh — Validaciones y health check de Ghost-Kali
# ──────────────────────────────────────────────────────────────────────────────
#  Comprobaciones de solo lectura (NO modifican el sistema):
#    check_root · check_deps · check_network · check_tor_config
#    check_proxychains_config · check_mullvad_logged_in · check_disk_space
#    check_kernel_params · check_file_permissions
#  Agregadores:
#    run_health_check (resumen humano) · generate_health_report (JSON)
#
#  ⚖️  DISCLAIMER: Ghost-Kali es una herramienta 100% defensiva, solo para fines
#      educativos, auditorías autorizadas e investigación responsable.
#
#  LIBRERÍA: cargar con `source`, no ejecutar. Depende de colors.sh y logger.sh.
# ──────────────────────────────────────────────────────────────────────────────

# ── Guarda de ejecución directa ───────────────────────────────────────────────
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    printf 'Este archivo es una librería y debe cargarse con «source», no ejecutarse.\n' >&2
    printf 'Uso: source lib/validators.sh\n' >&2
    exit 1
fi

# ── Guarda de idempotencia ────────────────────────────────────────────────────
[[ -n ${_GHOST_VALIDATORS_LOADED:-} ]] && return 0
_GHOST_VALIDATORS_LOADED=1

# ── Dependencias: logger.sh (que a su vez carga colors.sh) ─────────────────────
if [[ -z ${_GHOST_LOGGER_LOADED:-} ]]; then
    _ghost_lib_dir=${BASH_SOURCE[0]%/*}
    if [[ -f ${_ghost_lib_dir}/logger.sh ]]; then
        # shellcheck source=lib/logger.sh
        source "${_ghost_lib_dir}/logger.sh"
    fi
fi
# Fallbacks mínimos si el logger no estuviera disponible: validators siempre debe
# poder ejecutarse, aunque sea con una salida sencilla.
if ! declare -F log_info >/dev/null 2>&1; then
    log_info() { printf 'INFO  %s\n' "$*"; }
    log_ok() { printf 'OK    %s\n' "$*"; }
    log_warn() { printf 'WARN  %s\n' "$*" >&2; }
    log_error() { printf 'ERROR %s\n' "$*" >&2; }
    log_debug() { :; }
    log_section() { printf '\n== %s ==\n' "$*"; }
    log_table() { while [[ $# -ge 2 ]]; do
        printf '  %s: %s\n' "$1" "$2"
        shift 2
    done; }
fi

# ── Configuración (respeta valores definidos por el usuario antes de cargar) ───
[[ -z ${GHOST_DEPS_REQUIRED+x} ]] &&
    GHOST_DEPS_REQUIRED=(mullvad tor proxychains4 curl nc systemctl jq)
[[ -z ${GHOST_DEPS_OPTIONAL+x} ]] &&
    GHOST_DEPS_OPTIONAL=(torsocks obfs4proxy dnscrypt-proxy macchanger)

GHOST_TOR_CONTROL_PORT=${GHOST_TOR_CONTROL_PORT:-9051}
GHOST_TOR_SOCKS_PORT=${GHOST_TOR_SOCKS_PORT:-9050}
GHOST_TORRC=${GHOST_TORRC:-/etc/tor/torrc}
GHOST_PROXYCHAINS_CONFS=${GHOST_PROXYCHAINS_CONFS:-/etc/proxychains4.conf:/etc/proxychains.conf}
GHOST_CONFIG_DIR=${GHOST_CONFIG_DIR:-/etc/ghost-kali}
GHOST_MIN_DISK_MB=${GHOST_MIN_DISK_MB:-100}

# ──────────────────────────────────────────────────────────────────────────────
#  ACUMULADOR DE RESULTADOS
#  Cada check registra su veredicto para que los agregadores puedan resumirlo.
#  Estados: ok | warn | fail | skip
# ──────────────────────────────────────────────────────────────────────────────
declare -ga GHOST_HEALTH_NAMES=()
declare -gA GHOST_HEALTH_STATUS=()
declare -gA GHOST_HEALTH_DETAIL=()

_health_reset() {
    GHOST_HEALTH_NAMES=()
    GHOST_HEALTH_STATUS=()
    GHOST_HEALTH_DETAIL=()
}

_record_check() {
    local name=$1 status=$2 detail=${3:-}
    GHOST_HEALTH_NAMES+=("$name")
    GHOST_HEALTH_STATUS[$name]=$status
    GHOST_HEALTH_DETAIL[$name]=$detail
}

# _v_json_escape TEXTO → escapa un string para JSON (validators es autónomo y no
# depende de los helpers internos del logger para generar su reporte).
_v_json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/\\r}
    s=${s//$'\n'/\\n}
    printf '%s' "$s"
}

# ──────────────────────────────────────────────────────────────────────────────
#  COMPROBACIONES INDIVIDUALES
# ──────────────────────────────────────────────────────────────────────────────

# check_root → verifica privilegios de root (necesarios para gestionar red).
check_root() {
    local uid=${EUID:-$(id -u)}
    if [[ $uid -eq 0 ]]; then
        log_ok "Privilegios de root verificados."
        _record_check root ok "euid=0"
        return 0
    fi
    log_error "Se requieren privilegios de root. Ejecuta con: sudo joseph-trio"
    _record_check root fail "euid=$uid"
    return 1
}

# check_deps → verifica dependencias requeridas (fallo) y opcionales (aviso).
check_deps() {
    local d missing=() missing_opt=()

    for d in "${GHOST_DEPS_REQUIRED[@]}"; do
        command -v "$d" >/dev/null 2>&1 || missing+=("$d")
    done
    for d in "${GHOST_DEPS_OPTIONAL[@]}"; do
        command -v "$d" >/dev/null 2>&1 || missing_opt+=("$d")
    done

    if [[ ${#missing_opt[@]} -gt 0 ]]; then
        log_warn "Dependencias opcionales ausentes: ${missing_opt[*]}"
        log_warn "Algunas funciones avanzadas (ofuscación, MAC) podrían no estar disponibles."
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Faltan dependencias requeridas: ${missing[*]}"
        log_error "Instálalas con: sudo apt update && sudo apt install -y ${missing[*]}"
        _record_check deps fail "faltan: ${missing[*]}"
        return 1
    fi

    log_ok "Todas las dependencias requeridas están presentes."
    _record_check deps ok "opc. ausentes: ${missing_opt[*]:-ninguna}"
    return 0
}

# check_network → comprueba que existe conectividad de capa 3 (ruta por defecto).
# POR QUÉ no probamos contra un servidor externo: evitamos generar tráfico
# identificable antes de que la cadena de anonimato esté levantada.
check_network() {
    if ip route show default 2>/dev/null | grep -q .; then
        local gw
        gw=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')
        log_ok "Ruta de red por defecto presente (gateway: ${gw:-desconocido})."
        _record_check network ok "gw=${gw:-?}"
        return 0
    fi
    log_error "No hay ruta de red por defecto. Revisa tu conexión a Internet."
    _record_check network fail "sin ruta por defecto"
    return 1
}

# check_tor_config → revisa que Tor esté instalado y su torrc tenga ControlPort.
check_tor_config() {
    if ! command -v tor >/dev/null 2>&1; then
        log_warn "Tor no está instalado; se omite la verificación de su configuración."
        _record_check tor_config skip "tor ausente"
        return 1
    fi
    if [[ ! -r $GHOST_TORRC ]]; then
        log_warn "No se pudo leer $GHOST_TORRC (¿permisos o ruta distinta?)."
        _record_check tor_config warn "torrc no legible"
        return 1
    fi

    local has_control
    has_control=$(grep -Ec "^[[:space:]]*ControlPort[[:space:]]+${GHOST_TOR_CONTROL_PORT}\b" \
        "$GHOST_TORRC" 2>/dev/null || printf '0')

    if [[ $has_control -ge 1 ]]; then
        log_ok "ControlPort ${GHOST_TOR_CONTROL_PORT} configurado en torrc."
        _record_check tor_config ok "controlport ${GHOST_TOR_CONTROL_PORT}"
        return 0
    fi

    log_warn "ControlPort ${GHOST_TOR_CONTROL_PORT} no está declarado en $GHOST_TORRC."
    log_warn "Es necesario para «Nueva Identidad» (NEWNYM). Ver install.sh o docs/HARDENING.md."
    _record_check tor_config warn "sin controlport"
    return 1
}

# check_proxychains_config → busca un proxychains.conf que enrute por el SOCKS de Tor.
check_proxychains_config() {
    local conf found=""
    IFS=':' read -ra _confs <<<"$GHOST_PROXYCHAINS_CONFS"
    for conf in "${_confs[@]}"; do
        [[ -r $conf ]] && {
            found=$conf
            break
        }
    done

    if [[ -z $found ]]; then
        log_warn "No se encontró un archivo proxychains.conf legible."
        _record_check proxychains warn "conf ausente"
        return 1
    fi

    if grep -Eq "^[[:space:]]*socks[45][[:space:]]+127\.0\.0\.1[[:space:]]+${GHOST_TOR_SOCKS_PORT}\b" \
        "$found" 2>/dev/null; then
        log_ok "proxychains enruta por el SOCKS de Tor (127.0.0.1:${GHOST_TOR_SOCKS_PORT}) en $found."
        _record_check proxychains ok "$found"
        return 0
    fi

    log_warn "$found no declara socks5 127.0.0.1 ${GHOST_TOR_SOCKS_PORT}."
    _record_check proxychains warn "sin socks tor"
    return 1
}

# check_mullvad_logged_in → comprueba si hay una sesión de Mullvad activa.
# IMPORTANTE: nunca imprimimos el número de cuenta ni tokens; solo el veredicto.
check_mullvad_logged_in() {
    if ! command -v mullvad >/dev/null 2>&1; then
        log_warn "Mullvad CLI no está instalado; se omite la verificación de cuenta."
        _record_check mullvad_account skip "cli ausente"
        return 1
    fi

    local out
    out=$(mullvad account get 2>/dev/null || true)
    if printf '%s' "$out" | grep -qiE 'device|expires|account|paid until'; then
        log_ok "Sesión de Mullvad activa."
        _record_check mullvad_account ok "sesion activa"
        return 0
    fi

    log_warn "No hay sesión de Mullvad. Inicia con: mullvad account login <número>"
    _record_check mullvad_account warn "sin sesion"
    return 1
}

# check_disk_space → verifica espacio libre para logs y archivos temporales.
check_disk_space() {
    local target=/var/log avail_mb
    [[ -d $target ]] || target=/
    avail_mb=$(df -Pm "$target" 2>/dev/null | awk 'NR==2{print $4}')
    avail_mb=${avail_mb:-0}

    if [[ $avail_mb -ge $GHOST_MIN_DISK_MB ]]; then
        log_ok "Espacio en disco suficiente (${avail_mb} MB libres en ${target})."
        _record_check disk ok "${avail_mb}MB"
        return 0
    fi

    log_warn "Poco espacio en disco (${avail_mb} MB en ${target}). Recomendado ≥ ${GHOST_MIN_DISK_MB} MB."
    _record_check disk warn "${avail_mb}MB"
    return 1
}

# check_kernel_params → informa parámetros sysctl relevantes para la privacidad.
# Solo LEE (no modifica): la corrección de estos valores corresponde a HARDENING.
check_kernel_params() {
    local v_fwd v_ipv6 status=ok
    v_fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || printf 'n/a')
    v_ipv6=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || printf 'n/a')

    log_info "net.ipv4.ip_forward=${v_fwd} · net.ipv6.conf.all.disable_ipv6=${v_ipv6}"

    if [[ $v_ipv6 != 1 ]]; then
        log_warn "IPv6 no está deshabilitado: posible fuga de IPv6. Ver docs/HARDENING.md."
        status=warn
    fi

    _record_check kernel "$status" "ipfwd=${v_fwd} ipv6dis=${v_ipv6}"
    [[ $status == ok ]]
}

# check_file_permissions → avisa de archivos sensibles con permisos demasiado laxos.
check_file_permissions() {
    local f perm issues=0
    local -a sensitive=("${GHOST_CONFIG_DIR}/config" "$GHOST_TORRC")

    for f in "${sensitive[@]}"; do
        [[ -e $f ]] || continue
        perm=$(stat -c '%a' "$f" 2>/dev/null || printf '')
        [[ -z $perm ]] && continue
        # Bit de escritura para «otros» (0002): no debería estar activo.
        if [[ $((0$perm & 0002)) -ne 0 ]]; then
            log_warn "Permisos laxos en ${f} (${perm}): escribible por cualquier usuario."
            issues=$((issues + 1))
        fi
    done

    if [[ $issues -eq 0 ]]; then
        log_ok "Permisos de archivos sensibles correctos."
        _record_check permissions ok "sin hallazgos"
        return 0
    fi

    log_warn "Se detectaron ${issues} archivo(s) con permisos laxos."
    _record_check permissions warn "${issues} hallazgos"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
#  AGREGADORES
# ──────────────────────────────────────────────────────────────────────────────

# _run_all_checks → ejecuta todas las comprobaciones sin abortar ante un fallo.
_run_all_checks() {
    _health_reset
    check_root || true
    check_deps || true
    check_network || true
    check_tor_config || true
    check_proxychains_config || true
    check_mullvad_logged_in || true
    check_disk_space || true
    check_kernel_params || true
    check_file_permissions || true
}

# _overall_status → imprime el veredicto global (ok | warn | fail).
_overall_status() {
    local overall=ok name
    for name in "${GHOST_HEALTH_NAMES[@]}"; do
        case ${GHOST_HEALTH_STATUS[$name]} in
            fail)
                overall=fail
                break
                ;;
            warn) [[ $overall == ok ]] && overall=warn ;;
        esac
    done
    printf '%s' "$overall"
}

# run_health_check → ejecuta todo y muestra un resumen humano. Devuelve 0 salvo
# que haya al menos un fallo (los avisos no se consideran fallo).
run_health_check() {
    log_section "Health Check — Ghost-Kali"
    _run_all_checks

    local name ok=0 warn=0 fail=0 skip=0
    for name in "${GHOST_HEALTH_NAMES[@]}"; do
        case ${GHOST_HEALTH_STATUS[$name]} in
            ok) ok=$((ok + 1)) ;;
            warn) warn=$((warn + 1)) ;;
            fail) fail=$((fail + 1)) ;;
            skip) skip=$((skip + 1)) ;;
        esac
    done

    log_section "Resumen"
    log_table "Correctas" "$ok" "Advertencias" "$warn" "Fallos" "$fail" "Omitidas" "$skip"

    if [[ $fail -gt 0 ]]; then
        log_error "Health check con fallos. Revisa los mensajes anteriores."
        return 1
    fi
    log_ok "Health check superado."
    return 0
}

# generate_health_report → ejecuta todo y emite un reporte JSON por stdout.
# Devuelve 0 salvo que el veredicto global sea «fail».
generate_health_report() {
    _run_all_checks

    local ts overall name i last
    ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
    overall=$(_overall_status)
    last=$((${#GHOST_HEALTH_NAMES[@]} - 1))

    printf '{\n'
    printf '  "app": "ghost-kali",\n'
    printf '  "timestamp": "%s",\n' "$ts"
    printf '  "overall": "%s",\n' "$overall"
    printf '  "checks": [\n'
    for i in "${!GHOST_HEALTH_NAMES[@]}"; do
        name=${GHOST_HEALTH_NAMES[$i]}
        printf '    { "name": "%s", "status": "%s", "detail": "%s" }' \
            "$(_v_json_escape "$name")" \
            "$(_v_json_escape "${GHOST_HEALTH_STATUS[$name]}")" \
            "$(_v_json_escape "${GHOST_HEALTH_DETAIL[$name]}")"
        [[ $i -lt $last ]] && printf ','
        printf '\n'
    done
    printf '  ]\n'
    printf '}\n'

    [[ $overall != fail ]]
}
