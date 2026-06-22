#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  lib/dashboard.sh — Dashboard visual de Ghost-Kali (7 widgets)
# ──────────────────────────────────────────────────────────────────────────────
#  Dibuja en la terminal un panel modular y de SOLO LECTURA con:
#    1) Mapa de conexión   2) Circuitos Tor   3) Ancho de banda del túnel
#    4) Geo/IP pública     5) Uptime          6) Alertas   7) Estado del sistema
#
#  ⚖️  DISCLAIMER ÉTICO/LEGAL: herramienta 100% DEFENSIVA. Solo inspecciona TU
#      sistema y tu red para proteger tu privacidad legítima. No ataca, no
#      escanea redes ajenas, no explota nada. Uso educativo y ético.
#
#  🔐 INVARIANTES:
#      · Solo lectura; NUNCA modifica archivos ni servicios.
#      · NUNCA usa rm -rf, iptables -F, killall, pkill, systemctl stop.
#      · NUNCA imprime credenciales ni datos sensibles.
#
#  LIBRERÍA: cargar con `source lib/dashboard.sh`, NO ejecutar. Depende de
#  lib/colors.sh, lib/logger.sh, lib/netutils.sh, lib/vpnctl.sh y lib/torctl.sh.
# ──────────────────────────────────────────────────────────────────────────────

# ── Guarda de ejecución directa ───────────────────────────────────────────────
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    printf 'Este archivo es una librería y debe cargarse con «source», no ejecutarse.\n' >&2
    printf 'Uso: source lib/dashboard.sh\n' >&2
    exit 1
fi

# ── Guarda de idempotencia ────────────────────────────────────────────────────
[[ -n ${_GHOST_DASHBOARD_LOADED:-} ]] && return 0
_GHOST_DASHBOARD_LOADED=1

_ghost_lib_dir=${BASH_SOURCE[0]%/*}

# _dash_load_deps → carga las librerías de las que depende el dashboard.
# POR QUÉ aquí y no inline: centralizar la carga permite que el dashboard
# funcione tanto si se cargó como parte del toolkit como de forma aislada.
_dash_load_deps() {
    local d var
    for d in colors logger netutils vpnctl torctl; do
        case $d in
            colors) var=_GHOST_COLORS_LOADED ;;
            logger) var=_GHOST_LOGGER_LOADED ;;
            netutils) var=_GHOST_NETUTILS_LOADED ;;
            vpnctl) var=_GHOST_VPNCTL_LOADED ;;
            torctl) var=_GHOST_TORCTL_LOADED ;;
        esac
        if [[ -z ${!var:-} && -f ${_ghost_lib_dir}/${d}.sh ]]; then
            # shellcheck source=/dev/null
            source "${_ghost_lib_dir}/${d}.sh"
        fi
    done
}
_dash_load_deps

# Fallbacks mínimos de logging y de utilidades si algo no estuviera disponible.
if ! declare -F log_info >/dev/null 2>&1; then
    log_info() { printf 'INFO  %s\n' "$*"; }
    log_ok() { printf 'OK    %s\n' "$*"; }
    log_warn() { printf 'WARN  %s\n' "$*" >&2; }
    log_error() { printf 'ERROR %s\n' "$*" >&2; }
fi
if ! declare -F ghost_strip_ansi >/dev/null 2>&1; then
    ghost_strip_ansi() { printf '%s' "${1:-}" | sed -E 's/\x1b\[[0-9;]*m//g'; }
fi
# Variables de color con defaults vacíos (si colors.sh no estuviera cargado).
: "${C_PRIMARY:=}" "${C_ACCENT:=}" "${C_MUTED:=}" "${C_SUCCESS:=}"
: "${C_WARNING:=}" "${C_ERROR:=}" "${C_RESET:=}"

# ── Constantes configurables ──────────────────────────────────────────────────
GHOST_DASH_REFRESH=${GHOST_DASH_REFRESH:-5}
GHOST_DASH_COMPACT=${GHOST_DASH_COMPACT:-0}
GHOST_VERSION=${GHOST_VERSION:-v5.0-elite}
GHOST_DASH_WIDTH=${GHOST_DASH_WIDTH:-78}

# Flag interno de dry-run a nivel de dashboard (lo fija dashboard_render).
_DASH_DRY=0

# ──────────────────────────────────────────────────────────────────────────────
#  CAJAS ASCII
#  POR QUÉ medimos el ancho visible: el contenido puede llevar códigos de color
#  ANSI; para que el relleno cuadre, calculamos la longitud SIN los escapes.
# ──────────────────────────────────────────────────────────────────────────────

# _dash_strwidth TEXTO → ancho de visualización (nº de caracteres), independiente
# del locale. POR QUÉ: con locale C, ${#cadena} cuenta BYTES, y los acentos o los
# glifos de caja (multibyte UTF-8) descuadran el relleno. Contamos los bytes que
# NO son de continuación UTF-8 (rango 0x80–0xBF): así obtenemos el nº de caracteres.
_dash_strwidth() {
    local LC_ALL=C s=$1 stripped
    stripped=${s//[$'\x80'-$'\xbf']/}
    printf '%d' "${#stripped}"
}

# _dash_repeat CHAR N → CHAR repetido N veces.
_dash_repeat() {
    local ch=$1 n=$2 out='' i
    for ((i = 0; i < n; i++)); do out+=$ch; done
    printf '%s' "$out"
}

# _dash_box_top TÍTULO → borde superior con título.
_dash_box_top() {
    local title=${1:-}
    local inner=$((GHOST_DASH_WIDTH - 2))
    local t
    t=$(_dash_strwidth "$title")
    local fill=$((inner - 3 - t)) # "─ " (2) + " " (1) tras el título
    [[ $fill -lt 0 ]] && fill=0
    printf '%s┌─ %s%s%s %s┐%s\n' \
        "$C_MUTED" "$C_PRIMARY" "$title" "$C_MUTED" "$(_dash_repeat '─' "$fill")" "$C_RESET"
}

# _dash_box_bottom → borde inferior.
_dash_box_bottom() {
    local inner=$((GHOST_DASH_WIDTH - 2))
    printf '%s└%s┘%s\n' "$C_MUTED" "$(_dash_repeat '─' "$inner")" "$C_RESET"
}

# _dash_box_line CONTENIDO → una línea de contenido dentro de la caja.
_dash_box_line() {
    local text=$1 plain vis usable pad
    plain=$(ghost_strip_ansi "$text")
    vis=$(_dash_strwidth "$plain")
    local inner=$((GHOST_DASH_WIDTH - 2))
    usable=$((inner - 2)) # un espacio a cada lado
    if [[ $vis -gt $usable ]]; then
        # Si no cabe, truncamos sobre el texto plano (perdiendo color) para no
        # romper el ancho de la caja.
        text=${plain:0:usable}
        vis=$usable
    fi
    pad=$((usable - vis))
    printf '%s│%s %s%*s %s│%s\n' \
        "$C_MUTED" "$C_RESET" "$text" "$pad" "" "$C_MUTED" "$C_RESET"
}

# ──────────────────────────────────────────────────────────────────────────────
#  HELPERS DE DATOS (solo lectura del sistema)
# ──────────────────────────────────────────────────────────────────────────────

# _dash_get_loadavg → carga promedio (1, 5, 15 min).
_dash_get_loadavg() {
    if [[ -r /proc/loadavg ]]; then
        awk '{print $1", "$2", "$3}' /proc/loadavg
    elif command -v uptime >/dev/null 2>&1; then
        uptime | sed -E 's/.*load average[s]?: //'
    else
        printf '?'
    fi
}

# _dash_get_meminfo → memoria usada / total en formato legible.
_dash_get_meminfo() {
    if command -v free >/dev/null 2>&1; then
        free -h 2>/dev/null | awk '/^Mem:/{print $3" / "$2}'
    elif [[ -r /proc/meminfo ]]; then
        awk '/MemTotal:/{t=$2} /MemAvailable:/{a=$2}
             END{ printf "%d / %d MiB", (t-a)/1024, t/1024 }' /proc/meminfo
    else
        printf '?'
    fi
}

# _dash_find_wg_interface → interfaz WireGuard/Mullvad activa, si existe.
_dash_find_wg_interface() {
    ip -o link show 2>/dev/null | awk -F': ' '{print $2}' |
        grep -iE 'mullvad|^wg' | head -1
}

# _dash_get_tunnel_uptime → tiempo aproximado del túnel (proceso/interfaz).
_dash_get_tunnel_uptime() {
    local iface pid secs=""
    iface=$(_dash_find_wg_interface)
    if command -v pgrep >/dev/null 2>&1; then
        pid=$(pgrep -x tor 2>/dev/null | head -1)
        [[ -n $pid ]] && secs=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
    fi
    if [[ -n $secs && $secs =~ ^[0-9]+$ ]]; then
        printf '%dd %02dh %02dm' "$((secs / 86400))" "$(((secs % 86400) / 3600))" "$(((secs % 3600) / 60))"
    elif [[ -n $iface ]]; then
        printf 'interfaz %s activa (tiempo no disponible)' "$iface"
    else
        printf 'sin túnel detectado'
    fi
}

# _dash_evaluate_alerts → imprime una alerta por línea (vacío = todo correcto).
_dash_evaluate_alerts() {
    local mv=no tr=no
    declare -F _net_mullvad_active >/dev/null 2>&1 && { _net_mullvad_active && mv=yes; }
    declare -F _net_tor_active >/dev/null 2>&1 && { _net_tor_active && tr=yes; }
    [[ $mv == no && $tr == no ]] &&
        printf 'No hay túnel activo (VPN/Tor): el tráfico va directo.\n'

    if declare -F net_get_dns_servers >/dev/null 2>&1 &&
        declare -F _net_is_mullvad_dns >/dev/null 2>&1; then
        local s
        while IFS= read -r s; do
            [[ -z $s ]] && continue
            _net_is_mullvad_dns "$s" ||
                printf 'Resolutor DNS no-Mullvad: %s (posible fuga).\n' "$s"
        done < <(net_get_dns_servers 2>/dev/null)
    fi

    local v6
    v6=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    [[ -n $v6 && $v6 != 1 ]] &&
        printf 'IPv6 no está deshabilitado: posible fuga de IPv6.\n'

    printf 'Recuerda: WebRTC solo se verifica de forma fiable en el navegador.\n'
}

# ──────────────────────────────────────────────────────────────────────────────
#  WIDGETS
# ──────────────────────────────────────────────────────────────────────────────

# dashboard_widget_connection_map → widget 1: mapa ASCII de conexión.
dashboard_widget_connection_map() {
    _dash_box_top "1. Mapa de conexión"
    local iface="?" gw="?" tunnel="none" mv=no tr=no mid
    if declare -F net_get_active_interface >/dev/null 2>&1; then
        iface=$(net_get_active_interface)
        gw=$(net_get_default_gateway)
        iface=${iface:-?}
        gw=${gw:-?}
    fi
    declare -F _net_mullvad_active >/dev/null 2>&1 && { _net_mullvad_active && mv=yes; }
    declare -F _net_tor_active >/dev/null 2>&1 && { _net_tor_active && tr=yes; }
    if [[ $mv == yes && $tr == yes ]]; then
        mid="MULLVAD->TOR"
        tunnel="mullvad+tor"
    elif [[ $mv == yes ]]; then
        mid="MULLVAD"
        tunnel="mullvad"
    elif [[ $tr == yes ]]; then
        mid="TOR"
        tunnel="tor"
    else
        mid="DIRECTO"
        tunnel="none"
    fi
    _dash_box_line "[TU KALI] --(${iface})--> [${mid}] --(túnel)--> [INTERNET]"
    _dash_box_line "Interfaz: ${iface}   Gateway: ${gw}   Túnel: ${tunnel}"
    _dash_box_bottom
}

# dashboard_widget_tor_circuits → widget 2: circuitos Tor activos.
dashboard_widget_tor_circuits() {
    _dash_box_top "2. Circuitos Tor"
    if [[ ${_DASH_DRY:-0} == 1 ]]; then
        _dash_box_line "[dry-run] Consultaría circuitos vía ControlPort 9051."
        _dash_box_bottom
        return 0
    fi
    if ! declare -F _tor_is_running >/dev/null 2>&1 ||
        ! declare -F _tor_getinfo_multi >/dev/null 2>&1 || ! _tor_is_running; then
        _dash_box_line "Tor no está accesible (ControlPort 9051): sin circuitos."
        _dash_box_bottom
        return 0
    fi
    local data line id status count=0
    data=$(_tor_getinfo_multi circuit-status 2>/dev/null)
    if [[ -z $data ]]; then
        _dash_box_line "No hay circuitos activos."
    else
        while IFS= read -r line; do
            [[ -z $line ]] && continue
            id=$(awk '{print $1}' <<<"$line")
            status=$(awk '{print $2}' <<<"$line")
            _dash_box_line "Circuito ${id}: ${status}"
            count=$((count + 1))
            if [[ $count -ge 5 ]]; then
                _dash_box_line "… (se muestran los primeros 5)"
                break
            fi
        done <<<"$data"
    fi
    _dash_box_bottom
}

# dashboard_widget_bandwidth → widget 3: ancho de banda de la interfaz del túnel.
dashboard_widget_bandwidth() {
    _dash_box_top "3. Ancho de banda del túnel"
    local iface
    iface=$(_dash_find_wg_interface)
    if [[ -z $iface ]]; then
        _dash_box_line "No se detectó interfaz de túnel (Mullvad/WireGuard) activa."
        _dash_box_bottom
        return 0
    fi
    local base="/sys/class/net/${iface}/statistics" rx tx hrx htx
    rx=$(cat "${base}/rx_bytes" 2>/dev/null)
    tx=$(cat "${base}/tx_bytes" 2>/dev/null)
    if declare -F net_humanize_bytes >/dev/null 2>&1; then
        hrx=$(net_humanize_bytes "${rx:-0}")
        htx=$(net_humanize_bytes "${tx:-0}")
    else
        hrx="${rx:-0} B"
        htx="${tx:-0} B"
    fi
    _dash_box_line "Interfaz: ${iface}"
    _dash_box_line "Recibido: ${hrx}    Enviado: ${htx}"
    _dash_box_bottom
}

# dashboard_widget_geo → widget 4: IP pública, país, ISP y salida por Mullvad.
dashboard_widget_geo() {
    _dash_box_top "4. Geolocalización / IP pública"
    if [[ ${_DASH_DRY:-0} == 1 ]]; then
        _dash_box_line "[dry-run] Consultaría la IP pública en am.i.mullvad.net."
        _dash_box_bottom
        return 0
    fi
    if declare -F net_is_online >/dev/null 2>&1 && ! net_is_online; then
        _dash_box_line "Sin conexión a internet."
        _dash_box_bottom
        return 0
    fi
    local body="" ip="?" country="?" isp="?" mv="?"
    if declare -F _net_curl_json >/dev/null 2>&1; then
        body=$(_net_curl_json "https://am.i.mullvad.net/json")
        if [[ -n $body ]]; then
            ip=$(_net_json_get "$body" ip)
            country=$(_net_json_get "$body" country)
            isp=$(_net_json_get "$body" organization)
            mv=$(_net_json_get "$body" mullvad_exit_ip)
        fi
    fi
    _dash_box_line "IP: ${ip:-?}    País: ${country:-?}"
    _dash_box_line "ISP: ${isp:-?}    ¿Sale por Mullvad?: ${mv:-?}"
    _dash_box_bottom
}

# dashboard_widget_uptime → widget 5: uptime del sistema y del túnel.
dashboard_widget_uptime() {
    _dash_box_top "5. Uptime"
    local sys
    if uptime -p >/dev/null 2>&1; then
        sys=$(uptime -p 2>/dev/null)
    else
        sys=$(uptime 2>/dev/null)
    fi
    [[ -z $sys ]] && sys="?"
    _dash_box_line "Sistema: ${sys}"
    _dash_box_line "Túnel:   $(_dash_get_tunnel_uptime)"
    _dash_box_bottom
}

# dashboard_widget_alerts → widget 6: alertas de seguridad/privacidad.
dashboard_widget_alerts() {
    _dash_box_top "6. Alertas de seguridad"
    local -a alerts
    mapfile -t alerts < <(_dash_evaluate_alerts)
    if [[ ${#alerts[@]} -eq 0 ]]; then
        _dash_box_line "${C_SUCCESS}Sin alertas: configuración de privacidad correcta.${C_RESET}"
    else
        local a
        for a in "${alerts[@]}"; do
            _dash_box_line "${C_WARNING}! ${a}${C_RESET}"
        done
    fi
    _dash_box_bottom
}

# dashboard_widget_system → widget 7: carga, memoria, interfaz y versión.
dashboard_widget_system() {
    _dash_box_top "7. Sistema"
    local load mem iface="?"
    load=$(_dash_get_loadavg)
    mem=$(_dash_get_meminfo)
    declare -F net_get_active_interface >/dev/null 2>&1 && iface=$(net_get_active_interface)
    _dash_box_line "Carga: ${load}    Memoria: ${mem}"
    _dash_box_line "Interfaz activa: ${iface:-?}    Ghost-Kali: ${GHOST_VERSION}"
    _dash_box_bottom
}

# ──────────────────────────────────────────────────────────────────────────────
#  CABECERA / PIE / PANTALLA
# ──────────────────────────────────────────────────────────────────────────────

# dashboard_clear_screen → limpia la pantalla de forma portable (solo en TTY).
dashboard_clear_screen() {
    [[ -t 1 ]] || return 0 # no limpiar si la salida no es una terminal
    if command -v tput >/dev/null 2>&1 && tput clear 2>/dev/null; then
        return 0
    fi
    printf '\033[2J\033[H'
}

# dashboard_header → banner del dashboard con fecha/hora.
dashboard_header() {
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')
    _dash_box_top "GHOST-KALI ${GHOST_VERSION} · Dashboard"
    _dash_box_line "${C_ACCENT}Privacidad operativa${C_RESET}   ·   ${now}"
    _dash_box_bottom
}

# dashboard_footer → pie con atajos y aviso ético.
dashboard_footer() {
    _dash_box_top "Atajos / Aviso"
    _dash_box_line "En bucle: Ctrl+C para salir."
    _dash_box_line "${C_MUTED}Uso educativo y ético: protege tu privacidad; no facilita abusos.${C_RESET}"
    _dash_box_bottom
}

# ──────────────────────────────────────────────────────────────────────────────
#  RENDER Y BUCLE
# ──────────────────────────────────────────────────────────────────────────────

# dashboard_render [--dry-run] [--compact] → dibuja el dashboard completo.
dashboard_render() {
    local compact=${GHOST_DASH_COMPACT:-0} a
    _DASH_DRY=${GHOST_DRY_RUN:-0}
    for a in "$@"; do
        case $a in
            --dry-run) _DASH_DRY=1 ;;
            --compact) compact=1 ;;
        esac
    done

    dashboard_clear_screen
    dashboard_header
    dashboard_widget_connection_map # 1
    if [[ $compact != 1 ]]; then
        dashboard_widget_tor_circuits # 2
        dashboard_widget_bandwidth    # 3
    fi
    dashboard_widget_geo # 4
    if [[ $compact != 1 ]]; then
        dashboard_widget_uptime # 5
    fi
    dashboard_widget_alerts # 6
    dashboard_widget_system # 7
    dashboard_footer
}

# dashboard_loop [intervalo] [--dry-run] → refresca el dashboard cada N segundos.
# POR QUÉ un sleep troceado: permite responder a Ctrl+C casi de inmediato en
# lugar de esperar a que termine un sleep largo.
dashboard_loop() {
    local interval=${GHOST_DASH_REFRESH:-5} dry=${GHOST_DRY_RUN:-0} a
    for a in "$@"; do
        case $a in
            --dry-run) dry=1 ;;
            *[!0-9]*) ;; # ignora argumentos no numéricos
            *) interval=$a ;;
        esac
    done

    if [[ $dry == 1 ]]; then
        log_info "[dry-run] Refrescaría el dashboard cada ${interval}s (Ctrl+C para salir)."
        dashboard_render --dry-run
        return 0
    fi

    # Salida limpia con Ctrl+C: una bandera que el bucle consulta.
    local _dash_running=1
    trap '_dash_running=0' INT
    command -v tput >/dev/null 2>&1 && tput civis 2>/dev/null # ocultar cursor

    while [[ $_dash_running == 1 ]]; do
        dashboard_render
        local waited=0
        while [[ $waited -lt $interval && $_dash_running == 1 ]]; do
            sleep 1
            waited=$((waited + 1))
        done
    done

    command -v tput >/dev/null 2>&1 && tput cnorm 2>/dev/null # restaurar cursor
    trap - INT
    printf '\n'
    log_info "Dashboard cerrado."
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
#  API EXPUESTA (recordatorio)
#  Esto es una librería: `source lib/dashboard.sh` expone las funciones
#  dashboard_*. NO se ejecuta nada automáticamente ni hay main(): el orquestador
#  (joseph-trio) decide cuándo renderizar o entrar en el bucle. Todo es de solo
#  lectura; las funciones que consultan la red respetan --dry-run.
# ──────────────────────────────────────────────────────────────────────────────
