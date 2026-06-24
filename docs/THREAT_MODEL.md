# Modelo de Amenazas - Ghost-Kali v5.0

**Version:** 5.0.0 | **Fecha:** 2026-06-24

> El anonimato absoluto no existe. Este documento describe que protege la
> cascada VPN + Tor + Proxychains, que no protege, y contra quien.

---

## 1. Actores de Amenaza

| Actor | Capacidad | Motivacion | Nivel de Riesgo |
|-------|-----------|------------|-----------------|
| ISP | Tráfico, DNS, DPI, correlacion temporal | Comercial, legal | ALTO |
| Adversario local (LAN) | ARP spoofing, sniffing, DHCP malicioso | Variada | MEDIO |
| Sitios web destino | Fingerprinting, cookies, JavaScript | Comercial, forense | MEDIO |
| Agencias estatales | Correlacion global, analisis de tráfico, nodos Tor | Inteligencia | CRITICO |
| Nodos Tor maliciosos | Captura de tráfico, correlacion entrada/salida | Inteligencia, criminal | ALTO |
| Proveedor VPN | Tráfico, DNS, logs, correlacion temporal | Comercial, legal | ALTO |
| Malware local | Keylogging, captura de pantalla, exfiltracion | Criminal | CRITICO |

## 2. Superficies de Ataque del Toolkit

- **Archivos de configuracion.** Permisos e integridad de `torrc`,
  `proxychains.conf` y `scope`.
- **Dependencias.** Binarios del sistema y librerias de las que depende el
  toolkit.
- **Memoria.** Claves, identificadores de circuito y buffers.
- **Red.** Handshake TCP, resolucion DNS y patrones de timing.
- **Procesos.** Arbol de procesos y argumentos de linea de comandos visibles.
- **Logs.** Journal de systemd, historial de shell y archivos temporales.

## 3. Supuestos de Confianza

El modelo asume lo siguiente. Si algun supuesto falla, las garantias se
debilitan:

- El operador tiene control fisico del equipo.
- El sistema base (Kali) no esta comprometido.
- Mullvad VPN no colabora con el adversario relevante.
- La red Tor no esta comprometida de forma global.
- El hardware no tiene puertas traseras a nivel de firmware.
- El operador sigue los procedimientos de `OPSEC_GUIDE.md`.

## 4. Riesgos Mitigados por Cada Capa

| Capa | Riesgos Mitigados |
|------|-------------------|
| **VPN (Mullvad)** | El ISP no ve el destino final. La IP real queda oculta ante el primer salto de Tor. |
| **Tor** | La IP real queda oculta ante el destino. El tráfico se mezcla con el de muchos usuarios. |
| **Proxychains** | Las aplicaciones no-Tor se enrutan por Tor. El DNS se resuelve por proxy. |

## 5. Riesgos NO Mitigados

La cascada no protege contra:

- Compromiso del endpoint (malware, keylogger, BIOS/UEFI).
- Correlacion temporal de tráfico (ataque de confirmacion).
- Fingerprinting de navegador y sistema operativo.
- Fugas a nivel de aplicacion (WebRTC, DNS del sistema, STUN, IPv6).
- Analisis de tráfico extremo a extremo por un adversario global.
- Compromiso simultaneo del nodo de entrada y del nodo de salida de Tor.
- Error humano (autenticarse con identidad civil, descargar archivos).
- Entorno fisico comprometido (camaras, microfonos, observacion directa).

## 6. Limitaciones del Anonimato

- El anonimato absoluto no existe. Es un espectro de riesgo, no un estado
  binario.
- Cada capa adicional reduce la superficie pero añade complejidad y puntos de
  fallo.
- La correlacion temporal es el punto debil de cualquier sistema de baja
  latencia.
- El eslabon mas debil es, casi siempre, el operador.

## 7. Escenarios de Uso Legitimo

- Auditor de seguridad realizando un pentest autorizado por escrito.
- Investigador analizando infraestructura maliciosa desde un entorno aislado.
- Periodista o activista operando en un entorno hostil.
- Denunciante protegiendo su identidad.
- Ciudadano ejerciendo su derecho a la privacidad.
- Equipo de red team emulando a un adversario contra infraestructura propia o
  explicitamente autorizada.

## 8. Como Usar Este Documento

Revisar este modelo al inicio de cada compromiso. Confirmar que los supuestos
de confianza se sostienen para el contexto concreto y que los riesgos no
mitigados son aceptables o se compensan con controles externos.

---

> Este modelo de amenazas es un documento vivo. Debe actualizarse conforme
> evolucionen las capacidades de los adversarios y las contramedidas
> disponibles.
