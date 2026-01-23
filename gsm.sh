#!/bin/bash
set -u

# ==========================================
# Game Server Manager (GSM) - Modular Entry
# ==========================================

# Resolve Base Directory
BASE_DIR=$(cd "$(dirname "$(readlink -f "$0")")"; pwd)
LIB_DIR="$BASE_DIR/lib"

# Source Libraries
source "$LIB_DIR/core.sh"
source "$LIB_DIR/ui.sh"
source "$LIB_DIR/steam.sh"
source "$LIB_DIR/tuning.sh"
source "$LIB_DIR/servers.sh"
source "$LIB_DIR/network.sh"

# Watchdog Mode
if [ "${1:-}" == "__watchdog_internal" ]; then
    echo "Starting GSM Watchdog Loop..."
    while true; do
        # Placeholder for old watchdog logic (simplify for now)
        sleep 60
    done
    exit 0
fi

# Main Execution Flow
init_gsm() {
    ensure_folder_structure
    
    # Root Check / User Fix
    if [ "$(id -u)" -eq 0 ]; then
        ensure_gsm_user
    else
        # If running as non-root, warn if certain things might fail?
        # Ideally user runs as root, we drop for steamcmd.
        pass
    fi
    
    ensure_deps
}

main_menu() {
  while true; do
    clear
    echo -e "${C_BOLD}${C_BLUE}GSM - Game Server Manager (Modular v2.0)${C_RESET}"
    echo ""
    
    list_servers

    echo -e "${C_BOLD}--- [ Main Menu ] ---${C_RESET}"
    echo -e " ${C_CYAN}1)${C_RESET} List Installed Servers   ${C_CYAN}6)${C_RESET} Backup Server Data"
    echo -e " ${C_CYAN}2)${C_RESET} Start Server           ${C_CYAN}7)${C_RESET} Exec Env Config (TODO)"
    echo -e " ${C_CYAN}3)${C_RESET} Stop Server            ${C_CYAN}8)${C_RESET} System Performance Tuning"
    echo -e " ${C_CYAN}4)${C_RESET} Search & Install       ${C_CYAN}9)${C_RESET} Delete Server ${C_RED}[DANGER]${C_RESET}"
    echo -e " ${C_CYAN}5)${C_RESET} Install by AppID       ${C_CYAN}10)${C_RESET} Update GSM Script"
  echo -e " ${C_CYAN}0)${C_RESET} Exit                 ${C_RED}99)${C_RESET} Uninstall GSM ${C_RED}[DESTRUCTIVE]${C_RESET}"
    echo ""
    
    read -p "Select option: " choice
    echo ""
    
    case "$choice" in
      1) clear; list_servers ;;
      2) 
         clear; list_servers
         appid=$(select_server_interactive "Start AppID: ")
         [ "$appid" != "0" ] && start_server "$appid"
         ;;
      3)
         clear; echo "Running Servers:"; list_running_servers
         appid=$(select_server_interactive "Stop AppID: ")
         [ "$appid" != "0" ] && stop_server "$appid"
         ;;
     4) 
        clear
        steam_search_and_install 
        ;;
      5)
         clear
         read -p "Enter Steam AppID: " appid
         [ -n "$appid" ] && install_or_update_game "$appid"
         ;;
      6)
         clear; list_servers
         appid=$(select_server_interactive "Backup AppID: ")
         [ "$appid" != "0" ] && backup_save "$appid"
         ;;
      8) clear; run_full_tuning ;;
      9)
         clear; list_servers
         appid=$(select_server_interactive "DELETE AppID: ")
         [ "$appid" != "0" ] && delete_server "$appid"
         ;;
      10) clear; update_self ;;
      99) uninstall_gsm ;;
      0) exit 0 ;;
      *) print_error "Invalid option" ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..." dummy
  done
}

# Run
init_gsm
main_menu
