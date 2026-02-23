#!/bin/bash
# Collect detailed BIOS information
sudo dmidecode -t bios -t system -t baseboard -t chassis -t processor -t memory -t cache -t connector -t slot

echo -n "Name: "; sudo dmidecode -s baseboard-product-name
echo -n "Serial Number: "; sudo dmidecode -s baseboard-serial-number

echo -n "Baseboard Manufacturer: "; sudo dmidecode -s baseboard-manufacturer
echo -n "Baseboard Version (Rev): "; sudo dmidecode -s baseboard-version

echo -n "BIOS Build: "; sudo dmidecode -s bios-version
echo -n "BIOS Date: "; sudo dmidecode -s bios-release-date

