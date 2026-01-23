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
REPO_URL="https://github.com/TONYUNTURN/Game-server-manager.git"

print_info "Starting GSM installation..."

# 1. Install Dependencies
print_info "Installing dependencies..."
# Added git to dependencies
apt-get update -y
apt-get install -y curl jq screen wget tar sudo git lib32gcc-s1 lib32stdc++6

# 2. Prepare Directory & Clone
if [ -d "$INSTALL_DIR" ]; then
    print_info "Directory $INSTALL_DIR exists."
    # Check if it is a git repo
    if [ -d "$INSTALL_DIR/.git" ]; then
        print_info "Updating via git..."
        cd "$INSTALL_DIR"
        git fetch origin
        git reset --hard origin/main
        print_success "Updated source code."
    else
        print_warn "Directory exists but is not a git repo. Backing up and reinstalling..."
        mv "$INSTALL_DIR" "${INSTALL_DIR}_backup_$(date +%s)"
        git clone "$REPO_URL" "$INSTALL_DIR"
    fi
else
    print_info "Cloning repository..."
    git clone "$REPO_URL" "$INSTALL_DIR"
fi

if [ ! -f "$INSTALL_DIR/gsm.sh" ]; then
    print_error "Installation failed: gsm.sh not found."
    exit 1
fi

# 3. Create Directories
mkdir -p "$INSTALL_DIR/common"
mkdir -p "$INSTALL_DIR/servers"
mkdir -p "$INSTALL_DIR/data"

chmod +x "$INSTALL_DIR/gsm.sh"
# Also chmod libs if necessary, though sourcing doesn't strict require +x unless executed
chmod +x "$INSTALL_DIR/lib/"*.sh 2>/dev/null || true

# 4. Create Symlink
if [ ! -d "/usr/local/bin" ]; then
    mkdir -p "/usr/local/bin"
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
