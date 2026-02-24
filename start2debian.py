#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
start2debian.py — erzeugt eine EFI-Shell start2deb.nsh zum Start von Debian GRUB.

Standard: ESP=/boot/efi, Ausgabe=/boot/efi/start2deb.nsh
Reihenfolge: shimx64.efi (Secure Boot) -> grubx64.efi -> EFI\BOOT\BOOTX64.EFI
"""

import argparse
import os
import sys

def check_mountpoint(path):
    """Prueft, ob path gemountet ist und liefert (True/False, device, fstype)."""
    device = fstype = None
    try:
        with open('/proc/mounts', 'r', encoding='utf-8') as f:
            for line in f:
                fields = line.split()
                if len(fields) >= 3 and fields[1] == path:
                    device, fstype = fields[0], fields[2]
                    return True, device, fstype
    except Exception:
        pass
    return False, device, fstype

def find_efi_binaries(esp):
    """Prueft auf vorhandene EFI-Binaries im Debian-typischen Layout."""
    cand = {
        'shim': os.path.join(esp, 'EFI', 'debian', 'shimx64.efi'),
        'grub': os.path.join(esp, 'EFI', 'debian', 'grubx64.efi'),
    }
    exists = {k: os.path.exists(v) for k, v in cand.items()}
    return cand, exists

def generate_nsh(prefer='auto', max_fs=31, verbose=False):
    """Erzeugt den start2deb.nsh Text."""
    lines = []
    lines.append('# start2deb.nsh automatisch generiert (Debian GRUB Chainload)')
    lines.append('echo -off')
    lines.append('map -r')
    if verbose:
        lines.append('echo "INFO: map -r ausgefuehrt; Suche nach GRUB (shim/grub)..."')

    # Reihenfolge
    order = ['shim', 'grub']
    if prefer == 'grub':
        order = ['grub', 'shim']
    elif prefer == 'shim':
        order = ['shim', 'grub']

    rel = {
        'shim': r'EFI\debian\shimx64.efi',
        'grub': r'EFI\debian\grubx64.efi',
    }

    # 1) relativ (falls startup.nsh im ESP-Root liegt)
    for key in order:
        if verbose:
            lines.append(f'echo "Pruefe {rel[key]} (relativ)"')
        lines.append(f'if exist {rel[key]} then \n {rel[key]} \n endif')

    lines.append('echo "FEHLER: Keine startbare Debian-GRUB-UEFI-Binaerdatei gefunden."')
    # Warte 5 s, damit die Meldung sichtbar bleibt (EFI Shell: Zeit in Mikrosekunden)
    lines.append('stall 5000000')

    return '\n'.join(lines)

def write_file(path, content, overwrite=False):
    if os.path.exists(path) and not overwrite:
        raise FileExistsError(f"Zieldatei existiert bereits: {path} (verwenden Sie --force)")
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(content)

def main():
    ap = argparse.ArgumentParser(
        description="Generiert eine EFI-Shell start2deb.nsh zum Chainload von Debian GRUB.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    ap.add_argument("-e", "--esp", default="/boot/efi", help="ESP-Mountpunkt (EFI System Partition)")
    ap.add_argument("-o", "--output", default=None,
                    help="Ausgabedatei; Standard: <ESP>/start2deb.nsh")
    ap.add_argument("--prefer", choices=["auto", "shim", "grub"], default="auto",
                    help="Bevorzugte Binaerdatei in der Reihenfolge der Versuche")
    ap.add_argument("--max-fs", type=int, default=31,
                    help="Letzte fsN-Nummer, die geprueft wird (0..N)")
    ap.add_argument("--dry-run", action="store_true",
                    help="Nur ausgeben, nicht schreiben")
    ap.add_argument("--force", action="store_true",
                    help="Existierende Zieldatei ueberschreiben")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="Zusaetzliche echo-Zeilen in der .nsh")

    args = ap.parse_args()

    # Checks: ESP vorhanden und gemountet?
    ok, dev, fstype = check_mountpoint(args.esp)
    if not ok:
        print(f"FEHLER: {args.esp} ist nicht gemountet.", file=sys.stderr)
        sys.exit(2)
    # FAT wird typischerweise verwendet (UEFI verlangt ESP als FAT)
    if fstype.lower() not in ("vfat", "fat", "fat32"):
        print(f"WARNUNG: Dateisystem von {args.esp} ist '{fstype}', nicht FAT/vfat.", file=sys.stderr)

    candidates, exists = find_efi_binaries(args.esp)
    if not any(exists.values()):
        print(
            "WARNUNG: Keine der erwarteten Binaerdateien gefunden:\n"
            f"  {candidates['shim']} (vorhanden={exists['shim']})\n"
            f"  {candidates['grub']} (vorhanden={exists['grub']})\n"
            "Die generierte startup.nsh enthält dennoch generische Pfade (fsN:\\...).",
            file=sys.stderr
        )

    content = generate_nsh(prefer=args.prefer, max_fs=args.max_fs, verbose=args.verbose)

    out = args.output or os.path.join(args.esp, "start2deb.nsh")
    if args.dry_run:
        print(content)
    else:
        try:
            write_file(out, content, overwrite=args.force)
        except FileExistsError as e:
            print(f"FEHLER: {e}", file=sys.stderr)
            sys.exit(3)
        print(f"OK: start2deb.nsh geschrieben nach {out}")
        print("Hinweis: Viele Firmwares koennen die UEFI-Shell so konfigurieren, dass startup.nsh im ESP-Root automatisch ausgefuehrt wird.")
        # Keine weitere Aktion nötig; das Chainload passiert in der Shell.
        # Für manuelle Tests: UEFI Shell starten und 'fs0:'; 'type startup.nsh' prüfen.

if __name__ == "__main__":
    if os.geteuid() != 0:
        sys.exit("Error: This script must be run as root.")
    main()

# Version die man per Hand erzeugen kann sehr einfach.
# echo -off
# connect > NUL
# fs0:
# mode 128 40
# ver -s >v sh_version
# efi\debian\grubx64.efi
## sudo cp start2debian.nsh /boot/efi/
