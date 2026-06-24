# Guia de Seguridad Operacional (OPSEC)

**Proyecto:** Ghost-Kali v5.0
**Version:** 5.0.0
**Fecha:** 2026-06-24
**Clasificacion:** Documento operativo - Uso autorizado

> Esta guia describe practicas defensivas de privacidad y anonimato para el
> tráfico propio del operador. Todas las tecnicas operan sobre el sistema
> propio. No habilitan acciones contra sistemas de terceros.

---

## 1. Que es OPSEC

OPSEC (Operations Security) es el proceso de identificar la informacion
critica y protegerla de la observacion del adversario. No es una herramienta:
es una disciplina. Las herramientas de Ghost-Kali reducen la superficie de
exposicion, pero el anonimato lo sostiene el comportamiento del operador.

El ciclo OPSEC tiene cinco pasos:

1. **Identificar la informacion critica.** Que dato, si se filtra, rompe el
   anonimato (IP real, identidad civil, ubicacion, patrones horarios).
2. **Analizar amenazas.** Quien quiere ese dato y con que capacidad (ver
   `THREAT_MODEL.md`).
3. **Analizar vulnerabilidades.** Por donde puede filtrarse (DNS, WebRTC,
   IPv6, metadatos, correlacion temporal).
4. **Evaluar el riesgo.** Probabilidad por impacto. Priorizar lo critico.
5. **Aplicar contramedidas.** Configurar, verificar y operar conforme a esta
   guia.

El ciclo es continuo. Cada sesion lo reinicia.

## 2. Principios de Anonimato Operacional

- **Separacion de identidades.** Nunca mezclar la identidad civil con la
  identidad operativa. Cuentas, correos, dispositivos y horarios distintos.
- **Compartimentacion.** Una identidad por contexto operativo. No reutilizar
  circuitos ni sesiones entre contextos.
- **Minimizacion de huella.** Menos datos expuestos significa menos superficie
  de correlacion. Desactivar lo que no se usa.
- **Temporalidad.** Sesiones cortas. Rotacion de identidad frecuente. La
  exposicion crece con el tiempo de sesion.
- **Cero confianza.** Asumir que cualquier capa puede fallar. Verificar todas
  antes de operar, no solo una.

## 3. Uso Seguro de la Cascada VPN + Tor + Proxychains

El orden de la cascada importa. La configuracion correcta es:

1. **VPN (Mullvad) primero.** Oculta el destino al ISP y la IP real al primer
   salto de Tor.
2. **Tor segundo.** Oculta la IP real al destino y mezcla el tráfico.
3. **Proxychains tercero.** Enruta aplicaciones que no hablan SOCKS de forma
   nativa a traves de Tor, con DNS por proxy.

Verificar cada capa antes de operar:

```bash
vpnctl_status            # VPN activa, sin fugas
torctl_status_panel      # Servicio Tor, SOCKS y ControlPort
torctl_is_exit_reachable # Egreso confirmado por Tor
proxyctl_chain_status    # Modo de cadena y proxy_dns
proxyctl_test_dns        # Resolucion DNS a traves de la cadena
```

Que hace cada capa y que NO hace:

| Capa | Protege | No protege |
|------|---------|------------|
| **VPN** | IP real ante el ISP y el destino directo | Contra el propio proveedor VPN |
| **Tor** | IP real ante el destino; mezcla tráfico | Contra correlacion temporal global |
| **Proxychains** | Enruta apps no-Tor; DNS por proxy | Contra fugas a nivel de aplicacion |

## 4. Errores que Destruyen el Anonimato

- Autenticarse en servicios con la identidad civil a traves de Tor.
- Descargar y abrir archivos (PDF, DOC, multimedia) durante la sesion. Pueden
  llamar a casa fuera de Tor.
- Ejecutar JavaScript en el navegador sobre Tor sin protecciones.
- Reutilizar una misma sesion para multiples contextos operativos.
- Habilitar servicios que filtran la IP real (WebRTC, DNS del sistema, STUN).
- No verificar fugas antes de operar.
- Usar una resolucion de pantalla o un fingerprint de navegador unicos.
- Operar desde una red corporativa o monitoreada.

## 5. Verificacion de Fugas

Antes de cada operacion, confirmar que no hay fugas:

- **Fuga DNS.** Verificar con `torctl_detect_leaks` y `proxyctl_test_dns`. El
  DNS debe resolver a traves de la cadena, nunca por el resolver del sistema.
- **Fuga WebRTC.** En navegador, deshabilitar WebRTC. El shell no puede
  mitigarla; es responsabilidad de la aplicacion.
- **Fuga IPv6.** Deshabilitar IPv6 a nivel de sistema (ver `HARDENING.md`).
  Tor enruta IPv4; el tráfico IPv6 puede escapar.
- **Fuga de tiempo.** Sincronizar NTP en UTC. La deriva horaria y los patrones
  temporales permiten correlacion.
- **Fuga HTTP.** Vigilar cabeceras como `X-Forwarded-For` y `Via` que revelan
  saltos intermedios.

## 6. Checklist Pre-Operacional

| #  | Verificacion | Comando | Estado |
|----|--------------|---------|--------|
| 1  | VPN activa y sin fugas | `vpnctl_status` | [ ] |
| 2  | Servicio Tor operativo | `torctl_status_panel` | [ ] |
| 3  | SOCKS de Tor responde | `torctl_check_socks` | [ ] |
| 4  | ControlPort responde | `torctl_check_control` | [ ] |
| 5  | Egreso confirmado por Tor | `torctl_is_exit_reachable` | [ ] |
| 6  | Sin fugas DNS/IPv6 | `torctl_detect_leaks` | [ ] |
| 7  | Modo de cadena correcto | `proxyctl_chain_status` | [ ] |
| 8  | proxy_dns activo | `proxyctl_test_dns` | [ ] |
| 9  | Conectividad de la cadena | `proxyctl_test_connection` | [ ] |
| 10 | IPv6 deshabilitado | `cat /proc/net/if_inet6` | [ ] |
| 11 | Firewall anti-fuga activo | (script de firewall) | [ ] |
| 12 | Timezone en UTC | `timedatectl` | [ ] |
| 13 | NTP sincronizado | `timedatectl show` | [ ] |
| 14 | Aplicaciones no esenciales cerradas | `ps aux` | [ ] |
| 15 | Sin logs persistentes de sesion | (ver `HARDENING.md`) | [ ] |
| 16 | Identidad operativa separada de la civil | (revision manual) | [ ] |

No iniciar operacion con cualquier item en `[ ]`.

## 7. Comportamiento Operativo

- No usar redes sociales, correo personal ni servicios vinculados a la
  identidad civil durante la operacion.
- No descargar archivos ni abrir adjuntos.
- No instalar software durante la sesion operativa.
- Cerrar todas las aplicaciones no esenciales antes de iniciar.
- Trabajar con teclado y pantalla limpios (sin reflejos, sin keyloggers).
- Considerar el entorno fisico: camaras, microfonos y testigos.

## 8. Cierre de Sesion Operativa

1. Cerrar todas las aplicaciones.
2. Regenerar el circuito Tor: `torctl_burn_circuit`.
3. Desconectar la VPN.
4. Limpiar los logs de sesion (ver `HARDENING.md`, seccion 8).
5. Verificar que no queden procesos residuales: `ps aux`.

---

> Esta guia es un documento operativo para profesionales de seguridad y
> privacidad. El operador asume la responsabilidad total por el uso de estas
> tecnicas y por el cumplimiento de la ley aplicable en su jurisdiccion.
