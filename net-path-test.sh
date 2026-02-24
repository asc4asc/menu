#!/usr/bin/env bash
# ns-path-test.sh
# Purpose: End-to-end path test fully inside Linux network namespaces
# Traffic never leaves to the default (root) namespace.
#
# Topologies supported:
#   1) Adopt existing interfaces as endpoints:
#        [src-ns: <src-if>] ---(L2 via switch ns bridge)--- [dst-ns: <dst-if>]
#      The script moves <src-if> into src-ns and <dst-if> into dst-ns.
#
#   2) Auto-create veth pairs (if --src-if / --dst-if are NOT given):
#        [src] -- veth_src <-> veth_sw1 -- [sw: br0] -- veth_sw2 <-> veth_dst -- [dst]
#
# Tests: ping (optionally flood with -f), tracepath, interface stats, MTU check.
# Language: English (comments, help, messages).
#
# Notes:
# - For adopting existing interfaces, they MUST currently be in the root namespace and DOWN.
# - The switch namespace contains a Linux bridge (L2 only, no IP).
# - The script will not assign any IP in the switch namespace.
# - Root privileges are required.

set -euo pipefail

# -------- Default parameters --------
NS_SRC="src"
NS_SW="sw"
NS_DST="dst"

IP_SRC="10.10.10.1/24"
IP_DST="10.10.10.2/24"

MTU="1500"
COUNT="5"
PKT_SIZE="56"   # payload for ping -s
FLOOD="0"       # 1 => enable ping -f
QUIET="0"
DO_CLEANUP="0"
ONLY_SETUP="0"
ONLY_TESTS="0"

# Optional adoption of existing base-namespace interfaces:
SRC_IF=""       # e.g., --src-if eno1
DST_IF=""       # e.g., --dst-if tap0

PING_BIN="${PING_BIN:-ping}"
TRACE_BIN="${TRACE_BIN:-tracepath}"

# -------- Help text --------
usage() {
  cat <<'EOF'
ns-path-test.sh - End-to-end path test using Linux network namespaces (no traffic in root namespace)

Usage:
  sudo ./ns-path-test.sh [options]

Options:
  -s, --src-ns NAME        Source namespace name                 (default: src)
  -w, --sw-ns  NAME        Switch namespace name                 (default: sw)
  -d, --dst-ns NAME        Destination namespace name            (default: dst)

  --src-if IFNAME          Adopt an existing root-ns interface as source endpoint
  --dst-if IFNAME          Adopt an existing root-ns interface as destination endpoint
                           NOTE: Interfaces must exist in root namespace and be DOWN.
                                 They will be moved into the respective namespaces.

  --src-ip CIDR            IP for source endpoint (e.g., 10.10.10.1/24)
  --dst-ip CIDR            IP for destination endpoint (e.g., 10.10.10.2/24)
  --mtu BYTES              MTU on all involved links              (default: 1500)

  -c, --count N            Number of ping probes                  (default: 5)
  -S, --size BYTES         Ping payload size (ping -s)            (default: 56)
  -f, --flood              Enable ping -f (flood mode)
  -q, --quiet              Reduce output verbosity

  --only-setup             Build topology only (no tests)
  --only-tests             Run tests only (assumes topology exists)
  --cleanup                Delete created namespaces and quit

  -h, --help, -?           Show this help and exit

Examples:
  # Auto-create veth-based path and test with flood and larger payload:
  sudo ./ns-path-test.sh -f -c 100 -S 1200 --mtu 1500

  # Adopt existing interfaces eno3 (source) and tap42 (destination):
  # (Both must be DOWN in root namespace before running.)
  sudo ip link set dev eno3 down
  sudo ip link set dev tap42 down
  sudo ./ns-path-test.sh --src-if eno3 --dst-if tap42 --src-ip 192.0.2.1/30 --dst-ip 192.0.2.2/30

  # Only build:
  sudo ./ns-path-test.sh --only-setup

  # Only tests (if namespaces already exist):
  sudo ./ns-path-test.sh --only-tests -c 500 -S 900

  # Cleanup:
  sudo ./ns-path-test.sh --cleanup

Topology:
  If --src-if/--dst-if are given:
     [src-ns:<src-if>] -- [sw-ns: br0 bridge] -- [dst-ns:<dst-if>]

  Otherwise:
     [src] -- veth_src <-> veth_sw1 -- [sw: br0] -- veth_sw2 <-> veth_dst -- [dst]
EOF
}

# -------- Logging --------
log() { [ "$QUIET" = "1" ] || echo "[*] $*"; }
err() { echo "[!] $*" >&2; }

# -------- Root requirement --------
require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "Root privileges are required. Please run with sudo."
    exit 1
  fi
}

# -------- Namespace utilities --------
ns_exists() {
  ip netns list | awk '{print $1}' | grep -qx -- "$1"
}

# Validate interface exists in root ns and is DOWN (for adoption)
check_root_if_down() {
  local ifname="$1"
  ip link show "$ifname" >/dev/null 2>&1 || {
    err "Interface '$ifname' not found in root namespace."
    exit 1
  }
  # Ensure it's in root ns (not inside a ns)
  if ip -all netns exec echo >/dev/null 2>&1; then :; fi # no-op to avoid shellcheck
  # Best-effort check: If interface is not visible via ip -n for any ns, assume root.
  # We still require it to be DOWN to safely move it.
  local state
  state=$(ip -br link show dev "$ifname" | awk '{print $2}')
  if [[ "$state" != "DOWN" && "$state" != "UNKNOWN" ]]; then
    err "Interface '$ifname' must be DOWN before adoption. Current state: $state"
    err "Run: sudo ip link set dev $ifname down"
    exit 1
  fi
}

# -------- Argument parsing --------
while [ $# -gt 0 ]; do
  case "$1" in
    -s|--src-ns) NS_SRC="$2"; shift 2 ;;
    -w|--sw-ns)  NS_SW="$2";  shift 2 ;;
    -d|--dst-ns) NS_DST="$2"; shift 2 ;;
    --src-if)    SRC_IF="$2"; shift 2 ;;
    --dst-if)    DST_IF="$2"; shift 2 ;;
    --src-ip)    IP_SRC="$2"; shift 2 ;;
    --dst-ip)    IP_DST="$2"; shift 2 ;;
    --mtu)       MTU="$2"; shift 2 ;;
    -c|--count)  COUNT="$2"; shift 2 ;;
    -S|--size)   PKT_SIZE="$2"; shift 2 ;;
    -f|--flood)  FLOOD="1"; shift 1 ;;
    -q|--quiet)  QUIET="1"; shift 1 ;;
    --only-setup) ONLY_SETUP="1"; shift 1 ;;
    --only-tests) ONLY_TESTS="1"; shift 1 ;;
    --cleanup)   DO_CLEANUP="1"; shift 1 ;;
    -h|--help|-\?) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 2 ;;
  esac
done

require_root

# -------- Topology creation --------
create_topology() {
  log "Creating namespaces: $NS_SRC, $NS_SW, $NS_DST"
  ns_exists "$NS_SRC" || ip netns add "$NS_SRC"
  ns_exists "$NS_SW"  || ip netns add "$NS_SW"
  ns_exists "$NS_DST" || ip netns add "$NS_DST"

  # Bring up loopback in all namespaces
  ip -n "$NS_SRC" link set lo up
  ip -n "$NS_SW"  link set lo up
  ip -n "$NS_DST" link set lo up

  # Create bridge in switch namespace
  if ! ip -n "$NS_SW" link show br0 >/dev/null 2>&1; then
    log "Creating bridge br0 in namespace $NS_SW"
    ip -n "$NS_SW" link add br0 type bridge
    ip -n "$NS_SW" link set br0 up
  else
    log "Bridge br0 already exists"
  fi

  # Prepare source endpoint
  if [ -n "$SRC_IF" ]; then
    log "Adopting root-ns interface '$SRC_IF' as source endpoint"
    check_root_if_down "$SRC_IF"
    ip link set "$SRC_IF" netns "$NS_SRC"
    ip -n "$NS_SRC" link set "$SRC_IF" mtu "$MTU"
    ip -n "$NS_SRC" link set "$SRC_IF" up
    # Connect to bridge via an intermediate veth pair (src<->sw) or directly?
    # Because '$SRC_IF' is now inside src ns, we still need L2 to the switch ns.
    # We'll create a veth pair: veth_src <-> veth_sw1 and keep $SRC_IF as host-facing inside src.
    if ! ip -n "$NS_SRC" link show veth_src >/dev/null 2>&1; then
      ip link add veth_src type veth peer name veth_sw1
      ip link set veth_src netns "$NS_SRC"
      ip link set veth_sw1 netns "$NS_SW"
    fi
    ip -n "$NS_SRC" link set veth_src mtu "$MTU" up
    ip -n "$NS_SW"  link set veth_sw1 mtu "$MTU" up
    ip -n "$NS_SW"  link set veth_sw1 master br0
    # You can bind IP on either $SRC_IF or veth_src. We bind to veth_src for a clean L2 towards switch.
    if ! ip -n "$NS_SRC" addr show dev veth_src | grep -q "${IP_SRC%/*}"; then
      ip -n "$NS_SRC" addr add "$IP_SRC" dev veth_src
    fi
  else
    # Auto veth for source
    if ! ip -n "$NS_SRC" link show veth_src >/dev/null 2>&1; then
      log "Creating veth pair for source: veth_src <-> veth_sw1"
      ip link add veth_src type veth peer name veth_sw1
      ip link set veth_src netns "$NS_SRC"
      ip link set veth_sw1 netns "$NS_SW"
    else
      log "veth_src already exists"
    fi
    ip -n "$NS_SRC" link set veth_src mtu "$MTU" up
    ip -n "$NS_SW"  link set veth_sw1 mtu "$MTU" up
    ip -n "$NS_SW"  link set veth_sw1 master br0
    if ! ip -n "$NS_SRC" addr show dev veth_src | grep -q "${IP_SRC%/*}"; then
      ip -n "$NS_SRC" addr add "$IP_SRC" dev veth_src
    fi
  fi

  # Prepare destination endpoint
  if [ -n "$DST_IF" ]; then
    log "Adopting root-ns interface '$DST_IF' as destination endpoint"
    check_root_if_down "$DST_IF"
    ip link set "$DST_IF" netns "$NS_DST"
    ip -n "$NS_DST" link set "$DST_IF" mtu "$MTU"
    ip -n "$NS_DST" link set "$DST_IF" up
    # Create veth to switch ns
    if ! ip -n "$NS_DST" link show veth_dst >/dev/null 2>&1; then
      ip link add veth_dst type veth peer name veth_sw2
      ip link set veth_dst netns "$NS_DST"
      ip link set veth_sw2 netns "$NS_SW"
    fi
    ip -n "$NS_DST" link set veth_dst mtu "$MTU" up
    ip -n "$NS_SW"  link set veth_sw2 mtu "$MTU" up
    ip -n "$NS_SW"  link set veth_sw2 master br0
    # Bind IP on veth_dst (L2 path to switch)
    if ! ip -n "$NS_DST" addr show dev veth_dst | grep -q "${IP_DST%/*}"; then
      ip -n "$NS_DST" addr add "$IP_DST" dev veth_dst
    fi
  else
    # Auto veth for destination
    if ! ip -n "$NS_DST" link show veth_dst >/dev/null 2>&1; then
      log "Creating veth pair for destination: veth_dst <-> veth_sw2"
      ip link add veth_dst type veth peer name veth_sw2
      ip link set veth_dst netns "$NS_DST"
      ip link set veth_sw2 netns "$NS_SW"
    else
      log "veth_dst already exists"
    fi
    ip -n "$NS_DST" link set veth_dst mtu "$MTU" up
    ip -n "$NS_SW"  link set veth_sw2 mtu "$MTU" up
    ip -n "$NS_SW"  link set veth_sw2 master br0
    if ! ip -n "$NS_DST" addr show dev veth_dst | grep -q "${IP_DST%/*}"; then
      ip -n "$NS_DST" addr add "$IP_DST" dev veth_dst
    fi
  fi

  log "Topology is ready."
}

# -------- Topology deletion --------
delete_topology() {
  log "Deleting namespaces if present: $NS_SRC $NS_SW $NS_DST"
  ns_exists "$NS_SRC" && ip netns delete "$NS_SRC" || true
  ns_exists "$NS_SW"  && ip netns delete "$NS_SW"  || true
  ns_exists "$NS_DST" && ip netns delete "$NS_DST" || true
  log "Cleanup done."
}

# -------- Topology visibility --------
print_topology() {
  log "=== Topology summary ==="
  log "Namespaces: $(ip netns list | tr '\n' ' ')"
  echo
  for ns in "$NS_SRC" "$NS_SW" "$NS_DST"; do
    if ns_exists "$ns"; then
      echo "[$ns] Links:"
      ip -n "$ns" -brief link
      echo "[$ns] Addresses:"
      ip -n "$ns" -brief addr
      echo
    fi
  done
}

# -------- Tests --------
run_tests() {
  # Determine endpoint IPs
  DST_IP=$(ip -n "$NS_DST" -brief addr show dev veth_dst | awk '/veth_dst/ {print $3}' | cut -d/ -f1 || true)
  SRC_IP=$(ip -n "$NS_SRC" -brief addr show dev veth_src | awk '/veth_src/ {print $3}' | cut -d/ -f1 || true)

  if [ -z "${DST_IP:-}" ] || [ -z "${SRC_IP:-}" ]; then
    err "Could not determine source/destination IPs on veth endpoints."
    err "Check that IPs are assigned to veth_src (src-ns) and veth_dst (dst-ns)."
    exit 1
  fi

  echo "=== Basic reachability test (src -> dst) ==="
  ip netns exec "$NS_SRC" "$PING_BIN" -c 1 "$DST_IP" || {
    err "Initial ping failed. Verify topology and IP assignment."
    exit 1
  }

  echo
  echo "=== Ping test (src -> dst) ==="
  PING_ARGS=(-c "$COUNT" -s "$PKT_SIZE")
  if [ "$FLOOD" = "1" ]; then
    PING_ARGS+=(-f)
    echo "(Flood mode enabled: ping -f)"
  fi
  echo "Command: $PING_BIN ${PING_ARGS[*]} $DST_IP"
  ip netns exec "$NS_SRC" "$PING_BIN" "${PING_ARGS[@]}" "$DST_IP"

  echo
  echo "=== Tracepath (src -> dst) ==="
  ip netns exec "$NS_SRC" "$TRACE_BIN" -n "$DST_IP" || true

  echo
  echo "=== Interface statistics (ip -s link) ==="
  echo "[src]"
  ip -n "$NS_SRC" -s link show veth_src | sed 's/^/  /'
  if [ -n "$SRC_IF" ]; then
    ip -n "$NS_SRC" -s link show "$SRC_IF" | sed 's/^/  /'
  fi
  echo "[sw]"
  ip -n "$NS_SW"  -s link show veth_sw1 | sed 's/^/  /'
  ip -n "$NS_SW"  -s link show veth_sw2 | sed 's/^/  /'
  echo "[dst]"
  ip -n "$NS_DST" -s link show veth_dst | sed 's/^/  /'
  if [ -n "$DST_IF" ]; then
    ip -n "$NS_DST" -s link show "$DST_IF" | sed 's/^/  /'
  fi

  echo
  echo "=== Latency quick check (ICMP, 50 probes) ==="
  ip netns exec "$NS_SRC" "$PING_BIN" -c 50 -i 0.02 -s "$PKT_SIZE" "$DST_IP" | sed 's/^/  /'

  echo
  echo "=== MTU / fragmentation check ==="
  SIZE_NOFRAG=$((MTU - 28)) # IPv4 header (20) + ICMP (8)
  if [ "$SIZE_NOFRAG" -gt 0 ]; then
    echo "Testing DF with -s $SIZE_NOFRAG -M do"
    ip netns exec "$NS_SRC" "$PING_BIN" -c 3 -s "$SIZE_NOFRAG" -M do "$DST_IP" || true
  fi
}

# -------- Control flow --------
if [ "$DO_CLEANUP" = "1" ]; then
  delete_topology
  exit 0
fi

if [ "$ONLY_TESTS" = "1" ] && [ "$ONLY_SETUP" = "1" ]; then
  err "--only-tests and --only-setup are mutually exclusive."
  exit 2
fi

# If adopting existing interfaces, ensure they are valid before proceeding
if [ -n "$SRC_IF" ]; then check_root_if_down "$SRC_IF"; fi
if [ -n "$DST_IF" ]; then check_root_if_down "$DST_IF"; fi

if [ "$ONLY_TESTS" = "0" ]; then
  create_topology
  print_topology
fi

if [ "$ONLY_SETUP" = "0" ]; then
  run_tests
fi
