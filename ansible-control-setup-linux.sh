#!/bin/bash
set -e

echo "=== Updating System ==="
sudo apt update && sudo apt upgrade -y

echo "=== Installing base packages ==="
sudo apt install -y \
    git \
    python3 \
    python3-pip \
    python3-venv \
    ssh \
    curl \
    nano \
    software-properties-common

echo "=== Installing Ansible ==="
sudo apt install -y ansible

echo "=== Installing ansible-lint ==="
pip3 install --user ansible-lint

echo "=== Creating SSH key for GitHub (if not existing) ==="
if [ ! -f ~/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -C "ansible-control-node" -f ~/.ssh/id_ed25519 -N ""
else
    echo "SSH Key already exists – skipping."
fi

echo "=== Setting SSH permissions ==="
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub

echo "=== Enabling SSH service ==="
sudo systemctl enable --now ssh

echo "=== Adding GitHub to known hosts ==="
ssh-keyscan github.com >> ~/.ssh/known_hosts
chmod 644 ~/.ssh/known_hosts

echo "=== Setup complete ==="
echo "--------------------------------------------"
echo "Öffne diesen Public Key in GitHub -> Settings -> SSH Keys:"
echo
cat ~/.ssh/id_ed25519.pub
echo
echo "--------------------------------------------"
echo "Danach kannst du das Repo klonen mit:"
echo "git clone git@github.com:DEINACCOUNT/DEINREPO.git"
echo "--------------------------------------------"
