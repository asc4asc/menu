# Vollständige Ansible-Site: dnsmasq als DHCP-Server

Diese Site installiert und konfiguriert **dnsmasq** als DHCP-Server für 192.168.111.0/24.

## Schnellstart
```bash
ansible-galaxy collection install -r requirements.yml
ansible-playbook -i inventory playbook.yml
```

## Struktur
- `inventory` – Hosts
- `playbook.yml` – Playbook
- `requirements.yml` – benötigte Collections
- `group_vars/all/` – globale Variablen (optional)
- `host_vars/` – host-spezifische Variablen
- `roles/dhcp_dnsmasq/` – komplette Role

## Standard-Parameter
- Interface: `eth0`
- Range: `192.168.111.100-192.168.111.200`
- Gateway/DNS: `192.168.111.1`
- Lease: `12h`
