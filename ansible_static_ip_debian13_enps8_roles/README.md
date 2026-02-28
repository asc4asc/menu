
# Ansible Role-basierte Lösung (mit `rules/` Verzeichnis)

Dieses Paket liefert eine **wiederverwendbare Ansible-Role** im Verzeichnis `rules/`. 
Das Playbook `site.yml` bindet die Role `static_ip` ein und setzt auf Debian 13
für das Interface `enps8` die statische IP **192.168.111.1/24** (standardmäßig **ohne Gateway**).

## Struktur
```
./ansible_static_ip_debian13_enps8_roles/
├─ ansible.cfg                  # Setzt roles_path auf ./rules
├─ site.yml                     # Playbook, das die Role anwendet
├─ run.sh                       # Wrapper: ansible-playbook -c=local --inventory=localhost, "$@" -v site.yml
└─ rules/
   └─ static_ip/
      ├─ defaults/
      │  └─ main.yml           # Standardvariablen (iface, address, prefix, netmask, DNS, Gateway)
      ├─ handlers/
      │  └─ main.yml           # ifupdown-Reload & NM-Reload
      ├─ tasks/
      │  └─ main.yml           # Erkennung NM vs. ifupdown, Anwendung
      └─ templates/
         └─ interfaces_static.j2
```

## Ausführen (Standard ohne Gateway/DNS)
```bash
./run.sh
```

## Mit Gateway/DNS (Beispiel)
```bash
./run.sh -e gateway4=192.168.111.254 -e dns_servers='["1.1.1.1","9.9.9.9"]'          -e nm_gateway=192.168.111.254 -e nm_dns='["1.1.1.1","9.9.9.9"]'
```

## Variablen (Defaults)
- `iface`: `enps8`
- `address`: `192.168.111.1`
- `prefix`: `24`
- `netmask`: `255.255.255.0`
- `gateway4`: `""` (leer ⇢ kein Default-Gateway)
- `dns_servers`: `[]`
- `nm_con_name`: `static-{{ iface }}`
- `nm_gateway`: `""`
- `nm_dns`: `[]`

> **Hinweis:** Für die NetworkManager-Variante benötigst du die Collection `community.general`:
> ```bash
> ansible-galaxy collection install community.general
> ```

## Verifikation
```bash
ip addr show enps8
ip route
resolvectl status 2>/dev/null || cat /etc/resolv.conf
systemctl is-active NetworkManager || true
nmcli dev show enps8 2>/dev/null || true
```

## Wiederverwendung
Du kannst das gesamte Verzeichnis in andere Projekte kopieren. Durch `ansible.cfg` ist `roles_path` bereits auf `./rules` gesetzt. Alternativ kannst du die Role `rules/static_ip` auch in bestehende Repositories unter `roles/` übernehmen.
