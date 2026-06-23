#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  install.sh — Instalador oficial de Ghost-Kali v5.0
# ──────────────────────────────────────────────────────────────────────────────
#  Instala Ghost-Kali en el sistema local: verifica dependencias, las instala vía
#  apt (con tu confirmación), copia el proyecto a /opt/ghost-kali, crea un symlink
#  global y ajusta permisos. Idempotente y con soporte de --dry-run.
#
#  ⚖️  DISCLAIMER ÉTICO/LEGAL: este instalador opera SOLO sobre tu sistema local.
#      No instala malware, backdoors ni herramientas ofensivas. Toda modificación
#      de archivos del sistema requiere confirmación explícita y backup previo.
#      Ghost-Kali es una herramienta DEFENSIVA de privacidad; úsala de forma ética.
#
#  🔐 INVARIANTES:
#      · No borra archivos del usuario sin confirmación; nunca usa rm -rf.
#      · No modifica /etc/tor/torrc ni /etc/proxychains4.conf (solo recomienda).
#      · No descarga ni ejecuta instaladores remotos (Mullvad: instrucciones).
#      · No imprime credenciales ni datos sensibles.
#
#  Ejecuta: sudo ./install.sh
# ──────────────────────────────────────────────────────────────────────────────

# ── Constantes configurables ──────────────────────────────────────────────────
GHOST_VERSION=${GHOST_VERSION:-v5.0-elite}
GHOST_NAME=${GHOST_NAME:-Ghost-Kali}
GHOST_AUTHOR=${GHOST_AUTHOR:-JosephAprendiz-svg}
GHOST_REPO=${GHOST_REPO:-https://github.com/JosephAprendiz-svg/Ghost-kali}
GHOST_DRY_RUN=${GHOST_DRY_RUN:-0}
GHOST_INSTALL_DIR=${GHOST_INSTALL_DIR:-/opt/ghost-kali}
GHOST_BIN_DIR=${GHOST_BIN_DIR:-/usr/local/bin}
GHOST_SYMLINK="${GHOST_BIN_DIR}/joseph-trio"

# Estado interno.
GHOST_NO_COLOR=${GHOST_NO_COLOR:-0}
GHOST_ASSUME_YES=${GHOST_ASSUME_YES:-0}
GHOST_ACTION=""
GHOST_SRC_DIR=""
GHOST_OS_ID=""
declare -a GHOST_MISSING_DEPS=()

# ──────────────────────────────────────────────────────────────────────────────
#  HELPERS PRIVADOS
# ──────────────────────────────────────────────────────────────────────────────

# _install_use_color → ¿debemos colorear? (no si --no-color o si no es terminal).
_install_use_color() {
    [[ ${GHOST_NO_COLOR:-0} != 1 && -t 1 ]]
}

# _install_log NIVEL MENSAJE → logging con colores (o plano) según el contexto.
# WARN y ERROR van a stderr para no contaminar la salida estándar.
_install_log() {
    local level=$1
    shift
    local msg=$* color="" reset="" tag
    if _install_use_color; then reset=$'\e[0m'; fi
    case $level in
        info)
            tag="INFO "
            [[ -n $reset ]] && color=$'\e[36m'
            ;;
        ok)
            tag="OK   "
            [[ -n $reset ]] && color=$'\e[32m'
            ;;
        warn)
            tag="WARN "
            [[ -n $reset ]] && color=$'\e[33m'
            ;;
        error)
            tag="ERROR"
            [[ -n $reset ]] && color=$'\e[31m'
            ;;
        *) tag="     " ;;
    esac
    if [[ $level == error || $level == warn ]]; then
        printf '%s[%s]%s %s\n' "$color" "$tag" "$reset" "$msg" >&2
    else
        printf '%s[%s]%s %s\n' "$color" "$tag" "$reset" "$msg"
    fi
}

# _install_die MENSAJE [CÓDIGO] → error fatal y salida.
_install_die() {
    _install_log error "$1"
    exit "${2:-1}"
}

# _install_confirm MENSAJE → sí/no. Con -y/--yes responde sí sin preguntar.
_install_confirm() {
    [[ ${GHOST_ASSUME_YES:-0} == 1 ]] && return 0
    local ans
    printf '%s [s/N]: ' "$1"
    read -r ans || return 1
    [[ $ans =~ ^[sSyY]$ ]]
}

# _install_cmd_exists COMANDO → ¿existe el comando en el PATH?
_install_cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

# _install_pkg_exists PAQUETE → ¿está instalado el paquete .deb?
_install_pkg_exists() {
    dpkg -s "$1" >/dev/null 2>&1
}

# _install_apt_update → actualiza la lista de paquetes (respeta --dry-run).
_install_apt_update() {
    if [[ ${GHOST_DRY_RUN:-0} == 1 ]]; then
        _install_log info "[dry-run] apt-get update"
        return 0
    fi
    if ! _install_cmd_exists apt-get; then
        _install_log warn "apt-get no está disponible; omito la actualización de paquetes."
        return 1
    fi
    _install_log info "Actualizando lista de paquetes (apt-get update)…"
    if apt-get update -y >/dev/null 2>&1; then
        return 0
    fi
    _install_log warn "apt-get update falló; continúo de todos modos."
    return 1
}

# _install_apt_install PAQUETES… → instala paquetes vía apt (respeta --dry-run).
_install_apt_install() {
    local -a pkgs=("$@")
    [[ ${#pkgs[@]} -eq 0 ]] && return 0
    if [[ ${GHOST_DRY_RUN:-0} == 1 ]]; then
        _install_log info "[dry-run] apt-get install -y ${pkgs[*]}"
        return 0
    fi
    if ! _install_cmd_exists apt-get; then
        _install_log error "apt-get no está disponible; instala manualmente: ${pkgs[*]}"
        return 1
    fi
    _install_log info "Instalando: ${pkgs[*]}"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >/dev/null 2>&1; then
        _install_log ok "Instalado: ${pkgs[*]}"
        return 0
    fi
    _install_log error "No se pudo instalar: ${pkgs[*]}"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
#  AYUDA / VERSIÓN / PARSEO
# ──────────────────────────────────────────────────────────────────────────────

# install_show_help → ayuda formateada.
install_show_help() {
    cat <<EOF
${GHOST_NAME} ${GHOST_VERSION} — Instalador

Uso: sudo ./install.sh [opciones]

Opciones:
  -h, --help          Muestra esta ayuda y sale.
  -v, --version       Muestra la versión y sale.
      --dry-run       Simula toda la instalación sin realizar cambios.
      --prefix DIR    Directorio de instalación (por defecto ${GHOST_INSTALL_DIR}).
      --no-color      Desactiva los colores ANSI.
  -y, --yes           Modo no interactivo: asume «sí» en las confirmaciones.
      --uninstall     Desinstala (delega en uninstall.sh o muestra instrucciones).

Ejemplos:
  sudo ./install.sh
  sudo ./install.sh --dry-run
  sudo ./install.sh -y --prefix /usr/local/share/ghost-kali

Uso ético y legal. Ghost-Kali protege tu privacidad; no facilita abusos.
EOF
}

# install_show_version → versión y créditos.
install_show_version() {
    cat <<EOF
${GHOST_NAME} ${GHOST_VERSION}
Autor:    ${GHOST_AUTHOR}
Repo:     ${GHOST_REPO}
Licencia: MIT
EOF
}

# install_parse_args → parsea todos los flags del instalador.
install_parse_args() {
    local a
    while [[ $# -gt 0 ]]; do
        a=$1
        case $a in
            -h | --help)
                install_show_help
                exit 0
                ;;
            -v | --version)
                install_show_version
                exit 0
                ;;
            --dry-run) GHOST_DRY_RUN=1 ;;
            --no-color) GHOST_NO_COLOR=1 ;;
            -y | --yes) GHOST_ASSUME_YES=1 ;;
            --prefix)
                shift
                [[ -n ${1:-} ]] || _install_die "--prefix requiere una ruta." 2
                GHOST_INSTALL_DIR=$1
                ;;
            --prefix=*) GHOST_INSTALL_DIR=${a#*=} ;;
            --uninstall) GHOST_ACTION=uninstall ;;
            *)
                printf 'Opción desconocida: %s\n\n' "$a" >&2
                install_show_help
                exit 2
                ;;
        esac
        shift
    done
    # Recalculamos el symlink por si cambió el directorio de binarios por entorno.
    GHOST_SYMLINK="${GHOST_BIN_DIR}/joseph-trio"
}

# ──────────────────────────────────────────────────────────────────────────────
#  VALIDACIONES DEL SISTEMA
# ──────────────────────────────────────────────────────────────────────────────

# install_require_root → exige root (salvo en --dry-run, que no cambia nada).
install_require_root() {
    local uid=${EUID:-$(id -u)}
    if [[ $uid -eq 0 ]]; then
        return 0
    fi
    if [[ ${GHOST_DRY_RUN:-0} == 1 ]]; then
        _install_log warn "No eres root; en --dry-run no se harán cambios. Continúo en simulación."
        return 0
    fi
    _install_die "El instalador debe ejecutarse como root. Usa: sudo ./install.sh" 1
}

# install_detect_os → detecta la distribución (Kali/Debian/Ubuntu o derivada).
install_detect_os() {
    if [[ ! -r /etc/os-release ]]; then
        _install_log warn "No encuentro /etc/os-release; no puedo verificar la distribución."
        _install_confirm "¿Continuar de todos modos?" || _install_die "Instalación cancelada." 1
        return 0
    fi
    local id idlike
    id=$(grep -E '^ID=' /etc/os-release | head -1 | cut -d= -f2 | tr -d '"')
    idlike=$(grep -E '^ID_LIKE=' /etc/os-release | head -1 | cut -d= -f2 | tr -d '"')
    GHOST_OS_ID=$id
    case $id in
        kali | debian | ubuntu)
            _install_log ok "Distribución compatible detectada: ${id}."
            ;;
        *)
            if [[ $idlike == *debian* ]]; then
                _install_log ok "Distribución derivada de Debian: ${id} (compatible)."
            else
                _install_log warn "Distribución no reconocida: ${id:-desconocida}. Está pensado para Kali/Debian/Ubuntu."
                _install_confirm "¿Continuar bajo tu propia responsabilidad?" || _install_die "Instalación cancelada." 1
            fi
            ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────────
#  DEPENDENCIAS
# ──────────────────────────────────────────────────────────────────────────────

# install_check_deps → verifica dependencias base y opcionales.
install_check_deps() {
    _install_log info "Verificando dependencias base…"
    local -a req=(curl wget jq) missing=()
    local c
    for c in "${req[@]}"; do
        if _install_cmd_exists "$c"; then
            _install_log ok "${c} presente."
        else
            _install_log warn "${c} ausente."
            missing+=("$c")
        fi
    done
    GHOST_MISSING_DEPS=("${missing[@]}")

    # Opcionales: no bloquean la instalación, solo se informan.
    for c in macchanger shellcheck shfmt; do
        if _install_cmd_exists "$c"; then
            _install_log ok "(opcional) ${c} presente."
        else
            _install_log info "(opcional) ${c} ausente."
        fi
    done
}

# install_install_deps → instala las dependencias base faltantes (con confirmación).
install_install_deps() {
    if [[ ${#GHOST_MISSING_DEPS[@]} -eq 0 ]]; then
        _install_log ok "Todas las dependencias base están presentes."
        return 0
    fi
    _install_log info "Dependencias faltantes: ${GHOST_MISSING_DEPS[*]}"
    if ! _install_confirm "¿Instalar las dependencias faltantes vía apt?"; then
        _install_log warn "Continúo sin instalarlas; algunas funciones podrían fallar."
        return 0
    fi
    _install_apt_update
    _install_apt_install "${GHOST_MISSING_DEPS[@]}"

    # macchanger es opcional pero útil para el hardening de MAC.
    if ! _install_cmd_exists macchanger; then
        if _install_confirm "¿Instalar macchanger (opcional, para aleatorizar la MAC)?"; then
            _install_apt_install macchanger
        fi
    fi
}

# install_check_tor → verifica/instala Tor. NO modifica torrc (solo recomienda).
install_check_tor() {
    if _install_cmd_exists tor; then
        _install_log ok "Tor ya está instalado."
    else
        _install_log warn "Tor no está instalado."
        if _install_confirm "¿Instalar Tor vía apt?"; then
            _install_apt_update
            _install_apt_install tor
        fi
    fi
    _install_log info "Recomendación (edición MANUAL de /etc/tor/torrc, este instalador NO lo toca):"
    _install_log info "  ControlPort 9051"
    _install_log info "  CookieAuthentication 1"
}

# install_check_proxychains → verifica/instala Proxychains. NO modifica su config.
install_check_proxychains() {
    if _install_cmd_exists proxychains4 || _install_cmd_exists proxychains; then
        _install_log ok "Proxychains ya está instalado."
    else
        _install_log warn "Proxychains no está instalado."
        if _install_confirm "¿Instalar proxychains4 vía apt?"; then
            _install_apt_update
            _install_apt_install proxychains4
        fi
    fi
    _install_log info "Verifica que /etc/proxychains4.conf tenga: socks5 127.0.0.1 9050 (SOCKS de Tor)."
    _install_log info "Este instalador NO modifica ese archivo."
}

# install_check_mullvad → verifica Mullvad. NO lo descarga/instala automáticamente.
# POR QUÉ no automatizamos: Mullvad no está en los repos de apt por defecto y
# descargar/ejecutar instaladores remotos sin verificación sería un riesgo de
# seguridad. Damos instrucciones desde la fuente oficial.
install_check_mullvad() {
    if _install_cmd_exists mullvad; then
        _install_log ok "Mullvad CLI ya está instalado."
        return 0
    fi
    _install_log warn "Mullvad no está instalado (no está en apt por defecto)."
    _install_log info "Instálalo manualmente desde la fuente oficial:"
    _install_log info "  1) Descarga el .deb desde https://mullvad.net/download/vpn/linux/"
    _install_log info "  2) Instálalo: sudo apt install ./MullvadVPN-<versión>_amd64.deb"
    _install_log info "  3) O añade el repositorio oficial de Mullvad (ver su documentación)."
    _install_log info "Ghost-Kali funcionará con Tor/Proxychains aunque Mullvad no esté presente."
}

# ──────────────────────────────────────────────────────────────────────────────
#  COPIA, SYMLINK, PERMISOS, CONFIG
# ──────────────────────────────────────────────────────────────────────────────

# install_backup_if_exists → hace backup del directorio de instalación si existe.
# Usa «mv» (nunca rm -rf): conservamos el contenido previo por seguridad.
install_backup_if_exists() {
    [[ -e $GHOST_INSTALL_DIR ]] || return 0
    local backup="${GHOST_INSTALL_DIR}.bak.$(date +%Y%m%d%H%M%S)"
    _install_log warn "Ya existe ${GHOST_INSTALL_DIR}."
    if [[ ${GHOST_DRY_RUN:-0} == 1 ]]; then
        _install_log info "[dry-run] Movería ${GHOST_INSTALL_DIR} → ${backup}"
        return 0
    fi
    if ! _install_confirm "¿Hacer backup del directorio existente antes de continuar?"; then
        _install_log warn "Sin backup; se sobrescribirá el contenido durante la copia."
        return 0
    fi
    if mv -- "$GHOST_INSTALL_DIR" "$backup"; then
        _install_log ok "Backup creado: ${backup}"
    else
        _install_die "No se pudo crear el backup de ${GHOST_INSTALL_DIR}." 1
    fi
}

# install_copy_files → copia el proyecto a GHOST_INSTALL_DIR.
install_copy_files() {
    local src=$GHOST_SRC_DIR
    _install_log info "Copiando archivos a ${GHOST_INSTALL_DIR}…"
    if [[ ${GHOST_DRY_RUN:-0} == 1 ]]; then
        _install_log info "[dry-run] mkdir -p ${GHOST_INSTALL_DIR} && copia de ${src}/ (excluyendo .git y backups)"
        return 0
    fi
    mkdir -p "$GHOST_INSTALL_DIR" || _install_die "No se pudo crear ${GHOST_INSTALL_DIR}." 1
    if _install_cmd_exists rsync; then
        rsync -a --exclude '.git' --exclude '*.bak.*' "${src}/" "${GHOST_INSTALL_DIR}/" ||
            _install_die "Fallo al copiar los archivos (rsync)." 1
    else
        # Fallback sin rsync: copia recursiva preservando atributos.
        cp -a "${src}/." "${GHOST_INSTALL_DIR}/" ||
            _install_die "Fallo al copiar los archivos (cp)." 1
    fi
    _install_log ok "Archivos copiados a ${GHOST_INSTALL_DIR}."
}

# install_create_symlink → crea/actualiza el symlink global en GHOST_BIN_DIR.
install_create_symlink() {
    local target="${GHOST_INSTALL_DIR}/joseph-trio"
    _install_log info "Creando symlink ${GHOST_SYMLINK} → ${target}"
    if [[ ${GHOST_DRY_RUN:-0} == 1 ]]; then
        _install_log info "[dry-run] ln -sfn ${target} ${GHOST_SYMLINK}"
        return 0
    fi
    mkdir -p "$GHOST_BIN_DIR" 2>/dev/null || true
    # Si ya existe como archivo regular (no symlink), no lo pisamos sin permiso.
    if [[ -e $GHOST_SYMLINK && ! -L $GHOST_SYMLINK ]]; then
        _install_log warn "${GHOST_SYMLINK} existe y NO es un symlink."
        if ! _install_confirm "¿Reemplazarlo por el symlink de Ghost-Kali?"; then
            _install_log warn "Symlink no creado; ejecuta con la ruta completa: ${target}"
            return 0
        fi
    fi
    if ln -sfn "$target" "$GHOST_SYMLINK"; then
        _install_log ok "Symlink creado: ejecuta «joseph-trio» desde cualquier lugar."
    else
        _install_log error "No se pudo crear el symlink en ${GHOST_BIN_DIR}."
        return 1
    fi
}

# install_set_permissions → ajusta permisos (ejecutables 0755, librerías 0644).
install_set_permissions() {
    if [[ ${GHOST_DRY_RUN:-0} == 1 ]]; then
        _install_log info "[dry-run] Ajustaría permisos: joseph-trio 0755, lib/*.sh 0644."
        return 0
    fi
    _install_log info "Ajustando permisos…"
    [[ -f ${GHOST_INSTALL_DIR}/joseph-trio ]] && chmod 0755 "${GHOST_INSTALL_DIR}/joseph-trio"
    [[ -f ${GHOST_INSTALL_DIR}/install.sh ]] && chmod 0755 "${GHOST_INSTALL_DIR}/install.sh"
    [[ -f ${GHOST_INSTALL_DIR}/uninstall.sh ]] && chmod 0755 "${GHOST_INSTALL_DIR}/uninstall.sh"
    # Las librerías se cargan con «source»; no necesitan bit de ejecución.
    if [[ -d ${GHOST_INSTALL_DIR}/lib ]]; then
        chmod 0644 "${GHOST_INSTALL_DIR}"/lib/*.sh 2>/dev/null || true
    fi
    _install_log ok "Permisos ajustados."
}

# install_create_config → crea una config local mínima si no existe (sin secretos).
install_create_config() {
    local cfg_dir="${GHOST_INSTALL_DIR}/config"
    local cfg="${cfg_dir}/config.local"
    local example="${cfg_dir}/config.example"
    if [[ ${GHOST_DRY_RUN:-0} == 1 ]]; then
        _install_log info "[dry-run] Crearía ${cfg} desde config.example si no existiera."
        return 0
    fi
    mkdir -p "$cfg_dir" 2>/dev/null || true
    if [[ -f $cfg ]]; then
        _install_log ok "La config local ya existe: ${cfg} (no se modifica)."
        return 0
    fi
    if [[ -f $example ]]; then
        cp -n "$example" "$cfg" && _install_log ok "Config creada desde el ejemplo: ${cfg}"
    else
        # Generamos una config mínima y segura. NUNCA contiene credenciales.
        cat >"$cfg" <<EOF
# Configuración local de ${GHOST_NAME} (${GHOST_VERSION})
# IMPORTANTE: este archivo NO debe contener credenciales ni números de cuenta.
GHOST_THEME=ghost
GHOST_BANNER_MODE=full
GHOST_DASH_REFRESH=5
EOF
        _install_log ok "Config mínima creada: ${cfg}"
    fi
}

# install_run_tests → comprobaciones básicas (bash -n siempre; shellcheck/shfmt si hay).
install_run_tests() {
    _install_log info "Comprobaciones básicas…"
    local base=$GHOST_INSTALL_DIR f rc=0
    # En --dry-run (o si aún no se copió) comprobamos el directorio de origen.
    if [[ ${GHOST_DRY_RUN:-0} == 1 || ! -f ${base}/joseph-trio ]]; then
        base=$GHOST_SRC_DIR
    fi

    if bash -n "${base}/joseph-trio" 2>/dev/null; then
        _install_log ok "Sintaxis de joseph-trio correcta."
    else
        _install_log warn "joseph-trio: bash -n reportó problemas."
        rc=1
    fi
    if [[ -d ${base}/lib ]]; then
        for f in "${base}"/lib/*.sh; do
            [[ -e $f ]] || continue
            if ! bash -n "$f" 2>/dev/null; then
                _install_log warn "$(basename "$f"): bash -n reportó problemas."
                rc=1
            fi
        done
    fi

    if _install_cmd_exists shellcheck; then
        if shellcheck -S error "${base}/joseph-trio" >/dev/null 2>&1; then
            _install_log ok "shellcheck -S error: sin errores en joseph-trio."
        else
            _install_log info "shellcheck tiene observaciones (revisa: shellcheck ${base}/joseph-trio)."
        fi
    else
        _install_log info "shellcheck no instalado; omito el análisis estático."
    fi
    if _install_cmd_exists shfmt; then
        if shfmt -d -i 4 -ci "${base}/joseph-trio" >/dev/null 2>&1; then
            _install_log ok "shfmt: formato correcto."
        else
            _install_log info "shfmt sugiere cambios de formato (opcional)."
        fi
    fi
    return "$rc"
}

# ──────────────────────────────────────────────────────────────────────────────
#  RESUMEN / DESINSTALACIÓN
# ──────────────────────────────────────────────────────────────────────────────

# install_summary → resumen final y próximos pasos.
install_summary() {
    printf '\n'
    if [[ ${GHOST_DRY_RUN:-0} == 1 ]]; then
        _install_log ok "Simulación (--dry-run) completada: no se realizó ningún cambio."
    else
        _install_log ok "Instalación de ${GHOST_NAME} ${GHOST_VERSION} completada."
    fi
    cat <<EOF

  Ruta de instalación : ${GHOST_INSTALL_DIR}
  Comando global      : joseph-trio   (symlink: ${GHOST_SYMLINK})

  Próximos pasos:
    1) Ejecuta:                 sudo joseph-trio
    2) Verifica el estado:      sudo joseph-trio --status
    3) Tor: habilita «ControlPort 9051» y «CookieAuthentication 1» en /etc/tor/torrc.
    4) Mullvad: inicia sesión con  mullvad account login <tu-cuenta>.

  Disclaimer: ${GHOST_NAME} es una herramienta DEFENSIVA de privacidad. Úsala de
  forma ética y legal, solo sobre sistemas para los que tengas autorización.
  Repositorio: ${GHOST_REPO}
EOF
}

# install_uninstall → desinstalación guiada (delega en uninstall.sh si existe).
install_uninstall() {
    local uninstaller="${GHOST_SRC_DIR}/uninstall.sh"
    [[ -f $uninstaller ]] || uninstaller="${GHOST_INSTALL_DIR}/uninstall.sh"

    if [[ -f $uninstaller ]]; then
        _install_log info "Delegando en ${uninstaller}…"
        local -a passthru=()
        [[ ${GHOST_DRY_RUN:-0} == 1 ]] && passthru+=(--dry-run)
        [[ ${GHOST_ASSUME_YES:-0} == 1 ]] && passthru+=(-y)
        [[ ${GHOST_NO_COLOR:-0} == 1 ]] && passthru+=(--no-color)
        bash "$uninstaller" "${passthru[@]}"
        return $?
    fi

    # Sin uninstaller: mostramos instrucciones, NO ejecutamos nada destructivo.
    _install_log warn "No se encontró uninstall.sh. Desinstalación manual:"
    _install_log info "  1) Elimina el symlink:      sudo rm -f ${GHOST_SYMLINK}"
    _install_log info "  2) Elimina la instalación:  sudo rm -rf ${GHOST_INSTALL_DIR}"
    _install_log info "     Revisa la ruta antes de borrar; este instalador NO la borra por ti."
}

# ──────────────────────────────────────────────────────────────────────────────
#  PUNTO DE ENTRADA
# ──────────────────────────────────────────────────────────────────────────────
install_main() {
    GHOST_SRC_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
    install_parse_args "$@"

    if [[ ${GHOST_ACTION:-} == uninstall ]]; then
        install_require_root
        install_uninstall
        exit $?
    fi

    _install_log info "Instalando ${GHOST_NAME} ${GHOST_VERSION}…"
    [[ ${GHOST_DRY_RUN:-0} == 1 ]] && _install_log warn "MODO --dry-run: no se realizarán cambios reales."

    install_require_root
    install_detect_os
    install_check_deps
    install_install_deps
    install_check_tor
    install_check_proxychains
    install_check_mullvad

    # Idempotencia: si el origen ya es el destino, no copiamos.
    if [[ $GHOST_SRC_DIR == "$GHOST_INSTALL_DIR" ]]; then
        _install_log info "El origen ya es ${GHOST_INSTALL_DIR}; omito la copia."
    else
        install_backup_if_exists
        install_copy_files
    fi

    install_set_permissions
    install_create_symlink
    install_create_config
    install_run_tests || _install_log warn "Algunas comprobaciones reportaron observaciones."
    install_summary
}

install_main "$@"
