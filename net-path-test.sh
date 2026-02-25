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
DURATION="10"      # default
KEEP="0"
DO_CLEANUP="0"

STATE_FILE="/tmp/ns-ping-f.state"
PING_BIN="${PING_BIN:-ping}"

log() { echo "[*] $*"; }
err() { echo "[!] $*" >&2; }

usage() {
  echo "Usage:"
  echo "  sudo ./ns-ping-f.sh --src-if IF1 --dst-if IF2 [options]"
  echo ""
  echo "Options:"
  echo "  --src-ip CIDR"
  echo "  --dst-ip CIDR"
  echo "  --mtu BYTES"
  echo "  -S --size BYTES"
  echo "  --duration SECONDS     (default: 10)"
  echo "  --keep                 keep namespaces after test"
  echo "  --cleanup              restore interfaces"
  exit 0
}

require_root() { [ "$(id -u)" -eq 0 ] || { err "Run as root"; exit 1; }; }

ns_exists() { ip netns list | awk '{print $1}' | grep -qx "$1"; }

force_down_root() {
  local ifn="$1"
  ip link show "$ifn" >/dev/null 2>&1 || { err "Interface $ifn not found in root namespace"; exit 1; }
  ip addr flush dev "$ifn" || true
  ip link set dev "$ifn" down
}

link_is_up() {
  local ifn="$1"
  # operstate must be up
  local op
  op=$(cat /sys/class/net/"$ifn"/operstate)
  [ "$op" = "up" ] || return 1
  # carrier must be 1 (if exists)
  if [ -r "/sys/class/net/$ifn/carrier" ]; then
    [ "$(cat /sys/class/net/$ifn/carrier)" = "1" ] || return 1
  fi
  return 0
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

  log "Cleanup complete"
}

# CRC counters from sysfs
get_crc() {
  ip netns exec "$1" cat "/sys/class/net/$2/statistics/rx_crc_errors" 2>/dev/null || echo 0
}

get_packets() {
  ip netns exec "$1" cat "/sys/class/net/$2/statistics/${3}_packets" 2>/dev/null || echo 0
}

# ------ create topology ------
create_topology() {
  force_down_root "$SRC_IF"
  force_down_root "$DST_IF"

  # Check that BOTH interfaces are physically LINK UP in root (carrier)
  # → ensures external cable/media-path OK BEFORE moving to namespaces
  if ! link_is_up "$SRC_IF"; then
    err "Source interface $SRC_IF has NO CARRIER. Check cable."
    exit 1
  fi
  if ! link_is_up "$DST_IF"; then
    err "Destination interface $DST_IF has NO CARRIER. Check cable."
    exit 1
  fi

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

  echo
  echo "=== LINK CHECK ==="
  ip -n "$NS_SRC" link show "$SRC_IF"
  ip -n "$NS_DST" link show "$DST_IF"

  # Show CRC existing
  local crc_src_before crc_dst_before
  crc_src_before=$(get_crc "$NS_SRC" "$SRC_IF")
  crc_dst_before=$(get_crc "$NS_DST" "$DST_IF")

  echo
  read -r -p "Press ENTER to start ping flood for ${DURATION}s..."

  local tx_before rx_before
  tx_before=$(get_packets "$NS_SRC" "$SRC_IF" tx)
  rx_before=$(get_packets "$NS_DST" "$DST_IF" rx)

  echo "Running: ping -f -s $PAYLOAD -w $DURATION $dst_ip"
  ip netns exec "$NS_SRC" $PING_BIN -f -s "$PAYLOAD" -w "$DURATION" "$dst_ip"

  local tx_after rx_after
  tx_after=$(get_packets "$NS_SRC" "$SRC_IF" tx)
  rx_after=$(get_packets "$NS_DST" "$DST_IF" rx)

  local crc_src_after crc_dst_after
  crc_src_after=$(get_crc "$NS_SRC" "$SRC_IF")
  crc_dst_after=$(get_crc "$NS_DST" "$DST_IF")

  echo
  echo "=== RESULTS ==="
  echo "TX packets delta: $((tx_after - tx_before))"
  echo "RX packets delta: $((rx_after - rx_before))"
  echo "CRC src delta:    $((crc_src_after - crc_src_before))"
  echo "CRC dst delta:    $((crc_dst_after - crc_dst_before))"
}

# ---------- arg parsing ----------
[ $# -eq 0 ] && usage

while [ $# -gt 0 ]; do
  case "$1" in
    --src-if) SRC_IF="$2"; shift 2 ;;
    --dst-if) DST_IF="$2"; shift 2 ;;
    --src-ip) IP_SRC="$2"; shift 2 ;;
    --dst-ip) IP_DST="$2"; shift 2 ;;
    --mtu) MTU="$2"; shift 2 ;;
    -S|--size) PAYLOAD="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --keep) KEEP="1"; shift 1 ;;
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

# Auto cleanup unless --keep
if [ "$KEEP" != "1" ]; then
  trap cleanup EXIT
fi

create_topology
run_test

if [ "$KEEP" = "1" ]; then
  log "Namespaces kept. Run --cleanup manually."
fi
