#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  lib/vpnctl.sh — Gestión avanzada (y 100% defensiva) de Mullvad VPN
# ──────────────────────────────────────────────────────────────────────────────
#  Panel de control sobre el cliente oficial `mullvad` para gestionar TU propia
#  suscripción: estado, conexión, relays, protocolo, lockdown, DNS, IPv6, fugas,
#  IP pública y recomendaciones. Solo consulta y configura tu VPN.
#
#  ⚖️  DISCLAIMER ÉTICO/LEGAL: herramienta 100% DEFENSIVA. No ataca, no escanea
#      redes ajenas, no explota nada. Funciones como «lockdown» o «killswitch»
#      existen para PROTEGER tu privacidad legítima (evitar fugas si el túnel
#      cae), NO para ocultar actividad ilícita. El uso responsable y legal es
#      responsabilidad exclusiva del usuario.
#
#  🔐 PRIVACIDAD (invariantes de este archivo):
#      · NUNCA imprime el número de cuenta completo (solo «**** **** XXXX»).
#      · NUNCA imprime tokens, códigos de login ni credenciales.
#      · NUNCA usa eval, rm -rf, iptables -F, killall, pkill, ni systemctl stop.
#      · Solo gestiona el dominio del propio cliente Mullvad.
#
#  LIBRERÍA: cargar con `source lib/vpnctl.sh`, NO ejecutar. Depende de
#  lib/logger.sh y lib/validators.sh.
# ──────────────────────────────────────────────────────────────────────────────

# ── Guarda de ejecución directa ───────────────────────────────────────────────
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	printf 'Este archivo es una librería y debe cargarse con «source», no ejecutarse.\n' >&2
	printf 'Uso: source lib/vpnctl.sh\n' >&2
	exit 1
fi

# ── Guarda de idempotencia ────────────────────────────────────────────────────
[[ -n ${_GHOST_VPNCTL_LOADED:-} ]] && return 0
_GHOST_VPNCTL_LOADED=1

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
GHOST_MULLVAD_BIN=${GHOST_MULLVAD_BIN:-mullvad}
GHOST_MULLVAD_TIMEOUT=${GHOST_MULLVAD_TIMEOUT:-15}
GHOST_VPN_CHECK_URL=${GHOST_VPN_CHECK_URL:-https://am.i.mullvad.net/json}
GHOST_VPN_LEAK_URL=${GHOST_VPN_LEAK_URL:-https://mullvad.net/check/}

# Estado de parseo de flags globales (lo rellena _vpn_parse_global_flags).
_VPN_DRY=0
_VPN_YES=0
declare -ga _VPN_POS=()

# ──────────────────────────────────────────────────────────────────────────────
#  HELPERS PRIVADOS
# ──────────────────────────────────────────────────────────────────────────────

# _vpn_installed → predicado silencioso: 0 si el CLI de Mullvad está disponible.
_vpn_installed() { command -v "$GHOST_MULLVAD_BIN" >/dev/null 2>&1; }

# _vpn_require_installed → exige el CLI y, si falta, orienta sobre cómo instalarlo.
_vpn_require_installed() {
	if _vpn_installed; then
		return 0
	fi
	log_error "El cliente «mullvad» no está instalado."
	log_error "Instálalo con: sudo apt install mullvad-vpn — o descárgalo de https://mullvad.net/download/"
	return 1
}

# _vpn_mullvad ARGS... → ejecuta `mullvad ARGS` con timeout y captura stdout+stderr.
# POR QUÉ 2>&1: queremos el mensaje de error del propio cliente para mostrarlo
# tal cual si algo falla (p. ej. una sintaxis que cambió entre versiones).
_vpn_mullvad() {
	timeout "$GHOST_MULLVAD_TIMEOUT" "$GHOST_MULLVAD_BIN" "$@" 2>&1
}

# _vpn_parse_global_flags ARGS... → separa flags globales de los posicionales.
# Rellena _VPN_DRY, _VPN_YES y el array _VPN_POS. POR QUÉ: centralizar el parseo
# de --dry-run / --non-interactive / --yes evita repetir lógica en cada función.
_vpn_parse_global_flags() {
	_VPN_DRY=${GHOST_DRY_RUN:-0}
	_VPN_YES=${GHOST_NON_INTERACTIVE:-0}
	_VPN_POS=()
	local a
	for a in "$@"; do
		case $a in
		--dry-run) _VPN_DRY=1 ;;
		--non-interactive | --yes) _VPN_YES=1 ;;
		*) _VPN_POS+=("$a") ;;
		esac
	done
}

# _vpn_dry MENSAJE → imprime una acción simulada (modo --dry-run).
_vpn_dry() { log_info "[dry-run] $*"; }

# _vpn_confirm PREGUNTA → pide confirmación salvo en modo no interactivo.
# POR QUÉ: las acciones de alto impacto (cortar tráfico, cambiar servidor) no
# deben ejecutarse por accidente.
_vpn_confirm() {
	[[ ${_VPN_YES:-0} == 1 ]] && return 0
	printf '%s [s/N]: ' "$1"
	local ans
	read -r ans
	if [[ $ans =~ ^[sSyY]$ ]]; then
		return 0
	fi
	log_warn "Operación cancelada."
	return 1
}

# _vpn_apply DESCRIPCIÓN ARGS... → ejecuta una acción de Mullvad y la registra.
# Muestra el error del cliente si falla, sin abortar el shell del usuario.
_vpn_apply() {
	local desc=$1
	shift
	local out rc
	out=$(_vpn_mullvad "$@")
	rc=$?
	if [[ $rc -eq 0 ]]; then
		log_ok "$desc"
		[[ -n $out ]] && log_info "$out"
		return 0
	fi
	log_error "No se pudo completar: ${desc}"
	[[ -n $out ]] && log_error "Mullvad respondió: ${out}"
	return 1
}

# _vpn_mask_account SALIDA → imprime SOLO «**** **** XXXX» a partir de la salida
# de `mullvad account get`. Nunca expone el número completo.
_vpn_mask_account() {
	local raw=$1 line digits
	line=$(grep -iE 'account' <<<"$raw" | head -1)
	digits=$(printf '%s' "$line" | tr -cd '0-9')
	if [[ ${#digits} -ge 4 ]]; then
		printf '**** **** %s' "${digits: -4}"
	else
		printf '**** **** ****'
	fi
}

# _vpn_find_wg_interface → nombre de la interfaz WireGuard de Mullvad, si existe.
_vpn_find_wg_interface() {
	ip -o link show 2>/dev/null | awk -F': ' '{print $2}' |
		grep -iE 'mullvad|^wg' | head -1
}

# _vpn_json_get JSON CLAVE → valor de una clave JSON (string o booleano).
# POR QUÉ con jq opcional: si jq está disponible parseamos de forma robusta; si
# no, recurrimos a un extractor simple con grep/sed para no añadir dependencias.
_vpn_json_get() {
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

# _vpn_human_bytes N → formatea bytes a unidades legibles (numfmt o, si no, awk).
_vpn_human_bytes() {
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

# ──────────────────────────────────────────────────────────────────────────────
#  API PÚBLICA — comprobaciones y estado
# ──────────────────────────────────────────────────────────────────────────────

# vpn_is_installed → informa si el cliente Mullvad está instalado.
vpn_is_installed() {
	if _vpn_installed; then
		log_ok "Cliente Mullvad detectado: $(command -v "$GHOST_MULLVAD_BIN")"
		return 0
	fi
	_vpn_require_installed
}

# vpn_is_logged_in → indica si hay sesión activa SIN revelar el número de cuenta.
vpn_is_logged_in() {
	_vpn_require_installed || return 1
	local out rc
	out=$(_vpn_mullvad account get)
	rc=$?
	if [[ $rc -eq 0 ]] && ! grep -qiE 'not logged in' <<<"$out" &&
		grep -qiE 'expir|account|device' <<<"$out"; then
		log_ok "Sesión de Mullvad activa."
		return 0
	fi
	log_warn "No hay sesión de Mullvad. Inicia con: mullvad account login <número> (no compartas el número)."
	return 1
}

# vpn_version → versión del cliente Mullvad.
vpn_version() {
	_vpn_require_installed || return 1
	log_section "Versión de Mullvad"
	printf '%s\n' "$(_vpn_mullvad version)"
}

# vpn_status → estado detallado de la conexión (salida cruda de mullvad status).
# Nota: puede incluir tu IP de salida (tu propia información), nunca credenciales.
vpn_status() {
	_vpn_require_installed || return 1
	local out rc
	out=$(_vpn_mullvad status)
	rc=$?
	if [[ $rc -ne 0 ]]; then
		log_error "No se pudo obtener el estado de Mullvad."
		[[ -n $out ]] && log_error "$out"
		return 1
	fi
	log_section "Estado de Mullvad VPN"
	printf '%s\n' "$out"
}

# vpn_account_info → datos de cuenta con el número ENMASCARADO («**** **** XXXX»).
vpn_account_info() {
	_vpn_require_installed || return 1
	local out rc
	out=$(_vpn_mullvad account get)
	rc=$?
	if [[ $rc -ne 0 ]] || grep -qiE 'not logged in' <<<"$out"; then
		log_warn "No hay sesión de Mullvad. Inicia con: mullvad account login <número>."
		return 1
	fi

	local masked expiry device
	masked=$(_vpn_mask_account "$out")
	expiry=$(grep -iE 'expir' <<<"$out" | head -1 | sed -E 's/^[^:]*:[[:space:]]*//')
	device=$(grep -iE 'device' <<<"$out" | head -1 | sed -E 's/^[^:]*:[[:space:]]*//')

	log_section "Cuenta de Mullvad"
	log_table "Número de cuenta" "$masked" "Expira" "${expiry:-?}" "Dispositivo" "${device:-?}"
}

# ──────────────────────────────────────────────────────────────────────────────
#  API PÚBLICA — conexión
# ──────────────────────────────────────────────────────────────────────────────

# vpn_connect [--dry-run] [--non-interactive] [--yes] → conecta Mullvad.
vpn_connect() {
	_vpn_require_installed || return 1
	_vpn_parse_global_flags "$@"
	if [[ ${_VPN_DRY} == 1 ]]; then
		_vpn_dry "Ejecutaría: ${GHOST_MULLVAD_BIN} connect"
		return 0
	fi
	_vpn_confirm "¿Conectar Mullvad VPN ahora?" || return 1
	_vpn_apply "Mullvad conectado." connect
}

# vpn_disconnect [--dry-run] [--non-interactive] [--yes] → desconecta Mullvad.
vpn_disconnect() {
	_vpn_require_installed || return 1
	_vpn_parse_global_flags "$@"
	if [[ ${_VPN_DRY} == 1 ]]; then
		_vpn_dry "Ejecutaría: ${GHOST_MULLVAD_BIN} disconnect"
		return 0
	fi
	_vpn_confirm "¿Desconectar Mullvad VPN? Esto expondrá tu IP real." || return 1
	_vpn_apply "Mullvad desconectado." disconnect
}

# vpn_reconnect [--dry-run] [--non-interactive] [--yes] → reconecta Mullvad.
vpn_reconnect() {
	_vpn_require_installed || return 1
	_vpn_parse_global_flags "$@"
	if [[ ${_VPN_DRY} == 1 ]]; then
		_vpn_dry "Ejecutaría: ${GHOST_MULLVAD_BIN} reconnect"
		return 0
	fi
	_vpn_confirm "¿Reconectar Mullvad? Habrá una breve interrupción." || return 1
	_vpn_apply "Mullvad reconectado." reconnect
}

# ──────────────────────────────────────────────────────────────────────────────
#  API PÚBLICA — relays
# ──────────────────────────────────────────────────────────────────────────────

# vpn_list_relays [country] → lista relays; filtra por código de país de 2 letras.
vpn_list_relays() {
	_vpn_require_installed || return 1
	local country=${1:-} out rc
	out=$(_vpn_mullvad relay list)
	rc=$?
	if [[ $rc -ne 0 ]]; then
		log_error "No se pudo obtener la lista de relays."
		[[ -n $out ]] && log_error "$out"
		return 1
	fi

	if [[ -z $country ]]; then
		log_section "Relays de Mullvad disponibles"
		printf '%s\n' "$out"
		return 0
	fi

	country=${country,,}
	local filtered
	# Imprime el bloque del país (cabecera sin sangría) y sus líneas indentadas.
	filtered=$(printf '%s\n' "$out" | awk -v cc="($country)" '
        /^[^[:space:]]/ { show = (index(tolower($0), cc) > 0) }
        show { print }
    ')
	if [[ -z $filtered ]]; then
		log_warn "No se encontraron relays para el país «${country}»."
		return 1
	fi
	log_section "Relays en país: ${country}"
	printf '%s\n' "$filtered"
}

# vpn_get_relay → relay/constraint actualmente configurado.
vpn_get_relay() {
	_vpn_require_installed || return 1
	local out rc
	out=$(_vpn_mullvad relay get)
	rc=$?
	if [[ $rc -ne 0 ]]; then
		log_error "No se pudo obtener el relay actual."
		[[ -n $out ]] && log_error "$out"
		return 1
	fi
	log_section "Relay actual configurado"
	printf '%s\n' "$out"
}

# vpn_set_relay <country> [city] [hostname] [--dry-run] [--non-interactive] [--yes]
vpn_set_relay() {
	_vpn_require_installed || return 1
	_vpn_parse_global_flags "$@"
	local country=${_VPN_POS[0]:-} city=${_VPN_POS[1]:-} host=${_VPN_POS[2]:-}

	if [[ -z $country ]]; then
		log_error "Uso: vpn_set_relay <país-2-letras> [ciudad] [hostname] [--dry-run]"
		return 1
	fi
	if ! [[ $country =~ ^[A-Za-z]{2}$ ]]; then
		log_error "El país debe ser un código ISO de 2 letras (p. ej. de, se, us)."
		return 1
	fi
	country=${country,,}

	local -a args=(relay set location "$country")
	[[ -n $city ]] && args+=("$city")
	[[ -n $host ]] && args+=("$host")
	local human="${country}${city:+ $city}${host:+ $host}"

	if [[ ${_VPN_DRY} == 1 ]]; then
		_vpn_dry "Ejecutaría: ${GHOST_MULLVAD_BIN} ${args[*]}"
		return 0
	fi
	_vpn_confirm "¿Cambiar el relay a «${human}»?" || return 1
	_vpn_apply "Relay fijado a: ${human}" "${args[@]}"
}

# vpn_recommend_relay [country] [--dry-run] → sugiere un relay.
# NOTA: el CLI de Mullvad NO expone la latencia de los relays directamente; por
# eso, como mejor esfuerzo, medimos nosotros con ping a unos pocos candidatos
# (tráfico hacia tu propio proveedor, nunca un escaneo de terceros).
vpn_recommend_relay() {
	_vpn_require_installed || return 1
	_vpn_parse_global_flags "$@"
	local country=${_VPN_POS[0]:-}

	log_info "Mullvad no expone la latencia de los relays; la mediremos con ping (mejor esfuerzo)."

	if [[ ${_VPN_DRY} == 1 ]]; then
		_vpn_dry "Actualizaría la lista de relays y mediría latencia a candidatos."
		return 0
	fi

	_vpn_mullvad relay update >/dev/null 2>&1 || true
	local list filtered
	list=$(_vpn_mullvad relay list 2>/dev/null)
	filtered=$list
	if [[ -n $country ]]; then
		country=${country,,}
		filtered=$(printf '%s\n' "$list" | awk -v cc="($country)" '
            /^[^[:space:]]/ { show = (index(tolower($0), cc) > 0) }
            show { print }
        ')
	fi

	local -a hosts
	mapfile -t hosts < <(printf '%s\n' "$filtered" |
		grep -oE '[a-z]{2}-[a-z]+-wg-[0-9]+' | head -5)
	if [[ ${#hosts[@]} -eq 0 ]]; then
		log_warn "No encontré relays WireGuard para medir."
		log_info "Sugerencia: deja que Mullvad elija automáticamente: mullvad relay set location ${country:-<país>}"
		return 1
	fi

	if ! command -v ping >/dev/null 2>&1; then
		log_warn "«ping» no está disponible; no puedo medir latencia."
		log_info "Candidatos: ${hosts[*]}"
		return 0
	fi

	log_section "Recomendación de relay por latencia"
	local best="" bestrtt="" h fqdn rtt
	for h in "${hosts[@]}"; do
		fqdn="${h}.relays.mullvad.net"
		rtt=$(ping -n -c1 -W1 "$fqdn" 2>/dev/null |
			sed -nE 's/.*time=([0-9.]+).*/\1/p' | head -1)
		if [[ -n $rtt ]]; then
			log_table "$h" "${rtt} ms"
			if [[ -z $bestrtt ]] || awk -v a="$rtt" -v b="$bestrtt" 'BEGIN{exit !(a<b)}'; then
				bestrtt=$rtt
				best=$h
			fi
		else
			log_table "$h" "sin respuesta"
		fi
	done

	if [[ -n $best ]]; then
		log_ok "Relay recomendado: ${best} (${bestrtt} ms)."
	else
		log_warn "Ningún candidato respondió al ping."
	fi
}

# ──────────────────────────────────────────────────────────────────────────────
#  API PÚBLICA — protocolo y opciones de túnel
# ──────────────────────────────────────────────────────────────────────────────

# vpn_set_protocol <wireguard|openvpn> [--dry-run] [--non-interactive] [--yes]
vpn_set_protocol() {
	_vpn_require_installed || return 1
	_vpn_parse_global_flags "$@"
	local proto=${_VPN_POS[0]:-}
	proto=${proto,,}
	case $proto in
	wireguard | openvpn) ;;
	*)
		log_error "Protocolo inválido. Usa: wireguard u openvpn."
		return 1
		;;
	esac
	[[ $proto == openvpn ]] &&
		log_warn "Mullvad está retirando OpenVPN gradualmente; WireGuard es el recomendado."

	if [[ ${_VPN_DRY} == 1 ]]; then
		_vpn_dry "Ejecutaría: ${GHOST_MULLVAD_BIN} relay set tunnel-protocol ${proto}"
		return 0
	fi
	_vpn_confirm "¿Cambiar el protocolo del túnel a ${proto}?" || return 1
	# NOTA: la sintaxis exacta puede variar según la versión de Mullvad; si falla,
	# se muestra el error del propio cliente para que ajustes el comando.
	_vpn_apply "Protocolo del túnel cambiado a ${proto}." relay set tunnel-protocol "$proto"
}

# vpn_get_protocol → protocolo del túnel actualmente configurado.
vpn_get_protocol() {
	_vpn_require_installed || return 1
	local out rc line
	out=$(_vpn_mullvad relay get)
	rc=$?
	if [[ $rc -ne 0 ]]; then
		log_error "No se pudo obtener el protocolo."
		[[ -n $out ]] && log_error "$out"
		return 1
	fi
	log_section "Protocolo del túnel"
	line=$(grep -iE 'tunnel|protocol' <<<"$out" | head -1)
	if [[ -n $line ]]; then
		log_info "$line"
	else
		printf '%s\n' "$out"
	fi
}

# vpn_ipv6 <on|off> [--dry-run] [--non-interactive] [--yes] → IPv6 en el túnel.
vpn_ipv6() {
	_vpn_require_installed || return 1
	_vpn_parse_global_flags "$@"
	local state=${_VPN_POS[0]:-}
	state=${state,,}
	case $state in
	on | off) ;;
	*)
		log_error "Uso: vpn_ipv6 <on|off>"
		return 1
		;;
	esac
	if [[ ${_VPN_DRY} == 1 ]]; then
		_vpn_dry "Ejecutaría: ${GHOST_MULLVAD_BIN} tunnel set ipv6 ${state}"
		return 0
	fi
	_vpn_confirm "¿Cambiar IPv6 del túnel a ${state}?" || return 1
	# NOTA: si tu versión de Mullvad usa otra sintaxis, se mostrará su error.
	_vpn_apply "IPv6 del túnel: ${state}." tunnel set ipv6 "$state"
}

# ──────────────────────────────────────────────────────────────────────────────
#  API PÚBLICA — protección de red (lockdown / killswitch / DNS)
# ──────────────────────────────────────────────────────────────────────────────

# _vpn_lockdown_apply <on|off> → aplica el modo lockdown (flags ya parseados).
# NOTA ÉTICA/LEGAL: el lockdown bloquea TODO el tráfico fuera del túnel para
# proteger tu privacidad si la VPN cae. No es un mecanismo para ocultar abusos.
_vpn_lockdown_apply() {
	local state=$1
	case $state in
	on | off) ;;
	*)
		log_error "Estado inválido: usa «on» u «off»."
		return 1
		;;
	esac
	if [[ ${_VPN_DRY} == 1 ]]; then
		_vpn_dry "Ejecutaría: ${GHOST_MULLVAD_BIN} lockdown-mode set ${state}"
		return 0
	fi
	local verbo="activar"
	[[ $state == off ]] && verbo="desactivar"
	_vpn_confirm "¿Seguro que deseas ${verbo} el modo lockdown? Afecta a TODO el tráfico." || return 1
	_vpn_apply "Modo lockdown: ${state}." lockdown-mode set "$state"
}

# vpn_lockdown_mode <on|off> [--dry-run] [--non-interactive] [--yes] (sin arg → estado).
vpn_lockdown_mode() {
	_vpn_require_installed || return 1
	_vpn_parse_global_flags "$@"
	local state=${_VPN_POS[0]:-}
	state=${state,,}
	if [[ -z $state ]]; then
		log_section "Modo lockdown (estado actual)"
		printf '%s\n' "$(_vpn_mullvad lockdown-mode get)"
		return 0
	fi
	_vpn_lockdown_apply "$state"
}

# vpn_killswitch <on|off> [--dry-run] [--non-interactive] [--yes]
# NOTA: Mullvad NO tiene un killswitch separado; su kill switch está siempre
# activo por defecto y el control configurable equivalente es el modo lockdown,
# al que mapeamos esta función informando claramente al usuario.
vpn_killswitch() {
	_vpn_require_installed || return 1
	_vpn_parse_global_flags "$@"
	local state=${_VPN_POS[0]:-}
	state=${state,,}
	log_info "En Mullvad el «kill switch» está SIEMPRE activo: bloquea el tráfico si el túnel cae."
	log_info "Se mapea al «modo lockdown» (bloqueo estricto incluso al (re)conectar)."
	if [[ -z $state ]]; then
		log_section "Kill switch / lockdown (estado actual)"
		printf '%s\n' "$(_vpn_mullvad lockdown-mode get)"
		return 0
	fi
	_vpn_lockdown_apply "$state"
}

# vpn_dns_leak_protection <on|off> [--dry-run] [--non-interactive] [--yes]
# Mullvad enruta la DNS DENTRO del túnel por defecto, evitando fugas.
vpn_dns_leak_protection() {
	_vpn_require_installed || return 1
	_vpn_parse_global_flags "$@"
	local state=${_VPN_POS[0]:-}
	state=${state,,}
	case $state in
	on)
		log_info "Mullvad enruta la DNS dentro del túnel por defecto, evitando fugas."
		if [[ ${_VPN_DRY} == 1 ]]; then
			_vpn_dry "Ejecutaría: ${GHOST_MULLVAD_BIN} dns set default"
			return 0
		fi
		_vpn_confirm "¿Aplicar la DNS por defecto de Mullvad (protegida en el túnel)?" || return 1
		_vpn_apply "Protección de DNS (Mullvad en el túnel) aplicada." dns set default
		;;
	off)
		log_warn "Desactivar la protección de DNS aumenta el riesgo de fugas y NO es recomendable."
		log_warn "Mullvad gestiona la DNS dentro del túnel; no hay un interruptor seguro de «apagado»."
		log_warn "Si necesitas una DNS personalizada, configúrala explícitamente: mullvad dns set custom <ip>"
		return 1
		;;
	*)
		log_error "Uso: vpn_dns_leak_protection <on|off>"
		return 1
		;;
	esac
}

# ──────────────────────────────────────────────────────────────────────────────
#  API PÚBLICA — diagnóstico de red
# ──────────────────────────────────────────────────────────────────────────────

# vpn_get_public_ip → IP pública actual (consulta un servicio de Mullvad).
vpn_get_public_ip() {
	if ! command -v curl >/dev/null 2>&1; then
		log_error "curl no está instalado."
		return 1
	fi
	local json ip country exit_ip
	json=$(curl -fsS --max-time "$GHOST_MULLVAD_TIMEOUT" "$GHOST_VPN_CHECK_URL" 2>/dev/null)
	if [[ -z $json ]]; then
		log_error "No se pudo consultar ${GHOST_VPN_CHECK_URL}. ¿Hay conexión a internet?"
		return 1
	fi
	ip=$(_vpn_json_get "$json" ip)
	country=$(_vpn_json_get "$json" country)
	exit_ip=$(_vpn_json_get "$json" mullvad_exit_ip)
	log_section "IP pública actual"
	log_table "IP" "${ip:-?}" "País" "${country:-?}" "¿Sale por Mullvad?" "${exit_ip:-desconocido}"
}

# vpn_check_leaks → verifica la salida vía Mullvad y orienta sobre DNS/WebRTC.
# Solo consulta tu IP de salida en un servicio de Mullvad; no envía datos personales.
vpn_check_leaks() {
	if ! command -v curl >/dev/null 2>&1; then
		log_error "curl no está instalado."
		return 1
	fi
	log_section "Verificación de fugas"
	local json ip country exit_ip
	json=$(curl -fsS --max-time "$GHOST_MULLVAD_TIMEOUT" "$GHOST_VPN_CHECK_URL" 2>/dev/null)
	if [[ -z $json ]]; then
		log_error "Sin respuesta de ${GHOST_VPN_CHECK_URL}. ¿Hay conexión a internet?"
		return 1
	fi
	ip=$(_vpn_json_get "$json" ip)
	country=$(_vpn_json_get "$json" country)
	exit_ip=$(_vpn_json_get "$json" mullvad_exit_ip)

	if [[ $exit_ip == true ]]; then
		log_ok "El tráfico SALE por Mullvad (IP ${ip:-?}, ${country:-?})."
	else
		log_error "El tráfico NO parece salir por Mullvad (IP ${ip:-?}). Posible fuga."
	fi
	log_info "Fuga de DNS: para una prueba completa visita ${GHOST_VPN_LEAK_URL} (servicio de Mullvad)."
	log_warn "Fuga de WebRTC: solo se comprueba en el NAVEGADOR; usa Tor Browser o desactiva WebRTC."
}

# vpn_bandwidth → tráfico del túnel (lee contadores de la interfaz, solo lectura).
# El CLI de Mullvad no expone estadísticas de ancho de banda por sesión, así que
# leemos rx/tx de la interfaz WireGuard desde /sys/class/net (sin modificar nada).
vpn_bandwidth() {
	log_section "Tráfico del túnel Mullvad"
	local iface
	iface=$(_vpn_find_wg_interface)
	if [[ -z $iface ]]; then
		log_warn "No se encontró una interfaz de Mullvad activa (¿VPN desconectada?)."
		log_info "Nota: el cliente Mullvad no expone estadísticas de ancho de banda por sesión."
		return 1
	fi
	local rx tx
	rx=$(cat "/sys/class/net/${iface}/statistics/rx_bytes" 2>/dev/null)
	tx=$(cat "/sys/class/net/${iface}/statistics/tx_bytes" 2>/dev/null)
	log_table "Interfaz" "$iface" \
		"Recibido" "$(_vpn_human_bytes "${rx:-0}")" \
		"Enviado" "$(_vpn_human_bytes "${tx:-0}")"
}

# vpn_status_panel → resumen compacto tipo dashboard.
vpn_status_panel() {
	log_section "Panel Mullvad VPN"
	if ! _vpn_installed; then
		log_error "El cliente «mullvad» no está instalado."
		log_error "Instálalo con: sudo apt install mullvad-vpn — o desde https://mullvad.net/download/"
		return 1
	fi
	local ver conn proto lock _tmpfile
	_tmpfile=$(mktemp)
	_vpn_mullvad version >"$_tmpfile" 2>/dev/null
	ver=$(head -1 "$_tmpfile")
	_vpn_mullvad status >"$_tmpfile" 2>/dev/null
	conn=$(head -1 "$_tmpfile")
	_vpn_mullvad relay get >"$_tmpfile" 2>/dev/null
	proto=$(grep -iE 'tunnel|protocol' "$_tmpfile" | head -1)
	_vpn_mullvad lockdown-mode get >"$_tmpfile" 2>/dev/null
	lock=$(head -1 "$_tmpfile")
	rm -f "$_tmpfile"
	log_table \
		"Cliente" "${ver:-?}" \
		"Conexión" "${conn:-?}" \
		"Protocolo" "${proto:-?}" \
		"Lockdown" "${lock:-?}"
}

# ──────────────────────────────────────────────────────────────────────────────
#  API EXPUESTA (recordatorio)
#  Esto es una librería: `source lib/vpnctl.sh` expone las funciones vpn_*.
#  NO se ejecuta nada automáticamente ni hay main(): el orquestador (joseph-trio)
#  decide qué invocar. Todas las acciones de cambio de estado respetan --dry-run
#  y piden confirmación salvo --non-interactive / --yes.
# ──────────────────────────────────────────────────────────────────────────────
