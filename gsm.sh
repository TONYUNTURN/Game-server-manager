#!/bin/bash
set -euo pipefail

# Watchdog Entry Point
if [ "${1:-}" == "__watchdog_internal" ]; then
    echo "Starting GSM Watchdog Loop..."
    while true; do
        # Find all game- session PIDs
        # grep -o doesn't give PIDs easily with screen -ls, but we can parse
        # screen -ls format:  1234.game-appid  (Detached)
        
        sessions=$(screen -ls | grep "\.game-[0-9]\+" | awk '{print $1}')
        for s in $sessions; do
            pid=${s%%.*}
            if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
                # Dynamic Renice: Check CPU
                # ps -p PID -o %cpu --no-headers
                cpu=$(ps -p "$pid" -o %cpu --no-headers | awk '{print int($1)}' 2>/dev/null || echo 0)
                
                if [ "$cpu" -gt 80 ]; then
                   renice -n -15 -p "$pid" >/dev/null 2>&1 || true
                else
                   renice -n -10 -p "$pid" >/dev/null 2>&1 || true
                fi
            fi
        done
        sleep 10
    done
    exit 0
fi

# =========================
# NAT VPS Dedicated 管理脚本（含 Steam 搜索）
# - 每个游戏按 AppID 存放在 servers/<AppID>
# - 每个游戏数据放在 data/<AppID>
# - 若需要运行时安装（Java/Mono 等），在 data/<AppID>/env.sh 中放入安装命令，脚本会自动 source（可选）
# =========================

BASE_DIR=$(cd "$(dirname "$0")"; pwd)
COMMON_DIR="$BASE_DIR/common"
STEAMCMD_DIR="$COMMON_DIR/steamcmd"
SERVERS_DIR="$BASE_DIR/servers"
DATA_DIR="$BASE_DIR/data"

# ========= UI Colors & Styles =========
C_RESET=$'\033[0m'
C_RED=$'\033[0;31m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[0;33m'
C_BLUE=$'\033[0;34m'
C_CYAN=$'\033[0;36m'
C_BOLD=$'\033[1m'

print_header() {
  local title="$1"
  echo -e "${C_CYAN}========================================${C_RESET}"
  echo -e "${C_BOLD} $title ${C_RESET}"
  echo -e "${C_CYAN}========================================${C_RESET}"
}

print_info() {
  echo -e "${C_CYAN}[INFO]${C_RESET} $1"
}

print_success() {
  echo -e "${C_GREEN}[OK]${C_RESET} $1"
}

print_error() {
  echo -e "${C_RED}[ERROR]${C_RESET} $1"
}

print_warn() {
  echo -e "${C_YELLOW}[WARN]${C_RESET} $1"
}

mkdir -p "$COMMON_DIR" "$STEAMCMD_DIR" "$SERVERS_DIR" "$DATA_DIR"

# 必须 root（因为可能 apt-get）
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 或 sudo 运行此脚本"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# Global Array for Interactive Selection
SERVER_LIST_IDS=()

# ========= 辅助函数 =========
SERVER_LIST_IDS=()

ensure_deps() {
  local NEED="curl jq screen wget tar"
  local miss=()
  for cmd in $NEED; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      miss+=("$cmd")
    fi
  done

  if [ ${#miss[@]} -gt 0 ]; then
    echo "安装缺失依赖: ${miss[*]}"
    apt-get update -y
    apt-get install -y --no-install-recommends "${miss[@]}"
  fi

  # 添加 i386 架构（如果尚未添加）
  if ! dpkg --print-foreign-architectures | grep -q i386; then
    dpkg --add-architecture i386
    apt-get update -y
  fi

  apt-get install -y lib32gcc-s1 lib32stdc++6 lib32z1 >/dev/null 2>&1 || true
}



install_steamcmd() {
  if [ -f "$STEAMCMD_DIR/steamcmd.sh" ]; then
    return
  fi
  echo "安装 SteamCMD 到: $STEAMCMD_DIR"
  mkdir -p "$STEAMCMD_DIR"
  wget -qO- https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    | tar -xzf - -C "$STEAMCMD_DIR"
  chmod +x "$STEAMCMD_DIR/steamcmd.sh"
}

# 可选运行时钩子：data/<APPID>/env.sh
source_game_env() {
  local appid="$1"
  local envfile="$DATA_DIR/$appid/env.sh"
  if [ -f "$envfile" ]; then
    echo "执行 $envfile ..."
    /bin/bash "$envfile"
  fi
}

# 尝试获取 App Name (Return name or appid)
# $2: mode (force_remote or local_only or auto) - default auto
get_game_name() {
  local appid="$1"
  local mode="${2:-auto}"
  local namefile="$DATA_DIR/$appid/name"

  if [ -f "$namefile" ]; then
    cat "$namefile"
    return
  fi

  if [ "$mode" == "local_only" ]; then
     echo "$appid"
     return
  fi

  # 1. Try Local Server Map first (High Accuracy)
  if [ -f "$SERVER_CACHE_FILE" ]; then
     local map_name
     map_name=$(grep "^$appid[[:space:]]" "$SERVER_CACHE_FILE" | cut -f2- || true)
     if [ -n "$map_name" ]; then
        mkdir -p "$DATA_DIR/$appid"
        printf '%s' "$map_name" > "$namefile"
        echo "$map_name"
        return
     fi
  fi

  # 2. Try Web API
  if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
     local raw
     raw=$(curl -s --max-time 5 "https://store.steampowered.com/api/appdetails?appids=${appid}&l=english" | tr -d '\0')
     
     local nm
     nm=$(echo "$raw" | jq -r ".[\"${appid}\"].data.name // empty" 2>/dev/null)
     if [ -n "$nm" ] && [ "$nm" != "null" ]; then
        mkdir -p "$DATA_DIR/$appid"
        printf '%s' "$nm" > "$namefile"
        echo "$nm"
        return
     fi
  fi
  
  # 3. Fallback to AppID
  echo "$appid"
}

install_or_update_game() {
  local appid="$1"
  
  # Step 1: 解析名字 (Feature 5 enhancement: Option 2 needs name resolution)
  # 如果已经有名字缓存，就用缓存；否则尝试联网获取展示给用户确认
  # Step 1: 解析名字
  # 1. Try cache (handled by get_game_name)
  # 2. Try SteamCMD (Deep) directly if Option 2 is used
  local game_name
  game_name=$(get_game_name "$appid" "force_remote")
  
  # 如果返回的还是 ID，或者是 "Steam Application"，尝试深度解析
  if [ "$game_name" == "$appid" ] || [[ "$game_name" == *"Steam Application"* ]]; then
     local deep_name
     deep_name=$(get_name_via_steamcmd "$appid")
     if [ -n "$deep_name" ]; then
        game_name="$deep_name"
        # Cache it
        mkdir -p "$DATA_DIR/$appid"
        printf '%s' "$game_name" > "$DATA_DIR/$appid/name"
     fi
  fi
  
  echo "========================================"
  echo " 准备安装/更新: $game_name (AppID: $appid)"
  echo "========================================"
  # 如果是数字（解析失败或纯ID），再次确认
  if [ "$game_name" = "$appid" ]; then
     echo -e "${C_YELLOW}未能解析出游戏名称。${C_RESET}"
     read -p "是否继续安装? (y/n): " confirm_unk
     if [ "$confirm_unk" != "y" ]; then print_info "已取消"; return 1; fi
  else
     echo -e "即将安装: ${C_GREEN}$game_name${C_RESET}"
     read -p "确认安装? (y/n, 0取消): " confirm_go
     if [ "$confirm_go" != "y" ]; then print_info "已取消"; return 1; fi
     
     # 保存到 known_servers
     save_known_server "$game_name" "$appid" "$game_name"
  fi

  mkdir -p "$SERVERS_DIR/$appid" "$DATA_DIR/$appid"
  source_game_env "$appid"
  install_steamcmd
  
  print_info "开始调用 SteamCMD 安装/更新 AppID: $appid ..."
  "$STEAMCMD_DIR/steamcmd.sh" +force_install_dir "$SERVERS_DIR/$appid" +login anonymous +app_update "$appid" validate +quit
  print_success "安装/更新完成: $appid"
}

# screen session 名称统一为 game-<appid>
# screen session 名称统一为 game-<appid>
start_server() {
  local appid="$1"
  local game_dir="$SERVERS_DIR/$appid"
  local data_dir="$DATA_DIR/$appid"
  local session="game-$appid"

  if screen -list | grep -q "\.${session}"; then
    echo "服务器 $appid 已在运行 (session: $session)"
    return
  fi

  if [ ! -d "$game_dir" ]; then
    echo "游戏目录不存在: $game_dir"
    return
  fi

  cd "$game_dir"

  cd "$game_dir"

  # 1. Check saved command
  local saved_cmd
  saved_cmd=$(get_saved_start_cmd "$appid")
  
  local cmd=""
  
  if [ -n "$saved_cmd" ] && [ -f "$saved_cmd" ] || [ -f "./$saved_cmd" ]; then
      # Handle relative path check issue if saved_cmd is just filename
      if [ -f "$saved_cmd" ]; then
         cmd="$saved_cmd"
      elif [ -f "./$saved_cmd" ]; then
         cmd="./$saved_cmd"
      fi
      
      if [ -n "$cmd" ]; then
         echo "发现已保存的启动命令: $cmd"
      fi
  fi
  
  if [ -z "$cmd" ]; then
      if [ -f "./start-server.sh" ]; then
        cmd="./start-server.sh -batch -cachedir=$data_dir"
      elif [ -f "./ProjectZomboid64" ]; then
        cmd="./ProjectZomboid64"
      elif [ -f "./TerrariaServer" ]; then
        cmd="./TerrariaServer -config $data_dir/serverconfig.txt"
      else
    echo "未找到默认启动脚本。"
    echo "正在搜索可能的启动文件..."

    # 搜索候选文件 (深度2, 排除常见的非可执行后缀, 查找 .sh, .x86, 无后缀文件等)
    # 使用 while read loop 将结果存入数组
    local candidates=()
    local i=0
    
    # 构建 find 命令查找:
    # 1. 必须是文件 (-type f)
    # 2. 深度最多 2 (-maxdepth 2)
    # 3. 排除特定后缀 (如 .so, .dll, .txt, .json, .c, .h, .md)
    # 4. 或者是 executable, 或者是 .sh, 或者是无后缀
    # 注意: find 的逻辑比较复杂，这里简化策略：列出所有非屏蔽后缀的文件，然后由用户选择
    
    while IFS= read -r file; do
      candidates+=("$file")
    done < <(find . -maxdepth 2 -type f \
      ! -name "*.so" ! -name "*.so.*" \
      ! -name "*.dll" ! -name "*.txt" \
      ! -name "*.json" ! -name "*.xml" \
      ! -name "*.conf" ! -name "*.ini" \
      ! -name "*.c" ! -name "*.h" ! -name "*.o" \
      ! -name "*.md" ! -name "*.png" ! -name "*.jpg" \
      ! -name "*.log" ! -name "*.dat" ! -name "*.db" \
      ! -path "./Steam/*" ! -path "./steamapps/*" \
      | sort)

    if [ ${#candidates[@]} -eq 0 ]; then
       echo "未找到任何可疑的启动文件。"
       read -p "请手动输入启动命令 (0 取消): " cmd
       if [ "$cmd" = "0" ] || [ -z "$cmd" ]; then return 1; fi
    else
       echo "找到以下文件，请选择启动项："
       for i in "${!candidates[@]}"; do
          # 显示文件名 (去掉 ./)
          echo -e " ${C_CYAN}[$((i+1))]${C_RESET} ${candidates[$i]}"
       done
       
       read -p "请输入序号 (1-${#candidates[@]}) 或 0 取消: " idx
       if [ "$idx" == "0" ] || [ -z "$idx" ]; then return 1; fi
       
       if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -gt ${#candidates[@]} ]; then
          print_error "无效的序号。"
          return 1
       fi
       
       cmd="${candidates[$((idx-1))]}"
       
       # 自动赋予执行权限
       if [ ! -x "$cmd" ]; then
          echo "正在赋予执行权限: $cmd"
          chmod +x "$cmd"
       fi
       
       # 保存选择 (Persistence)
       # Strip ./ for cleaner JSON? Or keep it?
       # Keep as is to ensure it works.
       save_start_cmd "$appid" "$cmd"
    fi
  fi
  fi # End check cmd

  echo "使用命令启动: $cmd"
  
  # Module 4: Game Specific Optimizations & Process Management
  
  # 1. CPU Affinity (Skip CPU 0)
  local cpu_cores
  cpu_cores=$(nproc)
  local affinity_cmd=""
  if [ "$cpu_cores" -gt 1 ]; then
      # taskset -c 1-(N-1)
      affinity_cmd="taskset -c 1-$((cpu_cores-1))"
  fi
  
  # 2. Priority
  local nice_cmd="nice -n -10 ionice -c 2 -n 0"
  
  # 3. Engine Specifics
  local engine_args=""
  
  # Detect Java (Minecraft, PZ)
  if [[ "$cmd" == *"java"* || "$cmd" == *"ProjectZomboid"* ]]; then
     local total_mem
     total_mem=$(free -m | awk '/^Mem:/{print $2}')
     # Simple heuristic: 75% RAM for Heap
     local heap=$((total_mem * 3 / 4))
     # If not customized in cmd, might add java args. 
     # But typically cmd is a script or binary.
     # For ProjectZomboid64 (binary) it reads .json usually.
     # If cmd is direct java command, we might append.
     # Assuming user script handles args, but we can set environment variables if supported.
     export _JAVA_OPTIONS="-XX:+UseG1GC -Xmx${heap}m"
  fi
  
  # Source Engine (Approximate detection)
  if [[ "$cmd" == *"srcds"* ]]; then
     engine_args=" -high"
  fi
  
  # vmtouch (Small file protection) - Optional
  if command -v vmtouch >/dev/null 2>&1; then
     print_info "Locking critical config files into memory..."
     find "$data_dir" -name "*.json" -o -name "*.ini" -o -name "*.db" | xargs -r vmtouch -dl >/dev/null 2>&1 &
  fi
  
  # Final Command Composition
  # We wrap in screen, so we put nice/taskset inside
  # screen -dmS session bash -lc "exec niceness taskset cmd"
  
  local final_exec="$nice_cmd $affinity_cmd $cmd $engine_args"
  
  screen -dmS "$session" bash -lc "exec $final_exec"
  echo "✅ 已在 screen 后台启动: $session"
  echo "   (Optimized: $affinity_cmd $nice_cmd)"
  echo "   查看控制台命令: screen -r $session"
}

stop_server() {
  local appid="$1"
  local session="game-$appid"
  if screen -list | grep -q "\.${session}"; then
    screen -S "$session" -X quit && print_success "已停止 $appid ($session)"
  else
    print_warn "未发现运行中的 session: $session"
  fi
}
# 删除已安装的服务器及其数据（不可恢复）
delete_server() {
  local appid="$1"
  local server_dir="$SERVERS_DIR/$appid"
  local data_dir="$DATA_DIR/$appid"
  local session="game-$appid"

  # 检查是否存在安装或数据
  if [ ! -d "$server_dir" ] && [ ! -d "$data_dir" ]; then
    echo "未找到 AppID $appid 的安装或数据目录（$server_dir 或 $data_dir）。取消。"
    return
  fi

  # 如果正在运行，先询问是否停止
  if screen -list | grep -q "\.${session}"; then
    read -p "检测到 session $session 正在运行，是否先停止它? (y/n): " stopans
    if [ "$stopans" = "y" ]; then
      screen -S "$session" -X quit || echo "提示：尝试停止失败，请手动停止后再删除。"
      # 给 screen 一点时间收尾
      sleep 1
    else
      echo "请先停止运行的服务器再删除；取消删除。"
      return
    fi
  fi

  # 强确认（避免误删）
  read -p "确认要永久删除 AppID $appid 的安装与数据？(输入 yes 确认, 0 取消): " confirm
  if [ "$confirm" != "yes" ]; then
    echo "删除已取消"
    return 1
  fi

  # 备份选项（建议）
  if [ -d "$data_dir" ]; then
    read -p "是否先备份数据目录 $data_dir 到 data/<appid>/backup_before_delete_<ts>.tar.gz ? (y/n): " bakans
    if [ "$bakans" = "y" ]; then
      dest="${data_dir}/backup_before_delete_$(date +%Y%m%d%H%M%S).tar.gz"
      tar -czf "$dest" -C "$data_dir" . && echo "已备份到: $dest" || echo "备份失败，继续后续删除操作..."
    fi
  fi

  # 真正删除
  echo "删除目录：$server_dir 与 $data_dir ..."
  rm -rf "$server_dir" "$data_dir"

  # 删除缓存的 name 文件（若存在）
  if [ -f "$DATA_DIR/$appid/name" ]; then
    rm -f "$DATA_DIR/$appid/name"
  fi

  # 删除 nat.conf（若存在）
  if [ -f "$DATA_DIR/$appid/nat.conf" ]; then
    rm -f "$DATA_DIR/$appid/nat.conf"
  fi
}
  # ========= Phase 2: Search & Name Resolution =========

# 更新本地 Steam 服务器列表缓存 (GetAppList)
# 文件格式: AppID <tab> Name
SERVER_CACHE_FILE="$COMMON_DIR/steam_servers_all.txt"
KNOWN_SERVERS_FILE="$COMMON_DIR/known_servers.json"
KNOWN_SERVERS_URL="https://raw.githubusercontent.com/TONYUNTURN/Game-server-manager/refs/heads/main/known_servers.json"

# 从 GitHub 更新 known_servers.json 并合并本地数据
update_known_servers() {
  echo "正在检查/更新 known_servers.json ..."
  local tmp_remote="/tmp/ks_remote.json"
  
  # Download remote
  if ! curl -s --max-time 10 "$KNOWN_SERVERS_URL" > "$tmp_remote"; then
     echo "⚠️  无法从 GitHub 下载 known_servers.json，跳过更新。"
     rm -f "$tmp_remote"
     return
  fi
  
  # Validate JSON
  if ! jq -e . "$tmp_remote" >/dev/null 2>&1; then
      echo "⚠️  下载的文件不是有效 JSON，跳过。"
      rm -f "$tmp_remote"
      return
  fi
  
  if [ ! -f "$KNOWN_SERVERS_FILE" ]; then
      mv "$tmp_remote" "$KNOWN_SERVERS_FILE"
      echo "✅ 已下载最新 known_servers.json"
      return
  fi
  
  # Merge Logic: Remote > Local (by ID)
  # We read local servers, remote servers, combine them.
  # If ID exists in both, use Remote (or combine? User said "以github上为准" -> Remote priority)
  # But we also want to keep "User added" ones.
  # Strategy:
  # 1. Load Local .servers -> L
  # 2. Load Remote .servers -> R
  # 3. Output = R + (L - R) (L entries where id is not in R)
  
  local tmp_merged="/tmp/ks_merged.json"
  
  jq -n --slurpfile remote "$tmp_remote" --slurpfile local "$KNOWN_SERVERS_FILE" '
    ($remote[0].servers) as $R |
    ($local[0].servers // []) as $L |
    # Create a set of Remote IDs for fast lookup
    ([$R[].appid] | unique) as $R_ids |
    
    # Filter Local: keep only those NOT in Remote
    ($L | map(select(.appid as $aid | $R_ids | index($aid) | not))) as $L_kept |
    
    # Combine
    { "servers": ($R + $L_kept) }
  ' > "$tmp_merged"
  
  if [ -s "$tmp_merged" ]; then
      mv "$tmp_merged" "$KNOWN_SERVERS_FILE"
      echo "✅ 已合并 GitHub 更新与本地数据。"
  else
      echo "⚠️  合并失败 (JSON Error?), 保留旧文件。"
  fi
  
  rm -f "$tmp_remote" "$tmp_merged"
}

update_server_cache() {
  # 如果文件存在且小于 7 天，跳过 (7 * 24 * 60 = 10080 minutes)
  if [ -f "$SERVER_CACHE_FILE" ]; then
    if [ $(find "$SERVER_CACHE_FILE" -mmin -10080 2>/dev/null) ]; then
      return
    fi
    echo "本地服务器列表缓存已过期 (>7天)，准备更新..."
  else
    echo "本地服务器列表缓存不存在，准备下载..."
  fi

  echo "正在下载 Steam AppList (可能需要几秒钟)..."
  local json_dump="/tmp/steam_apps.json"
  
  # 下载 full list
  curl -s --max-time 60 "https://api.steampowered.com/ISteamApps/GetAppList/v2/" > "$json_dump"
  
  if [ ! -s "$json_dump" ]; then
    echo "下载失败或为空，跳过更新。"
    rm -f "$json_dump"
    return
  fi

  # 简单的 JSON 校验
  if ! jq -e . "$json_dump" >/dev/null 2>&1; then
     echo "⚠️  下载的 AppList 不是有效的 JSON (可能 API 限制)，跳过更新。"
     rm -f "$json_dump"
     return
  fi

  echo "正在解析并构建 Dedicated Server 索引..."
  # 逻辑: 
  # 1. jq 提取 appid/name
  # 2. grep -i "server" (过滤掉绝大多数非 server 应用)
  # 3. 过滤掉工具、Demo 等 (简单的关键词排除)
  # 4. 格式化为: appid \t name
  
  jq -r '.applist.apps[] | "\(.appid)\t\(.name)"' "$json_dump" 2>/dev/null \
    | grep -i "server" \
    | grep -ivE "test|demo|trailer|video|dlc|driver|tool|sdk" \
    > "$SERVER_CACHE_FILE" || true
    
  echo "索引构建完成。条目数: $(wc -l < "$SERVER_CACHE_FILE")"
  rm -f "$json_dump"
}

# 通过 SteamCMD 获取精准名称 (Deep Inspection)
get_name_via_steamcmd() {
  local appid="$1"
  # 确保 steamcmd 可用
  install_steamcmd >/dev/null 2>&1
  
  echo "正在深度解析 AppID $appid 名称 (SteamCMD)..." >&2
  local info
  info=$("$STEAMCMD_DIR/steamcmd.sh" +login anonymous +app_info_print "$appid" +quit 2>/dev/null)
  
  # 提取 logic:
  # 寻找 "common" 块，然后提取里面的 "name"
  # 这是一个非常简化的 parser，假设 "common" 后面的第一个 "name" 是游戏名
  # 结构参考: "common" { ... "name" "Project Zomboid" ... }
  
  # 1. 找到 common 区块
  # 2. 在里面找到 name
  local extracted
  # 使用 grep -pcrE 可能太复杂，这里用 sed 来做多行匹配的简化版
  # 只要匹配到 common 之后出现的 "name" "XXXX" 
  
  # 临时文件处理比较稳妥
  local tmp_info="/tmp/info_$appid.txt"
  echo "$info" > "$tmp_info"
  
  # awk logic:
  # enter_common flag
  # if enter_common, find "name", print, exit
  extracted=$(awk '
    /"common"/ { inside=1 } 
    inside && /"name"/ { 
        # Line format: "name" "My Game"
        # Remove "name" and quotes
        $1=""; 
        gsub(/"/, "", $0);
        # Trim leading space
        sub(/^[ \t]+/, "", $0);
        print $0; 
        exit 
    }
  ' "$tmp_info")
  
  rm -f "$tmp_info"
  
  if [ -n "$extracted" ]; then
     echo "$extracted"
  else
     echo ""
  fi
}



# 缓存 running sessions 避免每次循环 check
get_running_sessions_cached() {
    screen -ls | grep -o "game-[0-9]\+" | sort | uniq
}

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
    
    # 尝试快速获取名称 (local preferred)
    local name
    name=$(get_game_name "$appid")
    
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
     name=$(get_game_name "$appid")
     # Clean output for dashboard
     printf " ${C_CYAN}[%d]${C_RESET} ${C_GREEN}●${C_RESET} %-20s (ID: %s)\n" "$i" "$name" "$appid"
  done
  return 0
}

# Helper for interactive selection
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
      # Assume text input is manual ID? Or error?
      # Let's assume error for safety in "Index Mode", usually user won't type ID if they see [1] [2]
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


backup_save() {
  local appid="$1"
  local target_dir="$DATA_DIR/$appid"
  if [ ! -d "$target_dir" ]; then
    echo "未找到数据目录: $target_dir"
    return
  fi
  local dest="${target_dir}/backup_$(date +%Y%m%d%H%M%S).tar.gz"
  tar -czf "$dest" -C "$target_dir" . && echo "备份完成: $dest"
}

# ========= 新增：Steam 搜索并安装（使用 jq 做 URL encode，避免 python 依赖） =========
# 解析 Dedicated Server AppID


# 获取已保存的启动命令
get_saved_start_cmd() {
  local appid="$1"
  if [ ! -f "$KNOWN_SERVERS_FILE" ]; then return; fi
  
  # jq query: find matching appid, extract cmd
  jq -r --arg id "$appid" '.servers[] | select(.appid == $id) | .cmd // empty' "$KNOWN_SERVERS_FILE" 2>/dev/null
}

# 保存启动命令到 known_servers
save_start_cmd() {
  local appid="$1"
  local cmd="$2"
  
  if [ ! -f "$KNOWN_SERVERS_FILE" ]; then 
      echo '{"servers": []}' > "$KNOWN_SERVERS_FILE"
  fi
  
  local tmp_json
  tmp_json=$(mktemp)
  
  # Logic:
  # 1. Check if entry exists for this appid
  # 2. If exists, update .cmd
  # 3. If not exists, create new entry with name="Unknown" (shouldn't happen usually if installed via GSM)
  
  # Easier way: select entry, update.
  # If entry doesn't exist, we might need to add it, but normally we only save cmd for installed games which should be in known_servers if installed via Option 5 or searched.
  # But if user installed manually or ID lookup failed, it might not be there.
  
  # Let's try to update if exists.
  jq --arg id "$appid" --arg c "$cmd" '
    (
      .servers |= map(if .appid == $id then . + {"cmd": $c} else . end)
    )
  ' "$KNOWN_SERVERS_FILE" > "$tmp_json"
  
  # Check if it was updated (dirty check: if file changed?)
  # Actually, if the appid is not in list, the map above does nothing.
  # We should check if we need to append.
  # Safe bet: start_server usually called on installed games. 
  # Let's just assume we only update existing records for now to avoid complexity of fetching name again.
  
  if jq -e --arg id "$appid" '.servers[] | select(.appid == $id)' "$KNOWN_SERVERS_FILE" >/dev/null 2>&1; then
      mv "$tmp_json" "$KNOWN_SERVERS_FILE"
  else
      # Entry not found, ignore saving for now or append minimal?
      # Let's append minimal to support "Manual Install" case
      jq --arg id "$appid" --arg c "$cmd" \
         '.servers += [{"name": "Custom Server", "appid": $id, "cmd": $c, "keywords": []}]' \
         "$KNOWN_SERVERS_FILE" > "$tmp_json" && mv "$tmp_json" "$KNOWN_SERVERS_FILE"
  fi
  rm -f "$tmp_json"
}

# 保存到 known_servers.json
save_known_server() {
  local name="$1"
  local appid="$2"
  local term="$3"
  
  if [ ! -f "$KNOWN_SERVERS_FILE" ]; then
    echo '{"servers": []}' > "$KNOWN_SERVERS_FILE"
  fi

  # 检查是否已存在
  # New schema: .servers[] .appid
  if jq -e --arg id "$appid" '.servers[] | select(.appid == $id)' "$KNOWN_SERVERS_FILE" >/dev/null 2>&1; then
    # 已存在，跳过
    return
  fi

  echo "正在保存 $name ($appid) 到本地已知列表..."
  
  # 关键词生成逻辑
  # 1. Name split by space. If >1 words => Initials.
  # 2. If 1 word => First 3 chars.
  # 3. Always lowercase.
  
  local name_clean
  # Remove special chars for keyword gen?
  name_clean=$(echo "$name" | sed 's/[^a-zA-Z0-9 ]//g' | tr 'A-Z' 'a-z')
  
  local keyword_arr="[]"
  
  # Check word count
  local word_count
  word_count=$(echo "$name_clean" | awk '{print NF}')
  
  local k1=""
  if [ "$word_count" -gt 1 ]; then
      # Initials
      k1=$(echo "$name_clean" | awk '{ for(i=1;i<=NF;i++) printf substr($i,1,1) }')
  else
      # First 3 chars
      k1=$(echo "$name_clean" | awk '{ print substr($1,1,3) }')
  fi
  
  # Construct JSON update
  local tmp_json
  tmp_json=$(mktemp)
  
  jq --arg nm "$name" --arg id "$appid" --arg k "$k1" \
     '.servers += [{"name": $nm, "appid": $id, "keywords": [$k]}]' \
     "$KNOWN_SERVERS_FILE" > "$tmp_json" && mv "$tmp_json" "$KNOWN_SERVERS_FILE"
      
  echo "已保存 (Keyword: $k1)。"
}

# 检查网络连通性
# 检查网络连通性 (Fix: Option 1 API Error)
check_network() {
  # 以前是 curl -s ... appids=10，如果不成功直接把功能封了。
  # 现在稍微宽容一点，或者换个更稳的 endpoint。
  # 实际上，如果 API 返回 429 或 error，也不代表完全断网。
  # 只要能解析 dns 并且有回包就行。
  echo "正在检查 Steam API 连通性..."
  
  # 使用 curl -I 检查头部即可，或者检查 google
  if curl -s --head --max-time 3 "https://store.steampowered.com/" >/dev/null; then
    return 0
  fi
  
  # 如果 store 失败，尝试 api
  if curl -s --max-time 3 "https://api.steampowered.com/ISteamWebAPI/GetAPIList/v1/" >/dev/null; then
    return 0
  fi

  echo "⚠️  无法连接到 Steam Store/API。搜索功能可能不可用。"
  echo "    (如果你确认网络正常，可以忽略此错误继续尝试)"
  # return 1 # 不强制 block，让用户自己决定，或者 ask
  read -p "是否强制继续尝试搜索? (y/n): " force
  if [ "$force" = "y" ]; then return 0; fi
  return 1
}

steam_search_and_install() {
  set +e
  
  # Feature: First time update (or always update check)
  update_known_servers

  # 检查/更新 Steam Cache
  update_server_cache
  
  check_network || print_warn "Steam API 连通性检查失败。"

  read -p "搜索关键词 (英文，例: zomboid): " SEARCH_KEYWORD
  if [ -z "$SEARCH_KEYWORD" ]; then
    print_info "关键词为空，取消。"
    return
  fi
  
  local term_lower
  term_lower=$(echo "$SEARCH_KEYWORD" | tr 'A-Z' 'a-z')
  
  local merged_results="/tmp/search_results_$$.txt"
  touch "$merged_results"
  
  # 1. Search Known Servers (New Schema)
  if [ -f "$KNOWN_SERVERS_FILE" ]; then
     jq -r --arg t "$term_lower" '
       .servers[] 
       | select(.keywords[] | contains($t)) 
       | "\(.appid)\t\(.name) [Known]"
     ' "$KNOWN_SERVERS_FILE" >> "$merged_results" 2>/dev/null || true
  fi
  
  # 2. Search Steam App Cache
  if [ -f "$SERVER_CACHE_FILE" ]; then
     grep -i "$SEARCH_KEYWORD" "$SERVER_CACHE_FILE" >> "$merged_results" || true
  fi
  
  # 3. Search Web API
  local term_encoded
  term_encoded=$(printf '%s' "$SEARCH_KEYWORD" | jq -s -R -r @uri)
  local res
  res=$(curl -s --max-time 5 "https://store.steampowered.com/api/storesearch/?term=${term_encoded}&l=english&cc=US")
  if [ -n "$res" ]; then
     echo "$res" | jq -r '.items[] | "\(.id)\t\(.name)"' >> "$merged_results" 2>/dev/null || true
  fi
  
  if [ ! -s "$merged_results" ]; then
     print_warn "未找到匹配结果。"
     rm -f "$merged_results"
     return
  fi
  
  print_header "搜索结果 (Top 15)"
  
  local ids=()
  local names=()
  local i=0
  
  # Sort & Dedup
  while IFS=$'\t' read -r appid name; do
     [ -z "$appid" ] && continue
     ids+=("$appid")
     names+=("$name")
     if [ $i -ge 15 ]; then break; fi
  done < <(sort -u -k1,1 "$merged_results" | sort -t$'\t' -k2)
  
  rm -f "$merged_results"
  
  if [ ${#ids[@]} -eq 0 ]; then
     print_warn "处理后无结果。"
     return
  fi

  for i in "${!ids[@]}"; do
     printf " ${C_CYAN}[%d]${C_RESET} %-40s (AppID: %s)\n" "$((i+1))" "${names[$i]}" "${ids[$i]}"
  done
  
  echo ""
  read -p "选择序号安装 (0 取消): " idx
  if [ -z "$idx" ] || ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -eq 0 ] || [ "$idx" -gt ${#ids[@]} ]; then
     return
  fi
  
  local sel_id="${ids[$((idx-1))]}"
  install_or_update_game "$sel_id"
  set -e
}

# ========= Performance Tuning Module =========

detect_env() {
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    systemd-detect-virt || echo "physical"
  elif [ -f /sys/class/dmi/id/product_name ]; then
    if grep -iqE "kvm|vmware|virtual|xen" /sys/class/dmi/id/product_name; then
      echo "kvm"
    else
      echo "physical"
    fi
  else
    echo "physical"
  fi
}

tuning_sys_net() {
  print_header "Module 1: System & Network Tuning"
  
  local virt
  virt=$(detect_env)
  print_info "Environment detected: $virt"

  # Network Stack
  print_info "Optimizing Network Stack (TCP BBR, Buffers)..."
  
  cat > /etc/sysctl.d/99-gsm-tuning.conf <<EOF
# GSM Tuning
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 65535
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
fs.file-max = 2097152
vm.panic_on_oom = 0
EOF
  sysctl -p /etc/sysctl.d/99-gsm-tuning.conf >/dev/null 2>&1 || print_warn "sysctl reload failed"

  # File Descriptors
  print_info "Increasing File Descriptor Limits..."
  if ! grep -q "root soft nofile 65535" /etc/security/limits.conf 2>/dev/null; then
    echo "* soft nofile 65535" >> /etc/security/limits.conf
    echo "* hard nofile 65535" >> /etc/security/limits.conf
    echo "root soft nofile 65535" >> /etc/security/limits.conf
    echo "root hard nofile 65535" >> /etc/security/limits.conf
  fi
  ulimit -n 65535 2>/dev/null || true

  # Disk I/O (Only for KVM/Virtual)
  if [[ "$virt" == "kvm" || "$virt" == "oracle" || "$virt" == "xen" ]]; then
     print_info "Virtualization detected, setting I/O scheduler to none/noop..."
     for dev in /sys/block/sd*/queue/scheduler; do
       if [ -f "$dev" ]; then
          echo "none" > "$dev" 2>/dev/null || echo "noop" > "$dev" 2>/dev/null || true
       fi
     done
  fi
}

tuning_memory() {
  print_header "Module 2: Memory Strategy"
  
  local total_mem
  total_mem=$(free -m | awk '/^Mem:/{print $2}')
  print_info "Total Memory: ${total_mem}MB"

  if [ "$total_mem" -lt 4096 ]; then
     # Case A: < 4GB -> Enable zRAM
     print_info "Low Memory detected. Configuring zRAM..."
     if command -v zramctl >/dev/null 2>&1; then
         # Try manual setup
         modprobe zram num_devices=1 2>/dev/null || true
         if [ -b /dev/zram0 ]; then
             # Reset if needed
             swapoff /dev/zram0 2>/dev/null || true
             zramctl --reset /dev/zram0 2>/dev/null || true
             
             local zsize=$((total_mem / 2))
             echo "${zsize}M" > /sys/block/zram0/disksize || true
             mkswap /dev/zram0 >/dev/null 2>&1 || true
             swapon -p 100 /dev/zram0 >/dev/null 2>&1 || true
             print_success "zRAM enabled on /dev/zram0 (${zsize}M)"
         fi
     fi
     sysctl -w vm.swappiness=10 >/dev/null
     
  elif [ "$total_mem" -gt 8192 ]; then
     # Case B: > 8GB
     print_info "High Memory detected. Tuning for latency..."
     sysctl -w vm.swappiness=0 >/dev/null
     if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo "never" > /sys/kernel/mm/transparent_hugepage/enabled
     fi
  fi
}

start_watchdog_service() {
   if screen -list | grep -q "gsm-watchdog"; then
       print_info "Watchdog already running."
   else
       print_info "Starting GSM Watchdog..."
       # Pass absolute path to self
       local self_path
       self_path=$(readlink -f "$0")
       screen -dmS gsm-watchdog bash -c "$self_path __watchdog_internal"
       print_success "Watchdog started."
   fi
}

run_full_tuning() {
    tuning_sys_net
    tuning_memory
    start_watchdog_service
    print_success "System Performance Tuning Completed."
    read -p "Press Enter to return..."
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

# ========= 主菜单 =========
ensure_deps

while true; do
  clear
  echo -e "${C_BOLD}${C_BLUE}GSM - Game Server Manager${C_RESET}"
  echo ""
  
  # Dashboard (Always Show Installed Servers)
  # list_servers now handles the visuals for the dashboard
  list_servers

  echo -e "${C_BOLD}--- [ Main Menu ] ---${C_RESET}"
  echo -e " ${C_CYAN}1)${C_RESET} List Installed Servers   ${C_CYAN}6)${C_RESET} Backup Server Data"
  echo -e " ${C_CYAN}2)${C_RESET} Start Server           ${C_CYAN}7)${C_RESET} Exec Env Config"
  echo -e " ${C_CYAN}3)${C_RESET} Stop Server            ${C_CYAN}8)${C_RESET} System Performance Tuning ${C_GREEN}[NEW]${C_RESET}"
  echo -e " ${C_CYAN}4)${C_RESET} Search & Install       ${C_CYAN}9)${C_RESET} Delete Server ${C_RED}[DANGER]${C_RESET}"
  echo -e " ${C_CYAN}5)${C_RESET} Install by AppID       ${C_RED}99)${C_RESET} Uninstall GSM ${C_RED}[DESTRUCTIVE]${C_RESET}"
  echo -e " ${C_CYAN}0)${C_RESET} Exit"
  echo ""
  
  read -p "Select option: " choice
  echo ""
  
  case "$choice" in
    1) 
       clear
       list_servers 
       ;;
    2)
       clear
       list_servers
       appid=$(select_server_interactive "启动 AppID (序号/0返回): ")
       [[ "$appid" == "0" || -z "$appid" ]] && continue
       [ -n "$appid" ] && start_server "$appid"
       ;;
    3)
       clear
       echo -e "${C_GREEN}=== Active Servers ===${C_RESET}"
       list_running_servers || { echo "No running servers."; continue; }
       echo ""
       appid=$(select_server_interactive "停止 AppID (序号/0返回): ")
       [[ "$appid" == "0" || -z "$appid" ]] && continue
       [ -n "$appid" ] && stop_server "$appid"
       ;;
    4) 
       clear
       steam_search_and_install 
       ;;
    5)
       clear
       read -p "输入AppID (0 返回): " appid
       [[ "$appid" == "0" || -z "$appid" ]] && continue
       [ -n "$appid" ] && install_or_update_game "$appid"
       ;;
    6)
       clear
       list_servers
       appid=$(select_server_interactive "备份 AppID (序号/0返回): ")
       [[ "$appid" == "0" || -z "$appid" ]] && continue
       [ -n "$appid" ] && backup_save "$appid"
       ;;
    7)
       clear
       # Env is typically manual ID or installed? 
       # Let's assume installed for now, use list_servers
       list_servers
       appid=$(select_server_interactive "AppID for Env (序号/0返回): ")
       [[ "$appid" == "0" || -z "$appid" ]] && continue
       source_game_env "$appid"
       ;;

    8)
       clear
       run_full_tuning
       ;;
    9)
       clear
       list_servers
       appid=$(select_server_interactive "删除 AppID (序号/0返回): ")
       [[ "$appid" == "0" || -z "$appid" ]] && continue
       [ -n "$appid" ] && delete_server "$appid"
       ;;
    99)
       uninstall_gsm
       ;;
    0) echo "Bye."; exit 0 ;;
    *) print_error "Invalid option" ;;
  esac
  
  # Auto-refresh: If action returned 1 (cancel), skip pause
  # If action returned 0 (success/info), pause for user to read
  if [ $? -eq 0 ]; then
     echo ""
     read -p "Press Enter to continue..." dummy
  fi
done
