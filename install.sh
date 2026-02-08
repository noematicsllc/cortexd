#!/bin/bash
set -e

# Cortex installation script
# Binary install:  curl -fsSL <url> | sudo bash
# Source install:   sudo ./install.sh --from-source

VERSION="0.2.1"
REPO="noematicsllc/cortexd"
INSTALL_DIR="/var/lib/cortex"
BIN_DIR="/usr/local/bin"
RUN_DIR="/run/cortex"

FROM_SOURCE=false
for arg in "$@"; do
    case "$arg" in
        --from-source) FROM_SOURCE=true ;;
        --help|-h)
            echo "Usage: install.sh [--from-source]"
            echo ""
            echo "  Default:       Download pre-built binaries from GitHub releases"
            echo "  --from-source: Build from source (requires Elixir, Erlang, Cargo)"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run with --help for usage"
            exit 1
            ;;
    esac
done

if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root"
    exit 1
fi

detect_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64)  echo "x86_64" ;;
        aarch64) echo "aarch64" ;;
        arm64)   echo "aarch64" ;;  # macOS reports arm64
        *)
            echo "Unsupported architecture: $arch" >&2
            echo "Supported: x86_64, aarch64" >&2
            echo "Try: sudo ./install.sh --from-source" >&2
            exit 1
            ;;
    esac
}

install_from_binary() {
    local arch
    arch="$(detect_arch)"
    local tarball="cortexd-${VERSION}-linux-${arch}.tar.gz"
    local url="https://github.com/${REPO}/releases/download/v${VERSION}/${tarball}"

    echo "Downloading cortexd v${VERSION} for ${arch}..."

    local tmpdir
    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" EXIT

    if ! curl -fSL -o "${tmpdir}/${tarball}" "$url"; then
        echo "Download failed: $url" >&2
        echo "" >&2
        echo "The release may not exist yet. Options:" >&2
        echo "  1. Check https://github.com/${REPO}/releases" >&2
        echo "  2. Build from source: sudo ./install.sh --from-source" >&2
        exit 1
    fi

    # Download CLI binary
    local cli_name="cortex-linux-${arch}"
    local cli_url="https://github.com/${REPO}/releases/download/v${VERSION}/${cli_name}"

    echo -n "Installing... "
    tar -xzf "${tmpdir}/${tarball}" -C "$tmpdir"

    # Install daemon release (Mix release name is "cortex")
    cp -r "${tmpdir}/cortex/"* "$INSTALL_DIR/bin/" 2>/dev/null || true

    # Download and install CLI binary
    if curl -fSL -o "${tmpdir}/cortex-cli" "$cli_url" 2>/dev/null; then
        cp "${tmpdir}/cortex-cli" "$BIN_DIR/cortex"
        chmod 755 "$BIN_DIR/cortex"
    else
        echo ""
        echo "  Warning: CLI binary download failed. Daemon installed, but 'cortex' CLI not available."
    fi

    echo "done"
}

install_from_source() {
    # Check build dependencies
    local missing=""
    if ! command -v elixir > /dev/null 2>&1; then missing="$missing elixir"; fi
    if ! command -v mix > /dev/null 2>&1; then missing="$missing mix"; fi
    if ! command -v erl > /dev/null 2>&1; then missing="$missing erlang"; fi

    if [ -n "$missing" ]; then
        echo "Missing build dependencies:$missing" >&2
        echo "" >&2
        echo "Install Elixir and Erlang/OTP, then retry." >&2
        echo "Or download pre-built binaries: sudo ./install.sh" >&2
        exit 1
    fi

    # Build Elixir release
    echo -n "Building release... "
    MIX_ENV=prod mix deps.get --only prod > /dev/null 2>&1
    MIX_ENV=prod mix release --overwrite > /dev/null 2>&1
    echo "done"

    # Install release
    echo -n "Installing release... "
    cp -r _build/prod/rel/cortex/* "$INSTALL_DIR/bin/"
    echo "done"

    # Build Rust CLI (optional)
    echo -n "Building CLI... "
    if command -v cargo > /dev/null 2>&1; then
        (cd cli && cargo build --release > /dev/null 2>&1)
        cp cli/target/release/cortex "$BIN_DIR/cortex"
        chmod 755 "$BIN_DIR/cortex"
        echo "done"
    else
        echo "skipped (cargo not found)"
        echo "  Install Rust to build CLI, or download pre-built binary from GitHub releases"
    fi
}

echo "Installing Cortex v${VERSION}..."

# Stop daemon if running
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
mkdir -p /etc/cortex/mesh

# Install
if [ "$FROM_SOURCE" = true ]; then
    install_from_source
else
    install_from_binary
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
ReadWritePaths=/var/lib/cortex /run/cortex /etc/cortex

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
