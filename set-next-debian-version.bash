#!/bin/bash

# Setze die gewünschte Debian-Distribution
# Beispiele: stable, testing, bookworm, trixie, sid
DIST="${1:-trixie}"

# Zielpfad für die sources.list
OUTPUT="/etc/apt/sources.list"

cat > "$OUTPUT" <<EOF
# Generated sources.list for Debian ($DIST)
deb http://deb.debian.org/debian $DIST main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian $DIST main contrib non-free non-free-firmware

deb http://deb.debian.org/debian $DIST-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian $DIST-updates main contrib non-free non-free-firmware

deb http://security.debian.org/debian-security $DIST-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security $DIST-security main contrib non-free non-free-firmware
EOF

echo "sources.list wurde erzeugt: $OUTPUT"
echo "Distribution: $DIST"
