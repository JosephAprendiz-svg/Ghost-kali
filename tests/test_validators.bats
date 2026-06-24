#!/usr/bin/env bats
# tests/test_validators.bats — Pruebas para lib/validators.sh
# ──────────────────────────────────────────────────────────────────────────────
#  Suite BATS para la API de validadores puros de Ghost-Kali (validate_*).
#  Es 100% local, determinista y CI-friendly: no hace red real ni operaciones
#  destructivas, y usa skips/stubs para lo que dependa del sistema o de paquetes.
#
#  ⚖️  Parte de un toolkit DEFENSIVO de privacidad. Estas pruebas solo validan
#      comportamiento local y seguro; no escanean redes ajenas ni explotan nada.
# ──────────────────────────────────────────────────────────────────────────────

# setup() se ejecuta antes de CADA test: localiza la raíz del proyecto y carga
# la librería bajo prueba en un entorno limpio (cada test es un proceso aislado).
setup() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    # shellcheck source=/dev/null
    source "${PROJECT_ROOT}/lib/validators.sh"
}

# teardown() se ejecuta tras cada test. BATS limpia BATS_TEST_TMPDIR de forma
# automática; no creamos temporales fuera de él, así que no hay nada más que hacer.
teardown() {
    :
}

# ──────────────────────────────────────────────────────────────────────────────
#  A. validate_ipv4
# ──────────────────────────────────────────────────────────────────────────────

@test "validate_ipv4 acepta IPv4 pública válida (8.8.8.8)" {
    run validate_ipv4 "8.8.8.8"
    [ "$status" -eq 0 ]
}

@test "validate_ipv4 acepta IPv4 privada válida (192.168.1.1)" {
    run validate_ipv4 "192.168.1.1"
    [ "$status" -eq 0 ]
}

@test "validate_ipv4 rechaza octeto mayor que 255 (256.1.1.1)" {
    run validate_ipv4 "256.1.1.1"
    [ "$status" -eq 1 ]
}

@test "validate_ipv4 rechaza IPv4 incompleta (192.168.1)" {
    run validate_ipv4 "192.168.1"
    [ "$status" -eq 1 ]
}

@test "validate_ipv4 rechaza cadena vacía" {
    run validate_ipv4 ""
    [ "$status" -eq 1 ]
}

@test "validate_ipv4 rechaza un hostname como IPv4" {
    run validate_ipv4 "example.com"
    [ "$status" -eq 1 ]
}

# ──────────────────────────────────────────────────────────────────────────────
#  B. validate_ipv6
# ──────────────────────────────────────────────────────────────────────────────

@test "validate_ipv6 acepta loopback (::1)" {
    run validate_ipv6 "::1"
    [ "$status" -eq 0 ]
}

@test "validate_ipv6 acepta IPv6 completa" {
    run validate_ipv6 "2001:0db8:85a3:0000:0000:8a2e:0370:7334"
    [ "$status" -eq 0 ]
}

@test "validate_ipv6 rechaza IPv6 inválida (gg::1)" {
    run validate_ipv6 "gg::1"
    [ "$status" -eq 1 ]
}

@test "validate_ipv6 rechaza cadena vacía" {
    run validate_ipv6 ""
    [ "$status" -eq 1 ]
}

# ──────────────────────────────────────────────────────────────────────────────
#  C. validate_port
# ──────────────────────────────────────────────────────────────────────────────

@test "validate_port acepta el puerto 1" {
    run validate_port "1"
    [ "$status" -eq 0 ]
}

@test "validate_port acepta el puerto 8080" {
    run validate_port "8080"
    [ "$status" -eq 0 ]
}

@test "validate_port acepta el puerto 65535" {
    run validate_port "65535"
    [ "$status" -eq 0 ]
}

@test "validate_port rechaza el puerto 0" {
    run validate_port "0"
    [ "$status" -eq 1 ]
}

@test "validate_port rechaza el puerto 70000" {
    run validate_port "70000"
    [ "$status" -eq 1 ]
}

@test "validate_port rechaza una cadena no numérica" {
    run validate_port "abc"
    [ "$status" -eq 1 ]
}

# ──────────────────────────────────────────────────────────────────────────────
#  D. validate_hostname
# ──────────────────────────────────────────────────────────────────────────────

@test "validate_hostname acepta un hostname simple (example.com)" {
    run validate_hostname "example.com"
    [ "$status" -eq 0 ]
}

@test "validate_hostname acepta un subdominio (sub.example.com)" {
    run validate_hostname "sub.example.com"
    [ "$status" -eq 0 ]
}

@test "validate_hostname rechaza un hostname con espacios" {
    run validate_hostname "exa mple.com"
    [ "$status" -eq 1 ]
}

@test "validate_hostname rechaza un hostname vacío" {
    run validate_hostname ""
    [ "$status" -eq 1 ]
}

# ──────────────────────────────────────────────────────────────────────────────
#  E. validate_url
# ──────────────────────────────────────────────────────────────────────────────

@test "validate_url acepta una URL http" {
    run validate_url "http://example.com"
    [ "$status" -eq 0 ]
}

@test "validate_url acepta una URL https" {
    run validate_url "https://example.com"
    [ "$status" -eq 0 ]
}

@test "validate_url rechaza una URL ftp" {
    run validate_url "ftp://example.com"
    [ "$status" -eq 1 ]
}

@test "validate_url rechaza una URL sin esquema" {
    run validate_url "example.com"
    [ "$status" -eq 1 ]
}

# ──────────────────────────────────────────────────────────────────────────────
#  F. validate_mac
# ──────────────────────────────────────────────────────────────────────────────

@test "validate_mac acepta MAC con dos puntos" {
    run validate_mac "aa:bb:cc:dd:ee:ff"
    [ "$status" -eq 0 ]
}

@test "validate_mac acepta MAC con guiones" {
    run validate_mac "aa-bb-cc-dd-ee-ff"
    [ "$status" -eq 0 ]
}

@test "validate_mac rechaza una MAC demasiado corta" {
    run validate_mac "aa:bb:cc:dd:ee"
    [ "$status" -eq 1 ]
}

@test "validate_mac rechaza una MAC con caracteres inválidos" {
    run validate_mac "zz:bb:cc:dd:ee:ff"
    [ "$status" -eq 1 ]
}

# ──────────────────────────────────────────────────────────────────────────────
#  G. validate_is_root  (probamos ambos casos según el EUID real)
# ──────────────────────────────────────────────────────────────────────────────

@test "validate_is_root detecta root cuando EUID es 0" {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        skip "requiere ejecutarse como root"
    fi
    run validate_is_root
    [ "$status" -eq 0 ]
}

@test "validate_is_root detecta no-root cuando EUID no es 0" {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        skip "se está ejecutando como root"
    fi
    run validate_is_root
    [ "$status" -eq 1 ]
}

# ──────────────────────────────────────────────────────────────────────────────
#  H. validate_command_exists
# ──────────────────────────────────────────────────────────────────────────────

@test "validate_command_exists encuentra un comando existente (bash)" {
    run validate_command_exists "bash"
    [ "$status" -eq 0 ]
}

@test "validate_command_exists no encuentra un comando inexistente" {
    run validate_command_exists "comando_falso_xyz_12345"
    [ "$status" -eq 1 ]
}

# ──────────────────────────────────────────────────────────────────────────────
#  I. validate_file_exists / validate_directory_exists / validate_is_executable
# ──────────────────────────────────────────────────────────────────────────────

@test "validate_file_exists encuentra un archivo existente" {
    local tmpfile="${BATS_TEST_TMPDIR}/existente.txt"
    touch "$tmpfile"
    run validate_file_exists "$tmpfile"
    [ "$status" -eq 0 ]
}

@test "validate_file_exists no encuentra un archivo inexistente" {
    run validate_file_exists "${BATS_TEST_TMPDIR}/no_existe_xyz.txt"
    [ "$status" -eq 1 ]
}

@test "validate_directory_exists encuentra un directorio existente" {
    local tmpdir="${BATS_TEST_TMPDIR}/subdir"
    mkdir -p "$tmpdir"
    run validate_directory_exists "$tmpdir"
    [ "$status" -eq 0 ]
}

@test "validate_directory_exists rechaza un directorio inexistente" {
    run validate_directory_exists "${BATS_TEST_TMPDIR}/no_existe_dir"
    [ "$status" -eq 1 ]
}

@test "validate_is_executable encuentra un archivo ejecutable" {
    local tmpfile="${BATS_TEST_TMPDIR}/script.sh"
    printf '#!/usr/bin/env bash\ntrue\n' >"$tmpfile"
    chmod +x "$tmpfile"
    run validate_is_executable "$tmpfile"
    [ "$status" -eq 0 ]
}

@test "validate_is_executable rechaza un archivo no ejecutable" {
    local tmpfile="${BATS_TEST_TMPDIR}/plano.txt"
    touch "$tmpfile"
    chmod 0644 "$tmpfile"
    run validate_is_executable "$tmpfile"
    [ "$status" -eq 1 ]
}

# ──────────────────────────────────────────────────────────────────────────────
#  J. validate_is_writable / validate_is_readable
# ──────────────────────────────────────────────────────────────────────────────

@test "validate_is_writable detecta un archivo escribible" {
    local tmpfile="${BATS_TEST_TMPDIR}/escribible.txt"
    touch "$tmpfile"
    chmod 0644 "$tmpfile"
    run validate_is_writable "$tmpfile"
    [ "$status" -eq 0 ]
}

@test "validate_is_readable detecta un archivo legible" {
    local tmpfile="${BATS_TEST_TMPDIR}/legible.txt"
    touch "$tmpfile"
    chmod 0644 "$tmpfile"
    run validate_is_readable "$tmpfile"
    [ "$status" -eq 0 ]
}

# ──────────────────────────────────────────────────────────────────────────────
#  K. validate_non_empty
# ──────────────────────────────────────────────────────────────────────────────

@test "validate_non_empty acepta una cadena no vacía" {
    run validate_non_empty "ghost"
    [ "$status" -eq 0 ]
}

@test "validate_non_empty rechaza una cadena vacía" {
    run validate_non_empty ""
    [ "$status" -eq 1 ]
}

@test "validate_non_empty rechaza una cadena de solo espacios" {
    run validate_non_empty "   "
    [ "$status" -eq 1 ]
}

# ──────────────────────────────────────────────────────────────────────────────
#  L. validate_is_integer / validate_is_positive_integer
# ──────────────────────────────────────────────────────────────────────────────

@test "validate_is_integer acepta un entero positivo" {
    run validate_is_integer "42"
    [ "$status" -eq 0 ]
}

@test "validate_is_integer acepta un entero negativo" {
    run validate_is_integer "-7"
    [ "$status" -eq 0 ]
}

@test "validate_is_integer rechaza un decimal" {
    run validate_is_integer "3.14"
    [ "$status" -eq 1 ]
}

@test "validate_is_integer rechaza letras" {
    run validate_is_integer "abc"
    [ "$status" -eq 1 ]
}

@test "validate_is_positive_integer acepta un entero positivo" {
    run validate_is_positive_integer "42"
    [ "$status" -eq 0 ]
}

@test "validate_is_positive_integer rechaza un entero negativo" {
    run validate_is_positive_integer "-7"
    [ "$status" -eq 1 ]
}

@test "validate_is_positive_integer rechaza el cero" {
    run validate_is_positive_integer "0"
    [ "$status" -eq 1 ]
}

@test "validate_is_positive_integer rechaza un decimal" {
    run validate_is_positive_integer "3.14"
    [ "$status" -eq 1 ]
}

# ──────────────────────────────────────────────────────────────────────────────
#  M. validate_in_array
# ──────────────────────────────────────────────────────────────────────────────

@test "validate_in_array encuentra un valor presente" {
    run validate_in_array "ghost" "alpha" "ghost" "omega"
    [ "$status" -eq 0 ]
}

@test "validate_in_array no encuentra un valor ausente" {
    run validate_in_array "zeta" "alpha" "ghost" "omega"
    [ "$status" -eq 1 ]
}

# ──────────────────────────────────────────────────────────────────────────────
#  N. validate_interface_exists
# ──────────────────────────────────────────────────────────────────────────────

@test "validate_interface_exists detecta la interfaz loopback (lo)" {
    if [[ ! -e /sys/class/net/lo ]]; then
        skip "no hay interfaz lo en este entorno"
    fi
    run validate_interface_exists "lo"
    [ "$status" -eq 0 ]
}

@test "validate_interface_exists rechaza una interfaz inexistente" {
    run validate_interface_exists "eth999999"
    [ "$status" -eq 1 ]
}

# ──────────────────────────────────────────────────────────────────────────────
#  O. validate_tor_port  (sin red real: host inválido para rechazar, stub para aceptar)
# ──────────────────────────────────────────────────────────────────────────────

@test "validate_tor_port rechaza un host inválido" {
    run validate_tor_port "no.existe.invalid.example" 9050
    [ "$status" -eq 1 ]
}

@test "validate_tor_port acepta un puerto válido con stub de nc" {
    # Creamos un «nc» falso que siempre responde OK, sin abrir ninguna conexión real.
    local stubdir="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$stubdir"
    printf '#!/usr/bin/env bash\nexit 0\n' >"${stubdir}/nc"
    chmod +x "${stubdir}/nc"
    PATH="${stubdir}:${PATH}" run validate_tor_port "127.0.0.1" 9050
    [ "$status" -eq 0 ]
}

# ──────────────────────────────────────────────────────────────────────────────
#  P. validate_proxychains_config
# ──────────────────────────────────────────────────────────────────────────────

@test "validate_proxychains_config acepta un proxychains4.conf válido" {
    local cfg="${BATS_TEST_TMPDIR}/proxychains4.conf"
    cat >"$cfg" <<'CONF'
strict_chain
proxy_dns
[ProxyList]
socks5 127.0.0.1 9050
CONF
    run validate_proxychains_config "$cfg"
    [ "$status" -eq 0 ]
}

@test "validate_proxychains_config rechaza un archivo vacío" {
    local cfg="${BATS_TEST_TMPDIR}/vacio.conf"
    : >"$cfg"
    run validate_proxychains_config "$cfg"
    [ "$status" -eq 1 ]
}

@test "validate_proxychains_config rechaza un archivo sin [ProxyList]" {
    local cfg="${BATS_TEST_TMPDIR}/sin_proxylist.conf"
    cat >"$cfg" <<'CONF'
strict_chain
proxy_dns
CONF
    run validate_proxychains_config "$cfg"
    [ "$status" -eq 1 ]
}

# ──────────────────────────────────────────────────────────────────────────────
#  Q. validate_mullvad_account  (solo formato; NO contacta ninguna API)
# ──────────────────────────────────────────────────────────────────────────────

@test "validate_mullvad_account acepta un número de cuenta numérico" {
    run validate_mullvad_account "1234567812345678"
    [ "$status" -eq 0 ]
}

@test "validate_mullvad_account rechaza letras" {
    run validate_mullvad_account "abcd1234efgh"
    [ "$status" -eq 1 ]
}

@test "validate_mullvad_account rechaza una cadena vacía" {
    run validate_mullvad_account ""
    [ "$status" -eq 1 ]
}

# ──────────────────────────────────────────────────────────────────────────────
#  R. validate_strict_yes_no
# ──────────────────────────────────────────────────────────────────────────────

@test "validate_strict_yes_no acepta s" {
    run validate_strict_yes_no "s"
    [ "$status" -eq 0 ]
}

@test "validate_strict_yes_no acepta S" {
    run validate_strict_yes_no "S"
    [ "$status" -eq 0 ]
}

@test "validate_strict_yes_no acepta y" {
    run validate_strict_yes_no "y"
    [ "$status" -eq 0 ]
}

@test "validate_strict_yes_no acepta Y" {
    run validate_strict_yes_no "Y"
    [ "$status" -eq 0 ]
}

@test "validate_strict_yes_no acepta n" {
    run validate_strict_yes_no "n"
    [ "$status" -eq 0 ]
}

@test "validate_strict_yes_no acepta N" {
    run validate_strict_yes_no "N"
    [ "$status" -eq 0 ]
}

@test "validate_strict_yes_no rechaza otra letra" {
    run validate_strict_yes_no "x"
    [ "$status" -eq 1 ]
}

@test "validate_strict_yes_no rechaza una cadena vacía" {
    run validate_strict_yes_no ""
    [ "$status" -eq 1 ]
}

# ──────────────────────────────────────────────────────────────────────────────
#  S. Presencia de torrc / paquetes (skip condicional si no están)
# ──────────────────────────────────────────────────────────────────────────────

@test "validate_torrc_exists detecta /etc/tor/torrc" {
    if [[ ! -e /etc/tor/torrc ]]; then
        skip "/etc/tor/torrc no existe en este entorno"
    fi
    run validate_torrc_exists
    [ "$status" -eq 0 ]
}

@test "validate_tor_installed detecta tor instalado" {
    if ! command -v tor >/dev/null 2>&1; then
        skip "tor no está instalado"
    fi
    run validate_tor_installed
    [ "$status" -eq 0 ]
}

@test "validate_proxychains_installed detecta proxychains4 instalado" {
    if ! command -v proxychains4 >/dev/null 2>&1; then
        skip "proxychains4 no está instalado"
    fi
    run validate_proxychains_installed
    [ "$status" -eq 0 ]
}

@test "validate_mullvad_installed detecta mullvad instalado" {
    if ! command -v mullvad >/dev/null 2>&1; then
        skip "mullvad no está instalado"
    fi
    run validate_mullvad_installed
    [ "$status" -eq 0 ]
}

# EOF
