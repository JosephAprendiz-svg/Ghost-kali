# Ghost-Kali

Operational anonymity toolkit for Kali Linux — Mullvad + Tor + Proxychains.

Features
- Easy menu to start Mullvad (WireGuard), Tor and Proxychains.
- Kill-switch management.
- Tor identity rotation (manual & timed).
- Live dashboard (IP, country, Mullvad status).
- Security checks (IP + DNS leak testing).

Install (local)
1. Copia `joseph-trio` a `/usr/local/bin` y dale permisos:
   sudo mv joseph-trio /usr/local/bin/joseph-trio
   sudo chmod +x /usr/local/bin/joseph-trio

Usage
- sudo joseph-trio

Security & privacy
- Do NOT include your Mullvad account files, WireGuard confs, or private keys in this repo.
- The project includes example config only.

License
MIT — see LICENSE.
