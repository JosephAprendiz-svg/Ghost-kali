#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  lib/torctl.sh — Gestión avanzada (y 100% defensiva) de Tor
# ──────────────────────────────────────────────────────────────────────────────
#  Habla el Tor Control Protocol contra 127.0.0.1:9051 SOLO para consultar y
#  gestionar de forma controlada tu propia instancia de Tor:
#    detección de auth, NEWNYM, circuitos, streams, exit node, ancho de banda,
#    uptime, ruta del circuito, panel de estado y verificación de salida.
#
#  ⚖️  DISCLAIMER: herramienta 100% DEFENSIVA. Cero ataques, cero exploits.
#      Solo lectura y comandos de control autorizados sobre tu propio Tor.
#
#  🔐 SEGURIDAD (invariantes de este archivo):
#      · NUNCA imprime el contenido de la cookie de control ni contraseñas.
#      · NUNCA escribe en /etc/tor/torrc.
#      · NUNCA modifica la configuración de Tor.
#      · Solo /dev/tcp (sin depender de torsocks ni proxychains internamente).
#
#  LIBRERÍA: cargar con `source lib/torctl.sh`, NO ejecutar. Depende de
#  lib/logger.sh y lib/validators.sh.
# ──────────────────────────────────────────────────────────────────────────────

# ── Guarda de ejecución directa ───────────────────────────────────────────────
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    printf 'Este archivo es una librería y debe cargarse con «source», no ejecutarse.\n' >&2
    printf 'Uso: source lib/torctl.sh\n' >&2
    exit 1
fi

# ── Guarda de idempotencia ────────────────────────────────────────────────────
[[ -n ${_GHOST_TORCTL_LOADED:-} ]] && return 0
_GHOST_TORCTL_LOADED=1

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
# Fallbacks mínimos de logging por si las librerías no estuvieran disponibles.
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
GHOST_TOR_CONTROL_PORT=${GHOST_TOR_CONTROL_PORT:-9051}
GHOST_TOR_SOCKS_PORT=${GHOST_TOR_SOCKS_PORT:-9050}
GHOST_TOR_CONTROL_HOST=${GHOST_TOR_CONTROL_HOST:-127.0.0.1}
GHOST_TOR_COOKIE_PATH=${GHOST_TOR_COOKIE_PATH:-/var/run/tor/control.authcookie}
GHOST_TORRC=${GHOST_TORRC:-/etc/tor/torrc}
# Timeout (s) para las lecturas del ControlPort; evita que cat se quede colgado.
GHOST_TOR_TIMEOUT=${GHOST_TOR_TIMEOUT:-10}

# ──────────────────────────────────────────────────────────────────────────────
#  TRANSPORTE DE BAJO NIVEL
#  POR QUÉ /dev/tcp: es nativo de bash, no añade dependencias (nc puede variar
#  entre traditional/openbsd/ncat) y nos basta para hablar con un puerto local.
# ──────────────────────────────────────────────────────────────────────────────

# _tor_open → abre el ControlPort en el descriptor 3, SIN ruido en stderr.
# POR QUÉ: si la conexión falla, bash imprime «connect: Connection refused» por
# su cuenta; silenciamos temporalmente stderr durante la apertura para que el
# único mensaje que vea el usuario sea el nuestro, claro y traducido.
_tor_open() {
    exec 4>&2 2>/dev/null
    exec 3<>"/dev/tcp/${GHOST_TOR_CONTROL_HOST}/${GHOST_TOR_CONTROL_PORT}"
    local rc=$?
    exec 2>&4 4>&-
    return $rc
}

# _tor_is_running → 0 si el ControlPort acepta conexiones, 1 si no.
# POR QUÉ: permite fallar rápido y con un mensaje claro antes de cada operación.
_tor_is_running() {
    _tor_open || return 1
    exec 3>&- 3<&-
    return 0
}

# _tor_require → comprueba conectividad y orienta al usuario si Tor no responde.
_tor_require() {
    if _tor_is_running; then
        return 0
    fi
    log_error "Tor no responde en ${GHOST_TOR_CONTROL_HOST}:${GHOST_TOR_CONTROL_PORT}."
    log_error "Comprueba el servicio (systemctl status tor) y que el ControlPort esté abierto."
    log_error "Si el ControlPort no está accesible, revisa docs/HARDENING.md."
    return 1
}

# _tor_raw COMANDOS... → envía comandos SIN autenticar (solo válido para
# PROTOCOLINFO, que el protocolo permite antes de autenticar) y QUIT.
_tor_raw() {
    _tor_open || return 1
    local c
    for c in "$@"; do printf '%s\r\n' "$c" >&3; done
    printf 'QUIT\r\n' >&3
    timeout "$GHOST_TOR_TIMEOUT" cat <&3 | tr -d '\r'
    exec 3>&- 3<&-
    return 0
}

# detect_tor_auth → detecta el método de autenticación del ControlPort.
# Imprime: cookie | password | none | error
# POR QUÉ vía PROTOCOLINFO: es la forma estándar y no requiere estar autenticado.
detect_tor_auth() {
    local resp methods cf
    resp=$(_tor_raw 'PROTOCOLINFO 1') || {
        printf 'error\n'
        return 1
    }

    methods=$(printf '%s\n' "$resp" | grep -oE 'METHODS=[A-Z,]+' | head -1 | cut -d= -f2)

    # Si Tor reporta la ruta real de la cookie, la adoptamos (no leemos su valor).
    cf=$(printf '%s\n' "$resp" | grep -oE 'COOKIEFILE="[^"]+"' | head -1 |
        sed -E 's/COOKIEFILE="(.*)"/\1/')
    [[ -n $cf ]] && GHOST_TOR_COOKIE_PATH=$cf

    # Preferimos COOKIE (o SAFECOOKIE) sobre contraseña. Comparamos tokens exactos.
    if [[ ,${methods}, == *,COOKIE,* || ,${methods}, == *,SAFECOOKIE,* ]]; then
        printf 'cookie\n'
    elif [[ ,${methods}, == *,HASHEDPASSWORD,* ]]; then
        printf 'password\n'
    elif [[ ,${methods}, == *,NULL,* ]]; then
        printf 'none\n'
    else
        printf 'error\n'
        return 1
    fi
}

# _tor_build_auth → construye la línea AUTHENTICATE adecuada.
# ⚠️ La salida contiene material sensible (cookie en hex o contraseña): se usa
#    ÚNICAMENTE para enviarla al socket. JAMÁS debe registrarse ni imprimirse.
_tor_build_auth() {
    local method
    method=$(detect_tor_auth) || return 1

    case $method in
        cookie)
            # Nota: SAFECOOKIE estricto exige un reto-respuesta HMAC que esta
            # librería no implementa; en la práctica los despliegues con
            # CookieAuthentication 1 también ofrecen COOKIE plano, que sí usamos.
            if [[ ! -r $GHOST_TOR_COOKIE_PATH ]]; then
                log_error "No se puede leer la cookie de control (${GHOST_TOR_COOKIE_PATH})."
                log_error "Ejecuta como root o revisa permisos del directorio de Tor."
                return 1
            fi
            local hex
            hex=$(od -An -v -tx1 "$GHOST_TOR_COOKIE_PATH" 2>/dev/null | tr -d ' \n')
            if [[ -z $hex ]]; then
                log_error "La cookie de control está vacía o no se pudo codificar."
                return 1
            fi
            printf 'AUTHENTICATE %s' "$hex"
            ;;
        password)
            if [[ -z ${GHOST_TOR_CONTROL_PASSWORD:-} ]]; then
                log_error "El ControlPort usa contraseña. Define GHOST_TOR_CONTROL_PASSWORD."
                log_error "(Tor solo guarda el hash en torrc; la contraseña en claro la aportas tú.)"
                return 1
            fi
            local p=${GHOST_TOR_CONTROL_PASSWORD//\\/\\\\}
            p=${p//\"/\\\"}
            printf 'AUTHENTICATE "%s"' "$p"
            ;;
        none)
            printf 'AUTHENTICATE'
            ;;
        *)
            log_error "No se pudo determinar el método de autenticación del ControlPort."
            return 1
            ;;
    esac
}

# _tor_exec COMANDO → autentica, envía UN comando y devuelve su respuesta.
# Códigos de retorno: 0 ok · 1 sin conexión · 2 auth no construible · 3 auth fallida
# La salida NO incluye la línea de AUTHENTICATE (para no exponer el resultado de
# auth al llamador) ni se registra el material de autenticación en ningún punto.
_tor_exec() {
    local auth
    auth=$(_tor_build_auth) || return 2

    _tor_open || return 1
    printf '%s\r\n' "$auth" >&3
    local c
    for c in "$@"; do printf '%s\r\n' "$c" >&3; done
    printf 'QUIT\r\n' >&3

    local all
    all=$(timeout "$GHOST_TOR_TIMEOUT" cat <&3 | tr -d '\r')
    exec 3>&- 3<&-

    # La primera línea es la respuesta a AUTHENTICATE.
    local first
    first=$(printf '%s\n' "$all" | head -1)
    if [[ $first != 250* ]]; then
        return 3
    fi
    # Devolvemos todo menos esa primera línea.
    printf '%s\n' "$all" | sed '1d'
    return 0
}

# _tor_getinfo_one CLAVE → valor de un GETINFO de una sola línea.
_tor_getinfo_one() {
    local key=$1 resp rc
    resp=$(_tor_exec "GETINFO ${key}")
    rc=$?
    [[ $rc -ne 0 ]] && return $rc
    printf '%s\n' "$resp" | sed -nE "s#^250[ +-]${key}=(.*)\$#\1#p" | head -1
}

# _tor_getinfo_multi CLAVE → líneas de datos de un GETINFO multilínea (250+ ... .)
_tor_getinfo_multi() {
    local key=$1 resp rc line inblock=0
    resp=$(_tor_exec "GETINFO ${key}")
    rc=$?
    [[ $rc -ne 0 ]] && return $rc
    while IFS= read -r line; do
        if [[ $inblock -eq 1 ]]; then
            [[ $line == "." ]] && {
                inblock=0
                continue
            }
            printf '%s\n' "$line"
        elif [[ $line == "250+${key}="* ]]; then
            inblock=1
        fi
    done <<<"$resp"
}

# ──────────────────────────────────────────────────────────────────────────────
#  UTILIDADES DE FORMATO
# ──────────────────────────────────────────────────────────────────────────────

# _human_bytes N → formatea un número de bytes a unidades legibles.
_human_bytes() {
    awk -v b="${1:-0}" 'BEGIN{
        split("B KiB MiB GiB TiB",u," "); i=1;
        while (b>=1024 && i<5){ b/=1024; i++ }
        if (i==1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i]
    }'
}

# _human_duration SEGUNDOS → formatea una duración a «Nd HHh MMm SSs».
_human_duration() {
    local s=${1:-0} d h m
    [[ $s =~ ^[0-9]+$ ]] || s=0
    d=$((s / 86400))
    s=$((s % 86400))
    h=$((s / 3600))
    s=$((s % 3600))
    m=$((s / 60))
    s=$((s % 60))
    printf '%dd %02dh %02dm %02ds' "$d" "$h" "$m" "$s"
}

# _tor_node_ip FINGERPRINT → IP del relay (consulta GETINFO ns/id/$FP).
_tor_node_ip() {
    local fp=$1 ns
    [[ -n $fp ]] || return 1
    ns=$(_tor_exec "GETINFO ns/id/\$${fp}") || return 1
    # En la línea «r»: r nick id digest fecha hora IP ORPort DirPort → IP es $7.
    printf '%s\n' "$ns" | awk '/^r /{print $7; exit}'
}

# _tor_ip_country IP → código de país del relay (GETINFO ip-to-country/IP).
_tor_ip_country() {
    local ip=$1 cc
    [[ -n $ip ]] || {
        printf '??'
        return
    }
    cc=$(_tor_getinfo_one "ip-to-country/${ip}" 2>/dev/null)
    printf '%s' "${cc:-??}"
}

# _tor_latest_general_circuit → línea del circuito GENERAL construido más reciente.
_tor_latest_general_circuit() {
    local data line best=""
    data=$(_tor_getinfo_multi circuit-status) || return 1
    while IFS= read -r line; do
        [[ $line == *"PURPOSE=GENERAL"* ]] || continue
        [[ $line == *" BUILT "* ]] || continue
        best=$line # el más reciente aparece al final del listado
    done <<<"$data"
    [[ -n $best ]] || return 1
    printf '%s\n' "$best"
}

# ──────────────────────────────────────────────────────────────────────────────
#  API PÚBLICA
# ──────────────────────────────────────────────────────────────────────────────

# tor_authenticate → verifica que podemos autenticarnos en el ControlPort.
tor_authenticate() {
    _tor_require || return 1
    local ver rc
    ver=$(_tor_getinfo_one version)
    rc=$?
    if [[ $rc -eq 0 && -n $ver ]]; then
        log_ok "Autenticado en el ControlPort de Tor (versión ${ver})."
        return 0
    fi
    case $rc in
        3) log_error "Autenticación rechazada por el ControlPort." ;;
        2) log_error "No se pudo construir la autenticación (cookie/contraseña)." ;;
        *) log_error "El ControlPort no respondió como se esperaba (código ${rc})." ;;
    esac
    log_error "Configura cookie (CookieAuthentication 1) o contraseña. Ver docs/HARDENING.md."
    return 1
}

# tor_newnym [--dry-run] → solicita una nueva identidad (SIGNAL NEWNYM).
tor_newnym() {
    local dry=${GHOST_DRY_RUN:-0}
    [[ ${1:-} == --dry-run ]] && dry=1

    if [[ $dry == 1 ]]; then
        log_info "[dry-run] Enviaría «SIGNAL NEWNYM» para obtener una nueva identidad Tor."
        return 0
    fi

    _tor_require || return 1
    if _tor_exec 'SIGNAL NEWNYM' >/dev/null; then
        log_ok "Nueva identidad Tor solicitada (SIGNAL NEWNYM)."
        return 0
    fi
    log_error "No se pudo solicitar una nueva identidad. ¿ControlPort accesible y autenticado?"
    return 1
}

# tor_get_circuits → lista los circuitos activos.
tor_get_circuits() {
    _tor_require || return 1
    local data
    data=$(_tor_getinfo_multi circuit-status) || {
        log_error "No se pudieron obtener los circuitos (¿autenticación correcta?)."
        return 1
    }
    if [[ -z $data ]]; then
        log_warn "No hay circuitos activos en este momento."
        return 0
    fi
    log_section "Circuitos Tor activos"
    local line id status
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        id=$(awk '{print $1}' <<<"$line")
        status=$(awk '{print $2}' <<<"$line")
        log_table "Circuito ${id}" "${status}"
    done <<<"$data"
    return 0
}

# tor_get_streams → lista los streams activos.
tor_get_streams() {
    _tor_require || return 1
    local data
    data=$(_tor_getinfo_multi stream-status) || {
        log_error "No se pudieron obtener los streams."
        return 1
    }
    if [[ -z $data ]]; then
        log_warn "No hay streams activos en este momento."
        return 0
    fi
    log_section "Streams Tor activos"
    local line sid sstatus target
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        sid=$(awk '{print $1}' <<<"$line")
        sstatus=$(awk '{print $2}' <<<"$line")
        target=$(awk '{print $4}' <<<"$line")
        log_table "Stream ${sid}" "${sstatus} → ${target:-?}"
    done <<<"$data"
    return 0
}

# tor_close_stream <ID> [--dry-run] [--non-interactive|--yes]
# Cierra un stream por ID. Pide confirmación salvo en modo no interactivo.
tor_close_stream() {
    local id="" dry=${GHOST_DRY_RUN:-0} noninteractive=${GHOST_NON_INTERACTIVE:-0}
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run) dry=1 ;;
            --yes | --non-interactive) noninteractive=1 ;;
            *) id=$1 ;;
        esac
        shift
    done

    if [[ -z $id ]]; then
        log_error "Uso: tor_close_stream <ID> [--dry-run] [--non-interactive]"
        return 1
    fi
    if ! [[ $id =~ ^[0-9]+$ ]]; then
        log_error "ID de stream inválido: «${id}» (debe ser numérico)."
        return 1
    fi

    if [[ $dry == 1 ]]; then
        log_info "[dry-run] Cerraría el stream ${id} con «CLOSESTREAM ${id} 1»."
        return 0
    fi

    if [[ $noninteractive != 1 ]]; then
        printf 'Vas a cerrar el stream %s. ¿Continuar? [s/N] ' "$id"
        local ans
        read -r ans
        if ! [[ $ans =~ ^[sSyY]$ ]]; then
            log_warn "Operación cancelada."
            return 1
        fi
    fi

    _tor_require || return 1
    # Razón 1 = REASON_MISC (cierre genérico solicitado por el usuario).
    if _tor_exec "CLOSESTREAM ${id} 1" >/dev/null; then
        log_ok "Stream ${id} cerrado."
        return 0
    fi
    log_error "No se pudo cerrar el stream ${id}."
    return 1
}

# tor_get_exit_nodes → muestra información del nodo de salida actual.
tor_get_exit_nodes() {
    _tor_require || return 1
    local circ path exit_hop fp ip country
    circ=$(_tor_latest_general_circuit) || {
        log_warn "Aún no hay un circuito GENERAL construido."
        return 1
    }
    path=$(awk '{print $3}' <<<"$circ")
    exit_hop=${path##*,}
    fp=${exit_hop%%~*}
    fp=${fp#\$}
    ip=$(_tor_node_ip "$fp")
    country=$(_tor_ip_country "$ip")
    log_section "Nodo de salida actual"
    log_table "Fingerprint" "$fp" "IP" "${ip:-desconocida}" "País" "${country:-??}"
    return 0
}

# tor_get_consensus_info → información básica de conectividad/consenso.
# POR QUÉ no volcamos el consenso completo: es enorme y ruidoso; nos quedamos con
# las señales útiles de estado (versión, bootstrap, circuito, dormancia).
tor_get_consensus_info() {
    _tor_require || return 1
    local ver estab dormant boot
    ver=$(_tor_getinfo_one version)
    estab=$(_tor_getinfo_one status/circuit-established)
    dormant=$(_tor_getinfo_one dormant)
    boot=$(_tor_getinfo_one status/bootstrap-phase)
    log_section "Estado del consenso / conectividad"
    log_table \
        "Versión Tor" "${ver:-?}" \
        "Circuito establecido" "${estab:-?}" \
        "Inactivo (dormant)" "${dormant:-?}" \
        "Bootstrap" "${boot:-?}"
    return 0
}

# tor_check_bridges → comprueba si hay bridges configurados en torrc.
# POR PRIVACIDAD: informa de CUÁNTOS bridges hay, pero NUNCA imprime sus direcciones.
tor_check_bridges() {
    if [[ ! -r $GHOST_TORRC ]]; then
        log_warn "No se pudo leer ${GHOST_TORRC}."
        return 1
    fi
    local use count
    use=$(grep -Eic '^[[:space:]]*UseBridges[[:space:]]+1' "$GHOST_TORRC" || true)
    count=$(grep -Eic '^[[:space:]]*Bridge[[:space:]]+' "$GHOST_TORRC" || true)

    if [[ $use -ge 1 && $count -ge 1 ]]; then
        log_ok "Bridges habilitados: ${count} configurado(s)."
    elif [[ $count -ge 1 ]]; then
        log_warn "Hay ${count} bridge(s) en torrc, pero «UseBridges 1» no está activo."
    else
        log_info "No hay bridges configurados (conexión directa a la red Tor)."
    fi
    return 0
}

# tor_bandwidth_stats → estadísticas acumuladas de tráfico.
tor_bandwidth_stats() {
    _tor_require || return 1
    local r w
    r=$(_tor_getinfo_one traffic/read)
    w=$(_tor_getinfo_one traffic/written)
    if [[ -z $r && -z $w ]]; then
        log_error "No se pudieron obtener las estadísticas de tráfico."
        return 1
    fi
    log_section "Ancho de banda de Tor (acumulado)"
    log_table "Leído" "$(_human_bytes "${r:-0}")" "Escrito" "$(_human_bytes "${w:-0}")"
    return 0
}

# tor_uptime → tiempo que lleva corriendo Tor (vía ControlPort o, si no, proceso).
tor_uptime() {
    local secs
    secs=$(_tor_getinfo_one uptime 2>/dev/null)
    if ! [[ $secs =~ ^[0-9]+$ ]]; then
        # Fallback: tiempo de vida del proceso tor.
        local pid
        pid=$(pgrep -x tor 2>/dev/null | head -1)
        [[ -n $pid ]] && secs=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
    fi
    if [[ $secs =~ ^[0-9]+$ ]]; then
        log_section "Uptime de Tor"
        log_table "Tiempo activo" "$(_human_duration "$secs")"
        return 0
    fi
    log_warn "No se pudo determinar el uptime de Tor."
    return 1
}

# tor_circuit_path → muestra la ruta (saltos y países) del circuito actual.
tor_circuit_path() {
    _tor_require || return 1
    local circ path
    circ=$(_tor_latest_general_circuit) || {
        log_warn "Aún no hay un circuito GENERAL construido."
        return 1
    }
    path=$(awk '{print $3}' <<<"$circ")

    log_section "Ruta del circuito actual"
    local -a hops
    IFS=',' read -ra hops <<<"$path"
    local n=${#hops[@]} i=1 hop fp ip country role
    for hop in "${hops[@]}"; do
        fp=${hop%%~*}
        fp=${fp#\$}
        ip=$(_tor_node_ip "$fp")
        country=$(_tor_ip_country "$ip")
        if [[ $i -eq 1 ]]; then
            role="Entrada"
        elif [[ $i -eq $n ]]; then
            role="Salida"
        else
            role="Intermedio"
        fi
        log_table "Salto ${i} (${role})" "${ip:-?} [${country:-??}]"
        i=$((i + 1))
    done
    return 0
}

# tor_status_panel → resumen compacto del estado de Tor.
tor_status_panel() {
    log_section "Panel de estado de Tor"
    if ! _tor_is_running; then
        log_error "Tor no está accesible en ${GHOST_TOR_CONTROL_HOST}:${GHOST_TOR_CONTROL_PORT}."
        return 1
    fi
    local ver estab exitcc="??" circ
    ver=$(_tor_getinfo_one version)
    estab=$(_tor_getinfo_one status/circuit-established)
    if circ=$(_tor_latest_general_circuit 2>/dev/null); then
        local p ex fp ip
        p=$(awk '{print $3}' <<<"$circ")
        ex=${p##*,}
        fp=${ex%%~*}
        fp=${fp#\$}
        ip=$(_tor_node_ip "$fp")
        exitcc=$(_tor_ip_country "$ip")
    fi
    log_table \
        "ControlPort" "${GHOST_TOR_CONTROL_HOST}:${GHOST_TOR_CONTROL_PORT}" \
        "Versión" "${ver:-?}" \
        "Circuito establecido" "${estab:-?}" \
        "País de salida" "${exitcc:-??}"
    return 0
}

# tor_verify_exit → comprueba que el tráfico realmente sale por Tor.
# Usa --socks5-hostname para que también la DNS viaje por Tor (evita fuga de DNS).
tor_verify_exit() {
    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl no está instalado; no se puede verificar la salida."
        return 1
    fi
    local url="https://check.torproject.org/api/ip" out
    out=$(curl -fsS --max-time 15 \
        --socks5-hostname "${GHOST_TOR_CONTROL_HOST}:${GHOST_TOR_SOCKS_PORT}" \
        "$url" 2>/dev/null)

    if [[ -z $out ]]; then
        log_error "Sin respuesta de ${url} a través del SOCKS de Tor (${GHOST_TOR_SOCKS_PORT})."
        log_error "¿Tor escucha en ${GHOST_TOR_SOCKS_PORT}? ¿Hay conectividad de red?"
        return 1
    fi

    if printf '%s' "$out" | grep -qi '"IsTor"[[:space:]]*:[[:space:]]*true'; then
        log_ok "El tráfico SALE por Tor. ✔"
        local ip
        ip=$(printf '%s' "$out" | grep -oE '"IP":"[^"]+"' | head -1 |
            sed -E 's/"IP":"(.*)"/\1/')
        [[ -n $ip ]] && log_info "IP de salida observada: ${ip}"
        return 0
    fi

    log_error "El tráfico NO sale por Tor según check.torproject.org."
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
#  API EXPUESTA (recordatorio)
#  Esto es una librería: al hacer `source lib/torctl.sh` quedan disponibles las
#  funciones públicas anteriores. NO se ejecuta ninguna acción automáticamente;
#  el orquestador (joseph-trio) decide qué invocar. No hay main() a propósito.
# ──────────────────────────────────────────────────────────────────────────────
