
# Ansible Role: NAT (MASQUERADE) auf Interface

Diese Rolle aktiviert IPv4-Forwarding und setzt **MASQUERADE** für den ausgehenden Verkehr
über ein definiertes Interface. Bevorzugt wird **nftables** (Debian 13 Standard),
**iptables** dient als Fallback.

## Dateien
- `site.yml` – ruft die Rolle auf
- `ansible.cfg` – setzt `roles_path=./rules`
- `run.sh` – Wrapper mit deinem Aufrufschema
- `rules/masq/` – die Rolle

## Standardwerte (`rules/masq/defaults/main.yml`)
```yaml
wan_iface: "enps8"                   # Egress-Interface
internal_ipv4_cidr: "192.168.111.0/24"  # internes Netz hinter dem Interface
enable_ipv4_forward: true
enable_ipv6: false
internal_ipv6_cidr: ""
prefer_nftables: true
nft_main_conf: "/etc/nftables.conf"
nft_drop_dir: "/etc/nftables.d"
nft_snippet: "10-masq-{{ wan_iface }}.nft"
```

## Ausführung
```bash
./run.sh
# oder mit Variablen
./run.sh -e wan_iface=enps8 -e internal_ipv4_cidr=192.168.111.0/24
```

## Was die Rolle macht (präzise)
- Aktiviert `net.ipv4.ip_forward=1` (optional IPv6)
- **nftables**:
  - legt `{{ nft_drop_dir }}` an
  - sorgt dafür, dass `{{ nft_main_conf }}` `include "{{ nft_drop_dir }}/*.nft"` enthält
  - rendert `{{ nft_drop_dir }}/{{ nft_snippet }}` mit MASQUERADE-Regel
  - lädt die Konfiguration (`nft -f {{ nft_main_conf }}`) und aktiviert den Dienst
- **iptables** (Fallback):
  - fügt idempotent eine MASQUERADE-Regel hinzu
  - speichert Regeln via `netfilter-persistent` (falls vorhanden)

## Verifikation
```bash
sysctl net.ipv4.ip_forward
nft list ruleset | sed -n '/table ip nat/,/}/p'  # falls nftables benutzt
iptables -t nat -S | grep MASQUERADE || true     # falls iptables Fallback
ip r
```

## Hinweise
- Wenn dein internes Netz **nicht** eingeschränkt werden soll, setze `internal_ipv4_cidr` auf leeren String:
  ```bash
  ./run.sh -e internal_ipv4_cidr=""
  ```
- Stelle sicher, dass die **Firewall-Filterregeln** Forwarding nicht blockieren. Diese Rolle kümmert sich nur um **NAT** und **IP-Forwarding**, nicht um Filter-Policies.
