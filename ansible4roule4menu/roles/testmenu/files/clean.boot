#!/bin/bash

# Function to display help text
show_help() {
    echo "Usage: ${0##*/} [-h|--help] [-f|--force]"
    echo
    echo "This script delete the hard disk where the root/boot of this installation is placed."
    echo
    echo "Options:"
    echo "  -h, --help      Display this help text and exit"
    echo "  -f, --force     Force the script to show the hard disk"
    echo
    echo "Note: The script will delete the hard disk only if the -f or --force option is used,"
    echo "or if the file 'this_is_a_test_install' is present in the root directory."
    echo
    echo "This script is from asc@ekf.de with the help of copilot."
}

# Function to find the root/boot disk
find_root_disk() {
    root_disk=$(lsblk | grep \ disk | awk '{print $1}')
    # root_disk=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')
    echo "Clean Root/boot disk: $root_disk"
    sleep 3
    sudo dd if=/dev/zero of=/dev/${root_disk} count=1000 && sudo sync && sudo poweroff
}

# Check for help option
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
fi

# Check for force option or presence of 'this_is_a_test_install' file
if [[ "$1" == "-f" || "$1" == "--force" || -f /this_is_a_test_install ]]; then
    find_root_disk
else
    root_disk=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')
    echo "Use -f or --force option, or create 'this_is_a_test_install' file"
    echo "In the root directory to clean the root/boot disk: $root_disk"
    exit 1
fi
