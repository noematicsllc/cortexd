#!/bin/bash
set -e

# Cortex uninstallation script
# Run as root: sudo ./uninstall.sh

if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root"
    exit 1
fi

echo "Uninstalling Cortex..."

# Stop and disable service
if systemctl is-active --quiet cortexd 2>/dev/null; then
    echo "Stopping cortexd service..."
    systemctl stop cortexd
fi

if systemctl is-enabled --quiet cortexd 2>/dev/null; then
    echo "Disabling cortexd service..."
    systemctl disable cortexd
fi

# Remove service file
if [ -f /etc/systemd/system/cortexd.service ]; then
    rm /etc/systemd/system/cortexd.service
    systemctl daemon-reload
    echo "Removed systemd service"
fi

# Remove CLI
if [ -f /usr/local/bin/cortex ]; then
    rm /usr/local/bin/cortex
    echo "Removed CLI"
fi

# Remove data and installation (prompt for confirmation)
if [ -d /var/lib/cortex ]; then
    read -p "Remove all data in /var/lib/cortex? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf /var/lib/cortex
        echo "Removed /var/lib/cortex"
    else
        echo "Kept /var/lib/cortex (data preserved)"
    fi
fi

# Remove runtime directory
rm -rf /run/cortex 2>/dev/null || true

# Remove user and group (prompt for confirmation)
if getent passwd cortex > /dev/null; then
    read -p "Remove cortex user and group? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        userdel cortex 2>/dev/null || true
        echo "Removed cortex user"
    fi
fi

if getent group cortex > /dev/null; then
    groupdel cortex 2>/dev/null || true
    echo "Removed cortex group"
fi

echo ""
echo "Uninstallation complete!"
