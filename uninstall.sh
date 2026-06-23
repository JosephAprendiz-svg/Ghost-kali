#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  uninstall.sh — Desinstalador oficial y seguro de Ghost-Kali v5.0
# ──────────────────────────────────────────────────────────────────────────────
#  Elimina la instalación de Ghost-Kali (/opt/ghost-kali por defecto) y su symlink
#  global, con backup opcional y múltiples guardas de seguridad. Idempotente y con
#  soporte de --dry-run.
#
#  ⚖️  DISCLAIMER ÉTICO/LEGAL: opera SOLO sobre tu sistema local y con tu
#      consentimiento. No elimina malware ni herramientas ofensivas. Toda
#      eliminación requiere confirmación explícita (o -y) y, por defecto, backup.
#      Ghost-Kali es una herramienta DEFENSIVA de privacidad; úsala de forma ética.
#
#  🔐 INVARIANTES:
#      · No borra nada sin confirmación (salvo -y); el rm -rf va tras varias guardas.
#      · No toca /etc/tor/torrc ni /etc/proxychains4.conf.
#      · No desinstala paquetes del sistema sin confirmación separada (--purge).
#      · No imprime credenciales ni datos sensibles.
#
#  Ejecuta: sudo ./uninstall.sh
# ──────────────────────────────────────────────────────────────────────────────

# ── Constantes configurables ──────────────────────────────────────────────────
GHOST_VERSION=${GHOST_VERSION:-v5.0-elite}
GHOST_NAME=${GHOST_NAME:-Ghost-Kali}
GHOST_AUTHOR=${GHOST_AUTHOR:-JosephAprendiz-svg}
GHOST_REPO=${GHOST_REPO:-https://github.com/JosephAprendiz-svg/Ghost-kali}
GHOST_LICENSE=${GHOST_LICENSE:-MIT}

GHOST_DRY_RUN=${GHOST_DRY_RUN:-0}
GHOST_NO_COLOR=${GHOST_NO_COLOR:-0}
GHOST_ASSUME_YES=${GHOST_ASSUME_YES:-0}
GHOST_PURGE=${GHOST_PURGE:-0}

GHOST_INSTALL_DIR=${GHOST_INSTALL_DIR:-/opt/ghost-kali}
GHOST_BIN_DIR=${GHOST_BIN_DIR:-/usr/local/bin}
GHOST_SYMLINK="${GHOST_BIN_DIR}/joseph-trio"

# ── Estado interno (para el resumen final) ────────────────────────────────────
GHOST_SRC_DIR=""
GHOST_SYMLINK_REMOVED="no"
GHOST_BACKUP_PATH=""
GHOST_INSTALL_REMOVED="no"
GHOST_INSTALL_MOVED=0
declare -a GHOST_PURGED_PKGS=()

# ──────────────────────────────────────────────────────────────────────────────
#  HELPERS PRIVADOS
# ──────────────────────────────────────────────────────────────────────────────

# _uninstall_use_color → 0 si debemos colorear (no si --no-color o no es terminal).
_uninstall_use_color() {
    [[ ${GHOST_NO_COLOR:-0} != 1 && -t 1 ]]
}

# _uninstall_log NIVEL MENSAJE → logging con niveles. WARN/ERROR van a stderr.
_uninstall_log() {
    local level=$1
    shift
    local msg=$* color="" reset="" tag
    if _uninstall_use_color; then reset=$'\e[0m'; fi
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

# _uninstall_die MENSAJE [CÓDIGO] → error fatal y salida.
_uninstall_die() {
    _uninstall_log error "$1"
    exit "${2:-1}"
}

# _uninstall_confirm MENSAJE → sí/no. Con -y/--yes responde sí. Default: no.
_uninstall_confirm() {
    [[ ${GHOST_ASSUME_YES:-0} == 1 ]] && return 0
    local ans
    printf '%s [s/N]: ' "$1"
    read -r ans || return 1
    [[ $ans =~ ^[sSyY]$ ]]
}

# _uninstall_cmd_exists COMANDO → 0 si el comando existe en el PATH.
_uninstall_cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

# _uninstall_timestamp → marca de tiempo YYYYMMDDhhmmss para los backups.
_uninstall_timestamp() {
    date +%Y%m%d%H%M%S
}

# _uninstall_apt_remove PAQUETE… → desinstala paquetes vía apt (respeta --dry-run).
_uninstall_apt_remove() {
    local -a pkgs=("$@")
    [[ ${#pkgs[@]} -eq 0 ]] && return 0
    if [[ ${GHOST_DRY_RUN:-0} == 1 ]]; then
        _uninstall_log info "[dry-run] apt-get remove -y ${pkgs[*]}"
        return 0
    fi
    if ! _uninstall_cmd_exists apt-get; then
        _uninstall_log error "apt-get no está disponible; no puedo desinstalar: ${pkgs[*]}"
        return 1
    fi
    _uninstall_log info "Desinstalando: ${pkgs[*]}"
    if DEBIAN_FRONTEND=noninteractive apt-get remove -y "${pkgs[@]}" >/dev/null 2>&1; then
        _uninstall_log ok "Desinstalado: ${pkgs[*]}"
        return 0
    fi
    _uninstall_log error "No se pudo desinstalar: ${pkgs[*]} (continúo)."
    return 1
}

# _uninstall_is_critical_path RUTA → 0 si es una ruta crítica que NUNCA borramos.
# POR QUÉ: es la última línea de defensa contra un rm -rf catastrófico si alguien
# pasa --prefix con una ruta peligrosa o si una variable quedó vacía.
_uninstall_is_critical_path() {
    local p=${1%/} # quitamos una posible barra final
    case $p in
        "" | "/" | "/home" | "/etc" | "/usr" | "/usr/local" | "/usr/local/bin" | \
            "/bin" | "/sbin" | "/lib" | "/lib64" | "/var" | "/tmp" | "/root" | "/opt")
            return 0
            ;;
    esac
    return 1
}

# _uninstall_path_contains_ghost RUTA → 0 si la ruta contiene "ghost" (insensible).
# POR QUÉ: protección adicional; solo borramos directorios que «parecen» nuestros.
_uninstall_path_contains_ghost() {
    local p=${1,,} # a minúsculas (bash 4+)
    [[ $p == *ghost* ]]
}

# _uninstall_readlink_f RUTA → resuelve el destino real de forma portable.
_uninstall_readlink_f() {
    local path=$1
    if _uninstall_cmd_exists readlink && readlink -f "$path" >/dev/null 2>&1; then
        readlink -f "$path"
        return 0
    fi
    # Fallback sin readlink -f.
    if [[ -d $path ]]; then
        (cd -P "$path" 2>/dev/null && pwd)
        return 0
    fi
    local dir base rdir
    dir=$(dirname "$path")
    base=$(basename "$path")
    rdir=$(cd -P "$dir" 2>/dev/null && pwd) || return 1
    if [[ -L "${rdir}/${base}" ]]; then
        local tgt
        tgt=$(readlink "${rdir}/${base}")
        if [[ $tgt == /* ]]; then
            printf '%s\n' "$tgt"
        else
            printf '%s/%s\n' "$rdir" "$tgt"
        fi
        return 0
    fi
    printf '%s/%s\n' "$rdir" "$base"
}

# ──────────────────────────────────────────────────────────────────────────────
#  AYUDA / VERSIÓN / PARSEO
# ──────────────────────────────────────────────────────────────────────────────

# uninstall_show_help → ayuda detallada en español.
uninstall_show_help() {
    cat <<EOF
${GHOST_NAME} ${GHOST_VERSION} — Desinstalador

Uso: sudo ./uninstall.sh [opciones]

Opciones:
  -h, --help          Muestra esta ayuda y sale.
  -v, --version       Muestra la versión y sale.
      --dry-run       Simula la desinstalación sin realizar cambios (no requiere root).
      --prefix DIR    Directorio de instalación a desinstalar (por defecto ${GHOST_INSTALL_DIR}).
      --no-color      Desactiva los colores ANSI.
  -y, --yes           Modo no interactivo: asume «sí» en TODAS las confirmaciones.
      --purge         Pregunta, por separado, si desinstalar tor y proxychains4.
                      Mullvad NUNCA se desinstala automáticamente.

Ejemplos:
  sudo ./uninstall.sh
  ./uninstall.sh --dry-run
  sudo ./uninstall.sh -y
  sudo ./uninstall.sh --purge
  ./uninstall.sh --prefix /usr/local/share/ghost-kali

Este desinstalador NO toca /etc/tor/torrc ni /etc/proxychains4.conf ni ninguna
configuración del sistema. Uso ético y legal; protege tu privacidad, no facilita abusos.
EOF
}

# uninstall_show_version → versión y créditos.
uninstall_show_version() {
    cat <<EOF
${GHOST_NAME} ${GHOST_VERSION}
Autor:    ${GHOST_AUTHOR}
Repo:     ${GHOST_REPO}
Licencia: ${GHOST_LICENSE}
EOF
}

# uninstall_parse_args → parsea todos los flags del desinstalador.
uninstall_parse_args() {
    local a
    while [[ $# -gt 0 ]]; do
        a=$1
        case $a in
            -h | --help)
                uninstall_show_help
                exit 0
                ;;
            -v | --version)
                uninstall_show_version
                exit 0
                ;;
            --dry-run) GHOST_DRY_RUN=1 ;;
            --no-color) GHOST_NO_COLOR=1 ;;
            -y | --yes) GHOST_ASSUME_YES=1 ;;
            --purge) GHOST_PURGE=1 ;;
            --prefix)
                shift
                [[ -n ${1:-} ]] || _uninstall_die "--prefix requiere una ruta." 2
                GHOST_INSTALL_DIR=$1
                ;;
            --prefix=*) GHOST_INSTALL_DIR=${a#*=} ;;
            *)
                printf 'Opción desconocida: %s\n\n' "$a" >&2
                uninstall_show_help
                exit 2
                ;;
        esac
        shift
    done
    # Recalculamos el symlink por si cambió el directorio de binarios por entorno.
    GHOST_SYMLINK="${GHOST_BIN_DIR}/joseph-trio"
}

# ──────────────────────────────────────────────────────────────────────────────
#  VALIDACIONES / DETECCIÓN
# ──────────────────────────────────────────────────────────────────────────────

# uninstall_require_root → exige root (salvo en --dry-run, que no cambia nada).
uninstall_require_root() {
    local uid=${EUID:-$(id -u)}
    if [[ $uid -eq 0 ]]; then
        return 0
    fi
    if [[ ${GHOST_DRY_RUN:-0} == 1 ]]; then
        _uninstall_log warn "No eres root; en --dry-run no se harán cambios. Continúo en simulación."
        return 0
    fi
    _uninstall_die "El desinstalador debe ejecutarse como root. Usa: sudo ./uninstall.sh" 1
}

# uninstall_detect_installation → comprueba si hay instalación y muestra detalles.
# Si no existe, informa y SALE con 0 (comportamiento idempotente y no fatal).
uninstall_detect_installation() {
    if [[ ! -e $GHOST_INSTALL_DIR ]]; then
        _uninstall_log info "No se encontró ninguna instalación en ${GHOST_INSTALL_DIR}."
        _uninstall_log info "No hay nada que desinstalar; el sistema ya está limpio."
        # Si quedara un symlink residual de Ghost-Kali, lo señalamos sin tocarlo.
        if [[ -L $GHOST_SYMLINK ]]; then
            local tgt
            tgt=$(readlink "$GHOST_SYMLINK" 2>/dev/null)
            _uninstall_log warn "Existe un symlink residual: ${GHOST_SYMLINK} → ${tgt}"
            _uninstall_log info "Si te pertenece, elimínalo con: sudo rm -f ${GHOST_SYMLINK}"
        fi
        exit 0
    fi

    _uninstall_log info "Instalación detectada en: ${GHOST_INSTALL_DIR}"

    # Guardas TEMPRANAS: si la ruta es crítica o no parece nuestra, abortamos aquí,
    # ANTES de tocar nada. POR QUÉ aquí: el paso de backup mueve el directorio, así
    # que la protección debe aplicarse antes del backup, no solo antes del rm -rf.
    if _uninstall_is_critical_path "$GHOST_INSTALL_DIR"; then
        _uninstall_die "Ruta crítica del sistema (${GHOST_INSTALL_DIR}); abortando por seguridad." 3
    fi
    if ! _uninstall_path_contains_ghost "$GHOST_INSTALL_DIR"; then
        _uninstall_die "La ruta ${GHOST_INSTALL_DIR} no contiene «ghost»; abortando por seguridad." 3
    fi

    if _uninstall_cmd_exists du; then
        local size
        size=$(du -sh "$GHOST_INSTALL_DIR" 2>/dev/null | cut -f1)
        [[ -n $size ]] && _uninstall_log info "Tamaño aproximado: ${size}"
    fi

    # Estado del symlink global.
    local expected="${GHOST_INSTALL_DIR}/joseph-trio"
    if [[ -L $GHOST_SYMLINK ]]; then
        local raw
        raw=$(readlink "$GHOST_SYMLINK" 2>/dev/null)
        if [[ $raw == "$expected" ]]; then
            _uninstall_log info "Symlink global: ${GHOST_SYMLINK} → ${raw} (de Ghost-Kali)."
        else
            _uninstall_log warn "El symlink ${GHOST_SYMLINK} NO apunta a Ghost-Kali (→ ${raw}); no se tocará."
        fi
    elif [[ -e $GHOST_SYMLINK ]]; then
        _uninstall_log warn "${GHOST_SYMLINK} existe pero NO es un symlink; no se tocará."
    else
        _uninstall_log info "No hay symlink global en ${GHOST_SYMLINK}."
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
#  OPERACIONES
# ──────────────────────────────────────────────────────────────────────────────

# uninstall_remove_symlink → elimina el symlink SOLO si apunta a Ghost-Kali.
uninstall_remove_symlink() {
    GHOST_SYMLINK_REMOVED="no"
    if [[ ! -e $GHOST_SYMLINK && ! -L $GHOST_SYMLINK ]]; then
        _uninstall_log info "No hay symlink que eliminar en ${GHOST_SYMLINK}."
        return 0
    fi
    if [[ ! -L $GHOST_SYMLINK ]]; then
        _uninstall_log warn "${GHOST_SYMLINK} no es un symlink; no se elimina (seguridad)."
        return 0
    fi

    # Verificamos que el symlink REALMENTE apunte a nuestra instalación.
    local expected="${GHOST_INSTALL_DIR}/joseph-trio" raw
    raw=$(readlink "$GHOST_SYMLINK" 2>/dev/null)
    if [[ $raw != "$expected" ]]; then
        # Segunda oportunidad: comparamos rutas resueltas (por si difieren detalles).
        local r1 r2
        r1=$(_uninstall_readlink_f "$GHOST_SYMLINK")
        r2=$(_uninstall_readlink_f "$expected")
        if [[ -z $r1 || $r1 != "$r2" ]]; then
            _uninstall_log warn "El symlink ${GHOST_SYMLINK} NO apunta a Ghost-Kali (→ ${raw}); no se toca."
            return 0
        fi
    fi

    if [[ ${GHOST_DRY_RUN:-0} == 1 ]]; then
        _uninstall_log info "[dry-run] rm -f ${GHOST_SYMLINK}"
        GHOST_SYMLINK_REMOVED="(simulado)"
        return 0
    fi
    # rm -f sobre un symlink elimina el enlace, nunca el destino.
    if rm -f -- "$GHOST_SYMLINK"; then
        _uninstall_log ok "Symlink eliminado: ${GHOST_SYMLINK}"
        GHOST_SYMLINK_REMOVED="sí"
    else
        _uninstall_log error "No se pudo eliminar el symlink ${GHOST_SYMLINK}."
        GHOST_SYMLINK_REMOVED="no"
    fi
}

# uninstall_backup_installation → backup opcional ANTES de borrar.
# POR QUÉ con mv: mover a .bak conserva una copia íntegra y, de paso, retira la
# instalación de su ubicación original SIN usar rm -rf.
uninstall_backup_installation() {
    GHOST_BACKUP_PATH=""
    GHOST_INSTALL_MOVED=0
    [[ -e $GHOST_INSTALL_DIR ]] || return 0

    if ! _uninstall_confirm "¿Crear un backup de ${GHOST_INSTALL_DIR} antes de eliminar?"; then
        _uninstall_log info "Backup omitido por el usuario."
        return 0
    fi

    local backup="${GHOST_INSTALL_DIR}.bak.$(_uninstall_timestamp)"
    if [[ ${GHOST_DRY_RUN:-0} == 1 ]]; then
        _uninstall_log info "[dry-run] mv ${GHOST_INSTALL_DIR} → ${backup}"
        GHOST_BACKUP_PATH="${backup} (simulado)"
        GHOST_INSTALL_MOVED=1
        return 0
    fi
    if mv -- "$GHOST_INSTALL_DIR" "$backup"; then
        _uninstall_log ok "Backup creado (instalación movida): ${backup}"
        GHOST_BACKUP_PATH="$backup"
        GHOST_INSTALL_MOVED=1
    else
        # No abortamos: el usuario podrá decidir en el paso de borrado.
        _uninstall_log error "No se pudo crear el backup; la instalación permanece intacta."
        GHOST_BACKUP_PATH=""
        GHOST_INSTALL_MOVED=0
    fi
}

# uninstall_remove_installation → elimina GHOST_INSTALL_DIR con todas las guardas.
uninstall_remove_installation() {
    GHOST_INSTALL_REMOVED="no"

    # Si el backup ya movió la instalación, no queda nada que borrar (idempotente).
    if [[ ${GHOST_INSTALL_MOVED:-0} == 1 ]]; then
        _uninstall_log info "La instalación ya se trasladó al backup; no queda nada que borrar en ${GHOST_INSTALL_DIR}."
        GHOST_INSTALL_REMOVED="sí"
        return 0
    fi
    if [[ ! -e $GHOST_INSTALL_DIR ]]; then
        _uninstall_log info "No existe ${GHOST_INSTALL_DIR}; nada que eliminar."
        return 0
    fi

    # ── Guardas de seguridad ANTES de cualquier rm -rf ──
    if _uninstall_is_critical_path "$GHOST_INSTALL_DIR"; then
        _uninstall_die "Ruta crítica del sistema (${GHOST_INSTALL_DIR}); abortando por seguridad." 3
    fi
    if ! _uninstall_path_contains_ghost "$GHOST_INSTALL_DIR"; then
        _uninstall_die "La ruta ${GHOST_INSTALL_DIR} no contiene «ghost»; abortando por seguridad." 3
    fi

    if ! _uninstall_confirm "¿Eliminar definitivamente ${GHOST_INSTALL_DIR}? Esta acción no se puede deshacer"; then
        _uninstall_log warn "Eliminación cancelada por el usuario."
        return 0
    fi

    if [[ ${GHOST_DRY_RUN:-0} == 1 ]]; then
        _uninstall_log info "[dry-run] rm -rf ${GHOST_INSTALL_DIR}"
        GHOST_INSTALL_REMOVED="(simulado)"
        return 0
    fi

    # rm -rf acotado: solo sobre GHOST_INSTALL_DIR, tras pasar todas las guardas.
    if rm -rf -- "$GHOST_INSTALL_DIR"; then
        _uninstall_log ok "Instalación eliminada: ${GHOST_INSTALL_DIR}"
        GHOST_INSTALL_REMOVED="sí"
    else
        _uninstall_log error "No se pudo eliminar ${GHOST_INSTALL_DIR}."
        GHOST_INSTALL_REMOVED="no"
    fi
}

# uninstall_purge_packages → desinstalación OPCIONAL de paquetes (solo con --purge).
uninstall_purge_packages() {
    GHOST_PURGED_PKGS=()
    _uninstall_log info "Modo --purge: desinstalación opcional de paquetes del sistema."
    _uninstall_log warn "Otros programas podrían depender de estos paquetes. Procede con cuidado."

    # tor — confirmación SEPARADA.
    if _uninstall_cmd_exists tor || dpkg -s tor >/dev/null 2>&1; then
        if _uninstall_confirm "¿Desinstalar el paquete «tor» del sistema?"; then
            _uninstall_apt_remove tor && GHOST_PURGED_PKGS+=(tor)
        else
            _uninstall_log info "Se conserva «tor»."
        fi
    else
        _uninstall_log info "«tor» no está instalado; nada que desinstalar."
    fi

    # proxychains4 — confirmación SEPARADA.
    if _uninstall_cmd_exists proxychains4 || dpkg -s proxychains4 >/dev/null 2>&1; then
        if _uninstall_confirm "¿Desinstalar el paquete «proxychains4» del sistema?"; then
            _uninstall_apt_remove proxychains4 && GHOST_PURGED_PKGS+=(proxychains4)
        else
            _uninstall_log info "Se conserva «proxychains4»."
        fi
    else
        _uninstall_log info "«proxychains4» no está instalado; nada que desinstalar."
    fi

    # Mullvad — NUNCA automático; solo instrucciones.
    _uninstall_log warn "Mullvad NO se desinstala automáticamente."
    _uninstall_log info "Si deseas quitarlo: sudo apt remove mullvad-vpn (verifica el nombre exacto del paquete)."
}

# uninstall_summary → resumen final claro de todo lo realizado.
uninstall_summary() {
    printf '\n'
    local mode
    if [[ ${GHOST_DRY_RUN:-0} == 1 ]]; then
        mode="SIMULACIÓN (--dry-run)"
    else
        mode="real"
    fi
    _uninstall_log ok "Desinstalación finalizada (modo: ${mode})."

    cat <<EOF

  Resumen:
    Ruta objetivo        : ${GHOST_INSTALL_DIR}
    Symlink (${GHOST_SYMLINK})
                  eliminado : ${GHOST_SYMLINK_REMOVED:-no}
    Backup               : ${GHOST_BACKUP_PATH:-no}
    Instalación borrada  : ${GHOST_INSTALL_REMOVED:-no}
EOF
    if [[ ${GHOST_PURGE:-0} == 1 ]]; then
        local pk="ninguno"
        [[ ${#GHOST_PURGED_PKGS[@]} -gt 0 ]] && pk="${GHOST_PURGED_PKGS[*]}"
        printf '    Paquetes purgados    : %s\n' "$pk"
    fi

    cat <<EOF

  Próximos pasos:
    · No se ha tocado /etc/tor/torrc ni /etc/proxychains4.conf.
    · Si guardaste configuraciones fuera de ${GHOST_INSTALL_DIR}, revísalas tú mismo.
    · Para reinstalar: ejecuta ./install.sh desde el repositorio.

  Disclaimer: ${GHOST_NAME} es una herramienta DEFENSIVA de privacidad. Esta
  desinstalación solo ha operado sobre tu sistema local y con tu consentimiento.
  Repositorio: ${GHOST_REPO}
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
#  PUNTO DE ENTRADA
# ──────────────────────────────────────────────────────────────────────────────
uninstall_main() {
    GHOST_SRC_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
    uninstall_parse_args "$@"

    _uninstall_log info "Desinstalador de ${GHOST_NAME} ${GHOST_VERSION}"
    [[ ${GHOST_DRY_RUN:-0} == 1 ]] && _uninstall_log warn "MODO --dry-run: no se realizarán cambios reales."

    uninstall_require_root
    uninstall_detect_installation # sale con 0 si no hay instalación (idempotente)
    uninstall_remove_symlink
    uninstall_backup_installation
    uninstall_remove_installation
    [[ ${GHOST_PURGE:-0} == 1 ]] && uninstall_purge_packages
    uninstall_summary
    return 0
}

uninstall_main "$@"

# EOF
