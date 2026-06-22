<div align="center">

```
 ██████╗ ██╗  ██╗ ██████╗ ███████╗████████╗   ██╗  ██╗ █████╗ ██╗     ██╗
██╔════╝ ██║  ██║██╔═══██╗██╔════╝╚══██╔══╝   ██║ ██╔╝██╔══██╗██║     ██║
██║  ███╗███████║██║   ██║███████╗   ██║      █████╔╝ ███████║██║     ██║
██║   ██║██╔══██║██║   ██║╚════██║   ██║      ██╔═██╗ ██╔══██║██║     ██║
╚██████╔╝██║  ██║╚██████╔╝███████║   ██║      ██║  ██╗██║  ██║███████╗██║
 ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝      ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝
```

### 👻 **Ghost-Kali** · Cadena de anonimato multicapa para Kali Linux

*“La privacidad no es un crimen, es un derecho.”*

[![Version](https://img.shields.io/badge/version-5.0.0-BD93F9?style=flat-square)](https://github.com/JosephAprendiz-svg/Ghost-kali/releases)
[![License](https://img.shields.io/badge/license-MIT-50FA7B?style=flat-square)](LICENSE)
[![ShellCheck](https://img.shields.io/badge/shellcheck-passing-50FA7B?style=flat-square&logo=gnu-bash&logoColor=white)](#-estándares-de-código)
[![CI](https://img.shields.io/github/actions/workflow/status/JosephAprendiz-svg/Ghost-kali/ci.yml?branch=main&style=flat-square&label=CI)](https://github.com/JosephAprendiz-svg/Ghost-kali/actions)
[![Bash](https://img.shields.io/badge/bash-5.0+-1F425F?style=flat-square&logo=gnu-bash&logoColor=white)](#)
[![Platform](https://img.shields.io/badge/platform-Kali%20%7C%20Debian%20%7C%20Ubuntu-557C94?style=flat-square&logo=linux&logoColor=white)](#)

[![Stars](https://img.shields.io/github/stars/JosephAprendiz-svg/Ghost-kali?style=social)](https://github.com/JosephAprendiz-svg/Ghost-kali/stargazers)
[![Contributors](https://img.shields.io/github/contributors/JosephAprendiz-svg/Ghost-kali?style=flat-square)](https://github.com/JosephAprendiz-svg/Ghost-kali/graphs/contributors)
[![Last commit](https://img.shields.io/github/last-commit/JosephAprendiz-svg/Ghost-kali?style=flat-square)](https://github.com/JosephAprendiz-svg/Ghost-kali/commits)
[![Repo size](https://img.shields.io/github/repo-size/JosephAprendiz-svg/Ghost-kali?style=flat-square)](#)

</div>

---

> ⚖️ **Solo para fines educativos, auditorías autorizadas e investigación responsable de seguridad.**
> Ghost-Kali es una herramienta **100 % defensiva**: protege tu privacidad, no ataca a nadie. Cero exploits, cero ataques. Lee el [Disclaimer Legal](#-disclaimer-legal) antes de usarla.

---

## 📖 Descripción

**Ghost-Kali** es un orquestador de anonimato para Kali Linux que encadena tres capas de privacidad independientes —**Mullvad VPN (WireGuard) → Tor → Proxychains**— bajo una única interfaz coherente, auditable y con un cuidado obsesivo por la experiencia de usuario.

No reinventa la criptografía: se apoya en proyectos maduros y revisados por la comunidad (el daemon de Mullvad, la red Tor y `proxychains-ng`) y aporta lo que normalmente falta: **orquestación reproducible, verificación de fugas, un panel de estado en vivo y documentación de nivel OPSEC**. La idea es sencilla: que configurar una cadena de anonimato robusta sea tan fácil como ejecutar un comando, sin sacrificar la transparencia sobre lo que ocurre por debajo.

Está pensado para investigadores de seguridad, periodistas, defensores de la privacidad y administradores que necesitan trabajar con una huella reducida **dentro de la ley y con autorización**.

---

## 📑 Tabla de Contenidos

- [📖 Descripción](#-descripción)
- [✨ Características](#-características)
- [🚀 Quick Start](#-quick-start)
- [🔧 Instalación detallada](#-instalación-detallada)
- [🎮 Uso](#-uso)
- [🎨 Temas visuales](#-temas-visuales)
- [📊 Comparativa](#-comparativa)
- [❓ FAQ](#-faq)
- [🗺️ Roadmap](#️-roadmap)
- [👥 Contribuidores](#-contribuidores)
- [💜 Sponsors](#-sponsors)
- [⚖️ Disclaimer Legal](#-disclaimer-legal)
- [📜 Licencia](#-licencia)

---

## ✨ Características

| | Característica | Descripción |
|---|---|---|
| 🔒 | **Triple capa de anonimato** | Mullvad (WireGuard) + Tor + Proxychains orquestados como una sola cadena. |
| 🎨 | **4 temas visuales** | `ghost`, `midnight`, `forest` y `matrix`, con soporte truecolor y modo `--no-color`. |
| 📊 | **Dashboard de 7 widgets** | Mapa de conexión, circuitos Tor, ancho de banda, geolocalización, uptime, alertas y sistema. |
| 🔄 | **Rotación automática** | Nueva identidad Tor (`NEWNYM`) e isolación de streams en intervalos configurables. |
| 🥷 | **Modo sigilo** | Bridges + transporte conectable (obfs4) para entornos con DPI o censura. |
| 🧪 | **Test de seguridad completo** | Verificación de IP pública, fugas DNS, exit de Tor y avisos de WebRTC. |
| 🗺️ | **Mapa de conexión ASCII** | Visualiza la ruta `Tú → Mullvad → Tor → Internet` de un vistazo. |
| 📚 | **Documentación nivel OPSEC** | Modelo de amenazas, guía de endurecimiento y manual operativo. |
| ✅ | **CI/CD integrado** | `shellcheck`, `shfmt`, tests BATS y escaneo de secretos en cada PR. |
| 🌐 | **Multi-idioma** | Interfaz y documentación en español, con guía de traducción incluida. |

---

## 🚀 Quick Start

```bash
git clone https://github.com/JosephAprendiz-svg/Ghost-kali.git
cd Ghost-kali
sudo bash install.sh
```

Y arranca:

```bash
sudo joseph-trio
```

> 💡 ¿Solo quieres ver qué haría sin tocar tu sistema? Usa el modo seguro:
> ```bash
> sudo joseph-trio --dry-run --health-check
> ```

---

## 🔧 Instalación detallada

### Requisitos

| Requisito | Mínimo | Notas |
|---|---|---|
| **SO** | Kali / Debian / Ubuntu / Arch | Probado principalmente en Kali Linux. |
| **Bash** | 5.0+ | `bash --version` |
| **Privilegios** | `root` (sudo) | Necesario para gestionar interfaces de red y servicios. |
| **Cuenta Mullvad** | Activa | Ghost-Kali **no** vende ni gestiona cuentas; usa la tuya. |
| **Conexión** | Internet | Para descargar dependencias y levantar la cadena. |

**Dependencias requeridas:** `mullvad` · `tor` · `proxychains4` · `curl` · `nc` · `systemctl` · `jq`
**Opcionales (recomendadas):** `torsocks` · `obfs4proxy` · `dnscrypt-proxy` · `macchanger`

### Instalación con el wizard

El instalador es **idempotente** (puedes ejecutarlo varias veces sin romper nada) y guía 11 pasos: disclaimer, dependencias, `ControlPort` de Tor, configuración de proxychains, tema, binarios, librerías, documentación, configuración, autocompletado y un *health check* final.

```bash
sudo bash install.sh          # Wizard interactivo
sudo bash install.sh --yes    # Instalación desatendida (acepta defaults)
```

> 📝 El instalador hace **backup automático** de cualquier configuración previa y registra todo en `/var/log/ghost-kali-install.log`.

### Verificación

```bash
sudo joseph-trio --health-check   # Comprueba dependencias y configuración
sudo joseph-trio --version        # Muestra versión + commit + fecha
```

Un *health check* correcto devuelve código de salida `0`.

---

## 🎮 Uso

### Menú interactivo

```bash
sudo joseph-trio
```

```
  1.  Modo Privacidad           (solo Mullvad)
  2.  Modo Anónimo Total        (Mullvad + Tor + Proxychains)
  3.  Modo Sigilo               (Mullvad + Tor + Bridges + Ofuscación)
  4.  Nueva Identidad Tor
  5.  Rotación Automática
  6.  Dashboard en Vivo
  7.  Test de Seguridad Completo
  8.  Mapa de Conexión
  9.  Panel de Estado Tor
 10.  Auditoría de Seguridad
 11.  Apagar Todo
 12.  Modo Monitor
  S.  Navegador Anónimo
  C.  Configuración
  0.  Salir
```

### Flags de línea de comandos

| Flag | Descripción |
|---|---|
| `--dry-run` | Muestra qué se ejecutaría, sin tocar el sistema. |
| `--non-interactive` | Modo desatendido para scripts y automatización. |
| `--mode <n>` | Arranca directo en un modo (1–3). |
| `--theme <nombre>` | Aplica un tema (`ghost`, `midnight`, `forest`, `matrix`). |
| `--dashboard` | Abre el dashboard en vivo. |
| `--health-check` | Ejecuta el chequeo de salud y sale. |
| `--verbose` / `--quiet` | Ajusta el nivel de salida. |
| `--no-color` / `--no-banner` | Salida plana, ideal para logs y CI. |
| `--version` / `--help` | Información y ayuda. |

### Ejemplos

```bash
# Levantar anonimato total de forma desatendida
sudo joseph-trio --mode 2 --non-interactive

# Dashboard con tema matrix y refresco cada 3 s
sudo joseph-trio --dashboard --theme matrix --dashboard-interval 3

# Auditoría de seguridad sin ejecutar nada (solo simulación)
sudo joseph-trio --mode 2 --dry-run --verbose
```

> 🛑 Pulsa `Ctrl+C` en cualquier momento: Ghost-Kali captura la señal y cierra la cadena de forma ordenada (*graceful shutdown*).

---

## 🎨 Temas visuales

Cada tema define una paleta ANSI truecolor completa (primario, secundario, acento, warning, error, success, *muted*, fondo y texto). Cámbialos en caliente con la tecla `c` del dashboard o con `--theme`.

| Tema | Vibra | Primario | Acento | Uso recomendado |
|---|---|---|---|---|
| 👻 **ghost** *(default)* | Dracula / morado | `#BD93F9` | `#F8F8F2` | Uso diario, agradable en sesiones largas. |
| 🌙 **midnight** | Azul nocturno | `#5B8DEE` | `#E0E0E0` | Entornos oscuros, alto contraste suave. |
| 🌲 **forest** | Terminal retro ámbar/verde | `#00FF41` | `#39FF14` | Estética *hacker* clásica. |
| 🟩 **matrix** | Verde fósforo puro | `#00FF00` | `#00FF41` | Máximo dramatismo, modo kiosk. |

```bash
sudo joseph-trio --theme forest
```

---

## 📊 Comparativa

Ghost-Kali no compite con sistemas operativos completos: es una **capa de orquestación** ligera y nativa de Kali. Esta tabla es honesta sobre dónde encaja cada herramienta.

| | **Ghost-Kali** | **Anonsurf** | **Tails** | **Whonix** |
|---|:---:|:---:|:---:|:---:|
| Tipo | Script orquestador | Script proxy-transparente | SO amnésico en vivo | SO aislado por VM |
| Aislamiento | Proceso / red | Red (sistema) | Sistema completo (amnésico) | VM (gateway + workstation) |
| VPN integrada | ✅ Mullvad | ❌ | ⚠️ Desaconsejada | ⚠️ Desaconsejada por defecto |
| Tor | ✅ | ✅ | ✅ (núcleo) | ✅ (núcleo) |
| Dashboard en vivo | ✅ 7 widgets | ❌ | ❌ | Parcial |
| Funciona sobre tu Kali actual | ✅ | ✅ | ❌ (arranca aparte) | ❌ (requiere VMs) |
| Garantía de aislamiento fuerte | ⚠️ Limitada | ⚠️ Limitada | ✅ Alta | ✅ Muy alta |
| Curva de aprendizaje | Baja | Baja | Media | Alta |

> 🔍 **Nota honesta:** si tu modelo de amenazas incluye adversarios con muchos recursos, **Tails** y **Whonix** ofrecen garantías de aislamiento que un script *no puede* igualar, porque aíslan a nivel de sistema operativo o de máquina virtual. Ghost-Kali prioriza la comodidad y la transparencia sobre Kali; elige la herramienta según tu riesgo real, no según cuál se vea más espectacular.

---

## ❓ FAQ

**1. ¿Combinar VPN + Tor me hace más anónimo automáticamente?**
No necesariamente. El propio Proyecto Tor advierte que añadir una VPN puede ayudar o **perjudicar** según tu escenario. Ghost-Kali te da la herramienta y la documentación para que decidas con criterio; no promete invisibilidad.

**2. ¿Ghost-Kali oculta mi identidad por completo?**
Ninguna herramienta puede prometer eso. La des-anonimización suele venir del *comportamiento* del usuario (iniciar sesión en tu cuenta real, fugas de DNS/WebRTC, metadatos de archivos), no solo de la red. Lee `docs/OPSEC_GUIDE.md`.

**3. ¿Necesito pagar algo?**
Ghost-Kali es gratis y MIT. Necesitas tu propia cuenta de **Mullvad** (de pago); el proyecto no la incluye ni la vende.

**4. ¿Funciona fuera de Kali?**
Está optimizado para Kali, pero el instalador detecta Debian, Ubuntu y Arch. En otras distros puede requerir ajustes manuales.

**5. ¿Por qué Mullvad y no otra VPN?**
Por su política sin registros, pago anónimo y CLI estable que facilita la automatización. Puedes adaptar el proyecto a otra VPN, pero el soporte oficial es para Mullvad.

**6. ¿El `--dry-run` es realmente seguro?**
Sí: imprime los comandos que ejecutaría sin tocar tu red ni tus servicios. Úsalo para auditar el comportamiento antes de ejecutarlo en serio.

**7. ¿Qué pasa con las fugas de DNS y WebRTC?**
El *test de seguridad* (opción 7) comprueba tu IP pública, posibles fugas de DNS y el exit de Tor, y te avisa sobre WebRTC. Las fugas de WebRTC se mitigan en el **navegador**, no en la red: usa Tor Browser.

**8. ¿Puedo usar esto para actividades ilegales?**
No. Ghost-Kali existe para proteger la privacidad legítima. El uso indebido es responsabilidad exclusiva del usuario y va en contra del propósito del proyecto.

**9. ¿Deja rastros en mi sistema?**
Genera logs locales (rotados y configurables) y archivos de configuración. `uninstall.sh` los limpia. No es un sistema amnésico como Tails.

**10. ¿Cómo reporto un fallo de seguridad?**
Sigue el proceso de divulgación responsable de [`SECURITY.md`](SECURITY.md). No abras un issue público para vulnerabilidades.

---

## 🗺️ Roadmap

- **v5.1** — Soporte para múltiples proveedores de VPN; perfiles de configuración por escenario.
- **v5.2** — Integración opcional con `nftables` para *killswitch* a nivel de kernel.
- **v5.3** — Modo monitor con exportación de métricas (Prometheus textfile).
- **v6.0** — Reescritura del dashboard con TUI completa y plugins de comunidad.

> Las prioridades se ajustan según el feedback de la comunidad. ¿Tienes una idea? Abre un *feature request*.

---

## 👥 Contribuidores

Este proyecto es posible gracias a las personas que dedican su tiempo a mejorarlo. 💜

<!-- Reemplaza este bloque con la tabla generada por all-contributors -->
```
( Aún no hay contribuidores externos — ¡podrías ser el primero! )
```

¿Quieres aparecer aquí? Lee [`CONTRIBUTING.md`](CONTRIBUTING.md) y abre tu primer PR.

---

## 💜 Sponsors

Si Ghost-Kali te resulta útil y quieres apoyar su desarrollo y mantenimiento:

[![GitHub Sponsors](https://img.shields.io/badge/GitHub-Sponsors-EA4AAA?style=flat-square&logo=github-sponsors)](https://github.com/sponsors/JosephAprendiz-svg)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-Apóyame-FF5E5B?style=flat-square&logo=ko-fi&logoColor=white)](https://ko-fi.com/)

Cada aporte se reinvierte en auditorías, documentación y mejoras de seguridad.

---

## ⚖️ Disclaimer Legal

> **LEE ESTO ANTES DE USAR GHOST-KALI.**
>
> Ghost-Kali se distribuye **exclusivamente con fines educativos, de auditoría autorizada y de investigación responsable de seguridad**. Es una herramienta **defensiva** de protección de la privacidad.
>
> - El uso de VPN, Tor o herramientas de anonimato puede estar **regulado o restringido** en tu jurisdicción. Es tu responsabilidad conocer y cumplir las leyes aplicables.
> - **No** uses esta herramienta para acceder sin autorización a sistemas, evadir restricciones legítimas, ni para ninguna actividad ilícita.
> - Realiza auditorías de seguridad **únicamente** sobre sistemas para los que tengas permiso explícito y por escrito.
> - El software se ofrece **"tal cual", sin garantías** de ningún tipo. Los autores y contribuidores **no se hacen responsables** del mal uso ni de los daños derivados de su uso.
>
> Al usar Ghost-Kali aceptas estos términos y asumes toda la responsabilidad legal de tus acciones.

> *“Argumentar que no te importa la privacidad porque no tienes nada que ocultar es como decir que no te importa la libertad de expresión porque no tienes nada que decir.”*
> — Edward Snowden

---

## 📜 Licencia

Distribuido bajo la **Licencia MIT**. Consulta [`LICENSE`](LICENSE) para más detalles.

```
Copyright (c) 2026 JosephAprendiz-svg

Se concede permiso, de forma gratuita, a cualquier persona que obtenga
una copia de este software y los archivos de documentación asociados...
```

---

<div align="center">

**Si Ghost-Kali te ha sido útil, déjanos una ⭐ — nos ayuda muchísimo.**

*Hecho con 💜 para la comunidad de la privacidad.*

`#PrivacyIsARight`

</div>
