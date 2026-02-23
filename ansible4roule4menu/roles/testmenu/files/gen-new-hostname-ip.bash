#!/bin/bash

# Function to get the active Ethernet interface
get_active_ethernet_interface() {
    for interface in $(ls /sys/class/net/); do
        if [[ $(cat /sys/class/net/$interface/operstate) == "up" ]]; then
            echo $interface
            return
        fi
    done
}

# Function to get the IP address of an interface
get_ip_address() {
    local interface=$1
    ip -4 addr show $interface | grep -oP '(?<=inet\s)\d+(\.\d+){3}'
}

# Function to generate a unique hostname based on the IP address
generate_hostname() {
    local ip_address=$1
    # Replace dots with hyphens
    echo "host-$(echo $ip_address | tr '.' '-')"
}

# Function to set the hostname
set_hostname() {
    local hostname=$1
    sudo hostnamectl set-hostname $hostname
    sudo sed -i "s/127.0.1.1.*/127.0.1.1\t$hostname/" /etc/hosts
}

active_interface=$(get_active_ethernet_interface)
if [[ -n $active_interface ]]; then
    ip_address=$(get_ip_address $active_interface)
    if [[ -n $ip_address ]]; then
        hostname=$(generate_hostname $ip_address)
        set_hostname $hostname
        echo "Hostname set to: $hostname"
        sudo service networking restart
    else
        echo "Could not retrieve IP address."
    fi
else
    echo "No active Ethernet interface found."
fi
