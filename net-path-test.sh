#!/usr/bin/env bash
set -euo pipefail

NS_SRC="src"
NS_DST="dst"

SRC_IF=""
DST_IF=""

IP_SRC="10.10.10.1/30"
IP_DST="10.10.10.2/30"

MTU="1500"
PAYLOAD="56"
QUIET="0"
KEEP_AFTER="0"
DO_CLEANUP="0"

STATE_FILE="/tmp/ns-ping-f.state"
PING_BIN="${PING_BIN:-ping}"

log() { [ "$QUIET" = "1" ] || echo "[*] $*"; }
err() { echo "[!] $*" >&2; }

usage() {
  echo "Usage:"
  echo "  sudo ./ns-ping-f-10s.sh --src-if IF1 --dst-if IF2 [options]"
  echo "Options:"
  echo "  --src-ip CIDR       default: 10.10.10.1/30"
  echo "  --dst-ip CIDR       default: 10.10.10.2/30"
  echo "  --mtu BYTES         default: 1500"
  echo "  -S --size BYTES     default: 56"
  echo "  --keep              do not auto-cleanup"
  echo "  --cleanup           restore and remove namespaces"
  exit 0
}

require_root() { [ "$(id -u)" -eq 0 ] || { err "Run as root"; exit 1; }; }

ns_exists() { ip netns list | awk '{print $1}' | grep -qx "$1"; }

force_root_if_down() {
  local ifn="$1"
  ip link show "$ifn" >/dev/null 2>&1 || { err "Interface $ifn not in root ns"; exit 1; }
  ip addr flush dev "$ifn" || true
  ip link set dev "$ifn" down
}

save_state() {
  echo "NS_SRC=$NS_SRC" > "$STATE_FILE"
  echo "NS_DST=$NS_DST" >> "$STATE_FILE"
  echo "SRC_IF=$SRC_IF" >> "$STATE_FILE"
  echo "DST_IF=$DST_IF" >> "$STATE_FILE"
}

load_state() {
  [ -f "$STATE_FILE" ] || { err "No state file"; exit 1; }
  # shellcheck disable=SC1090
  . "$STATE_FILE"
}

cleanup() {
  log "Cleanup: restoring interfaces"
  load_state || true

  if ns_exists "$NS_SRC" && ip -n "$NS_SRC" link show "$SRC_IF" &>/dev/null; then
    ip -n "$NS_SRC" link set "$SRC_IF" down
    ip -n "$NS_SRC" addr flush dev "$SRC_IF" || true
    ip -n "$NS_SRC" link set "$SRC_IF" netns 1 || true
  fi

  if ns_exists "$NS_DST" && ip -n "$NS_DST" link show "$DST_IF" &>/dev/null; then
    ip -n "$NS_DST" link set "$DST_IF" down
    ip -n "$NS_DST" addr flush dev "$DST_IF" || true
    ip -n "$NS_DST" link set "$DST_IF" netns 1 || true
  fi

  ns_exists "$NS_SRC" && ip netns delete "$NS_SRC" || true
  ns_exists "$NS_DST" && ip netns delete "$NS_DST" || true

  rm -f "$STATE_FILE" || true

  log "Cleanup complete."
}

packet_counter() {
  ip netns exec "$1" cat "/sys/class/net/$2/statistics/${3}_packets" 2>/dev/null || echo 0
}

link_up() {
  ip -n "$1" -br link show "$2" | grep -q "UP" && ip -n "$1" -br link show "$2" | grep -q "LOWER_UP"
}

create_topology() {
  force_root_if_down "$SRC_IF"
  force_root_if_down "$DST_IF"

  ns_exists "$NS_SRC" || ip netns add "$NS_SRC"
  ns_exists "$NS_DST" || ip netns add "$NS_DST"
  ip -n "$NS_SRC" link set lo up
  ip -n "$NS_DST" link set lo up

  ip link set "$SRC_IF" netns "$NS_SRC"
  ip link set "$DST_IF" netns "$NS_DST"

  ip -n "$NS_SRC" link set "$SRC_IF" mtu "$MTU" up
  ip -n "$NS_DST" link set "$DST_IF" mtu "$MTU" up

  ip -n "$NS_SRC" addr add "$IP_SRC" dev "$SRC_IF"
  ip -n "$NS_DST" addr add "$IP_DST" dev "$DST_IF"

  save_state
}

run_test() {
  local dst_ip
  dst_ip=$(ip -n "$NS_DST" -br addr show dev "$DST_IF" | awk '{print $3}' | cut -d/ -f1)

  echo "Warm-up ping:"
  ip netns exec "$NS_SRC" ping -c 1 "$dst_ip" || { err "Warm-up failed"; exit 1; }

  echo "Link check:"
  link_up "$NS_SRC" "$SRC_IF" || { err "SRC link DOWN"; exit 1; }
  link_up "$NS_DST" "$DST_IF" || { err "DST link DOWN"; exit 1; }
  echo "Both links UP."

  # ---- NEW: Wait for key press BEFORE flood ----
  echo
  read -r -p "Press ENTER to start 10-second flood test..."

  local tx_before rx_before
  tx_before=$(packet_counter "$NS_SRC" "$SRC_IF" tx)
  rx_before=$(packet_counter "$NS_DST" "$DST_IF" rx)

  echo "Running 10-second flood:"
  echo "Command: ping -f -s $PAYLOAD -w 10 $dst_ip"
  ip netns exec "$NS_SRC" ping -f -s "$PAYLOAD" -w 10 "$dst_ip"

  local tx_after rx_after
  tx_after=$(packet_counter "$NS_SRC" "$SRC_IF" tx)
  rx_after=$(packet_counter "$NS_DST" "$DST_IF" rx)

  echo "TX delta: $((tx_after - tx_before))"
  echo "RX delta: $((rx_after - rx_before))"
}

# ------------ ARG PARSING ------------
[ $# -eq 0 ] && usage

while [ $# -gt 0 ]; do
  case "$1" in
    --src-if) SRC_IF="$2"; shift 2 ;;
    --dst-if) DST_IF="$2"; shift 2 ;;
    --src-ip) IP_SRC="$2"; shift 2 ;;
    --dst-ip) IP_DST="$2"; shift 2 ;;
    --mtu) MTU="$2"; shift 2 ;;
    -S|--size) PAYLOAD="$2"; shift 2 ;;
    --keep) KEEP_AFTER="1"; shift 1 ;;
    -q|--quiet) QUIET="1"; shift 1 ;;
    --cleanup) DO_CLEANUP="1"; shift 1 ;;
    -h|--help|-\?) usage ;;
    *) err "Unknown: $1"; usage ;;
  esac
done

require_root

if [ "$DO_CLEANUP" = "1" ]; then
  cleanup
  exit 0
fi

if [ "$KEEP_AFTER" != "1" ]; then
  trap cleanup EXIT
fi

create_topology
run_test

if [ "$KEEP_AFTER" = "1" ]; then
  log "Namespaces kept. Run --cleanup manually."
fi

exit 0
