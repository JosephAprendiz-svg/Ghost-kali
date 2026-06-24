# Guia de Hardening - Ghost-Kali v5.0

**Version:** 5.0.0 | **Fecha:** 2026-06-24

> El hardening es la base de toda operacion. Sin un sistema endurecido, las
> capas de anonimato no bastan. Verificar cada punto antes de operar.

---

## 1. Hardening del Sistema Kali Linux

- Actualizacion completa antes de cada sesion:

  ```bash
  sudo apt update && sudo apt full-upgrade -y
  ```

- Endurecimiento del kernel via sysctl. Crear `/etc/sysctl.d/99-ghost.conf`:

  ```bash
  net.ipv4.ip_forward = 0
  net.ipv4.conf.all.rp_filter = 1
  net.ipv4.conf.default.rp_filter = 1
  net.ipv4.tcp_syncookies = 1
  net.ipv4.conf.all.accept_redirects = 0
  net.ipv4.conf.all.send_redirects = 0
  net.ipv4.conf.all.accept_source_route = 0
  kernel.kptr_restrict = 2
  kernel.dmesg_restrict = 1
  ```

  Aplicar: `sudo sysctl --system`.

- Deshabilitar servicios innecesarios: `systemctl list-unit-files --state=enabled`
  y desactivar lo que no se use.
- Remover paquetes no esenciales para reducir la superficie de ataque.
- Configurar `umask 077` en `/etc/profile` para que los archivos nuevos sean
  privados por defecto.
- Deshabilitar cuentas de invitado y accesos remotos no usados (SSH si no se
  requiere).

## 2. Configuracion Segura de Tor

Aplicar en `/etc/tor/torrc` (Ghost-Kali ofrece comandos para esto):

- `SocksPort 127.0.0.1:9050` - solo localhost.
- `ControlPort 127.0.0.1:9051` - solo localhost.
- `CookieAuthentication 1`.
- `SafeSocks 1`, `TestSocks 1`, `WarnUnsafeSocks 1`.
- `StrictNodes 1`.
- `EnforceDistinctSubnets 1`.
- Puentes obfs4 para entornos que censuran Tor.

Comandos relevantes:

```bash
torctl_set_socks_port /etc/tor/torrc 127.0.0.1 9050
torctl_set_control_port /etc/tor/torrc 127.0.0.1 9051
torctl_enable_bridges /etc/tor/torrc     # habilita el mecanismo obfs4
torctl_recommend_config                  # imprime la plantilla recomendada
torctl_isolate_streams /etc/tor/torrc    # aislamiento de streams
```

## 3. Configuracion Segura de Proxychains

- `strict_chain` o `dynamic_chain` segun la necesidad operativa.
- `proxy_dns` obligatorio para evitar fugas DNS.
- `remote_dns_subnet 224`.
- Timeouts conservadores (`tcp_read_time_out`, `tcp_connect_time_out`).
- Sin proxies HTTP en claro.

Comandos relevantes:

```bash
proxyctl_set_tor_defaults     # cadena por defecto hacia Tor (socks5 127.0.0.1:9050)
proxyctl_enable_proxy_dns     # activa proxy_dns
proxyctl_set_mode strict_chain
proxyctl_reset_to_defaults    # restablece la plantilla segura
proxyctl_show_config          # muestra la config saneada (sin credenciales)
```

## 4. Configuracion Segura de Mullvad VPN

- VPN siempre activa (always-on) con kill switch.
- DNS de Mullvad exclusivamente.
- Sin IPv6 dentro del tunel.
- WireGuard preferido sobre OpenVPN.
- Verificar ausencia de fugas DNS tras conectar.

```bash
vpnctl_status     # estado del tunel y kill switch
vpnctl_verify     # verificacion de no fugas
```

## 5. Deshabilitar IPv6

Tor enruta IPv4; el tráfico IPv6 puede escapar de la cascada.

```bash
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
```

Hacerlo persistente en `/etc/sysctl.d/99-ghost.conf` y verificar:

```bash
cat /proc/net/if_inet6     # no debe haber direcciones de scope global (00)
```

## 6. Firewall Defensivo

Politica restrictiva por defecto:

- `INPUT`: DROP.
- `FORWARD`: DROP.
- `OUTPUT`: ACCEPT solo lo que pase por loopback o por el tunel VPN.

Principios:

- Permitir unicamente loopback y la interfaz del tunel VPN.
- Bloquear todo tráfico que no pase por la VPN (proteccion contra fuga si la
  VPN cae).
- Reglas explicitas anti-fuga DNS e IPv6.

El operador debe revisar el script de firewall antes de aplicarlo y conservar
una copia de las reglas previas para poder revertir.

## 7. Timezone y NTP

- Configurar el timezone en UTC para no filtrar la ubicacion por la hora local:

  ```bash
  sudo timedatectl set-timezone UTC
  ```

- Sincronizar NTP antes de conectar la VPN. Una deriva horaria notable facilita
  la correlacion temporal.

## 8. Logs y Auditoria

- Reducir los logs persistentes durante operaciones.
- Usar tmpfs para los logs de sesion cuando aplique.
- Limpiar al cerrar la sesion: revisar `journald`, `syslog` y el historial de
  shell.

  ```bash
  history -c
  cat /dev/null > ~/.bash_history
  sudo journalctl --rotate && sudo journalctl --vacuum-time=1s
  ```

- Verificar que no queden rastros relevantes antes de finalizar.

## 9. Actualizaciones

- Verificar la integridad de los paquetes con firmas GPG del repositorio.
- Actualizar antes de cada sesion operativa, nunca durante.
- No introducir software de terceros sin revisarlo.

---

> Hardening es la base de toda operacion. Sin hardening, las capas de anonimato
> son insuficientes. El operador debe verificar cada punto antes de iniciar.
