#!/bin/bash
set -e

# Cortex binary installation script
# Downloads pre-built binaries from GitHub releases

VERSION="${CORTEX_VERSION:-0.1.0-alpha}"
REPO="noematicsllc/cortexd"
INSTALL_DIR="/var/lib/cortex"
BIN_DIR="/usr/local/bin"
RUN_DIR="/run/cortex"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}==>${NC} $1"; }
warn() { echo -e "${YELLOW}Warning:${NC} $1"; }
error() { echo -e "${RED}Error:${NC} $1"; exit 1; }

# Check root
if [ "$(id -u)" != "0" ]; then
    error "This script must be run as root (try: sudo $0)"
fi

# Detect platform
detect_platform() {
    local os arch

    case "$(uname -s)" in
        Linux)  os="linux" ;;
        Darwin) os="darwin" ;;
        *)      error "Unsupported OS: $(uname -s)" ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)  arch="x86_64" ;;
        aarch64|arm64) arch="arm64" ;;
        *)             error "Unsupported architecture: $(uname -m)" ;;
    esac

    echo "${os}-${arch}"
}

PLATFORM=$(detect_platform)
info "Detected platform: $PLATFORM"

# Check for curl or wget
if command -v curl &> /dev/null; then
    DOWNLOAD="curl -fsSL"
    DOWNLOAD_OUT="curl -fsSL -o"
elif command -v wget &> /dev/null; then
    DOWNLOAD="wget -qO-"
    DOWNLOAD_OUT="wget -qO"
else
    error "curl or wget is required"
fi

# GitHub release URLs
BASE_URL="https://github.com/${REPO}/releases/download/v${VERSION}"
DAEMON_URL="${BASE_URL}/cortexd-${VERSION}-${PLATFORM}.tar.gz"
CLI_URL="${BASE_URL}/cortex-${PLATFORM}"

info "Installing Cortex v${VERSION}..."

# Stop existing service if running
if command -v systemctl &> /dev/null && systemctl is-active --quiet cortexd 2>/dev/null; then
    info "Stopping existing cortexd service..."
    systemctl stop cortexd
fi

# Create cortex user/group
if ! getent group cortex > /dev/null 2>&1; then
    groupadd -r cortex
    info "Created group: cortex"
fi

if ! getent passwd cortex > /dev/null 2>&1; then
    useradd -r -g cortex -d "$INSTALL_DIR" -s /usr/sbin/nologin cortex
    info "Created user: cortex"
fi

# Create directories
mkdir -p "$INSTALL_DIR/bin"
mkdir -p "$INSTALL_DIR/mnesia"
mkdir -p "$RUN_DIR"

# Download and install daemon
info "Downloading daemon..."
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

if ! $DOWNLOAD_OUT "$TMPDIR/daemon.tar.gz" "$DAEMON_URL"; then
    error "Failed to download daemon from $DAEMON_URL"
fi

info "Installing daemon..."
tar -xzf "$TMPDIR/daemon.tar.gz" -C "$TMPDIR"
cp -r "$TMPDIR/cortex/"* "$INSTALL_DIR/bin/"

# Download and install CLI
info "Downloading CLI..."
if ! $DOWNLOAD_OUT "$BIN_DIR/cortex" "$CLI_URL"; then
    error "Failed to download CLI from $CLI_URL"
fi
chmod 755 "$BIN_DIR/cortex"

# Set ownership
chown -R cortex:cortex "$INSTALL_DIR"
chown cortex:cortex "$RUN_DIR"

# Install systemd service (Linux only)
if [ "$(uname -s)" = "Linux" ] && command -v systemctl &> /dev/null; then
    info "Installing systemd service..."
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
fi

# Verify installation
info "Verifying installation..."
if "$BIN_DIR/cortex" --version > /dev/null 2>&1; then
    CLI_VERSION=$("$BIN_DIR/cortex" --version)
    info "CLI installed: $CLI_VERSION"
else
    warn "CLI verification failed"
fi

if [ -x "$INSTALL_DIR/bin/bin/cortex" ]; then
    info "Daemon installed to $INSTALL_DIR/bin/"
else
    warn "Daemon verification failed"
fi

echo ""
echo -e "${GREEN}Installation complete!${NC}"
echo ""
echo "To start the daemon:"
if [ "$(uname -s)" = "Linux" ] && command -v systemctl &> /dev/null; then
    echo "  sudo systemctl enable --now cortexd"
else
    echo "  sudo -u cortex $INSTALL_DIR/bin/bin/cortex start"
fi
echo ""
echo "To use the CLI:"
echo "  cortex ping"
echo "  cortex status"
echo "  cortex --help"
echo ""
echo "To uninstall:"
echo "  curl -fsSL https://raw.githubusercontent.com/${REPO}/main/uninstall.sh | sudo bash"
echo ""
