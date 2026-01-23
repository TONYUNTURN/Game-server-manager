#!/bin/bash

# ==========================================
# GSM Core Library
# ==========================================

# ========= Global Config =========
BASE_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
COMMON_DIR="$BASE_DIR/common"
STEAMCMD_DIR="$COMMON_DIR/steamcmd"
SERVERS_DIR="$BASE_DIR/servers"
DATA_DIR="$BASE_DIR/data"
LIB_DIR="$BASE_DIR/lib"

# Configurable GSM User
GSM_USER="gsm"
GSM_GROUP="gsm"

# ========= UI Colors & Styles =========
C_RESET=$'\033[0m'
C_RED=$'\033[0;31m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[0;33m'
C_BLUE=$'\033[0;34m'
C_CYAN=$'\033[0;36m'
C_BOLD=$'\033[1m'

# ========= Logging Helper =========
LOG_FILE="/var/log/gsm.log"

log_msg() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    # Make sure log file exists and is writable by us (root) or gsm user
    # If running as root, we can write.
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

# ========= Print Helpers =========
print_header() {
    echo -e "\n${C_BOLD}${C_BLUE}=== $1 ===${C_RESET}"
    log_msg "INFO" "Header: $1"
}

print_info() {
    echo -e "${C_CYAN}[INFO]${C_RESET} $1"
    log_msg "INFO" "$1"
}

print_success() {
    echo -e "${C_GREEN}[OK]${C_RESET} $1"
    log_msg "INFO" "Success: $1"
}

print_error() {
    echo -e "${C_RED}[ERROR]${C_RESET} $1" >&2
    log_msg "ERROR" "$1"
}

print_warn() {
    echo -e "${C_YELLOW}[WARN]${C_RESET} $1"
    log_msg "WARN" "$1"
}

# ========= Dependency & Environment =========
ensure_folder_structure() {
    mkdir -p "$COMMON_DIR" "$STEAMCMD_DIR" "$SERVERS_DIR" "$DATA_DIR"
    
    # Init log file content if empty
    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE" 2>/dev/null || true
        # If we are root, change owner to allow writing? 
        # Actually gsm user might not have access to /var/log/gsm.log unless we chown.
        # Let's handle permissions in check_user.
    fi
}

ensure_deps() {
    local deps=("curl" "wget" "screen" "jq" "tar" "sudo")
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        print_warn "Missing dependencies: ${missing[*]}"
        if [ "$(id -u)" -eq 0 ]; then
            print_info "Attempting to install..."
            apt-get update -qq && apt-get install -y "${missing[@]}"
        else
            print_error "Cannot install dependencies without root. Please install manually: ${missing[*]}"
            exit 1
        fi
    fi
    
    # 32-bit libs for SteamCMD
    if [ "$(id -u)" -eq 0 ]; then
        if ! dpkg -l | grep -q lib32gcc-s1; then
             print_info "Installing 32-bit libraries for SteamCMD..."
             apt-get install -y lib32gcc-s1 lib32stdc++6 || true
        fi
    fi
}

# ========= User Management =========
ensure_gsm_user() {
    # Only if root
    if [ "$(id -u)" -eq 0 ]; then
        if ! id "$GSM_USER" >/dev/null 2>&1; then
            print_info "Creating dedicated user '$GSM_USER'..."
            useradd -m -s /bin/bash "$GSM_USER"
            print_success "User '$GSM_USER' created."
        fi
        
        # Ensure permissions on directories
        chown -R "$GSM_USER:$GSM_GROUP" "$COMMON_DIR" "$SERVERS_DIR" "$DATA_DIR"
        chmod -R 755 "$COMMON_DIR" "$SERVERS_DIR" "$DATA_DIR"
        
        # Ensure log permission
        if [ -f "$LOG_FILE" ]; then
            chown "$GSM_USER:$GSM_GROUP" "$LOG_FILE"
        fi
    fi
}

# Helper to run command as GSM user if we are root
run_as_gsm() {
    local cmd="$1"
    if [ "$(id -u)" -eq 0 ]; then
        # Use runuser or su
        # Preserve environment? Maybe not all.
        su - "$GSM_USER" -c "$cmd"
    else
        # Already non-root (assume we are gsm or similar), just run
        bash -c "$cmd"
    fi
}

uninstall_gsm() {
  clear
  print_header "卸载 GSM (Game Server Manager)"
  echo -e "${C_RED}警告：此操作将永久删除 GSM 及其所有数据！${C_RESET}"
  echo "包括："
  echo "  - 所有已安装的游戏服务器 (servers/)"
  echo "  - 所有游戏存档和配置数据 (data/)"
  echo "  - 脚本本身及所有相关文件"
  echo ""
  echo "请务必确认您已备份重要数据！"
  echo ""
  
  read -p "是否确认要卸载且明白数据将永久丢失？(y/n): " confirm_1
  if [ "$confirm_1" != "y" ]; then
    echo "操作已取消。"
    return
  fi
  
  echo ""
  echo -e "${C_RED}FINAL WARNING: This is destructive.${C_RESET}"
  read -p "请输入 'UNINSTALL' 以确认最终卸载: " confirm_2
  
  if [ "$confirm_2" != "UNINSTALL" ]; then
    echo "确认失败，操作已取消。"
    return
  fi
  
  echo ""
  echo "正在停止所有 GSM 管理的 Screen 会话..."
  # Clean up screens
  local running_screens
  # Correct regex for grep to find sessions started by this logic if possible
  # Or just look for "game-" prefix which we use.
  running_screens=$(screen -ls | grep -o "game-[0-9]\+" | sort | uniq || true)
  if [ -n "$running_screens" ]; then
     for session in $running_screens; do
        screen -S "$session" -X quit || true
        echo "已停止 Session: $session"
     done
  fi
  
  # Remove symlink
  if [ -L "/usr/local/bin/gsm" ]; then
      echo "正在移除命令软链接..."
      rm -f "/usr/local/bin/gsm" || true
  fi
  
  echo "正在删除 GSM 目录: $BASE_DIR ..."
  
  # Change debug to see what path is being targeted
  if [ -z "$BASE_DIR" ] || [ "$BASE_DIR" = "/" ]; then
     echo "错误：BASE_DIR 为空或根目录，跳过删除以策安全。"
     return
  fi
  
  # Move out of the directory before deleting
  cd /tmp || cd /
  
  rm -rf "$BASE_DIR"
  
  if [ -d "$BASE_DIR" ]; then
     echo "错误：删除失败。请手动删除: $BASE_DIR"
  else
     echo "卸载完成。Goodbye!"
  fi
  
  exit 0
}
