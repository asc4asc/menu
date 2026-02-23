#!/bin/bash

# Farbdefinitionen für Ausgaben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'  # No Color (reset)

# Collect detailed BIOS information
# sudo dmidecode -t bios -t system -t baseboard -t chassis -t processor -t memory -t cache -t connector -t slot

echo -n -e "${YELLOW}Name: ${GREEN}"; sudo dmidecode -s baseboard-product-name && echo -n -e ${NC}
echo -n -e "${YELLOW}Serial Number: ${GREEN}" && sudo dmidecode -s baseboard-serial-number && echo -n -e ${NC}
echo -n -e "${YELLOW}Baseboard Manufacturer: ${GREEN}" && sudo dmidecode -s baseboard-manufacturer; echo -n -e ${NC}
echo -n -e "${YELLOW}Baseboard Version (Rev): ${GREEN}" && sudo dmidecode -s baseboard-version && echo -n -e ${NC}
echo -n -e "${YELLOW}BIOS Build: ${GREEN}" && sudo dmidecode -s bios-version && echo -n -e ${NC}
echo -n -e "${YELLOW}BIOS Date: ${GREEN}" && sudo dmidecode -s bios-release-date && echo -n -e ${NC}
