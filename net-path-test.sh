#!/usr/bin/env bash
# ns-ext-path-test.sh
# Purpose: Test a real/external path using two selected interfaces, without any bridges or veth.
#          Each interface is moved to its own netns (src, dst). Tests run only inside namespaces.
#
# Example external path:
#   [src-ns: <src-if> ] ----(your real external path: cable/switch/media)---- [dst-ns: <dst-if>]
#
# Notes:
# - You MUST provide --src-if and --dst-if (they must exist in the root namespace and be DOWN).
# - The script assigns IPs on those interfaces inside their namespaces and runs tests.
# - No bridge, no veth are created. Your external infrastructure provides L2/L3 connectivity.
# - Root privileges required.

set -euo pipefail

# ---------- Defaults ----------
NS_SRC="src"
NS_DST="dst"

SRC_IF=""
DST_IF=""

IP_SRC="10.10.10.1/30"   # use a /30 or /31 for point-to-point
IP_DST="10.10.10.2/30"

MTU="1500"
COUNT="5"
PKT_SIZE="56"
FLOOD="0"
QUIET="0"
ONLY_SETUP="0"
ONLY_TESTS="0"
DO_CLEANUP="0"

PING_BIN="${PING_BIN:-ping}"
ARPING_BIN="${ARPING_BIN:-arping}"
TRACE_BIN="${TRACE_BIN:-tracepath}"

# Track ifnames to return on cleanup
STATE_FILE="/tmp/ns-ext-path-test.state"

usage() {
  cat <<'EOF'
ns-ext-path-test.sh - External path test using two chosen interfaces moved into namespaces
No bridges, no veth. The real/existing external path is used as-is.

Usage:
  sudo ./ns-ext-path-test.sh --src-if IF1 --dst-if IF2 [options]

Required:
  --src-if IFNAME          Root-ns interface to use as source endpoint (must be DOWN)
  --dst-if IFNAME          Root-ns interface to use as destination endpoint (must be DOWN)

Options:
  -s, --src-ns NAME        Source namespace name              (default: src)
  -d, --dst-ns NAME        Destination namespace name         (default: dst)
  --src-ip CIDR            Source IP (e.g., 10.10.10.1/30)    (default: 10.10.10.1/30)
  --dst-ip CIDR            Destination IP (e.g., 10.10.10.2/30) (default: 10.10.10.2/30)
  --mtu BYTES              MTU for both interfaces            (default: 1500)

  -c, --count N            Number of ping probes              (default: 5)
  -S, --size BYTES         Ping payload (ping -s)             (default: 56)
  -f, --flood              Enable ping -f (flood mode, root only)
  -q, --quiet              Reduced verbosity

  --only-setup             Build namespaces and move interfaces; do not run tests
  --only-tests             Run tests assuming namespaces/interfaces already set
  --cleanup                Move interfaces back to root ns, delete namespaces

  -h, --help, -?           Show help and exit

Examples:
  # 1) Move two ports (e.g., enp1s0 and enp2s0) into src/dst, assign /30, test with flood:
  sudo ip link set enp1s0 down
  sudo ip link set enp2s0 down
  sudo ./ns-ext-path-test.sh --src-if enp1s0 --dst-if enp2s0 --src-ip 192.0.2.1/30 --dst-ip 192.0.2.2/30 -f -c 200 -S 1200

  # 2) Only setup, then run custom tests:
  sudo ./ns-ext-path-test.sh --src-if enp1s0 --dst-if enp2s0 --only-setup
  sudo ip netns exec src ping 192.0.2.2
  sudo ip netns exec src arping -I enp1s0 -c 5 192.0.2.2

  # 3) Cleanup (moves ports back to root namespace):
  sudo ./ns-ext-path-test.sh --cleanup
EOF
}

log() { [ "$QUIET" = "1" ] || echo "[*] $*"; }
err() { echo "[!] $*" >&2; }

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "Root privileges are required. Please run with sudo."
    exit 1
  fi
}

ns_exists() {
  ip netns list | awk '{print $1}' | grep -qx -- "$1"
}

check_root_if_down() {
  local ifname="$1"
  ip link show "$ifname" >/dev/null 2>&1 || { err "Interface '$ifname' not found in root namespace."; exit 1; }
  local state
  state=$(ip -br link show dev "$ifname" | awk '{print $2}')
  if [[ "$state" != "DOWN" && "$state" != "UNKNOWN" ]]; then
    err "Interface '$ifname' must be DOWN before moving. Current state: $state"
    err "Run: sudo ip link set dev $ifname down"
    exit 1
  fi
}

save_state() {
  echo "NS_SRC=$NS_SRC" > "$STATE_FILE"
  echo "NS_DST=$NS_DST" >> "$STATE_FILE"
  echo "SRC_IF=$SRC_IF" >> "$STATE_FILE"
  echo "DST_IF=$DST_IF" >> "$STATE_FILE"
}

load_state() {
  [ -f "$STATE_FILE" ] || { err "State file not found: $STATE_FILE"; exit 1; }
  # shellcheck disable=SC1090
  . "$STATE_FILE"
}

create_topology() {
  if [ -z "$SRC_IF" ] || [ -z "$DST_IF" ]; then
    err "Both --src-if and --dst-if are required (no bridges/veth are created)."
    exit 2
  fi

  log "Creating namespaces: $NS_SRC, $NS_DST"
  ns_exists "$NS_SRC" || ip netns add "$NS_SRC"
  ns_exists "$NS_DST" || ip netns add "$NS_DST"
  ip -n "$NS_SRC" link set lo up
  ip -n "$NS_DST" link set lo up

  log "Moving interfaces into namespaces (no base-ns traffic)"
  check_root_if_down "$SRC_IF"
  check_root_if_down "$DST_IF"

  ip link set "$SRC_IF" netns "$NS_SRC"
  ip link set "$DST_IF" netns "$NS_DST"

  # MTU and up
  ip -n "$NS_SRC" link set "$SRC_IF" mtu "$MTU" up
  ip -n "$NS_DST" link set "$DST_IF" mtu "$MTU" up

  # Assign IPs
  if ! ip -n "$NS_SRC" addr show dev "$SRC_IF" | grep -q "${IP_SRC%/*}"; then
    ip -n "$NS_SRC" addr add "$IP_SRC" dev "$SRC_IF"
  fi
  if ! ip -n "$NS_DST" addr show dev "$DST_IF" | grep -q "${IP_DST%/*}"; then
    ip -n "$NS_DST" addr add "$IP_DST" dev "$DST_IF"
  fi

  save_state
  log "Topology ready. src-if=$SRC_IF in ns=$NS_SRC, dst-if=$DST_IF in ns=$NS_DST"
}

print_topology() {
  log "=== Topology summary ==="
  for ns in "$NS_SRC" "$NS_DST"; do
    if ns_exists "$ns"; then
      echo "[$ns] Links:"
      ip -n "$ns" -brief link
      echo "[$ns] Addresses:"
      ip -n "$ns" -brief addr
      echo
    fi
  done
}

run_tests() {
  # Determine endpoint IPs from assigned interfaces
  local src_ip dst_ip
  src_ip=$(ip -n "$NS_SRC" -brief addr show dev "$SRC_IF" | awk '{print $3}' | cut -d/ -f1)
  dst_ip=$(ip -n "$NS_DST" -brief addr show dev "$DST_IF" | awk '{print $3}' | cut -d/ -f1)

  if [ -z "$src_ip" ] || [ -z "$dst_ip" ]; then
    err "Could not read IPs from interfaces. Verify IP assignment."
    exit 1
  fi

  echo "=== ARP/NDP reachability ==="
  # IPv4 arping; for IPv6, user would use arping -6 (not all distros support -6)
  if [[ "$dst_ip" =~ : ]]; then
    echo "(IPv6 detected) Skipping IPv4 arping. Use: ip netns exec $NS_SRC $PING_BIN -6 -c 1 $dst_ip"
  else
    ip netns exec "$NS_SRC" "$ARPING_BIN" -I "$SRC_IF" -c 3 "$dst_ip" || true
  fi

  echo
  echo "=== Ping test (src -> dst) ==="
  PING_ARGS=(-c "$COUNT" -s "$PKT_SIZE")
  if [ "$FLOOD" = "1" ]; then
    PING_ARGS+=(-f)
    echo "(Flood mode enabled: ping -f)"
  fi
  echo "Command: $PING_BIN ${PING_ARGS[*]} $dst_ip"
  ip netns exec "$NS_SRC" "$PING_BIN" "${PING_ARGS[@]}" "$dst_ip"

  echo
  echo "=== Tracepath (src -> dst) ==="
  # Note: Works for routed paths; for pure L2 it will still show PMTU hops if any.
  ip netns exec "$NS_SRC" "$TRACE_BIN" -n "$dst_ip" || true

  echo
  echo "=== Interface statistics (ip -s link) ==="
  echo "[src:$NS_SRC/$SRC_IF]"
  ip -n "$NS_SRC" -s link show "$SRC_IF" | sed 's/^/  /'
  echo "[dst:$NS_DST/$DST_IF]"
  ip -n "$NS_DST" -s link show "$DST_IF" | sed 's/^/  /'

  echo
  echo "=== MTU / DF check (IPv4) ==="
  if [[ ! "$dst_ip" =~ : ]]; then
    local size_nofrag=$((MTU - 28)) # 20 (IPv4) + 8 (ICMP)
    if [ "$size_nofrag" -gt 0 ]; then
      echo "Testing DF path with -s $size_nofrag -M do"
      ip netns exec "$NS_SRC" "$PING_BIN" -c 3 -s "$size_nofrag" -M do "$dst_ip" || true
    fi
  else
    echo "(IPv6) For PMTU, rely on normal ping/tracepath6; DF is implicit in IPv6."
  fi

  echo
  echo "=== Short latency run (50 probes, 20 ms interval) ==="
  ip netns exec "$NS_SRC" "$PING_BIN" -c 50 -i 0.02 -s "$PKT_SIZE" "$dst_ip" | sed 's/^/  /'
}

cleanup() {
  log "Cleanup: moving interfaces back to root namespace and deleting namespaces"
  if [ -f "$STATE_FILE" ]; then
    load_state || true
    # Try to move if still in namespaces

