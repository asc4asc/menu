#!/usr/bin/env bash
set -euo pipefail

# ANSI colors
RED="\033[0;31m"
GRN="\033[0;32m"
YLW="\033[1;33m"
NC="\033[0m"

# Unique namespace names per run (prevents collisions)
SELF_PID="$$"
NS_SRC="src-${SELF_PID}"
NS_DST="dst-${SELF_PID}"

SRC_IF=""
DST_IF=""

IP_SRC="10.10.10.1/30"
IP_DST="10.10.10.2/30"

MTU="1500"
PAYLOAD="56"       # iperf3 -l (Bytes)
DURATION="10"
PRE_SLEEP="2"

UDP_MODE="0"
UDP_BITRATE="200M" # iperf3 -b bei UDP verpflichtend

AUTO_MODE="0"
KEEP="0"
DO_CLEANUP="0"
DETECT_MODE="0"

# Eigener Port pro Lauf (Default: zufällig im Ephemeral-Bereich)
# Kann per --port überschrieben werden
IPERF_PORT="$(shuf -i 20000-60999 -n 1)"

STATE_FILE="/tmp/ns-iperf-${SELF_PID}.state"

log() { echo -e "[*] $*"; }
ok()  { echo -e "${GRN}[OK]${NC} $*"; }
err() { echo -e "${RED}[ERR]${NC} $*" >&2; }

usage() {
  echo "Usage:"
  echo "  sudo ./ns-iperf.sh [--auto] or --src-if X --dst-if Y [options]"
  echo ""
  echo "Options:"
  echo "  --auto -a"
  echo "  --detect | -d"
  echo "  --src-if IF"
  echo "  --dst-if IF"
  echo "  --src-ip CIDR         (default: ${IP_SRC})"
  echo "  --dst-ip CIDR         (default: ${IP_DST})"
  echo "  --mtu BYTES           (default: ${MTU})"
  echo "  --size BYTES          (iperf3 -l, default: ${PAYLOAD})"
  echo "  --duration SEC -D SEC (default: ${DURATION})"
  echo "  --pre-sleep SEC       (default: ${PRE_SLEEP})"
  echo "  --port N              (server/client port, default random: ${IPERF_PORT})"
  echo "  --udp"
  echo "  --udp-bitrate RATE    (e.g. 200M)"
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

# Move interface back to root if inside any namespace
restore_if_in_ns() {
  local dev="$1"
  local ns
  ns=$(ip netns identify "$dev" 2>/dev/null || true)
  if [ -n "${ns}" ]; then
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
    ip netns pids "$ns" | xargs -r kill -9 || true
    ip netns delete "$ns" || true
  fi
}

cleanup() {
  log "Cleanup: restoring interfaces"

  for iface in "$SRC_IF" "$DST_IF"; do
    [ -n "$iface" ] && restore_if_in_ns "$iface"
  done

  safe_delete_ns "$NS_SRC"
  safe_delete_ns "$NS_DST"

  rm -f "$STATE_FILE" || true

  ok "Cleanup complete"
}

get_crc() {
  ip netns exec "$1" cat "/sys/class/net/$2/statistics/rx_crc_errors" 2>/dev/null || echo 0
}

get_packets() {
  ip netns exec "$1" cat "/sys/class/net/$2/statistics/${3}_packets" 2>/dev/null || echo 0
}

save_state() {
  {
    echo "NS_SRC=$NS_SRC"
    echo "NS_DST=$NS_DST"
    echo "SRC_IF=$SRC_IF"
    echo "DST_IF=$DST_IF"
    echo "IPERF_PORT=$IPERF_PORT"
  } > "$STATE_FILE"
}

auto_select_ifaces() {
  log "Auto-selecting interfaces"
  local c=()
  for IF in $(ls /sys/class/net); do
    [ "$IF" = "lo" ] && continue
    [ -r "/sys/class/net/$IF/operstate" ] || continue
    [ "$(cat /sys/class/net/$IF/operstate)" = "up" ] || continue
    if [ -r "/sys/class/net/$IF/carrier" ]; then
      [ "$(cat /sys/class/net/$IF/carrier)" = "1" ] || continue
    fi
    if ip -4 addr show dev "$IF" | grep -q "inet "; then continue; fi
    c+=("$IF")
  done
  if [ ${#c[@]} -lt 2 ]; then
    err "AUTO mode: less than two valid interfaces found."
    exit 1
  fi
  SRC_IF="${c[0]}"
  DST_IF="${c[1]}"
  ok "Selected: SRC_IF=$SRC_IF DST_IF=$DST_IF"
}

create_topology() {
  # do NOT global cleanup of others; only our IFs
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
  ok "Topology ready: $NS_SRC <-> $NS_DST"
}

start_iperf_server() {
  # Server IMMER ohne -u starten, auf eigenem Port; PID exakt erfassen
  local pid
  pid="$(ip netns exec "$NS_DST" sh -c "nohup iperf3 -s -p $IPERF_PORT >/dev/null 2>&1 & echo \$!")"
  # Kurzes Warten und Prüfung, dass der Port lauscht
  sleep 0.3
  # optionaler Check: falls ss vorhanden
  if ip netns exec "$NS_DST" command -v ss >/dev/null 2>&1; then
    ip netns exec "$NS_DST" ss -lntup 2>/dev/null | grep -q ":$IPERF_PORT " || true
  fi
  echo "$pid"
}

stop_iperf_server() {
  local pid="$1"
  # Nur diesen konkreten Prozess beenden (kein pkill)
  ip netns exec "$NS_DST" sh -c "
    kill -TERM $pid 2>/dev/null || true
    for i in \$(seq 1 20); do
      kill -0 $pid 2>/dev/null || exit 0
      sleep 0.1
    done
    kill -KILL $pid 2>/dev/null || true
  "
}

# ----------------- iperf3 test -----------------
run_test() {
  local dst_ip jitter="" server_pid=""
  dst_ip=$(ip -n "$NS_DST" -br addr show dev "$DST_IF" | awk '{print $3}' | cut -d/ -f1)

  echo -e "${YLW}Sleeping ${PRE_SLEEP}s before iperf3...${NC}"
  sleep "$PRE_SLEEP"

  local crc_src_before crc_dst_before
  crc_src_before=$(get_crc "$NS_SRC" "$SRC_IF")
  crc_dst_before=$(get_crc "$NS_DST" "$DST_IF")

  local tx_before rx_before
  tx_before=$(get_packets "$NS_SRC" "$SRC_IF" tx)
  rx_before=$(get_packets "$NS_DST" "$DST_IF" rx)

  server_pid="$(start_iperf_server)"
  if [ -z "$server_pid" ]; then
    err "Failed to start iperf3 server"
    exit 1
  fi

  local IPERF_CMD
  if [ "$UDP_MODE" = "1" ]; then
    IPERF_CMD="iperf3 -u -b $UDP_BITRATE -c $dst_ip -p $IPERF_PORT -t $DURATION -l $PAYLOAD"
  else
    IPERF_CMD="iperf3 -c $dst_ip -p $IPERF_PORT -t $DURATION -l $PAYLOAD"
  fi

  set +e
  IPERF_OUT="$(ip netns exec "$NS_SRC" $IPERF_CMD 2>&1)"
  IPERF_RC=$?
  set -e

  # Nur unseren eigenen Server beenden
  stop_iperf_server "$server_pid"

  # UDP Jitter extrahieren (letzte Zeile mit 'ms' aus dem Summen-/Receiver-Block)
  if [ "$UDP_MODE" = "1" ]; then
    # Greife die letzte sinnvolle Zeile mit 'ms' (Jitter) ab und ziehe die Zahl vor 'ms'
    jitter="$(echo "$IPERF_OUT" \
      | awk '/sec/ && /ms/ {line=$0} END{print line}' \
      | awk '{for(i=1;i<=NF;i++){if($i ~ /ms$/){gsub(/ms/,"",$i);v=$i}}} END{if(v!="")print v}')"
  fi

  local tx_after rx_after
  tx_after=$(get_packets "$NS_SRC" "$SRC_IF" tx)
  rx_after=$(get_packets "$NS_DST" "$DST_IF" rx)

  local crc_src_after crc_dst_after
  crc_src_after=$(get_crc "$NS_SRC" "$SRC_IF")
  crc_dst_after=$(get_crc "$NS_DST" "$DST_IF")

  echo
  echo "=== RESULTS ==="
  echo "Namespace SRC: ${NS_SRC} | DST: ${NS_DST}"
  echo "Port: $IPERF_PORT"
  echo "TX packets delta: $((tx_after - tx_before))"
  echo "RX packets delta: $((rx_after - rx_before))"
  echo "CRC src delta: $((crc_src_after - crc_src_before))"
  echo "CRC dst delta: $((crc_dst_after - crc_dst_before))"
  if [ "$UDP_MODE" = "1" ]; then
    echo "UDP Jitter: ${jitter:-N/A} ms"
  fi

  echo
  echo "$IPERF_OUT"

  if [ $IPERF_RC -ne 0 ]; then
    err "iperf3 exit code: $IPERF_RC"
  else
    ok "iperf3 completed successfully"
  fi
}

detect_mode_run() {
  log "--detect: Ermittele DOWN-Interfaces ohne IPv4"
  local c=()
  for IF in $(ls /sys/class/net); do
    [ "$IF" = "lo" ] && continue
    if ip -4 addr show dev "$IF" | grep -q "inet "; then continue; fi
    [ -r "/sys/class/net/$IF/operstate" ] || continue
    [ "$(cat /sys/class/net/$IF/operstate)" = "up" ] || continue
    c+=("$IF")
  done
  if [ ${#c[@]} -lt 2 ]; then
    err "--detect: weniger als zwei geeignete DOWN-Interfaces gefunden."
    exit 1
  fi
  ok "Vorgeschlagene DOWN-Interfaces:"
  echo "  SRC_IF = ${c[0]}"
  echo "  DST_IF = ${c[1]}"
  echo
  ethtool --identify "${c[0]}" 3 || true
  ethtool --identify "${c[1]}" 3 || true
  ok "Blinken abgeschlossen"
  exit 0
}

# ---------- arg parsing ----------
[ $# -eq 0 ] && usage

while [ $# -gt 0 ]; do
  case "$1" in
    --auto|-a) AUTO_MODE="1"; shift 1 ;;
    --detect|-d) DETECT_MODE="1"; shift 1 ;;
    --src-if) SRC_IF="$2"; shift 2 ;;
    --dst-if) DST_IF="$2"; shift 2 ;;
    --src-ip) IP_SRC="$2"; shift 2 ;;
    --dst-ip) IP_DST="$2"; shift 2 ;;
    --mtu) MTU="$2"; shift 2 ;;
    --size) PAYLOAD="$2"; shift 2 ;;
    --duration|-D) DURATION="$2"; shift 2 ;;
    --pre-sleep) PRE_SLEEP="$2"; shift 2 ;;
    --port) IPERF_PORT="$2"; shift 2 ;;
    --udp) UDP_MODE="1"; shift 1 ;;
    --udp-bitrate) UDP_BITRATE="$2"; shift 2 ;;
    --keep) KEEP="1"; shift 1 ;;
    --cleanup) DO_CLEANUP="1"; shift 1 ;;
    -h|--help|-\?) usage ;;
    *) err "Unknown option: $1"; usage ;;
  esac
done

require_root

if [ "$DETECT_MODE" = "1" ]; then
  detect_mode_run
fi

if [ "$DO_CLEANUP" = "1" ]; then
  cleanup
  exit 0
fi

if [ "$AUTO_MODE" = "1" ]; then
  auto_select_ifaces
fi

if [ -z "$SRC_IF" ] || [ -z "$DST_IF" ]; then
  err "You must specify --auto or --src-if and --dst-if"
  exit 1
fi

# Auto-cleanup unless keeping
if [ "$KEEP" != "1" ]; then
  trap cleanup EXIT
fi

create_topology
run_test

if [ "$KEEP" = "1" ]; then
  log "Namespaces kept. Run --cleanup manually."
fi
