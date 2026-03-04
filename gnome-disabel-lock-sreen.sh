#!/usr/bin/env bash
# gnome-no-lock.sh
# Deaktiviert den GNOME-Sperrbildschirm in einer VM (VirtualBox) zuverlässig.
# Erstellt ein Backup der relevanten Einstellungen.
# Optional: störende Locker beenden, GNOME-Extensions deaktivieren, Auto-Unlock-Fallback aktivieren.

set -euo pipefail

# ------------------------------
# Optionen
# ------------------------------
DISABLE_EXTENSIONS=false     # --disable-extensions  → alle Extensions temporär deaktivieren
STOP_VBOXCLIENT=false        # --stop-vboxclient     → VBoxClient-Prozesse beenden (Diagnose/Workaround)
ENABLE_AUTO_UNLOCK=false     # --enable-auto-unlock  → systemd-User-Timer entsperrt bei Bedarf automatisch
VERBOSE=true

for arg in "$@"; do
  case "$arg" in
    --disable-extensions) DISABLE_EXTENSIONS=true ;;
    --stop-vboxclient)    STOP_VBOXCLIENT=true ;;
    --enable-auto-unlock) ENABLE_AUTO_UNLOCK=true ;;
    --quiet)              VERBOSE=false ;;
    -h|--help)
      cat <<'EOF'
Usage: ./gnome-no-lock.sh [--disable-extensions] [--stop-vboxclient] [--enable-auto-unlock] [--quiet]

Ohne Flags: Setzt nur die notwendigen GNOME/dconf-Schalter.
  --disable-extensions   Deaktiviert alle GNOME-Extensions (temporär, bis Re-Login/Neustart Shell)
  --stop-vboxclient      Stoppt VBoxClient-Prozesse (Clipboard/Display/Drag&Drop/Seamless)
  --enable-auto-unlock   Aktiviert einen systemd-User-Timer, der eine gelockte Session automatisch entsperrt
  --quiet                Weniger Ausgabe
EOF
      exit 0
      ;;
    *)
      echo "Unbekannte Option: $arg" >&2
      exit 2
      ;;
  esac
done

log() { $VERBOSE && echo -e "$*"; }

# ------------------------------
# Vorbedingungen prüfen
# ------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1"; exit 1; }; }
need_cmd gsettings
need_cmd dconf
need_cmd loginctl

# ------------------------------
# Backup anlegen
# ------------------------------
TS=$(date +%F_%H%M%S)
BACKUP="$HOME/gnome-unlock-backup-$TS.txt"
{
  echo "# GNOME No-Lock Backup $TS"
  echo "# User: $USER"
  echo "# Session:"
  loginctl list-sessions
  echo

  echo "# gsettings org.gnome.desktop.screensaver"
  for k in lock-enabled idle-activation-enabled; do
    echo "$k = $(gsettings get org.gnome.desktop.screensaver "$k" 2>/dev/null || echo "<n/a>")"
  done

  echo "# gsettings org.gnome.settings-daemon.plugins.power"
  for k in idle-dim; do
    echo "$k = $(gsettings get org.gnome.settings-daemon.plugins.power "$k" 2>/dev/null || echo "<n/a>")"
  done

  echo "# gsettings org.gnome.settings-daemon.plugins.media-keys"
  echo "screensaver = $(gsettings get org.gnome.settings-daemon.plugins.media-keys screensaver 2>/dev/null || echo "<n/a>")"

  echo "# (Ubuntu) ubuntu-lock-on-suspend"
  echo "ubuntu-lock-on-suspend = $(gsettings get org.gnome.desktop.screensaver ubuntu-lock-on-suspend 2>/dev/null || echo "<n/a>")"

  echo "# dconf Werte"
  echo "/org/gnome/desktop/session/idle-delay = $(dconf read /org/gnome/desktop/session/idle-delay 2>/dev/null || echo "<n/a>")"
  echo "/org/gnome/desktop/screensaver/allow-lock-screen = $(dconf read /org/gnome/desktop/screensaver/allow-lock-screen 2>/dev/null || echo "<n/a>")"
  echo "/org/gnome/desktop/lockdown/disable-lock-screen = $(dconf read /org/gnome/desktop/lockdown/disable-lock-screen 2>/dev/null || echo "<n/a>")"
} > "$BACKUP"

log "Backup erstellt: $BACKUP"

# ------------------------------
# Kern-Einstellungen setzen
# ------------------------------
log "Setze GNOME/dconf-Einstellungen (Sperre vollständig deaktivieren)…"

# 1) GNOME darf grundsätzlich nicht sperren (Lockdown + Screensaver-Allow)
dconf write /org/gnome/desktop/lockdown/disable-lock-screen true
dconf write /org/gnome/desktop/screensaver/allow-lock-screen false

# 2) Klassische Screensaver/Idle-Schalter
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.desktop.screensaver idle-activation-enabled false

# 3) Ubuntu-spezifisch (falls vorhanden): nicht beim Suspend sperren
if gsettings get org.gnome.desktop.screensaver ubuntu-lock-on-suspend >/dev/null 2>&1; then
  gsettings set org.gnome.desktop.screensaver ubuntu-lock-on-suspend false
fi

# 4) Idle komplett deaktivieren, kein Dimmen
dconf write /org/gnome/desktop/session/idle-delay 0
gsettings set org.gnome.settings-daemon.plugins.power idle-dim false

# 5) Hotkey (Super+L / Screensaver) neutralisieren
gsettings set org.gnome.settings-daemon.plugins.media-keys screensaver "''"

# ------------------------------
# Störende Fremd-Locker entfernen (optional)
# ------------------------------
# Falls diese Tools aktiv sind, überfahren sie GNOME (v. a. unter X11)
for p in xscreensaver xss-lock light-locker; do
  if pgrep -a "$p" >/dev/null 2>&1; then
    log "Beende Fremd-Locker: $p"
    pkill -9 "$p" || true
  fi
done

# ------------------------------
# VBoxClient-Trigger stoppen (optional)
# ------------------------------
if $STOP_VBOXCLIENT; then
  log "Stoppe VBoxClient-Prozesse (Display/Clipboard/Drag&Drop/Seamless)…"
  pkill -f VBoxClient || true
fi

# ------------------------------
# GNOME-Extensions deaktivieren (optional)
# ------------------------------
if $DISABLE_EXTENSIONS; then
  if command -v gnome-extensions >/dev/null 2>&1; then
    log "Deaktiviere alle GNOME-Extensions (temporär)…"
    # Liste holen und alle deaktivieren
    while read -r ext; do
      [ -n "$ext" ] && gnome-extensions disable "$ext" || true
    done < <(gnome-extensions list)
  else
    log "Hinweis: gnome-extensions CLI nicht vorhanden – überspringe."
  fi
fi

# ------------------------------
# Optional: Auto-Unlock-Fallback (systemd --user)
# ------------------------------
if $ENABLE_AUTO_UNLOCK; then
  log "Aktiviere Auto-Unlock (systemd --user Timer)…"
  mkdir -p "$HOME/.config/systemd/user"

  cat > "$HOME/.config/systemd/user/gnome-auto-unlock.service" << 'EOF'
[Unit]
Description=Auto-unlock GNOME session if it gets locked

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'sid=$(loginctl list-sessions --no-legend | awk -v u="$USER" '\''$3==u {print $1; exit}'\''); [ -n "$sid" ] && loginctl unlock-session "$sid"'
EOF

  cat > "$HOME/.config/systemd/user/gnome-auto-unlock.timer" << 'EOF'
[Unit]
Description=Periodically auto-unlock GNOME session

[Timer]
OnUnitActiveSec=2s
Unit=gnome-auto-unlock.service

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now gnome-auto-unlock.timer
fi

# ------------------------------
# Ergebnis anzeigen
# ------------------------------
log "Prüfe gesetzte Werte:"
echo "lock-enabled                  = $(gsettings get org.gnome.desktop.screensaver lock-enabled)"
echo "idle-activation-enabled       = $(gsettings get org.gnome.desktop.screensaver idle-activation-enabled)"
echo "ubuntu-lock-on-suspend        = $(gsettings get org.gnome.desktop.screensaver ubuntu-lock-on-suspend 2>/dev/null || echo '<n/a>')"
echo "idle-delay                    = $(dconf read /org/gnome/desktop/session/idle-delay)"
echo "allow-lock-screen             = $(dconf read /org/gnome/desktop/screensaver/allow-lock-screen)"
echo "lockdown.disable-lock-screen  = $(dconf read /org/gnome/desktop/lockdown/disable-lock-screen)"
echo "media-keys.screensaver        = $(gsettings get org.gnome.settings-daemon.plugins.media-keys screensaver)"
echo "power.idle-dim                = $(gsettings get org.gnome.settings-daemon.plugins.power idle-dim)"

echo
echo "Hinweis:"
echo "- Unter X11 kannst du die GNOME Shell mit Alt+F2, 'r', Enter neu starten."
echo "- Unter Wayland bitte einmal ab- und wieder anmelden."
echo

B
echo "Fertig. Falls weiterhin eine Sperre auftritt, starte einmal neu oder nutze --enable-auto-unlock."
