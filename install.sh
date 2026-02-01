#!/bin/bash
set -e

# Cortex installation script
# Run as root: sudo ./install.sh

if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root"
    exit 1
fi

INSTALL_DIR="/var/lib/cortex"
BIN_DIR="/usr/local/bin"
RUN_DIR="/run/cortex"

echo "Installing Cortex..."

# Create cortex group and user
if ! getent group cortex > /dev/null; then
    groupadd -r cortex
    echo "Created group: cortex"
fi

if ! getent passwd cortex > /dev/null; then
    useradd -r -g cortex -d "$INSTALL_DIR" -s /usr/sbin/nologin cortex
    echo "Created user: cortex"
fi

# Create directories
mkdir -p "$INSTALL_DIR/bin"
mkdir -p "$INSTALL_DIR/mnesia"
mkdir -p "$RUN_DIR"

# Build release
echo "Building release..."
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix release --overwrite

# Install release
echo "Installing release..."
cp -r _build/prod/rel/cortex/* "$INSTALL_DIR/bin/"

# Build escript CLI
echo "Building CLI..."
mix escript.build

# Install CLI with setgid
cp cortex "$BIN_DIR/cortex"
chown root:cortex "$BIN_DIR/cortex"
chmod 2755 "$BIN_DIR/cortex"
echo "Installed CLI: $BIN_DIR/cortex (setgid cortex)"

# Set ownership
chown -R cortex:cortex "$INSTALL_DIR"
chown cortex:cortex "$RUN_DIR"

# Install systemd service
cat > /etc/systemd/system/cortexd.service << 'EOF'
[Unit]
Description=Cortex Storage Daemon
After=network.target

[Service]
Type=simple
User=cortex
Group=cortex
WorkingDirectory=/var/lib/cortex
Environment=HOME=/var/lib/cortex
Environment=CORTEX_SOCKET=/run/cortex/cortex.sock
Environment=CORTEX_DATA_DIR=/var/lib/cortex/mnesia
ExecStart=/var/lib/cortex/bin/bin/cortex start
ExecStop=/var/lib/cortex/bin/bin/cortex stop
Restart=on-failure
RestartSec=5

# Runtime directory
RuntimeDirectory=cortex
RuntimeDirectoryMode=0755

# Security
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/cortex /run/cortex

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

echo ""
echo "Installation complete!"
echo ""
echo "To start the daemon:"
echo "  sudo systemctl enable --now cortexd"
echo ""
echo "To use the CLI:"
echo "  cortex ping"
echo "  cortex status"
echo ""
