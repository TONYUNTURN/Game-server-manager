#!/bin/bash
set -u

# ==========================================
# Game Server Manager (GSM) Installer
# ==========================================

# Colors
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_CYAN='\033[0;36m'

print_info() { echo -e "${C_CYAN}[INFO]${C_RESET} $1"; }
print_success() { echo -e "${C_GREEN}[OK]${C_RESET} $1"; }
print_error() { echo -e "${C_RED}[ERROR]${C_RESET} $1"; }

# Check Root
if [ "$(id -u)" -ne 0 ]; then
    print_error "Please run as root or with sudo."
    exit 1
fi

INSTALL_DIR="/opt/gsm"
BIN_LINK="/usr/local/bin/gsm"
REPO_RAW_URL="https://raw.githubusercontent.com/TONYUNTURN/Game-server-manager/refs/heads/main"

print_info "Starting GSM installation..."

# 1. Install Dependencies
print_info "Installing dependencies..."
apt-get update -y
apt-get install -y curl jq screen wget tar sudo lib32gcc-s1 lib32stdc++6

# 2. Prepare Directory
if [ -d "$INSTALL_DIR" ]; then
    print_info "Directory $INSTALL_DIR exists. Updating..."
else
    mkdir -p "$INSTALL_DIR"
    print_success "Created directory $INSTALL_DIR"
fi

mkdir -p "$INSTALL_DIR/common"
mkdir -p "$INSTALL_DIR/servers"
mkdir -p "$INSTALL_DIR/data"

# 3. Download Scripts
print_info "Downloading gsm.sh..."
curl -sL "$REPO_RAW_URL/gsm.sh" -o "$INSTALL_DIR/gsm.sh"

if [ ! -s "$INSTALL_DIR/gsm.sh" ]; then
    print_error "Failed to download gsm.sh. Check network/URL."
    exit 1
fi

chmod +x "$INSTALL_DIR/gsm.sh"
print_success "Downloaded gsm.sh"

print_info "Downloading known_servers.json..."
curl -sL "$REPO_RAW_URL/known_servers.json" -o "$INSTALL_DIR/common/known_servers.json"
# It's okay if this fails lightly, gsm.sh can try again, but let's warn
if [ ! -s "$INSTALL_DIR/common/known_servers.json" ]; then
     print_error "Warning: Failed to download known_servers.json. gsm.sh might need to fetch it later."
else
     print_success "Downloaded known_servers.json"
fi

# 4. Create Symlink
if [ ! -d "/usr/local/bin" ]; then
    mkdir -p "/usr/local/bin"
    # Ensure it's in PATH? Usually it is, but if it didn't exist...
    # We can't easily change PATH for the user permanently here without editing rc files which is invasive.
    # Just create it and hope standard PATH includes it or user adds it.
fi

if [ -L "$BIN_LINK" ]; then
    rm "$BIN_LINK"
fi
ln -s "$INSTALL_DIR/gsm.sh" "$BIN_LINK"
print_success "Created command alias 'gsm' -> $BIN_LINK"

# 5. Finish
echo ""
print_success "Installation Complete!"
echo "Type 'gsm' to launch the manager."
echo "Directory: $INSTALL_DIR"
