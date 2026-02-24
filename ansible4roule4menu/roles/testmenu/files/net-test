#!/bin/bash

# Variables
INTERFACE_SERVER="enp3s0"
INTERFACE_CLIENT="enp4s0"
IP_SERVER="192.168.1.1"
IP_CLIENT="192.168.1.2"
DURATION=60
PARALLEL_STREAMS=4
INTERVAL=1

# Create network namespaces
sudo ip netns add server_ns
sudo ip netns add client_ns

# Move interfaces to namespaces
sudo ip link set $INTERFACE_SERVER netns server_ns
sudo ip link set $INTERFACE_CLIENT netns client_ns

# Assign IP addresses
sudo ip netns exec server_ns ip addr add $IP_SERVER/24 dev $INTERFACE_SERVER
sudo ip netns exec client_ns ip addr add $IP_CLIENT/24 dev $INTERFACE_CLIENT

# Bring up loopback interfaces
sudo ip netns exec server_ns ip link set lo up
sudo ip netns exec client_ns ip link set lo up

# Bring up network interfaces
sudo ip netns exec server_ns ip link set $INTERFACE_SERVER up
sudo ip netns exec client_ns ip link set $INTERFACE_CLIENT up

# Start iperf3 server in server namespace
sudo ip netns exec server_ns iperf3 -s -B $IP_SERVER &

# Wait a moment to ensure the server starts
sleep 2

# Run iperf3 client in client namespace
sudo ip netns exec client_ns iperf3 -c $IP_SERVER -B $IP_CLIENT -t $DURATION -P $PARALLEL_STREAMS -i $INTERVAL

# Clean up
sudo ip netns exec server_ns ip link set $INTERFACE_SERVER netns 1
sudo ip netns exec client_ns ip link set $INTERFACE_CLIENT netns 1
sudo ip netns delete server_ns
sudo ip netns delete client_ns
