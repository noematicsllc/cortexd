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

# Stop daemon if running (so we can overwrite files)
if systemctl is-active --quiet cortexd 2>/dev/null; then
    echo "Stopping existing cortexd service..."
    systemctl stop cortexd
fi

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

# Build release (suppress verbose output)
echo -n "Building release... "
MIX_ENV=prod mix deps.get --only prod > /dev/null 2>&1
MIX_ENV=prod mix release --overwrite > /dev/null 2>&1
echo "done"

# Install release
echo -n "Installing release... "
cp -r _build/prod/rel/cortex/* "$INSTALL_DIR/bin/"
echo "done"

# Build Rust CLI
echo -n "Building CLI... "
if command -v cargo > /dev/null 2>&1; then
    (cd cli && cargo build --release > /dev/null 2>&1)
    cp cli/target/release/cortex-cli "$BIN_DIR/cortex"
    chmod 755 "$BIN_DIR/cortex"
    echo "done"
    echo "Installed CLI to $BIN_DIR/cortex"
else
    echo "skipped (cargo not found)"
    echo "  Install Rust to build CLI, or download pre-built binary from GitHub releases"
fi

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
echo "To uninstall:"
echo "  sudo ./uninstall.sh"
echo ""
