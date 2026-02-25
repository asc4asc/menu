#!/usr/bin/env bash
set -euo pipefail

# ANSI colors
RED="\033[0;31m"
GRN="\033[0;32m"
YLW="\033[1;33m"
NC="\033[0m"

# Unique namespace names per run
SELF_PID="$$"
NS_SRC="src-${SELF_PID}"
NS_DST="dst-${SELF_PID}"

SRC_IF=""
DST_IF=""

IP_SRC="10.10.10.1/30"
IP_DST="10.10.10.2/30"

MTU="1500"
PAYLOAD="56"
DURATION="10"
PRE_SLEEP="2"

UDP_MODE="0"
UDP_BITRATE="200M"

AUTO_MODE="0"
KEEP="0"
DO_CLEANUP="0"

STATE_FILE="/tmp/ns-iperf-${SELF_PID}.state"

log() { echo -e "[*] $*"; }
ok()  { echo -e "${GRN}[OK]${NC} $*"; }
err() { echo -e "${RED}[ERR]${NC} $*" >&2; }

usage() {
  echo "Usage:"
  echo "  sudo ./ns-test.sh [--auto] or --src-if X --dst-if Y [options]"
  echo ""
  echo "Options:"
  echo "  --auto"
  echo "  --src-if IF"
  echo "  --dst-if IF"
  echo "  --udp"
  echo "  --udp-bitrate <rate>"
  echo "  --size BYTES"
  echo "  --duration SEC"
  echo "  --keep"
  echo "  --cleanup"
  exit 0
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Run as root"
    exit 1
  fi
}

ns_exists() { ip netns list | awk '{print $1}' | grep -qx "$1"; }

# move interface back if inside a namespace
restore_if_in_ns() {
  local dev="$1"
  local ns
  ns=$(ip netns identify "$dev" 2>/dev/null || true)
  if [ -n "$ns" ]; then
    ip netns exec "$ns" ip link set "$dev" netns 1 || true
  fi
}

force_down_root() {
  local ifn="$1"
  if ip link show "$ifn" >/dev/null 2>&1; then
    ip addr flush dev "$ifn" || true
    ip link set dev "$ifn" down || true
  fi
}

safe_delete_ns() {
  local ns="$1"
  if ns_exists "$ns"; then
    # ip netns pids "$ns" | xargs -r kill -9 || true
    ; # ip netns delete "$ns" || true
  fi
}

cleanup() {
  log "Cleanup: restoring interfaces"

  for iface in "$SRC_IF" "$DST_IF"; do
    restore_if_in_ns "$iface"
  done

  safe_delete_ns "$NS_SRC"
  safe_delete_ns "$NS_DST"

  rm -f "$STATE_FILE" || true

  ok "Cleanup done"
}

get_crc() {
  ip netns exec "$1" cat "/sys/class/net/$2/statistics/rx_crc_errors" 2>/dev/null || echo 0
}

get_packets() {
  ip netns exec "$1" cat "/sys/class/net/$2/statistics/${3}_packets" 2>/dev/null || echo 0
}

save_state() {
  echo "NS_SRC=$NS_SRC" > "$STATE_FILE"
  echo "NS_DST=$NS_DST" >> "$STATE_FILE"
  echo "SRC_IF=$SRC_IF" >> "$STATE_FILE"
  echo "DST_IF=$DST_IF" >> "$STATE_FILE"
}

auto_select_ifaces() {
  log "Selecting interfaces automatically"
  local c=()
  for IF in $(ls /sys/class/net); do
    [ "$IF" = "lo" ] && continue
    [ "$(cat /sys/class/net/$IF/operstate)" = "up" ] || continue
    if [ -r "/sys/class/net/$IF/carrier" ]; then
      [ "$(cat /sys/class/net/$IF/carrier)" = "1" ] || continue
    fi
    if ip -4 addr show dev "$IF" | grep -q "inet "; then continue; fi
    c+=("$IF")
  done
  [ ${#c[@]} -lt 2 ] && { err "Not enough usable interfaces"; exit 1; }
  SRC_IF="${c[0]}"
  DST_IF="${c[1]}"
  ok "Selected SRC_IF=$SRC_IF DST_IF=$DST_IF"
}

create_topology() {
  cleanup || true

  restore_if_in_ns "$SRC_IF"
  restore_if_in_ns "$DST_IF"

  force_down_root "$SRC_IF"
  force_down_root "$DST_IF"

  ip netns add "$NS_SRC"
  ip netns add "$NS_DST"

  ip -n "$NS_SRC" link set lo up
  ip -n "$NS_DST" link set lo up

  ip link set "$SRC_IF" netns "$NS_SRC"
  ip link set "$DST_IF" netns "$NS_DST"

  ip -n "$NS_SRC" link set "$SRC_IF" mtu "$MTU" up
  ip -n "$NS_DST" link set "$DST_IF" mtu "$MTU" up

  ip -n "$NS_SRC" addr add "$IP_SRC" dev "$SRC_IF"
  ip -n "$NS_DST" addr add "$IP_DST" dev "$DST_IF"

  save_state
  ok "Topology created: $NS_SRC <-> $NS_DST"
}

run_test() {
  local dst_ip jitter="" server_pid=""
  dst_ip=$(ip -n "$NS_DST" -br addr show dev "$DST_IF" | awk '{print $3}' | cut -d/ -f1)

  sleep "$PRE_SLEEP"

  local crc_src_before crc_dst_before
  crc_src_before=$(get_crc "$NS_SRC" "$SRC_IF")
  crc_dst_before=$(get_crc "$NS_DST" "$DST_IF")

  local tx_before rx_before
  tx_before=$(get_packets "$NS_SRC" "$SRC_IF" tx)
  rx_before=$(get_packets "$NS_DST" "$DST_IF" rx)

  # start server ALWAYS without -u
  ip netns exec "$NS_DST" iperf3 -s -D
  sleep 1

  # get server pid from namespace
  server_pid=$(ip netns exec "$NS_DST" pgrep -f "iperf3 -s" | head -n1)

  if [ -z "$server_pid" ]; then
    err "iperf3 server did not start"
    exit 1
  fi

  if [ "$UDP_MODE" = "1" ]; then
    IPERF_CMD="iperf3 -u -b $UDP_BITRATE -c $dst_ip -t $DURATION -l $PAYLOAD"
  else
    IPERF_CMD="iperf3 -c $dst_ip -t $DURATION -l $PAYLOAD"
  fi

  set +e
  IPERF_OUT="$(ip netns exec "$NS_SRC" $IPERF_CMD 2>&1)"
  IPERF_RC=$?
  set -e

  # kill only THIS iperf3 server
  ip netns exec "$NS_DST" kill -9 "$server_pid" || true

  if [ "$UDP_MODE" = "1" ]; then
    jitter=$(echo "$IPERF_OUT" | awk '/ms/{print $(NF-1)}' | sed 's/ms//')
  fi

  local tx_after rx_after
  tx_after=$(get_packets "$NS_SRC" "$SRC_IF" tx)
  rx_after=$(get_packets "$NS_DST" "$DST_IF" rx)

  local crc_src_after crc_dst_after
  crc_src_after=$(get_crc "$NS_SRC" "$SRC_IF")
  crc_dst_after=$(get_crc "$NS_DST" "$DST_IF")

  echo "=== RESULTS ==="
  echo "TX: $((tx_after - tx_before))"
  echo "RX: $((rx_after - rx_before))"
  echo "CRC SRC: $((crc_src_after - crc_src_before))"
  echo "CRC DST: $((crc_dst_after - crc_dst_before))"

  if [ "$UDP_MODE" = "1" ]; then
    echo "UDP Jitter: ${jitter:-N/A} ms"
  fi

  echo "$IPERF_OUT"

  [ $IPERF_RC -ne 0 ] && err "iperf3 exit code: $IPERF_RC" || ok "iperf3 test OK"
}

# ---------- arg parsing ----------
[ $# -eq 0 ] && usage

while [ $# -gt 0 ]; do
  case "$1" in
    --auto) AUTO_MODE="1"; shift 1 ;;
    --src-if) SRC_IF="$2"; shift 2 ;;
    --dst-if) DST_IF="$2"; shift 2 ;;
    --udp) UDP_MODE="1"; shift 1 ;;
    --udp-bitrate) UDP_BITRATE="$2"; shift 2 ;;
    --size) PAYLOAD="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --keep) KEEP="1"; shift 1 ;;
    --cleanup) DO_CLEANUP="1"; shift 1 ;;
    *) err "Unknown option"; usage ;;
  esac
done

require_root

[ "$DO_CLEANUP" = "1" ] && cleanup && exit 0
[ "$AUTO_MODE" = "1" ] && auto_select_ifaces

[ "$KEEP" != "1" ] && trap cleanup EXIT

create_topology
run_test

[ "$KEEP" = "1" ] && log "Namespaces kept: $NS_SRC $NS_DST"
