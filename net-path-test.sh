#!/usr/bin/env bash
# ns-ping-f-10s.sh
# Minimal, clear 10-second external path flood test using two chosen interfaces.
# - Forces interfaces DOWN in the root namespace automatically.
# - Moves IF1 to ns 'src' and IF2 to ns 'dst'.
# - Assigns IPs, sets MTU, brings links UP.
# - Verifies carrier/operstate and prints link stats.
# - Runs an unambiguous 10-second flood: ping -f -w 10 (exact command echoed).
# - Shows TX/RX packet deltas to prove traffic actually flowed.
# - Cleanup restores interfaces to root namespace (auto by default).
#
# Requirements: bash, iproute2 (ip), ping, root privileges.

set -euo pipefail

# ---------- Defaults ----------
NS_SRC="src"
NS_DST="dst"

SRC_IF=""
DST_IF=""

IP_SRC="10.10.10.1/30"   # point-to-point
IP_DST="10.10.10.2/30"

MTU="1500"
PAYLOAD="56"             # ping -s payload
QUIET="0"
DO_CLEANUP="0"
KEEP_AFTER="0"           # 1 = keep namespaces, skip auto-cleanup
STATE_FILE="/tmp/ns-ping-f-10s.state"

PING_BIN="${PING_BIN:-ping}"

usage() {
  cat <<'EOF'
ns-ping-f-10s.sh - Clear 10-second ping flood test between two selected interfaces (no bridges, no veth)

Usage:
  sudo ./ns-ping-f-10s.sh --src-if IF1 --dst-if IF2 [options]
  sudo ./ns-ping-f-10s.sh --cleanup

Required:
  --src-if IFNAME          Interface used as source endpoint (currently in root ns)
  --dst-if IFNAME          Interface used as destination endpoint (currently in root ns)

Options:
  -s, --src-ns NAME        Source namespace name                      (default: src)
  -d, --dst-ns NAME        Destination namespace name                 (default: dst)
  --src-ip CIDR            Source IP (e.g., 10.10.10.1/30)            (default: 10.10.10.1/30)
  --dst-ip CIDR            Destination IP (e.g., 10.10.10.2/30)       (default: 10.10.10.2/30)
  --mtu BYTES              MTU for both interfaces                    (default: 1500)
  -S, --size BYTES         Ping payload size for flood (ping -s)      (default: 56)
  --keep                   Keep namespaces after test (no auto-cleanup)
  -q, --quiet              Reduce verbosity

  --cleanup                Move interfaces back to root ns, delete namespaces
  -h, --help, -?           Show help and exit

Behavior:
  - The script will automatically force IF1 and IF2 DOWN in root ns before moving.
  - Flood duration: fixed 10 seconds -> ping -f -w 10
  - Warm-up: 1 normal ping to trigger ARP/neighbor resolution before flood.
  - Prints link status and TX/RX packet deltas to prove traffic.

Examples:
  sudo ./ns-ping-f-10s.sh --src-if enp1s0 --dst-if enp2s0 \
       --src-ip 192.0.2.1/30 --dst-ip 192.0.2.2/30 --mtu 1500 -S 1200

  # Keep namespaces for inspection, then cleanup:
  sudo ./ns-ping-f-10s.sh --src-if enp1s0 --dst-if enp2s0 --keep
  sudo ./ns-ping-f-10s.sh --cleanup
EOF
}

log() { [ "$QUIET" = "1" ] || echo "[*] $*"; }
err() { echo "[!] $*" >&2; }

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "Root privileges are required. Run with sudo."
    exit 1
  fi
}

ns_exists() { ip netns list | awk '{print $1}' | grep -qx -- "$1"; }

# Force an interface DOWN in the root namespace; flush IPs to avoid conflicts
force_root_if_down() {
  local ifname="$1"
  ip link show "$ifname" >/dev/null 2>&1 || { err "Interface '$ifname' not found in root namespace."; exit 1; }
  # Best-effort: ensure it is in root ns (if it were inside a ns, 'ip link show' would fail here)
  ip addr flush dev "$ifname" || true
  ip link set dev "$ifname" down
}

save_state() {
  {
    echo "NS_SRC=$NS_SRC"
    echo "NS_DST=$NS_DST"
    echo "SRC_IF=$SRC_IF"
    echo "DST_IF=$DST_IF"
  } > "$STATE_FILE"
}

load_state() {
  [ -f "$STATE_FILE" ] || { err "State file not found: $STATE_FILE (nothing to cleanup?)"; exit 1; }
  # shellcheck disable=SC1090
  . "$STATE_FILE"
}

# Read simple counters (packets) from sysfs, inside a namespace
read_pkts() {
  local ns="$1" ifn="$2" dir="$3" # dir = rx|tx
  ip netns exec "$ns" cat "/sys/class/net/$ifn/statistics/${dir}_packets" 2>/dev/null || echo 0
}

link_status() {
  # Returns "UP" if operstate=UP and carrier=1 (or LOWER_UP present); else "DOWN"
  local ns="$1" ifn="$2"
  local oper carrier
  oper=$(ip -n "$ns" -o link show "$ifn" | awk -F'state ' '{print $2}' | awk '{print $1}' | tr -d ',')
  if ip netns exec "$ns" test -r "/sys/class/net/$ifn/carrier"; then
    carrier=$(ip netns exec "$ns" cat "/sys/class/net/$ifn/carrier" 2>/dev/null || echo 0)
    if [[ "$oper" == "UP" && "$carrier" == "1" ]]; then echo "UP"; return 0; fi
  else
    if ip -n "$ns" -br link show dev "$ifn" | grep -q "LOWER_UP"; then echo "UP"; return 0; fi
  fi
  echo "DOWN"
}

create_topology() {
  if [ -z "$SRC_IF" ] || [ -z "$DST_IF" ]; then
    err "Both --src-if and --dst-if are required."
    exit 2
  fi

  log "Forcing interfaces DOWN in root namespace (prevent stray traffic)"
  force_root_if_down "$SRC_IF"
  force_root_if_down "$DST_IF"

  log "Creating namespaces: $NS_SRC, $NS_DST"
  ns_exists "$NS_SRC" || ip netns add "$NS_SRC"
  ns_exists "$NS_DST" || ip netns add "$NS_DST"
  ip -n "$NS_SRC" link set lo up
  ip -n "$NS_DST" link set lo up

  log "Moving interfaces into namespaces"
  ip link set "$SRC_IF" netns "$NS_SRC"
  ip link set "$DST_IF" netns "$NS_DST"

  ip -n "$NS_SRC" link set "$SRC_IF" mtu "$MTU" up
  ip -n "$NS_DST" link set "$DST_IF" mtu "$MTU" up

  ip -n "$NS_SRC" addr add "$IP_SRC" dev "$SRC_IF" || true
  ip -n "$NS_DST" addr add "$IP_DST" dev "$DST_IF" || true

  save_state
}

print_topology() {
  log "=== Topology ==="
  for ns in "$NS_SRC" "$NS_DST"; do
    if ns_exists "$ns"; then
      echo "[$ns] links:"
      ip -n "$ns" -br link
      echo "[$ns] addr:"
      ip -n "$ns" -br addr
      echo
    fi
  done
}

warmup_and_check() {
  local dst_ip
  dst_ip=$(ip -n "$NS_DST" -br addr show dev "$DST_IF" | awk '{print $3}' | cut -d/ -f1)
  if [ -z "$dst_ip" ]; then
    err "Destination IP is empty on $NS_DST/$DST_IF."
    exit 1
  fi

  local sstat dstat
  sstat=$(link_status "$NS_SRC" "$SRC_IF")
  dstat=$(link_status "$NS_DST" "$DST_IF")
  echo "Link status: src $NS_SRC/$SRC_IF = $sstat | dst $NS_DST/$DST_IF = $dstat"
  if [ "$sstat" != "UP" ] || [ "$dstat" != "UP" ]; then
    err "Network down. Check cabling/switch/negotiation and try again."
    exit 1
  fi

  echo "Warm-up ping (1 probe to build neighbor cache):"
  ip netns exec "$NS_SRC" $PING_BIN -c 1 "$dst_ip" || {
    err "Warm-up ping failed. Verify L2/L3 connectivity and IPs."
    exit 1
  }
}

run_flood_10s() {
  local dst_ip
  dst_ip=$(ip -n "$NS_DST" -br addr show dev "$DST_IF" | awk '{print $3}' | cut -d/ -f1)

  echo
  echo "=== 10-second ping flood (src -> dst) ==="
  echo "Command: ping -f -s $PAYLOAD -w 10 $dst_ip"

  # Counters before
  local tx_before rx_before
  tx_before=$(read_pkts "$NS_SRC" "$SRC_IF" tx)
  rx_before=$(read_pkts "$NS_DST" "$DST_IF" rx)

  # Flood 10s
  ip netns exec "$NS_SRC" $PING_BIN -f -s "$PAYLOAD" -w 10 "$dst_ip"

  # Counters after
  local tx_after rx_after
  tx_after=$(read_pkts "$NS_SRC" "$SRC_IF" tx)
  rx_after=$(read_pkts "$NS_DST" "$DST_IF" rx)

  # Deltas
  local tx_delta=$((tx_after - tx_before))
  local rx_delta=$((rx_after - rx_before))

  echo
  echo "=== Link packet counters (delta over 10s) ==="
  echo "TX src $NS_SRC/$SRC_IF: $tx_delta packets"
  echo "RX dst $NS_DST/$DST_IF: $rx_delta packets"
  if [ "$tx_delta" -gt 0 ] && [ "$rx_delta" -gt 0 ]; then
    echo "Result: Traffic observed on both ends. Flood ran for 10 seconds."
  else
    echo "Result: No packet movement detected. Investigate cabling/switch/MTU/filtering."
  fi
}

cleanup() {
  log "Cleanup: restore interfaces to root namespace and delete namespaces"
  if [ -f "$STATE_FILE" ]; then
    load_state || true
    if ns_exists "$NS_SRC" && ip -n "$NS_SRC" link show "$SRC_IF" >/dev/null 2>&1; then
      ip -n "$NS_SRC" link set "$SRC_IF" down
      ip -n "$NS_SRC" addr flush dev "$SRC_IF" || true
      ip -n "$NS_SRC" link set "$SRC_IF" netns 1 || true
    fi
    if ns_exists "$NS_DST" && ip -n "$NS_DST" link show "$DST_IF" >/dev/null 2>&1; then
      ip -n "$NS_DST" link set "$DST_IF" down
      ip -n "$NS_DST" addr flush dev "$DST_IF" || true
      ip -n "$NS_DST" link set "$DST_IF" netns 1 || true
    fi
    rm -f "$STATE_FILE" || true
  fi
  ns_exists "$NS_SRC" && ip netns delete "$NS_SRC" || true
  ns_exists "$NS_DST" && ip netns delete "$NS_DST" || true
  log "Cleanup complete."
}

# ---------- Arg parsing ----------
if [ $# -eq 0 ]; then usage; exit 0; fi
while [ $# -gt 0 ]; do
  case "$1" in
    --src-if)       SRC_IF="$2"; shift 2 ;;
    --dst-if)       DST_IF="$2"; shift 2 ;;
    -s|--src-ns)    NS_SRC="$2"; shift 2 ;;
    -d|--dst-ns)    NS_DST="$2"; shift 2 ;;
    --src-ip)       IP_SRC="$2"; shift 2 ;;
    --dst-ip)       IP_DST="$2"; shift 2 ;;
    --mtu)          MTU="$2"; shift 2 ;;
    -S|--size)      PAYLOAD="$2"; shift 2 ;;
    --keep)         KEEP_AFTER="1"; shift 1 ;;
    -q|--quiet)     QUIET="1"; shift 1 ;;
    --cleanup)      DO_CLEANUP="1"; shift 1 ;;
    -h|--help|-\?)  usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 2 ;;
  esac
done

require_root

# Auto-cleanup on exit unless --keep or explicit --cleanup
if [ "$KEEP_AFTER" != "1" ] && [ "$DO_CLEANUP" != "1" ]; then
  trap cleanup EXIT
fi

if [ "$DO_CLEANUP" = "1" ]; then
  cleanup
  exit 0
fi

create_topology
print_topology
warmup_and_check
run_flood_10s

# Cleanup happens via trap unless --keep
if [ "$KEEP_AFTER" = "1" ]; then
  log "Keeping namespaces as requested. Run '--cleanup' later to restore."
fi
exit 0
