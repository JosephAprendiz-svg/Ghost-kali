#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  lib/netutils.sh — Utilidades de red defensivas de Ghost-Kali
# ──────────────────────────────────────────────────────────────────────────────
#  Consulta información de TU propia conexión: IP pública (con fallbacks),
#  geolocalización, fugas de DNS/WebRTC, mapa de conexión ASCII, salida por Tor,
#  resolución de hosts, gateway/interfaz/DNS, contadores de tráfico y resumen.
#
#  ⚖️  DISCLAIMER ÉTICO/LEGAL: herramienta 100% DEFENSIVA. Solo inspecciona tu
#      propia red para proteger tu privacidad legítima. NO escanea redes ajenas,
#      NO ataca, NO explota. No usa nmap/masscan/hping3/ping -f ni similares.
#
#  🔐 INVARIANTES:
#      · Solo lectura del sistema; NUNCA modifica archivos ni servicios.
#      · NUNCA usa rm -rf, iptables -F, killall, pkill, systemctl stop.
#      · NUNCA imprime credenciales ni datos sensibles.
#      · Todo lo que envía tráfico real respeta --dry-run y usa timeouts.
#
#  LIBRERÍA: cargar con `source lib/netutils.sh`, NO ejecutar. Depende de
#  lib/logger.sh y lib/validators.sh.
# ──────────────────────────────────────────────────────────────────────────────

# ── Guarda de ejecución directa ───────────────────────────────────────────────
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    printf 'Este archivo es una librería y debe cargarse con «source», no ejecutarse.\n' >&2
    printf 'Uso: source lib/netutils.sh\n' >&2
    exit 1
fi

# ── Guarda de idempotencia ────────────────────────────────────────────────────
[[ -n ${_GHOST_NETUTILS_LOADED:-} ]] && return 0
_GHOST_NETUTILS_LOADED=1

# ── Dependencias: logger.sh y validators.sh ───────────────────────────────────
_ghost_lib_dir=${BASH_SOURCE[0]%/*}
if [[ -z ${_GHOST_LOGGER_LOADED:-} && -f ${_ghost_lib_dir}/logger.sh ]]; then
    # shellcheck source=lib/logger.sh
    source "${_ghost_lib_dir}/logger.sh"
fi
if [[ -z ${_GHOST_VALIDATORS_LOADED:-} && -f ${_ghost_lib_dir}/validators.sh ]]; then
    # shellcheck source=lib/validators.sh
    source "${_ghost_lib_dir}/validators.sh"
fi
# Fallbacks mínimos de logging si las librerías no estuvieran disponibles.
if ! declare -F log_info >/dev/null 2>&1; then
    log_info() { printf 'INFO  %s\n' "$*"; }
    log_ok() { printf 'OK    %s\n' "$*"; }
    log_warn() { printf 'WARN  %s\n' "$*" >&2; }
    log_error() { printf 'ERROR %s\n' "$*" >&2; }
    log_section() { printf '\n== %s ==\n' "$*"; }
    log_table() { while [[ $# -ge 2 ]]; do
        printf '  %s: %s\n' "$1" "$2"
        shift 2
    done; }
fi

# ── Constantes configurables ──────────────────────────────────────────────────
GHOST_NET_TIMEOUT=${GHOST_NET_TIMEOUT:-10}

# Proveedores de IP pública, en orden de preferencia (Mullvad primero).
if [[ -z ${GHOST_NET_IP_PROVIDERS+x} ]]; then
    declare -ga GHOST_NET_IP_PROVIDERS=(
        "https://am.i.mullvad.net/json"
        "https://ipinfo.io/json"
        "https://icanhazip.com"
        "https://checkip.amazonaws.com"
    )
fi

# Heurística de DNS de Mullvad: IP exacta del túnel y prefijo de sus resolutores
# públicos (DoH/DoT). No es CIDR estricto; basta para una advertencia de fuga.
if [[ -z ${GHOST_MULLVAD_DNS_RANGES+x} ]]; then
    declare -ga GHOST_MULLVAD_DNS_RANGES=(
        "10.64.0.1"
        "194.242.2."
    )
fi

# ──────────────────────────────────────────────────────────────────────────────
#  HELPERS PRIVADOS
# ──────────────────────────────────────────────────────────────────────────────

# _net_curl_json URL → cuerpo de la respuesta; vacío si falla. Siempre con timeout.
# POR QUÉ -fsS: fallar en errores HTTP, silencioso pero mostrando errores de red.
_net_curl_json() {
    command -v curl >/dev/null 2>&1 || return 1
    curl -fsS --max-time "$GHOST_NET_TIMEOUT" "$1" 2>/dev/null
}

# _net_json_get JSON CLAVE → valor (string o booleano). Usa jq si está disponible.
_net_json_get() {
    local json=$1 key=$2
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null
        return
    fi
    local v
    v=$(printf '%s' "$json" |
        grep -oE "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 |
        sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
    if [[ -z $v ]]; then
        v=$(printf '%s' "$json" |
            grep -oE "\"$key\"[[:space:]]*:[[:space:]]*(true|false)" | head -1 |
            grep -oE 'true|false')
    fi
    printf '%s' "$v"
}

# _net_extract_ip [TEXTO] → primera IPv4 encontrada (en $1 o, si no, en stdin).
_net_extract_ip() {
    local text=${1:-}
    [[ -z $text ]] && text=$(cat)
    grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' <<<"$text" | head -1
}

# _net_tcp_probe HOST PUERTO → 0 si se puede abrir una conexión TCP (con timeout).
# POR QUÉ TCP y no ICMP: el ping suele filtrarse; un connect a 443 es más fiable
# y no transmite ninguna información personal. host/puerto se pasan como args del
# subshell (no por interpolación) para evitar inyecciones.
_net_tcp_probe() {
    timeout 3 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$2" 2>/dev/null
}

# _net_is_mullvad_dns IP → 0 si la IP parece un resolutor de Mullvad.
_net_is_mullvad_dns() {
    local ip=$1 r
    for r in "${GHOST_MULLVAD_DNS_RANGES[@]}"; do
        [[ $ip == "$r" || $ip == "${r}"* ]] && return 0
    done
    return 1
}

# _net_mullvad_active → 0 si hay una interfaz WireGuard/Mullvad presente.
_net_mullvad_active() {
    ip -o link show 2>/dev/null | awk -F': ' '{print $2}' |
        grep -qiE 'mullvad|^wg'
}

# _net_tor_active → 0 si Tor parece activo (proceso o SOCKS escuchando).
_net_tor_active() {
    if command -v pgrep >/dev/null 2>&1 && pgrep -x tor >/dev/null 2>&1; then
        return 0
    fi
    timeout 2 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/9050"' 2>/dev/null
}

# _net_proxychains_present → 0 si proxychains está instalado.
_net_proxychains_present() {
    command -v proxychains4 >/dev/null 2>&1 || command -v proxychains >/dev/null 2>&1
}

# _net_detect_tunnel → imprime: mullvad | tor | none.
_net_detect_tunnel() {
    if _net_mullvad_active; then
        printf 'mullvad'
        return 0
    fi
    if _net_tor_active; then
        printf 'tor'
        return 0
    fi
    printf 'none'
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
#  API PÚBLICA — conectividad e identidad de red
# ──────────────────────────────────────────────────────────────────────────────

# net_is_online → 0 si hay conectividad a internet (sin enviar datos personales).
net_is_online() {
    local -a targets=("1.1.1.1 443" "9.9.9.9 443" "8.8.8.8 443")
    local t host port
    for t in "${targets[@]}"; do
        read -r host port <<<"$t"
        _net_tcp_probe "$host" "$port" && return 0
    done
    return 1
}

# net_get_public_ip [--dry-run] → IP pública con múltiples fallbacks.
net_get_public_ip() {
    local dry=${GHOST_DRY_RUN:-0}
    [[ ${1:-} == --dry-run ]] && dry=1
    if [[ $dry == 1 ]]; then
        log_info "[dry-run] Consultaría IP en ${GHOST_NET_IP_PROVIDERS[0]}"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl no está instalado."
        return 1
    fi

    local url body ip="" country="" isp="" mullvad="desconocido"
    for url in "${GHOST_NET_IP_PROVIDERS[@]}"; do
        body=$(_net_curl_json "$url")
        [[ -z $body ]] && continue
        case $url in
            *mullvad*)
                ip=$(_net_json_get "$body" ip)
                country=$(_net_json_get "$body" country)
                isp=$(_net_json_get "$body" organization)
                mullvad=$(_net_json_get "$body" mullvad_exit_ip)
                ;;
            *ipinfo*)
                ip=$(_net_json_get "$body" ip)
                country=$(_net_json_get "$body" country)
                isp=$(_net_json_get "$body" org)
                ;;
            *)
                ip=$(_net_extract_ip "$body")
                ;;
        esac
        [[ -n $ip ]] && break
    done

    if [[ -z $ip ]]; then
        log_error "No se pudo determinar la IP pública (todos los proveedores fallaron)."
        return 1
    fi
    log_section "IP pública"
    log_table "IP" "$ip" "País" "${country:-?}" "ISP/Org" "${isp:-?}" \
        "¿Sale por Mullvad?" "${mullvad:-desconocido}"
    return 0
}

# net_geo_lookup <ip> → geolocalización básica vía ipinfo.io (sin API key).
net_geo_lookup() {
    local ip=${1:-}
    if [[ -z $ip ]]; then
        log_error "Uso: net_geo_lookup <ip>"
        return 1
    fi
    if ! [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        log_error "IP inválida: ${ip}"
        return 1
    fi
    local body
    body=$(_net_curl_json "https://ipinfo.io/${ip}/json")
    if [[ -z $body ]]; then
        log_error "No se pudo geolocalizar ${ip} (¿hay conexión?)."
        return 1
    fi
    log_section "Geolocalización de ${ip}"
    log_table \
        "Ciudad" "$(_net_json_get "$body" city)" \
        "Región" "$(_net_json_get "$body" region)" \
        "País" "$(_net_json_get "$body" country)" \
        "Org" "$(_net_json_get "$body" org)"
}

# ──────────────────────────────────────────────────────────────────────────────
#  API PÚBLICA — fugas (DNS / WebRTC) y salida por Tor
# ──────────────────────────────────────────────────────────────────────────────

# net_get_dns_servers → resolutores DNS de /etc/resolv.conf (solo lectura).
net_get_dns_servers() {
    local resolv=/etc/resolv.conf
    if [[ ! -r $resolv ]]; then
        log_warn "No se pudo leer ${resolv}."
        return 1
    fi
    grep -E '^[[:space:]]*nameserver' "$resolv" | awk '{print $2}'
}

# net_dns_leak_test [--dry-run] → analiza los resolutores y prueba una resolución.
net_dns_leak_test() {
    local dry=${GHOST_DRY_RUN:-0}
    [[ ${1:-} == --dry-run ]] && dry=1

    log_section "Test de fugas de DNS"
    local -a servers
    mapfile -t servers < <(net_get_dns_servers)
    if [[ ${#servers[@]} -eq 0 ]]; then
        log_warn "No se detectaron servidores DNS en /etc/resolv.conf."
    else
        log_info "Servidores DNS detectados: ${servers[*]}"
    fi

    local s nonmullvad=0
    for s in "${servers[@]}"; do
        if _net_is_mullvad_dns "$s"; then
            log_ok "  ${s} → parece DNS de Mullvad."
        else
            log_warn "  ${s} → NO parece DNS de Mullvad (posible fuga si esperas anonimato)."
            nonmullvad=$((nonmullvad + 1))
        fi
    done
    [[ ${#servers[@]} -gt 1 ]] &&
        log_warn "Hay más de un servidor DNS configurado; revisa que no haya fugas."

    local domain="am.i.mullvad.net"
    if [[ $dry == 1 ]]; then
        log_info "[dry-run] Resolvería ${domain} con dig/drill/host/nslookup."
        return 0
    fi

    local tool="" t
    for t in dig drill host nslookup; do
        command -v "$t" >/dev/null 2>&1 && {
            tool=$t
            break
        }
    done
    if [[ -z $tool ]]; then
        log_warn "No hay herramienta de resolución (dig/drill/host/nslookup)."
    else
        log_info "Resolviendo ${domain} con ${tool}…"
        local result=""
        case $tool in
            dig) result=$(dig +short "$domain" 2>/dev/null | head -3 | tr '\n' ' ') ;;
            drill) result=$(drill "$domain" 2>/dev/null | awk '/IN[[:space:]]+A/{print $NF}' | head -3 | tr '\n' ' ') ;;
            host) result=$(host "$domain" 2>/dev/null | awk '/has address/{print $NF}' | head -3 | tr '\n' ' ') ;;
            nslookup) result=$(nslookup "$domain" 2>/dev/null | awk '/^Address: /{print $2}' | head -3 | tr '\n' ' ') ;;
        esac
        if [[ -n $result ]]; then
            log_ok "Resolución OK: ${result}"
        else
            log_warn "No se obtuvo respuesta de resolución."
        fi
    fi

    log_info "Para una verificación visual completa, usa https://mullvad.net/check/"
    if [[ $nonmullvad -gt 0 ]]; then
        log_warn "Veredicto: posible fuga de DNS (resolutores no-Mullvad detectados)."
        return 1
    fi
    log_ok "Veredicto: los resolutores configurados parecen de Mullvad."
    return 0
}

# net_webrtc_leak_check → orientación + detección de interfaces (no envía tráfico).
net_webrtc_leak_check() {
    log_section "Comprobación de fugas WebRTC"
    log_info "WebRTC SOLO puede comprobarse de forma fiable en el NAVEGADOR, no desde la terminal."
    log_warn "Un navegador con WebRTC activo puede revelar tu IP real aunque uses VPN/Tor."
    log_info "Recomendaciones:"
    log_info "  • Usa Tor Browser (bloquea WebRTC por defecto)."
    log_info "  • O desactívalo (Firefox: media.peerconnection.enabled = false)."
    log_info "  • Verifica en https://mullvad.net/check/ o https://browserleaks.com/webrtc"

    local -a ifaces
    mapfile -t ifaces < <(ip -o addr show 2>/dev/null | awk '{print $2}' | sort -u | grep -vE '^lo$')
    [[ ${#ifaces[@]} -gt 0 ]] &&
        log_info "Interfaces con IP (potencialmente visibles por WebRTC): ${ifaces[*]}"

    local tunnel
    tunnel=$(_net_detect_tunnel)
    case $tunnel in
        mullvad) log_ok "Túnel Mullvad detectado; aun así verifica WebRTC en el navegador." ;;
        tor) log_ok "Tor detectado; usa Tor Browser para neutralizar WebRTC." ;;
        *) log_warn "No se detectó túnel activo; el riesgo de exposición por WebRTC es mayor." ;;
    esac
}

# net_check_tor_exit [--dry-run] → ¿el tráfico de salida actual va por Tor?
# Refleja el enrutamiento por defecto; para probar el SOCKS de Tor específicamente
# usa tor_verify_exit() de lib/torctl.sh.
net_check_tor_exit() {
    local dry=${GHOST_DRY_RUN:-0}
    [[ ${1:-} == --dry-run ]] && dry=1
    if [[ $dry == 1 ]]; then
        log_info "[dry-run] Consultaría https://check.torproject.org/api/ip"
        return 0
    fi
    local body istor ip
    body=$(_net_curl_json "https://check.torproject.org/api/ip")
    if [[ -z $body ]]; then
        log_error "Sin respuesta de check.torproject.org. ¿Hay conexión a internet?"
        return 1
    fi
    istor=$(_net_json_get "$body" IsTor)
    ip=$(_net_json_get "$body" IP)
    log_section "¿Sale el tráfico por Tor?"
    if [[ $istor == true ]]; then
        log_ok "Sí: tu tráfico sale por Tor (IP de salida: ${ip:-?})."
        return 0
    fi
    log_warn "No: tu tráfico NO sale por Tor (IP: ${ip:-?})."
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
#  API PÚBLICA — diagnóstico y consultas locales (solo lectura)
# ──────────────────────────────────────────────────────────────────────────────

# net_resolve_host <hostname> [--dry-run] → resuelve un host a IPs.
net_resolve_host() {
    local dry=${GHOST_DRY_RUN:-0} host="" a
    for a in "$@"; do
        case $a in
            --dry-run) dry=1 ;;
            *) host=$a ;;
        esac
    done
    if [[ -z $host ]]; then
        log_error "Uso: net_resolve_host <hostname> [--dry-run]"
        return 1
    fi
    if [[ $dry == 1 ]]; then
        log_info "[dry-run] Resolvería ${host} con getent/dig/nslookup."
        return 0
    fi

    log_section "Resolución de ${host}"
    local ips=""
    if command -v getent >/dev/null 2>&1; then
        ips=$(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
    fi
    if [[ -z $ips ]] && command -v dig >/dev/null 2>&1; then
        ips=$(dig +short "$host" 2>/dev/null | grep -E '^[0-9a-fA-F:.]+$' | tr '\n' ' ')
    fi
    if [[ -z $ips ]] && command -v nslookup >/dev/null 2>&1; then
        ips=$(nslookup "$host" 2>/dev/null | awk '/^Address: /{print $2}' | tr '\n' ' ')
    fi

    if [[ -n $ips ]]; then
        log_ok "${host} → ${ips}"
        return 0
    fi
    log_warn "No se pudo resolver ${host}."
    return 1
}

# net_get_default_gateway → gateway por defecto.
net_get_default_gateway() {
    ip route show default 2>/dev/null | awk '/default/{print $3; exit}'
}

# net_get_active_interface → interfaz con la ruta por defecto.
net_get_active_interface() {
    ip route show default 2>/dev/null |
        awk '/default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

# net_humanize_bytes <bytes> → formatea a unidades legibles (numfmt o awk).
net_humanize_bytes() {
    local n=${1:-0}
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B "$n" 2>/dev/null && return
    fi
    awk -v b="$n" 'BEGIN{
        split("B KiB MiB GiB TiB",u," "); i=1;
        while (b>=1024 && i<5){ b/=1024; i++ }
        if (i==1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i]
    }'
}

# net_bandwidth_for_iface <iface> → rx/tx desde /sys/class/net (solo lectura).
net_bandwidth_for_iface() {
    local iface=${1:-}
    if [[ -z $iface ]]; then
        log_error "Uso: net_bandwidth_for_iface <iface>"
        return 1
    fi
    local base="/sys/class/net/${iface}/statistics"
    if [[ ! -d $base ]]; then
        log_error "Interfaz no encontrada: ${iface}"
        return 1
    fi
    local rx tx
    rx=$(cat "${base}/rx_bytes" 2>/dev/null)
    tx=$(cat "${base}/tx_bytes" 2>/dev/null)
    log_section "Tráfico de ${iface}"
    log_table "Interfaz" "$iface" \
        "Recibido" "$(net_humanize_bytes "${rx:-0}")" \
        "Enviado" "$(net_humanize_bytes "${tx:-0}")"
}

# net_wait_for_internet [timeout] [--dry-run] → espera hasta tener conexión.
net_wait_for_internet() {
    local dry=${GHOST_DRY_RUN:-0} timeout_s=30 a
    for a in "$@"; do
        case $a in
            --dry-run) dry=1 ;;
            *[!0-9]*) ;; # ignora cualquier otra cosa no numérica
            *) timeout_s=$a ;;
        esac
    done
    if [[ $dry == 1 ]]; then
        log_info "[dry-run] Esperaría hasta ${timeout_s}s a tener conexión."
        return 0
    fi
    log_info "Esperando conexión a internet (máx. ${timeout_s}s)…"
    local waited=0
    while [[ $waited -lt $timeout_s ]]; do
        if net_is_online; then
            log_ok "Conexión disponible tras ${waited}s."
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    log_error "No hubo conexión tras ${timeout_s}s."
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
#  API PÚBLICA — mapa y resumen
# ──────────────────────────────────────────────────────────────────────────────

# net_connection_map → mapa ASCII de la conexión y detección de túnel.
net_connection_map() {
    log_section "Mapa de conexión"
    local iface gw ip="?" country="?" mid mv="no" tr="no" pchains="no"
    iface=$(net_get_active_interface)
    iface=${iface:-?}
    gw=$(net_get_default_gateway)
    gw=${gw:-?}
    _net_mullvad_active && mv="sí"
    _net_tor_active && tr="sí"
    _net_proxychains_present && pchains="sí"

    if [[ $mv == sí && $tr == sí ]]; then
        mid="MULLVAD → TOR"
    elif [[ $mv == sí ]]; then
        mid="MULLVAD"
    elif [[ $tr == sí ]]; then
        mid="TOR"
    else
        mid="DIRECTO (sin túnel)"
    fi

    # IP pública solo si hay conexión (no bloqueamos el mapa si estás offline).
    if net_is_online; then
        local body
        body=$(_net_curl_json "${GHOST_NET_IP_PROVIDERS[0]}")
        if [[ -n $body ]]; then
            ip=$(_net_json_get "$body" ip)
            ip=${ip:-?}
            country=$(_net_json_get "$body" country)
            country=${country:-?}
        fi
    fi

    printf '\n'
    printf '  [TU KALI] --(%s)--> [%s] --(túnel)--> [INTERNET] --(IP: %s)--> [%s]\n' \
        "$iface" "$mid" "$ip" "$country"
    printf '\n'
    log_table \
        "Interfaz" "$iface" \
        "Gateway" "$gw" \
        "Mullvad" "$mv" \
        "Tor" "$tr" \
        "Proxychains" "$pchains" \
        "IP pública" "$ip" \
        "País" "$country"
    [[ $mid == "DIRECTO (sin túnel)" ]] &&
        log_warn "No se detectó túnel activo: tu tráfico va directo (sin VPN ni Tor)."
    return 0
}

# net_status_summary → resumen compacto de red.
net_status_summary() {
    log_section "Resumen de red"
    local iface gw dns tunnel
    iface=$(net_get_active_interface)
    gw=$(net_get_default_gateway)
    dns=$(net_get_dns_servers 2>/dev/null | tr '\n' ' ')
    tunnel=$(_net_detect_tunnel)
    log_table \
        "Interfaz activa" "${iface:-?}" \
        "Gateway" "${gw:-?}" \
        "DNS" "${dns:-?}" \
        "Túnel" "$tunnel"

    if net_is_online; then
        local body ip country
        body=$(_net_curl_json "${GHOST_NET_IP_PROVIDERS[0]}")
        ip=$(_net_json_get "$body" ip)
        country=$(_net_json_get "$body" country)
        log_table "IP pública" "${ip:-?}" "País" "${country:-?}"
    else
        log_warn "Sin conexión a internet; se omite la IP pública."
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
#  API EXPUESTA (recordatorio)
#  Esto es una librería: `source lib/netutils.sh` expone las funciones net_*.
#  NO se ejecuta nada automáticamente ni hay main(): el orquestador (joseph-trio)
#  decide qué invocar. Las funciones que envían tráfico real respetan --dry-run y
#  usan timeouts; el resto son consultas de solo lectura sobre tu propia red.
# ──────────────────────────────────────────────────────────────────────────────
