#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
UEFI BootOrder ändern und wiederherstellen (Linux, efibootmgr).

Funktionen:
- Zielauswahl per Name (--name, case-insensitive; optional --exact) oder per ID (--id)
- Backup in Textdatei (BootOrder + Beschreibungen)
- Wiederherstellung aus Backup (optional)
- Interaktiv (Default) oder nicht-interaktiv (--no-prompt)

Ablauf:
1) Aktuelle BootOrder + Einträge lesen
2) Backup schreiben
3) Ziel (Name/ID) vorn priorisieren und BootOrder setzen
4) Warten (oder nicht, per --no-prompt)
5) Wiederherstellen (Originalzustand oder aus Backup, per --restore-from-backup)

Exit-Codes:
- 0: Erfolg
- 1: Definierter Fehler (BootOrderError)
- 2: Unerwarteter Fehler (Exception)
"""

import subprocess
import re
import sys
import shutil
import logging
import argparse
from typing import List, Dict, Tuple
from pathlib import Path
from datetime import datetime

EFIBOOTMGR_CMD = "efibootmgr"
SUBPROC_TIMEOUT = 10  # Sekunden
DEFAULT_BACKUP_PATH = "/var/backups/bootorder.txt"

# --- Logging Setup (Standard INFO) ---
logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")


class BootOrderError(Exception):
    """Spezifische Ausnahme für Boot-Order-Operationen."""
    pass


def ensure_root() -> None:
    if hasattr(sys, "getuid") and sys.getuid() != 0:
        raise BootOrderError("Dieses Skript muss mit Root-Rechten ausgeführt werden (sudo).")


def ensure_efibootmgr_available() -> None:
    if shutil.which(EFIBOOTMGR_CMD) is None:
        raise BootOrderError("efibootmgr ist nicht installiert oder nicht im PATH.")


def run_efibootmgr(args: List[str]) -> str:
    try:
        result = subprocess.run(
            [EFIBOOTMGR_CMD] + args,
            capture_output=True,
            text=True,
            check=False,
            timeout=SUBPROC_TIMEOUT
        )
    except subprocess.TimeoutExpired as e:
        raise BootOrderError(f"efibootmgr-Zugriff hat das Timeout ({SUBPROC_TIMEOUT}s) überschritten.") from e
    except OSError as e:
        raise BootOrderError("efibootmgr konnte nicht ausgeführt werden (OSError).") from e

    if result.returncode != 0:
        raise BootOrderError(f"efibootmgr-Fehler (rc={result.returncode}).")
    if not result.stdout.strip():
        raise BootOrderError("efibootmgr lieferte leere Ausgabe.")
    return result.stdout


def parse_boot_order(output: str) -> List[str]:
    m = re.search(r"^BootOrder:\s*([0-9A-Fa-f,]+)\s*$", output, re.MULTILINE)
    if not m:
        raise BootOrderError("BootOrder konnte aus efibootmgr-Ausgabe nicht geparst werden.")
    order = [x.lower() for x in m.group(1).split(",")]
    if not order or any(not re.fullmatch(r"[0-9a-f]{4}", x) for x in order):
        raise BootOrderError(f"BootOrder-Format ungültig: {order}")
    return order


def parse_entries(output: str) -> Dict[str, str]:
    entries: Dict[str, str] = {}
    for line in output.splitlines():
        m = re.match(r"^Boot([0-9A-Fa-f]{4})\*?\s+(.*)$", line.strip())
        if m:
            entries[m.group(1).lower()] = m.group(2).strip()
    if not entries:
        raise BootOrderError("Keine Boot-Einträge gefunden.")
    return entries


def get_current_state() -> Tuple[List[str], Dict[str, str]]:
    out = run_efibootmgr([])
    order = parse_boot_order(out)
    entries = parse_entries(out)
    missing = [x for x in order if x not in entries]
    if missing:
        raise BootOrderError(f"BootOrder enthält unbekannte IDs: {', '.join(missing)}")
    return order, entries


def set_boot_order(order: List[str]) -> None:
    if not order:
        raise BootOrderError("Leere BootOrder kann nicht gesetzt werden.")
    if any(not re.fullmatch(r"[0-9a-f]{4}", x) for x in order):
        raise BootOrderError(f"Ungültige Boot-ID im Order: {order}")
    order_str = ",".join(x.upper() for x in order)
    logging.info(f"Setze BootOrder: {order_str}")
    run_efibootmgr(["-o", order_str])


def select_target_by_name(entries: Dict[str, str], name: str, exact: bool = False) -> str:
    name_ci = name.lower()
    matches: List[Tuple[str, str]] = []
    for bid, desc in entries.items():
        d_ci = desc.lower()
        if (d_ci == name_ci) if exact else (name_ci in d_ci):
            matches.append((bid, desc))
    if not matches:
        raise BootOrderError(f"Kein Eintrag gefunden für Name='{name}' (exact={exact}).")
    if len(matches) > 1:
        details = "; ".join(f"{bid.upper()}:{desc}" for bid, desc in matches)
        raise BootOrderError(f"Mehrdeutig: mehrere Einträge gefunden: {details}. Nutzen Sie --exact oder --id.")
    sel = matches[0][0]
    logging.info(f"Name-Ziel gewählt: {sel.upper()} -> {matches[0][1]}")
    return sel


def write_backup(path: Path, order: List[str], entries: Dict[str, str]) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8") as f:
            ts = datetime.now().isoformat()
            f.write(f"# Backup erstellt: {ts}")
            f.write("BootOrder=" + ",".join(x.upper() for x in order) + " ")
            for bid, desc in entries.items():
                f.write(f"BootEntry {bid.upper()}={desc} ")
        logging.info(f"Backup geschrieben: {path}")
    except Exception as e:
        raise BootOrderError(f"Backup konnte nicht geschrieben werden: {path} ({e})") from e


def read_backup_order(path: Path) -> List[str]:
    if not path.exists():
        raise BootOrderError(f"Backup-Datei nicht gefunden: {path}")
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
        line = next((l for l in lines if l.strip().startswith("BootOrder=")), None)
        if not line:
            raise BootOrderError("BootOrder= Zeile im Backup fehlt.")
        val = line.strip().split("=", 1)[1].strip()
        ids = [x.lower() for x in val.split(",")]
        if not ids or any(not re.fullmatch(r"[0-9a-f]{4}", x) for x in ids):
            raise BootOrderError(f"Ungültige BootOrder im Backup: {val}")
        return ids
    except Exception as e:
        raise BootOrderError(f"Backup konnte nicht gelesen werden: {path} ({e})") from e


def validate_ids_exist(ids: List[str], entries: Dict[str, str]) -> None:
    missing = [x for x in ids if x not in entries]
    if missing:
        raise BootOrderError(
            "Backup/Order enthält unbekannte IDs (aktuell nicht vorhanden): "
            + ", ".join(x.upper() for x in missing)
        )


def build_arg_parser() -> argparse.ArgumentParser:
    examples = r"""
Beispiele:
  # Ziel per Name (Substring), Backup Default-Pfad, interaktive Rückkehr
  sudo ./bootorder.py --name "Ubuntu"

  # Exakter Name (case-insensitive), kein Prompt, Backup an anderem Ort
  sudo ./bootorder.py --name "Windows Boot Manager" --exact --backup /root/bootorder_bak.txt --no-prompt

  # Ziel per ID, danach explizite Wiederherstellung aus Backupdatei
  sudo ./bootorder.py --id 0003 --restore-from-backup

  # Nur Hilfe anzeigen
  ./bootorder.py -h
"""
    p = argparse.ArgumentParser(
        prog="bootorder.py",
        description="UEFI BootOrder ändern und zurücksetzen (Linux, efibootmgr) mit Name-Targeting und Backup.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=examples
    )
    p.add_argument("-V", "--version", action="version", version="bootorder.py 1.0")

    target = p.add_mutually_exclusive_group(required=True)
    target.add_argument("--name", type=str,
                        help="Ziel nach Name (case-insensitive). Beispiel: --name 'Ubuntu'")
    target.add_argument("--id", type=lambda s: s.lower(),
                        help="Ziel nach ID (hex, 4 Stellen, z. B. 0003)")

    p.add_argument("--exact", action="store_true",
                   help="Exakter Namensabgleich (ganze Zeichenkette) statt Substring.")
    p.add_argument("--backup", type=Path, default=Path(DEFAULT_BACKUP_PATH),
                   help=f"Pfad zur Backup-Datei (Default: {DEFAULT_BACKUP_PATH})")
    p.add_argument("--restore-from-backup", action="store_true",
                   help="Wiederherstellung aus Backup-Datei statt Originalzustand im Speicher.")
    p.add_argument("--no-prompt", action="store_true",
                   help="Kein Warten auf Enter; sofortige Wiederherstellung einleiten.")
    p.add_argument("--verbose", action="store_true",
                   help="Ausführliche Logausgabe (DEBUG).")

    return p


def main():
    parser = build_arg_parser()
    args = parser.parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
        logging.debug("Verbose-Modus aktiv (DEBUG).")

    try:
        ensure_root()
        ensure_efibootmgr_available()

        # 1) Zustand lesen
        original_order, entries = get_current_state()
        logging.info("Aktuelle BootOrder: %s", ", ".join(x.upper() for x in original_order))
        logging.debug("Einträge: %s", ", ".join(f"{k.upper()}:{v}" for k, v in entries.items()))

        # 2) Backup
        write_backup(args.backup, original_order, entries)

        # 3) Ziel bestimmen
        if args.id:
            if not re.fullmatch(r"[0-9a-f]{4}", args.id):
                raise BootOrderError(f"Ungültige Ziel-ID: {args.id}")
            if args.id not in entries:
                raise BootOrderError(f"Ziel-ID {args.id.upper()} existiert nicht.")
            target_entry = args.id
            logging.info(f"ID-Ziel gewählt: {target_entry.upper()} -> {entries[target_entry]}")
        else:
            target_entry = select_target_by_name(entries, args.name, exact=args.exact)

        # 4) Neue Reihenfolge bauen und setzen
        new_order = [target_entry] + [x for x in original_order if x != target_entry]
        logging.info("Neue BootOrder: %s", ", ".join(x.upper() for x in new_order))
        set_boot_order(new_order)

        # 5) Interaktiv warten oder direkt weiter
        if not args.no_prompt:
            input("Drücken Sie Enter, um die ursprüngliche BootOrder wiederherzustellen...")

    except BootOrderError as e:
        logging.error("Fehler: %s", e)
        sys.exit(1)
    except Exception:
        logging.exception("Unerwarteter Fehler aufgetreten.")
        sys.exit(2)
    else:
        pass
    finally:
        # Wiederherstellung
        try:
            if args.restore_from_backup:
                logging.info("Stelle BootOrder aus Backup wieder her: %s", args.backup)
                backup_order = read_backup_order(args.backup)
                _, current_entries = get_current_state()
                validate_ids_exist(backup_order, current_entries)
                set_boot_order(backup_order)
            else:
                if 'original_order' in locals() and original_order:
                    logging.info("Stelle ursprüngliche BootOrder wieder her...")
                    set_boot_order(original_order)
                else:
                    logging.warning("Originalzustand unbekannt – keine Wiederherstellung möglich.")
            logging.info("Wiederherstellung abgeschlossen.")
        except BootOrderError as e:
            logging.error("Wiederherstellung fehlgeschlagen: %s", e)
        except Exception:
            logging.exception("Unerwarteter Fehler bei der Wiederherstellung.")


if __name__ == "__main__":
    main()

# old #!/bin/bash
# echo "Only raw start must be adaptet to other situations"
# sudo efibootmgr --create --disk /dev/sda --part 1 --label 'efi shell lin' --loader '\EFI\boot\bootx64.efi'
# sudo efibootmgr # check bootorder and set after this.
# sudo efibootmgr --bootorder 0004,0005,0006,0007,000B,000C

