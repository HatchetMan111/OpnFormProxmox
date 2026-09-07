# OpnForm auf Proxmox VE (LXC, Community-Scripts-Stil)

**OpnForm** – Open-Source Form Builder (Typeform-Alternative).
Stack: **Laravel-API + Nuxt-Client + PostgreSQL 16 + Redis 7 + Nginx-Ingress**,
deployt als offizieller Docker-Compose-Stack in einem LXC-Container.
Läuft vollständig lokal, keine Cloud nötig.

## Installation (Einzeiler, auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpnFormProxmox/main/install/opnform.sh)"
```

Mit Debug-Log (bei Fehlern immer diese Ausgabe posten):

```bash
DEBUG=1 bash -x -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpnFormProxmox/main/install/opnform.sh)" 2>&1 | tee /tmp/opnform-install-debug.log
```

## Was passiert

1. Host-Script (`install/opnform.sh`) erstellt LXC (Default: **2 vCPU, 4 GB RAM, 12 GB Disk**,
   Debian 12, `vmbr0`, DHCP, `onboot=1`, `nesting=1` – nötig für Docker im LXC).
   Bestehende CT-ID wird idempotent wiederverwendet (kein Neuaufbau).
2. Guest-Installer (`install/opnform-install.sh`) installiert Docker, lädt das offizielle
   `docker-compose.yml` von OpnForm/OpnForm, erzeugt `api/.env` + `client/.env` mit frischen
   Secrets, startet den Stack und richtet `opnform.service` (systemd, `enable`) ein.
3. Selbst-Verifikation: `systemctl is-active`, HTTP-Check auf `localhost:80`, finale URL-Ausgabe.

Ergebnis: Web UI unter **`http://[LXC-IP]:80`**.

> Hinweis: 1–2 GB RAM / 4–8 GB Disk reichen für diesen Stack **nicht**
> (Postgres + Redis + Node brauchen min. ~4 GB RAM, ~12 GB Disk).
> Für volle Isolation statt LXC geht auch eine VM – gleiche Compose-Schritte,
> aber mit mehr Overhead; LXC + Docker ist der empfohlene Default.

## Konfiguration (Variablen oben in `install/opnform.sh`, per Env überschreibbar)

| Variable | Default | Bedeutung |
|---|---|---|
| `CTID` | auto (`pvesh nextid`) | Container-ID |
| `HOSTNAME` | `opnform` | Hostname |
| `CPU` / `RAM` / `DISK` | `2` / `4096` / `12` | vCPU / MB RAM / GB Disk |
| `STORAGE` / `TEMPLATE_STORAGE` | `local-lvm` / `local` | Storages |
| `BRIDGE` / `IP_MODE` | `vmbr0` / `dhcp` | Netzwerk (`IP_MODE="192.168.1.50/24"` + `GATEWAY=…` für statisch) |
| `WEB_PORT` | `80` | Web-UI-Port |
| `OVERWRITE` | `0` | `1` = Container neu erstellen |
| `DEBUG` | `0` | `1` = `set -x` Trace |

Beispiel statische IP:

```bash
IP_MODE="192.168.1.50/24" GATEWAY="192.168.1.1" bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpnFormProxmox/main/install/opnform.sh)"
```

## Update

Script erneut laufen lassen (idempotent: `pull` + `up -d` + `migrate`, Secrets bleiben),
oder im LXC:

```bash
bash /usr/local/bin/opnform-install.sh
```

## Reboot-Test

```bash
pct reboot <CTID> && sleep 60 && curl -s -o /dev/null -w '%{http_code}\n' http://<LXC-IP>:80/
pct exec <CTID> -- systemctl is-active opnform docker
```

Erwartet: `200` (oder `302`) + `active` / `active`.

## Deinstallation

```bash
pct stop <CTID> && pct destroy <CTID>
```

## Struktur

```text
install/opnform.sh         # Host-Installer (Einzeiler-Einstieg, standalone)
install/opnform-install.sh # Guest-Installer (läuft im LXC, idempotent)
ct/opnform.sh              # optionale community-scripts/core-Variante
systemd/opnform.service    # Referenzkopie der Unit
README.md
```

Upstream: https://github.com/OpnForm/OpnForm · Docs: https://docs.opnform.com/deployment
