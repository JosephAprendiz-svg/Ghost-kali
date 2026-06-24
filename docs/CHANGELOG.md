# Changelog - Ghost-Kali

Formato basado en [Keep a Changelog](https://keepachangelog.com/) v1.1.0.
Versionado segun [SemVer](https://semver.org/) 2.0.0.

---

## [5.0.0] - 2026-06-24

### Added

- Refactorizacion completa a modulos `lib/`: `vpnctl.sh`, `torctl.sh`,
  `proxyctl.sh`, `colors.sh`, `logger.sh`, `validators.sh`, `netutils.sh`,
  `banner.sh`, `dashboard.sh`.
- Script principal `joseph-trio` como orquestador de la cascada.
- Instaladores `install.sh` y `uninstall.sh`.
- Tests unitarios con BATS en `tests/`.
- Pipeline CI/CD en `.github/workflows/ci.yml` (lint-shell, test-bats,
  validate-structure, kali-compat).
- Documentacion completa en `docs/`.
- Gestion de configuracion del propio cliente Tor: control de servicio,
  circuitos, seleccion de pais de salida, rotacion de identidad, aislamiento
  de streams y deteccion de fugas.
- Gestion del propio `proxychains.conf`: modo de cadena, `proxy_dns`, alta y
  baja de proxies, plantilla segura y ejecucion de comandos propios por la
  cadena.
- Perfil efimero de maxima privacidad (`torctl_ghost_circuit`): nodos
  estrictos, aislamiento de streams y registro local minimo, restaurable.
- Bitacora de operaciones de la sesion, exportable a JSON/CSV.

### Changed

- Arquitectura monolitica migrada a un sistema modular.
- Configuracion centralizada en constantes `readonly`.
- Sistema de colores basado en variables de tema.

### Deprecated

- Scripts legacy de versiones anteriores a v5.0.

### Removed

- Codigo duplicado entre modulos.
- Dependencias de herramientas no estandar.

### Fixed

- Fugas DNS en configuraciones por defecto.
- Idempotencia en las modificaciones de archivos de configuracion.
- Manejo de errores en operaciones de red.

### Security

- Backup atomico antes de toda modificacion de configuracion.
- Saneamiento de salida para no exponer credenciales, hashes ni cookies.
- Guardas de ejecucion directa e idempotencia en todos los modulos.
- Modo `--dry-run` y confirmacion interactiva en operaciones destructivas.

## [Unreleased]

(Vacio. Las proximas versiones se documentaran aqui.)

---

Enlaces:

- [5.0.0]: https://github.com/JosephAprendiz-svg/Ghost-kali/releases/tag/v5.0.0
-
