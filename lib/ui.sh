#!/bin/bash

# ==========================================
# GSM UI Library
# ==========================================

# Global Array for Interactive Selection
SERVER_LIST_IDS=()

# Helper for interactive selection (extracted from old gsm.sh)
select_server_interactive() {
  local prompt="${1:-请选择序号 (0 返回): }"
  
  # If list is empty, just read ID manually? Or return 0?
  if [ ${#SERVER_LIST_IDS[@]} -eq 0 ]; then
      read -p "无列表，请输入 AppID (0 返回): " manual_id
      echo "$manual_id"
      return
  fi
  
  read -p "$prompt" idx
  
  # Check cancel
  if [[ "$idx" == "0" || -z "$idx" ]]; then
      echo "0"
      return
  fi
  
  # Check if number
  if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
      print_error "请输入有效的数字序号。" >&2
      echo "0"
      return
  fi
  
  # Check range
  if [ "$idx" -gt ${#SERVER_LIST_IDS[@]} ]; then
      print_error "序号超出范围。" >&2
      echo "0"
      return
  fi
  
  # Get AppID
  local real_id="${SERVER_LIST_IDS[$((idx-1))]}"
  echo "$real_id"
}

# The main dashboard list
list_servers() {
  print_header "已安装服务器列表"
  SERVER_LIST_IDS=()
  
  if [ ! -d "$SERVERS_DIR" ]; then
    echo "  (无)"
    return
  fi

  # 预取运行状态
  local running_txt
  running_txt=$(screen -ls || true)
  
  local any=0
  local i=0
  
  # Table Header
  printf "${C_BOLD}%-4s %-30s %-15s %-10s${C_RESET}\n" "NO." "GAME NAME" "STATUS" "APPID"
  echo "------------------------------------------------------------"

  # 遍历目录
  for appid in $(find "$SERVERS_DIR" -maxdepth 1 -type d -printf "%f\n" 2>/dev/null | grep -E '^[1-9][0-9]*$' | sort -n || true); do
    any=1
    i=$((i+1))
    SERVER_LIST_IDS+=("$appid")
    
    # Need get_game_name from steam.sh or similar
    local name
    if declare -f get_game_name > /dev/null; then
        name=$(get_game_name "$appid")
    else
        name="AppID $appid"
    fi
    
    local session="game-$appid"
    local status=""
    if echo "$running_txt" | grep -q "\.${session}"; then
      status="${C_GREEN}RUNNING${C_RESET}"
    else
      status="${C_RED}STOPPED${C_RESET}"
    fi
    printf "${C_CYAN}[%d]${C_RESET}  %-30s %-25s %s\n" "$i" "$name" "$status" "$appid"
  done

  if [ "$any" -eq 0 ]; then
    echo "  (无已安装的服务器)"
  fi
  echo ""
}

list_running_servers() {
  local running_txt
  running_txt=$(screen -ls || true)
  local ids
  ids=$(echo "$running_txt" | grep -o "game-[0-9]\+" | sed 's/game-//' | sort | uniq)
  
  SERVER_LIST_IDS=()
  
  if [ -z "$ids" ]; then
     return 1
  fi
  
  local i=0
  for appid in $ids; do
     i=$((i+1))
     SERVER_LIST_IDS+=("$appid")
     local name
     if declare -f get_game_name > /dev/null; then
        name=$(get_game_name "$appid")
     else
        name="AppID $appid"
     fi
     # Clean output for dashboard
     printf " ${C_CYAN}[%d]${C_RESET} ${C_GREEN}●${C_RESET} %-20s (ID: %s)\n" "$i" "$name" "$appid"
  done
  return 0
}
