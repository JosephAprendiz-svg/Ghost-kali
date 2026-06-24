#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================
# Ghost-Kali :: lib/validators.sh
# ----------------------------------------------------------------------------
# Librería de validación y health check. 100% DEFENSIVA y de SOLO LECTURA:
# valida entorno, dependencias, configuración y entradas de usuario. NUNCA
# modifica el sistema, NUNCA ataca, escanea ni daña a terceros.
#
# Versión  : 5.0.0-elite
# Propósito: dar soporte a la orquestación segura de Mullvad VPN, Tor y
#            Proxychains en Kali Linux, comprobando el estado del sistema
#            sin alterarlo en ningún caso.
# Licencia : MIT
# Autor    : Joseph (JosephAprendiz-svg)
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# Guarda de ejecución directa: este archivo es una librería, no un ejecutable.
# ----------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	printf '%s\n' \
		"Error: lib/validators.sh es una librería de Ghost-Kali." \
		"Cárgala con 'source lib/validators.sh'; no la ejecutes directamente." >&2
	exit 1
fi

# ----------------------------------------------------------------------------
# Directorio de la librería (para localizar archivos hermanos opcionales).
# ----------------------------------------------------------------------------
_GHOST_VALIDATORS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)" ||
	_GHOST_VALIDATORS_DIR="."

# ----------------------------------------------------------------------------
# Carga opcional de colors.sh y logger.sh con fallbacks inline.
# ----------------------------------------------------------------------------
if [[ -r "${_GHOST_VALIDATORS_DIR}/colors.sh" ]]; then
	# shellcheck source=/dev/null
	source "${_GHOST_VALIDATORS_DIR}/colors.sh"
fi

# Fallbacks de color (se interpretan con printf '%b'). Solo se definen si
# colors.sh no los proporcionó.
: "${C_RESET:=\033[0m}"
: "${C_BOLD:=\033[1m}"
: "${C_DIM:=\033[2m}"
: "${C_RED:=\033[0;31m}"
: "${C_GREEN:=\033[0;32m}"
: "${C_YELLOW:=\033[0;33m}"

# Nivel de log (numérico). 10=debug 20=info 30=warn 40=error 99=silencio.
: "${GHOST_LOG_LEVEL:=20}"

if [[ -r "${_GHOST_VALIDATORS_DIR}/logger.sh" ]]; then
	# shellcheck source=/dev/null
	source "${_GHOST_VALIDATORS_DIR}/logger.sh"
fi

# Fallbacks de logging si logger.sh no definió las funciones. Respetan
# GHOST_LOG_LEVEL y escriben a stderr para no contaminar stdout.
if ! declare -F log_info >/dev/null 2>&1; then
	_ghost_fallback_log() {
		local level="$1"
		shift
		local threshold="${GHOST_LOG_LEVEL:-20}"
		((level < threshold)) && return 0
		printf '%b\n' "$*" >&2
	}
	log_debug() { _ghost_fallback_log 10 "[DEBUG] $*"; }
	log_info() { _ghost_fallback_log 20 "[INFO ] $*"; }
	log_warn() { _ghost_fallback_log 30 "[WARN ] $*"; }
	log_error() { _ghost_fallback_log 40 "[ERROR] $*"; }
fi

# ----------------------------------------------------------------------------
# Constantes configurables (sobrescribibles desde el entorno).
# ----------------------------------------------------------------------------
: "${GHOST_CONFIG_DIR:=/etc/ghost-kali}"
: "${GHOST_TORRC:=/etc/tor/torrc}"
: "${GHOST_TOR_CONTROL_PORT:=9051}"
: "${GHOST_TOR_SOCKS_PORT:=9050}"
: "${GHOST_PROXYCHAINS_CONFS:=/etc/proxychains.conf /etc/proxychains4.conf ${GHOST_CONFIG_DIR}/proxychains.conf}"
: "${GHOST_MIN_DISK_MB:=100}"
: "${GHOST_DEPS_REQUIRED:=ip curl grep awk sed sysctl df stat}"
: "${GHOST_DEPS_OPTIONAL:=nc mullvad tor proxychains4}"
: "${GHOST_VALIDATORS_VERSION:=5.0.0-elite}"

# ----------------------------------------------------------------------------
# Estado global del health check.
# ----------------------------------------------------------------------------
declare -gA GHOST_HEALTH_STATUS
declare -gA GHOST_HEALTH_DETAIL
declare -ga GHOST_HEALTH_NAMES=(root deps network tor_config proxychains mullvad_account disk kernel permissions)

# ============================================================================
# Helpers privados.
# ============================================================================

# Registra el resultado de una comprobación: nombre, estado (ok|warn|fail),
# y un detalle legible.
_record_check() {
	local name="$1"
	local status="$2"
	local detail="${3:-}"
	GHOST_HEALTH_STATUS["${name}"]="${status}"
	GHOST_HEALTH_DETAIL["${name}"]="${detail}"
}

# Limpia el estado acumulado del health check.
_health_reset() {
	GHOST_HEALTH_STATUS=()
	GHOST_HEALTH_DETAIL=()
}

# Escapa un texto para incrustarlo de forma segura en JSON.
_v_json_escape() {
	local text="${1:-}"
	text="${text//\\/\\\\}"
	text="${text//\"/\\\"}"
	text="${text//$'\n'/\\n}"
	text="${text//$'\r'/\\r}"
	text="${text//$'\t'/\\t}"
	printf '%s' "${text}"
}

# Construye un array JSON ["a","b",...] a partir de los argumentos recibidos.
_v_json_escape_array() {
	local first=1
	local elem
	printf '%s' "["
	for elem in "$@"; do
		if ((first)); then
			first=0
		else
			printf '%s' ","
		fi
		printf '"%s"' "$(_v_json_escape "${elem}")"
	done
	printf '%s' "]"
}

# ============================================================================
# Comprobaciones de health check (todas de SOLO LECTURA).
# ============================================================================

# Comprueba si el proceso actual se ejecuta como root.
check_root() {
	local detail
	if ((EUID == 0)); then
		detail="Ejecutando como root (UID 0)."
		_record_check "root" "ok" "${detail}"
		return 0
	fi
	detail="No se ejecuta como root; ciertas operaciones podrían requerir privilegios."
	_record_check "root" "warn" "${detail}"
	return 1
}

# Verifica la presencia de dependencias requeridas y opcionales.
check_deps() {
	local -a required optional
	local -a missing_required=() missing_optional=()
	local dep detail
	read -ra required <<<"${GHOST_DEPS_REQUIRED}"
	read -ra optional <<<"${GHOST_DEPS_OPTIONAL}"
	for dep in "${required[@]}"; do
		command -v "${dep}" >/dev/null 2>&1 || missing_required+=("${dep}")
	done
	for dep in "${optional[@]}"; do
		command -v "${dep}" >/dev/null 2>&1 || missing_optional+=("${dep}")
	done
	if ((${#missing_required[@]} > 0)); then
		detail="Faltan dependencias requeridas: ${missing_required[*]}"
		_record_check "deps" "fail" "${detail}"
		return 1
	fi
	if ((${#missing_optional[@]} > 0)); then
		detail="Dependencias opcionales ausentes: ${missing_optional[*]}"
		_record_check "deps" "warn" "${detail}"
		return 1
	fi
	detail="Todas las dependencias presentes."
	_record_check "deps" "ok" "${detail}"
	return 0
}

# Comprueba que exista una ruta de red por defecto (conectividad).
check_network() {
	local detail
	if ip route show default 2>/dev/null | grep -q .; then
		detail="Ruta por defecto presente; hay conectividad de red."
		_record_check "network" "ok" "${detail}"
		return 0
	fi
	detail="Sin ruta por defecto; no hay conectividad de red."
	_record_check "network" "fail" "${detail}"
	return 1
}

# Verifica que torrc sea legible y declare un ControlPort.
check_tor_config() {
	local detail
	if [[ ! -r "${GHOST_TORRC}" ]]; then
		detail="No se encuentra o no es legible torrc en ${GHOST_TORRC}."
		_record_check "tor_config" "warn" "${detail}"
		return 1
	fi
	if grep -Eq '^[[:space:]]*ControlPort[[:space:]]+' "${GHOST_TORRC}"; then
		detail="torrc presente con ControlPort configurado."
		_record_check "tor_config" "ok" "${detail}"
		return 0
	fi
	detail="torrc presente pero sin ControlPort explícito."
	_record_check "tor_config" "warn" "${detail}"
	return 1
}

# Busca una configuración de proxychains que apunte a Tor en localhost.
check_proxychains_config() {
	local -a confs
	local conf detail found=""
	read -ra confs <<<"${GHOST_PROXYCHAINS_CONFS}"
	for conf in "${confs[@]}"; do
		[[ -r "${conf}" ]] || continue
		if grep -Eiq "^[[:space:]]*socks[45][[:space:]]+127\.0\.0\.1[[:space:]]+${GHOST_TOR_SOCKS_PORT}" "${conf}"; then
			found="${conf}"
			break
		fi
	done
	if [[ -n "${found}" ]]; then
		detail="Proxychains enruta a Tor (127.0.0.1:${GHOST_TOR_SOCKS_PORT}) en ${found}."
		_record_check "proxychains" "ok" "${detail}"
		return 0
	fi
	detail="No se halló socks4/socks5 127.0.0.1:${GHOST_TOR_SOCKS_PORT} en los archivos de proxychains."
	_record_check "proxychains" "warn" "${detail}"
	return 1
}

# Detecta una sesión de Mullvad activa. NUNCA imprime el número de cuenta.
check_mullvad_logged_in() {
	local detail
	if ! command -v mullvad >/dev/null 2>&1; then
		detail="Cliente mullvad no instalado."
		_record_check "mullvad_account" "warn" "${detail}"
		return 1
	fi
	if mullvad account get 2>/dev/null | grep -qiE 'device|expires|account|paid until'; then
		detail="Sesión de Mullvad activa detectada."
		_record_check "mullvad_account" "ok" "${detail}"
		return 0
	fi
	detail="No se detectó una sesión de Mullvad activa."
	_record_check "mullvad_account" "warn" "${detail}"
	return 1
}

# Comprueba que haya espacio en disco suficiente para el directorio de config.
check_disk_space() {
	local target="${GHOST_CONFIG_DIR}"
	local avail detail
	[[ -d "${target}" ]] || target="/"
	avail="$(df -Pm "${target}" 2>/dev/null | awk 'NR==2 {print $4}')"
	if [[ -z "${avail}" || ! "${avail}" =~ ^[0-9]+$ ]]; then
		detail="No se pudo determinar el espacio disponible en ${target}."
		_record_check "disk" "warn" "${detail}"
		return 1
	fi
	if ((avail >= GHOST_MIN_DISK_MB)); then
		detail="Espacio disponible: ${avail} MB (mínimo ${GHOST_MIN_DISK_MB} MB) en ${target}."
		_record_check "disk" "ok" "${detail}"
		return 0
	fi
	detail="Espacio insuficiente: ${avail} MB disponibles, se requieren ${GHOST_MIN_DISK_MB} MB."
	_record_check "disk" "fail" "${detail}"
	return 1
}

# Lee parámetros del kernel relevantes para fugas. SOLO LECTURA (sysctl -n).
check_kernel_params() {
	local ip_forward ipv6_disabled detail
	ip_forward="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || printf '%s' "desconocido")"
	ipv6_disabled="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || printf '%s' "desconocido")"
	detail="net.ipv4.ip_forward=${ip_forward}; net.ipv6.conf.all.disable_ipv6=${ipv6_disabled}"
	if [[ "${ip_forward}" == "0" ]]; then
		_record_check "kernel" "ok" "${detail}"
		return 0
	fi
	_record_check "kernel" "warn" "${detail} (ip_forward activo: revisar posibles fugas)"
	return 1
}

# Detecta permisos laxos (escritura para 'otros'). NO modifica permisos.
check_file_permissions() {
	local -a targets lax=()
	local f mode other_digit detail
	targets=("${GHOST_CONFIG_DIR}" "${GHOST_TORRC}")
	for f in "${targets[@]}"; do
		[[ -e "${f}" ]] || continue
		mode="$(stat -c '%a' "${f}" 2>/dev/null || true)"
		[[ -n "${mode}" ]] || continue
		other_digit="${mode: -1}"
		[[ "${other_digit}" =~ ^[0-7]$ ]] || continue
		if (((other_digit & 2) != 0)); then
			lax+=("${f} (${mode})")
		fi
	done
	if ((${#lax[@]} > 0)); then
		detail="Permisos con escritura para otros en: ${lax[*]}"
		_record_check "permissions" "warn" "${detail}"
		return 1
	fi
	detail="Sin permisos de escritura para otros en los objetivos revisados."
	_record_check "permissions" "ok" "${detail}"
	return 0
}

# ============================================================================
# Agregadores del health check.
# ============================================================================

# Ejecuta todas las comprobaciones sin abortar ante un fallo individual.
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
	return 0
}

# Calcula el estado global a partir del estado acumulado: ok|warn|fail.
_overall_status() {
	local name status has_warn=0 has_fail=0
	for name in "${GHOST_HEALTH_NAMES[@]}"; do
		status="${GHOST_HEALTH_STATUS[${name}]:-}"
		case "${status}" in
		fail) has_fail=1 ;;
		warn) has_warn=1 ;;
		*) : ;;
		esac
	done
	if ((has_fail)); then
		printf '%s' "fail"
	elif ((has_warn)); then
		printf '%s' "warn"
	else
		printf '%s' "ok"
	fi
}

# Muestra un resumen humano del health check. Retorna 1 si hay fallos.
run_health_check() {
	local name status detail overall
	_run_all_checks
	printf '%b\n' "${C_BOLD}Ghost-Kali :: Health Check (v${GHOST_VALIDATORS_VERSION})${C_RESET}"
	for name in "${GHOST_HEALTH_NAMES[@]}"; do
		status="${GHOST_HEALTH_STATUS[${name}]:-desconocido}"
		detail="${GHOST_HEALTH_DETAIL[${name}]:-}"
		case "${status}" in
		ok) printf '%b\n' "  ${C_GREEN}[ OK ]${C_RESET} ${name}: ${detail}" ;;
		warn) printf '%b\n' "  ${C_YELLOW}[WARN]${C_RESET} ${name}: ${detail}" ;;
		fail) printf '%b\n' "  ${C_RED}[FAIL]${C_RESET} ${name}: ${detail}" ;;
		*) printf '%b\n' "  ${C_DIM}[????]${C_RESET} ${name}: ${detail}" ;;
		esac
	done
	overall="$(_overall_status)"
	case "${overall}" in
	ok) printf '%b\n' "${C_GREEN}Estado general: OK${C_RESET}" ;;
	warn) printf '%b\n' "${C_YELLOW}Estado general: ADVERTENCIA${C_RESET}" ;;
	fail) printf '%b\n' "${C_RED}Estado general: FALLO${C_RESET}" ;;
	*) : ;;
	esac
	[[ "${overall}" == "fail" ]] && return 1
	return 0
}

# Emite un informe JSON puro por stdout. Silencia los logs durante su ejecución.
generate_health_report() {
	local saved_log_level name status detail overall first=1
	saved_log_level="${GHOST_LOG_LEVEL:-20}"
	GHOST_LOG_LEVEL=99
	_run_all_checks
	overall="$(_overall_status)"
	printf '%s' "{"
	printf '"version":"%s",' "$(_v_json_escape "${GHOST_VALIDATORS_VERSION}")"
	printf '"overall":"%s",' "$(_v_json_escape "${overall}")"
	printf '%s' '"checks":{'
	for name in "${GHOST_HEALTH_NAMES[@]}"; do
		status="${GHOST_HEALTH_STATUS[${name}]:-desconocido}"
		detail="${GHOST_HEALTH_DETAIL[${name}]:-}"
		if ((first)); then
			first=0
		else
			printf '%s' ","
		fi
		printf '"%s":{"status":"%s","detail":"%s"}' \
			"$(_v_json_escape "${name}")" \
			"$(_v_json_escape "${status}")" \
			"$(_v_json_escape "${detail}")"
	done
	printf '%s' "}}"
	printf '\n'
	GHOST_LOG_LEVEL="${saved_log_level}"
	return 0
}

# ============================================================================
# Primitivas validate_* (deterministas, SOLO LECTURA, retornan 0/1).
# ============================================================================

# Valida una dirección IPv4 (base 10# para evitar interpretación octal).
validate_ipv4() {
	local ip="${1:-}"
	local -a octets
	local oct
	[[ "${ip}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
	IFS='.' read -ra octets <<<"${ip}"
	((${#octets[@]} == 4)) || return 1
	for oct in "${octets[@]}"; do
		[[ "${oct}" =~ ^0[0-9] ]] && return 1
		((10#${oct} <= 255)) || return 1
	done
	return 0
}

# Valida una dirección IPv6. Acepta la forma comprimida '::' y rechaza ':::'.
validate_ipv6() {
	local ip="${1:-}"
	local -a groups
	local g tmp dcolon=0 occurrences=0
	[[ "${ip}" == *":::"* ]] && return 1
	[[ "${ip}" == *:* ]] || return 1
	tmp="${ip}"
	while [[ "${tmp}" == *"::"* ]]; do
		occurrences=$((occurrences + 1))
		tmp="${tmp/::/__}"
	done
	((occurrences <= 1)) || return 1
	((occurrences == 1)) && dcolon=1
	if ((dcolon)); then
		local left="${ip%%::*}"
		local right="${ip##*::}"
		local -a lg=() rg=()
		if [[ -n "${left}" ]]; then IFS=':' read -ra lg <<<"${left}"; fi
		if [[ -n "${right}" ]]; then IFS=':' read -ra rg <<<"${right}"; fi
		((${#lg[@]} + ${#rg[@]} <= 7)) || return 1
		for g in "${lg[@]}" "${rg[@]}"; do
			[[ "${g}" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
		done
		return 0
	fi
	IFS=':' read -ra groups <<<"${ip}"
	((${#groups[@]} == 8)) || return 1
	for g in "${groups[@]}"; do
		[[ "${g}" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
	done
	return 0
}

# Valida un puerto TCP/UDP en el rango 1-65535.
validate_port() {
	local port="${1:-}"
	[[ "${port}" =~ ^[0-9]{1,5}$ ]] || return 1
	((10#${port} >= 1 && 10#${port} <= 65535)) || return 1
	return 0
}

# Valida un hostname (RFC 1123): etiquetas de 1-63 chars, total <= 253.
validate_hostname() {
	local host="${1:-}"
	local -a labels
	local label
	[[ -n "${host}" ]] || return 1
	((${#host} <= 253)) || return 1
	host="${host%.}"
	[[ "${host}" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
	IFS='.' read -ra labels <<<"${host}"
	((${#labels[@]} >= 1)) || return 1
	for label in "${labels[@]}"; do
		[[ -n "${label}" ]] || return 1
		((${#label} <= 63)) || return 1
		[[ "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
	done
	return 0
}

# Valida una URL http/https sin espacios.
validate_url() {
	local url="${1:-}"
	[[ "${url}" =~ ^https?://[^[:space:]]+$ ]] && return 0
	return 1
}

# Valida una dirección MAC (separadores ':' o '-').
validate_mac() {
	local mac="${1:-}"
	[[ "${mac}" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] && return 0
	[[ "${mac}" =~ ^([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}$ ]] && return 0
	return 1
}

# Verdadero si el usuario actual es root.
validate_is_root() {
	((EUID == 0)) && return 0
	return 1
}

# Verdadero si el comando existe en PATH.
validate_command_exists() {
	local cmd="${1:-}"
	[[ -n "${cmd}" ]] || return 1
	command -v "${cmd}" >/dev/null 2>&1 && return 0
	return 1
}

# Verdadero si la ruta es un archivo regular existente.
validate_file_exists() {
	local path="${1:-}"
	[[ -n "${path}" && -f "${path}" ]] && return 0
	return 1
}

# Verdadero si la ruta es un directorio existente.
validate_directory_exists() {
	local path="${1:-}"
	[[ -n "${path}" && -d "${path}" ]] && return 0
	return 1
}

# Verdadero si la ruta es ejecutable.
validate_is_executable() {
	local path="${1:-}"
	[[ -n "${path}" && -x "${path}" ]] && return 0
	return 1
}

# Verdadero si la ruta es escribible.
validate_is_writable() {
	local path="${1:-}"
	[[ -n "${path}" && -w "${path}" ]] && return 0
	return 1
}

# Verdadero si la ruta es legible.
validate_is_readable() {
	local path="${1:-}"
	[[ -n "${path}" && -r "${path}" ]] && return 0
	return 1
}

# Verdadero si el valor no está vacío.
validate_non_empty() {
	local value="${1:-}"
	[[ -n "${value}" ]] && return 0
	return 1
}

# Verdadero si el valor es un entero (admite signo negativo).
validate_is_integer() {
	local value="${1:-}"
	[[ "${value}" =~ ^-?[0-9]+$ ]] && return 0
	return 1
}

# Verdadero si el valor es un entero positivo (> 0).
validate_is_positive_integer() {
	local value="${1:-}"
	[[ "${value}" =~ ^[0-9]+$ ]] || return 1
	((10#${value} > 0)) || return 1
	return 0
}

# Verdadero si el primer argumento está presente en el resto de argumentos.
validate_in_array() {
	local needle="${1:-}"
	shift || true
	local item
	for item in "$@"; do
		[[ "${item}" == "${needle}" ]] && return 0
	done
	return 1
}

# Verdadero si existe la interfaz de red (lectura de /sys/class/net).
validate_interface_exists() {
	local iface="${1:-}"
	[[ -n "${iface}" ]] || return 1
	[[ -d "/sys/class/net/${iface}" ]] && return 0
	return 1
}

# Verdadero si el puerto de Tor escucha en el host propio (127.0.0.1).
# Restringido EXCLUSIVAMENTE a localhost: nunca contacta ni escanea a terceros.
validate_tor_port() {
	local port="${1:-${GHOST_TOR_SOCKS_PORT}}"
	validate_port "${port}" || return 1
	if command -v nc >/dev/null 2>&1; then
		nc -z -w 2 127.0.0.1 "${port}" >/dev/null 2>&1 && return 0
		return 1
	fi
	(exec 3<>"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1 && return 0
	return 1
}

# Verdadero si el archivo de proxychains tiene estructura válida (formato).
validate_proxychains_config() {
	local conf="${1:-}"
	[[ -n "${conf}" && -r "${conf}" ]] || return 1
	grep -Eiq '^[[:space:]]*\[ProxyList\]' "${conf}" || return 1
	grep -Eiq '^[[:space:]]*(socks[45]|http)[[:space:]]+[0-9.]+[[:space:]]+[0-9]+' "${conf}" || return 1
	return 0
}

# Valida SOLO el formato de un número de cuenta Mullvad (16 dígitos).
# NUNCA contacta la API ni imprime el número.
validate_mullvad_account() {
	local account="${1:-}"
	local digits="${account//[[:space:]]/}"
	[[ "${digits}" =~ ^[0-9]{16}$ ]] && return 0
	return 1
}

# Verdadero si la respuesta es un sí/no reconocido (es/en).
validate_strict_yes_no() {
	local answer="${1:-}"
	answer="${answer,,}"
	case "${answer}" in
	y | yes | n | no | s | si | sí) return 0 ;;
	*) return 1 ;;
	esac
}

# Verdadero si torrc existe y es legible.
validate_torrc_exists() {
	[[ -r "${GHOST_TORRC}" ]] && return 0
	return 1
}

# Verdadero si proxychains está instalado (proxychains4 o proxychains).
validate_proxychains_installed() {
	command -v proxychains4 >/dev/null 2>&1 && return 0
	command -v proxychains >/dev/null 2>&1 && return 0
	return 1
}

# Verdadero si Tor está instalado.
validate_tor_installed() {
	command -v tor >/dev/null 2>&1 && return 0
	return 1
}

# Verdadero si el cliente de Mullvad está instalado.
validate_mullvad_installed() {
	command -v mullvad >/dev/null 2>&1 && return 0
	return 1
}

