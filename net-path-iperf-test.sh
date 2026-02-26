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
  echo "  --auto"
  echo "  --detect | -d"
  echo "  --src-if IF"
  echo "  --dst-if IF"
  echo "  --src-ip CIDR         (default: ${IP_SRC})"
  echo "  --dst-ip CIDR         (default: ${IP_DST})"
  echo "  --mtu BYTES           (default: ${MTU})"
  echo "  --size BYTES          (iperf3 -l, default: ${PAYLOAD})"
  echo "  --duration SEC        (default: ${DURATION})"
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
