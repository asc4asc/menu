#!/usr/bin/env bash
# ns-ping-f-test.sh
# Minimal external path test with ping -f between two selected interfaces.
# No bridges, no veth. Exactly your external segment gets tested.
#
# Actions:
#   - Move --src-if into namespace 'src' and --dst-if into 'dst'
#   - Assign IPs, set MTU, bring links up
#   - Verify link state (operstate/carrier). If down -> abort with clear message
#   - Run ping -f from src to dst
#   - Cleanup: move interfaces back to root ns, delete namespaces
#
# Requirements: bash, iproute2 (ip), ping, root privileges
# Traffic policy: All test traffic runs inside namespaces (no root-ns traffic)

set -euo pipefail

# -------- Defaults --------
NS_SRC="src"
NS_DST="dst"

SRC_IF=""
DST_IF=""

IP_SRC="10.10.10.1/30"    # choose /30 or /31 for point-to-point
IP_DST="10.10.10.2/30"

MTU="1500"
COUNT="0"                 # 0 => unlimited; for flood this means Ctrl-C to stop
PAYLOAD="56"              # ping -s payload
QUIET="0"
DO_CLEANUP="0"
NO_AUTO_CLEANUP="0"

STATE_FILE="/tmp/ns-ping-f-test.state"

# -------- Help --------
usage() {
  cat <<'EOF'
ns-ping-f-test.sh - Minimal external path ping flood test with two chosen interfaces (no bridges, no veth)

Usage:
  sudo ./ns-ping-f-test.sh --src-if IF1 --dst-if IF2 [options]
  sudo ./ns-ping-f-test.sh --cleanup

Required:
  --src-if IFNAME          Root-ns interface for source endpoint (must be DOWN)
  --dst-if IFNAME          Root-ns interface for destination endpoint (must be DOWN)

Options:
  -s, --src-ns NAME        Source namespace name                  (default: src)
  -d, --dst-ns NAME        Destination namespace name             (default: dst)
  --src-ip CIDR            Source IP                              (default: 10.10.10.1/30)
  --dst-ip CIDR            Destination IP                         (default: 10.10.10.2/30)
  --mtu BYTES              MTU for both interfaces                (default: 1500)
  -S, --size BYTES         Ping payload for flood (ping -s)       (default: 56)
  -c, --count N            Ping count; 0 = unlimited until Ctrl-C (default: 0)
  -q, --quiet              Reduce script verbosity

  --cleanup                Move interfaces back to root ns and delete namespaces
  --no-auto-cleanup        Do NOT auto-cleanup on exit (manual --cleanup required)

  -h, --help, -?           Show this help and exit

Examples:
  # Prepare (ports must be DOWN in root ns)
  sudo ip link set enp1s0 down
  sudo ip link set enp2s0 down

  # Run flood test (stop with Ctrl-C). MTU 1500, payload 1200 bytes:
  sudo ./ns-ping-f-test.sh --src-if enp1s0 --dst-if enp2s0 --src-ip 192.0.2.1/30 --dst-ip 192.0.2.2/30 --mtu 1500 -S 1200

  # Limited flood (e.g., 10,000 packets):
  sudo ./ns-ping-f-test.sh --src-if enp1s0 --dst-if enp2s0 -c 10000

  # Cleanup later:
  sudo ./ns-ping-f-test.sh --cleanup
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

check_root_if_down() {
  local ifname="$1"
  ip link show "$ifname" >/dev/null 2>&1 || { err "Interface '$ifname' not found in root namespace."; exit 1; }
  local state; state=$(ip -br link show dev "$ifname" | awk '{print $2}')
  if [[ "$state" != "DOWN" && "$state" != "UNKNOWN" ]]; then
    err "Interface '$ifname' must be DOWN before moving (current: $state)."
    err "Run: sudo ip link set dev $ifname down"
    exit 1
  fi
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

link_status() {
  # Prints "UP" if operstate is up AND carrier is 1; else "DOWN"
  local ns="$1" ifn="$2"
  local oper carrier
  oper=$(ip -n "$ns" -o link show "$ifn" | awk -F'state ' '{print $2}' | awk '{print $1}' | tr -d ',')
  # Try sysfs carrier; if not present, fallback to LOWER_UP flag parsing
  if ip netns exec "$ns" test -r "/sys/class/net/$ifn/carrier"; then
    carrier=$(ip netns exec "$ns" cat "/sys/class/net/$ifn/carrier" 2>/dev/null || echo 0)
    if [[ "$oper" == "UP" && "$carrier" == "1" ]]; then
      echo "UP"; return 0
    fi
  else
    # Fallback: check LOWER_UP flag via ip -br link
    if ip -n "$ns" -br link show dev "$ifn" | grep -q "LOWER_UP"; then
      echo "UP"; return 0
    fi
  fi
  echo "DOWN"
}

create_topology() {
  if [ -z "$SRC_IF" ] || [ -z "$DST_IF" ]; then
    err "Both --src-if and --dst-if are required."
    exit 2
  fi

  log "Creating namespaces: $NS_SRC, $NS_DST"
  ns_exists "$NS_SRC" || ip netns add "$NS_SRC"
  ns_exists "$NS_DST" || ip netns add "$NS_DST"
  ip -n "$NS_SRC" link set lo up
  ip -n "$NS_DST" link set lo up

  check_root_if_down "$SRC_IF"
  check_root_if_down "$DST_IF"

  log "Moving interfaces into namespaces (no root-ns traffic)"
  ip link set "$SRC_IF" netns "$NS_SRC"
  ip link set "$DST_IF" netns "$NS_DST"

  ip -n "$NS_SRC" link set "$SRC_IF" mtu "$MTU" up
  ip -n "$NS_DST" link set "$DST_IF" mtu "$MTU" up

  # Assign IPs
  ip -n "$NS_SRC" addr add "$IP_SRC" dev "$SRC_IF" || true
  ip -n "$NS_DST" addr add "$IP_DST" dev "$DST_IF" || true

  save_state
  log "Topology ready: $SRC_IF in ns=$NS_SRC, $DST_IF in ns=$NS_DST"
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

run_ping_flood() {
  # Resolve IPs without mask
  local dst_ip
  dst_ip=$(ip -n "$NS_DST" -br addr show dev "$DST_IF" | awk '{print $3}' | cut -d/ -f1)
  if [ -z "$dst_ip" ]; then
    err "Destination IP empty on $NS_DST/$DST_IF."
    exit 1
  fi

  # Link state checks (network down handling)
  local sstat dstat
  sstat=$(link_status "$NS_SRC" "$SRC_IF")
  dstat=$(link_status "$NS_DST" "$DST_IF")
  if [ "$sstat" != "UP" ] || [ "$dstat" != "UP" ]; then
    err "Network down: link status -> src:$NS_SRC/$SRC_IF=$sstat, dst:$NS_DST/$DST_IF=$dstat"
    err "Check cabling/switch/auto-negotiation and try again."
    exit 1
  fi

  echo "=== ping flood (src -> dst) ==="
  echo "Interface src: $NS_SRC/$SRC_IF  ->  dst IP: $dst_ip"
  local args=(-f -s "$PAYLOAD")
  if [ "$COUNT" -gt 0 ]; then
    args=(-f -s "$PAYLOAD" -c "$COUNT")
  fi
  echo "Command: ping ${args[*]} $dst_ip"
  # Run ping inside src namespace
  ip netns exec "$NS_SRC" ping "${args[@]}" "$dst_ip"
}

cleanup() {
  log "Cleanup: moving interfaces back to root namespace and deleting namespaces"
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
  log "Cleanup done."
}

# -------- Arg parsing --------
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
    -c|--count)     COUNT="$2"; shift 2 ;;
    -q|--quiet)     QUIET="1"; shift 1 ;;
    --cleanup)      DO_CLEANUP="1"; shift 1 ;;
    --no-auto-cleanup) NO_AUTO_CLEANUP="1"; shift 1 ;;
    -h|--help|-\?)  usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 2 ;;
  esac
done

require_root

# Auto-cleanup on exit unless disabled
if [ "$NO_AUTO_CLEANUP" != "1" ] && [ "$DO_CLEANUP" != "1" ]; then
  trap cleanup EXIT
fi

if [ "$DO_CLEANUP" = "1" ]; then
  cleanup
  exit 0
fi

create_topology
print_topology
run_ping_flood

# If we reach here and auto-cleanup is enabled, trap will handle cleanup.
exit 0
