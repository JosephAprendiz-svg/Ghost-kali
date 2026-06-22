# Ghost‑Kali

![build](https://img.shields.io/badge/build-pending-lightgrey) ![license](https://img.shields.io/badge/license-MIT-blue) ![language](https://img.shields.io/badge/lang-español-brightgreen)

███████╗██╗  ██╗ ██████╗ ████████╗███████╗     ██╗  ██╗ █████╗ ██╗     ██╗
██╔════╝██║  ██║██╔════╝ ╚══██╔══╝██╔════╝     ██║  ██║██╔══██╗██║     ██║
█████╗  ███████║██║  ███╗   ██║   ███████╗     ███████║███████║██║     ██║
██╔══╝  ██╔══██║██║   ██║   ██║   ╚════██║     ██╔══██║██╔══██║██║     ██║
██║     ██║  ██║╚██████╔╝   ██║   ███████║     ██║  ██║██║  ██║███████╗██║
╚═╝     ╚═╝  ╚═╝ ╚═════╝    ╚═╝   ╚══════╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝

Ghost‑Kali — Toolkit de anonimato operativo para Kali Linux
---------------------------------------------------------

Resumen
- Ghost‑Kali es una herramienta para usuarios técnicos que desean orquestar de forma responsable y auditable conexiones anónimas usando Mullvad (WireGuard), Tor y proxychains.
- Diseñado para auditorías, investigación y aprendizaje. NO incluye ni facilita técnicas ofensivas ilegales.
- Este README completo explica instalación, uso, modelo de amenazas, seguridad y contribución.

Tabla de contenidos
1. Características
2. Quick Start
3. Requisitos
4. Instalación (local)
5. Uso básico
6. Flags y modo no interactivo
7. Configuración (config.example)
8. Seguridad, ética y límites de uso
9. Modelo de amenazas (resumen)
10. Validaciones y pruebas de fuga (IP / DNS)
11. Pruebas automáticas y CI
12. Contribuir
13. Seguridad del proyecto
14. Código de Conducta
15. Licencia
16. FAQ

1) Características
- Menú interactivo para iniciar/paro: Mullvad (WireGuard), Tor, proxychains.
- Kill‑switch robusto para evitar fugas fuera del túnel.
- Rotación de identidad Tor (manual y programada).
- Panel de estado en vivo: IP pública, país, estado de Mullvad, latencia.
- Test de fugas: IP, DNS y WebRTC (informes resumen).
- Modo `--dry-run`, `--non-interactive`, `--verbose`.
- Soporte para configuraciones de proxychains4.

2) Quick Start
- Requisitos mínimos: Kali (Debian‑based), Bash, sudo, acceso root para configurar redes.
- Instalar script principal:
  sudo mv joseph-trio /usr/local/bin/joseph-trio
  sudo chmod +x /usr/local/bin/joseph-trio
- Ejecutar:
  sudo joseph-trio --dry-run
  sudo joseph-trio       # modo interactivo

3) Requisitos
- Python y/o utilidades base (dependencias documentadas más abajo).
- Mullvad account + WireGuard (opcional si usas Mullvad).
- Tor (paquete system tor) y proxychains4.
- shellcheck y shfmt recomendados para contribuciones.

4) Instalación (local)
- Idempotente: el instalador crea backups de archivos modificados.
- Pasos:
  1. Revisar `install.sh` antes de ejecutar.
  2. Ejecutar en modo prueba:
     sudo bash install.sh --dry-run
  3. Ejecutar instalación:
     sudo bash install.sh
- El instalador:
  - crea `/etc/ghost-kali/` para configs,
  - copia `joseph-trio` a `/usr/local/bin/`,
  - crea usuarios/permisos limitados para servicios si aplica.

5) Uso básico
- Comandos principales:
  - Iniciar interfaz: sudo joseph-trio
  - Modo no interactivo (ejemplo): sudo joseph-trio --start --vpn mullvad --proxychains
  - Rotar Tor: sudo joseph-trio --tor-newnym
  - Health check: sudo joseph-trio --health-check

6) Flags disponibles (resumen)
- --dry-run       : muestra acciones sin ejecutarlas
- --verbose       : salida detallada
- --non-interactive: ejecución en scripts/CI
- --start/--stop  : iniciar/parar servicios
- --tor-newnym    : solicitar nueva identidad Tor
- --health-check  : comprobar integridad del stack

7) Configuración
- Archivo ejemplo: `/etc/ghost-kali/config.example`
- No subas tu config real. Guarda una `config.example` con variables genéricas.
- Proxychains: se recomienda `proxy_dns` y `strict_chain` dependiendo del uso.

8) Seguridad, ética y límites de uso (MANDATORY)
- Este proyecto es para investigación, auditoría y uso legítimo. Está PROHIBIDO su uso para actividades ilegales (DDoS, fraude, intrusión sin permiso).
- No subas archivos que contengan credenciales, claves privadas ni archivos de cuenta. Añádelos a `.gitignore`.
- Revisa y comprende leyes locales y políticas de tu proveedor de servicios.

9) Modelo de amenazas (resumen)
- Protege contra fugas de IP por fallo de VPN/Tor: kill‑switch y reglas iptables/ufw.
- Riesgos residuales: fingerprinting de aplicaciones, correlación de tráfico, metadatos de aplicaciones.
- Recomendación: usar Tor Browser o VM dedicada para tareas de alta privacidad.

10) Validaciones y pruebas
- Scripts de validación incluidos:
  - ip_check.sh (ver IP pública)
  - dns_leak_test.sh (test con varios resolvers)
  - webrtc_check.sh (comprobación WebRTC)
- Ejecución:
  sudo joseph-trio --health-check

11) CI y pruebas
- Se recomienda GitHub Actions con:
  - shellcheck
  - shfmt check
  - bats para pruebas unitarias de shell
  - secret scanning (no subir secretos)
- Archivo sugerido: `.github/workflows/ci.yml` (plantilla en docs/ci.md)

12) Contribuir
- Lee `CONTRIBUTING.md` antes de enviar PR.
- Usa branch por feature (ej: feat/v5-elite). Haz PR pequeños y descriptivos.
- Usa `shellcheck` y `shfmt` antes de pedir review.
- Mantén la ética: todo PR que introduzca capacidades ofensivas será rechazado.

13) Seguridad del proyecto (SECURITY.md)
- Reporte responsable: crea un issue privado o usa correo de seguridad (vacío aquí — usa GitHub security policy).
- No publiques exploits ni herramientas de ataque.

14) Código de Conducta
- Respeto, inclusión y colaboración. Lee `CODE_OF_CONDUCT.md` antes de contribuir.

15) Licencia
- MIT. Ver archivo `LICENSE`.

16) FAQ (breve)
Q: ¿Puedo usar otro proveedor VPN?
A: Sí, Ghost‑Kali es agnóstico; Mullvad es recomendado por su privacidad y WireGuard.

Q: ¿Esto me hace 100% anónimo?
A: No. Este toolkit reduce riesgos, pero no elimina todos los vectores de correlación o fingerprinting.

Q: ¿Puedo automatizar rotación de IP?
A: Sí — configura cron/timers junto a `--tor-newnym` o gestión de WireGuard.

Changelog
- Mantén `CHANGELOG.md` siguiendo Keep a Changelog. Primer release: v5.0 — scaffold y docs inicial.

Creditos & agradecimientos
- Proyecto comunitario — contribuciones y revisión bienvenida.
- Inspiración y mejores prácticas: proyectos de privacidad y hardening de comunidad.

Contacto
- Issues y PR en GitHub: https://github.com/JosephAprendiz-svg/Ghost-kali

---------------------------------------------------------
NOTAS FINALES (LEER)
- Revisa `install.sh` y `joseph-trio` antes de ejecutar.
- No aceptes instalar binarios sin revisar (no subimos binarios en el repo).
- Si necesitas que adapte el README (más secciones, español/inglés dual, badges personalizados), dime exactamente qué cambiar y lo actualizo al toque.
