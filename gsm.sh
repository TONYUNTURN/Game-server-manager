#!/bin/bash
set -euo pipefail

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

mkdir -p "$COMMON_DIR" "$STEAMCMD_DIR" "$SERVERS_DIR" "$DATA_DIR"

# 必须 root（因为可能 apt-get）
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 或 sudo 运行此脚本"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# ========= 辅助函数 =========
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
     read -p "未能解析出游戏名称，是否继续安装? (y/n): " confirm_unk
     if [ "$confirm_unk" != "y" ]; then echo "已取消"; return; fi
  else
     read -p "确认安装此游戏? (y/n): " confirm_go
     if [ "$confirm_go" != "y" ]; then echo "已取消"; return; fi
     
     # 保存到 known_servers
     save_known_server "$game_name" "$appid" "$game_name"
  fi

  mkdir -p "$SERVERS_DIR/$appid" "$DATA_DIR/$appid"
  source_game_env "$appid"
  install_steamcmd
  
  echo "🚀 开始调用 SteamCMD 安装/更新 AppID: $appid ..."
  "$STEAMCMD_DIR/steamcmd.sh" +force_install_dir "$SERVERS_DIR/$appid" +login anonymous +app_update "$appid" validate +quit
  echo "✅ 安装/更新完成: $appid"
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

  local cmd=""
  if [ -f "./start-server.sh" ]; then
    cmd="./start-server.sh -batch -cachedir=$data_dir"
  elif [ -f "./ProjectZomboid64" ]; then
    cmd="./ProjectZomboid64"
  elif [ -f "./TerrariaServer" ]; then
    cmd="./TerrariaServer -config $data_dir/serverconfig.txt"
  else
    echo "可执行文件列表（供参考）："
    find . -maxdepth 1 -type f -executable -printf "%f\n" || ls -1
    read -p "请输入启动命令 (例如 ./MyServerBinary 或 java -jar server.jar): " cmd
  fi

  echo "使用命令启动: $cmd"
  screen -dmS "$session" bash -lc "exec $cmd"
  echo "✅ 已在 screen 后台启动: $session"
  echo "   查看控制台命令: screen -r $session"
}

stop_server() {
  local appid="$1"
  local session="game-$appid"
  if screen -list | grep -q "\.${session}"; then
    screen -S "$session" -X quit && echo "已停止 $appid (session: $session)"
  else
    echo "未发现运行中的 session: $session"
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
  read -p "确认要永久删除 AppID $appid 的安装与数据？此操作不可恢复，请输入：yes 来确认: " confirm
  if [ "$confirm" != "yes" ]; then
    echo "删除已取消（确认输入不是 yes）"
    return
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
  echo "== 📂 已安装服务器列表 =="
  if [ ! -d "$SERVERS_DIR" ]; then
    echo "  (无)"
    return
  fi

  # 预取运行状态
  local running_txt
  running_txt=$(screen -ls || true)
  
  local any=0
  # 遍历目录
  for appid in $(find "$SERVERS_DIR" -maxdepth 1 -type d -printf "%f\n" 2>/dev/null | grep -E '^[1-9][0-9]*$' | sort -n || true); do
    any=1
    # 尝试快速获取名称 (local preferred)
    local name
    name=$(get_game_name "$appid")
    
    local session="game-$appid"
    local status="[OFF]"
    if echo "$running_txt" | grep -q "\.${session}"; then
      status="[RUNNING 🟢]"
    else
      status="[STOPPED 🔴]"
    fi
    printf "  %-30s %s (AppID: %s)\n" "$name" "$status" "$appid"
  done

  if [ "$any" -eq 0 ]; then
    echo "  (无已安装的服务器)"
  fi
  echo ""
}

list_running_servers() {
  local running_txt
  running_txt=$(screen -ls || true)
  # Extract game IDs from running sessions
  local ids
  ids=$(echo "$running_txt" | grep -o "game-[0-9]\+" | sed 's/game-//' | sort | uniq)
  
  if [ -z "$ids" ]; then
     # No running servers, maybe don't print anything or just simple msg
     # But per request 1: "At startup, show running games"
     # This function returns text, caller decides how to show.
     return 1
  fi
  
  for appid in $ids; do
     local name
     name=$(get_game_name "$appid")
     # Format: [AppID] [Name] [Status]
     # Since we know they are running (from screen -ls)
     printf "  [%s] %-25s [RUNNING 🟢]\n" "$appid" "$name" 
  done
  return 0
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
  # User said "first time run... force update".
  # We will just call it every time entering search, fairly cheap (curl)
  update_known_servers

  # 检查/更新 Steam Cache
  update_server_cache
  
  check_network || echo "注意: Web API 可能不可用。"

  read -p "请输入搜索关键词 (英文，例: zomboid): " TERM
  if [ -z "$TERM" ]; then
    echo "关键词为空，取消。"
    return
  fi
  
  local term_lower
  term_lower=$(echo "$TERM" | tr 'A-Z' 'a-z')
  
  local merged_results="/tmp/search_results_$$.txt"
  touch "$merged_results"
  
  # 1. Search Known Servers (New Schema)
  if [ -f "$KNOWN_SERVERS_FILE" ]; then
     # Logic: select servers where ANY keyword contains term_lower
     # Output: appid \t name [Known]
     jq -r --arg t "$term_lower" '
       .servers[] 
       | select(.keywords[] | contains($t)) 
       | "\(.appid)\t\(.name) [Known]"
     ' "$KNOWN_SERVERS_FILE" >> "$merged_results" 2>/dev/null || true
  fi
  
  # 2. Search Steam App Cache
  if [ -f "$SERVER_CACHE_FILE" ]; then
     grep -i "$TERM" "$SERVER_CACHE_FILE" >> "$merged_results" || true
  fi
  
  # 3. Search Web API
  local term_encoded
  term_encoded=$(printf '%s' "$TERM" | jq -s -R -r @uri)
  local res
  res=$(curl -s --max-time 5 "https://store.steampowered.com/api/storesearch/?term=${term_encoded}&l=english&cc=US")
  if [ -n "$res" ]; then
     echo "$res" | jq -r '.items[] | "\(.id)\t\(.name)"' >> "$merged_results" 2>/dev/null || true
  fi
  
  if [ ! -s "$merged_results" ]; then
     echo "❌ 未找到匹配结果。"
     rm -f "$merged_results"
     return
  fi
  
  echo "🔎 找到以下结果 (前 15 条):"
  
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
     echo "❌ 处理后无结果。"
     return
  fi

  for i in "${!ids[@]}"; do
     echo "[$((i+1))] ${names[$i]} (AppID: ${ids[$i]})"
  done
  
  read -p "请选择序号安装 (0 返回): " idx
  if [ -z "$idx" ] || ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -eq 0 ] || [ "$idx" -gt ${#ids[@]} ]; then
     return
  fi
  
  local sel_id="${ids[$((idx-1))]}"
  install_or_update_game "$sel_id"
  set -e
}

# ========= 主菜单 =========
ensure_deps

while true; do
  # Feature 1: 脚本启动/循环时，展示目前运行的游戏
  clear
  echo ""
  echo "============================================"
  echo " 🕹️  当前运行中的服务器:"
  if ! list_running_servers; then
     echo "  (暂无运行中)"
  fi
  echo "============================================"
  
  cat <<'EOF'
  NAT VPS Dedicated 管理器 (已优化)
  ---------------------------------
  1)  通过steam搜索/安装游戏
  2)  通过AppID安装/更新游戏
  3)  启动服务器
  4)  停止服务器
  5)  列出所有已安装
  6)  备份服务器数据
  7)  执行 env.sh
  8)  删除服务器 (慎用)
  0)  退出
EOF

  read -p "请选择: " choice
  case "$choice" in
    1) steam_search_and_install ;;
    2)
      read -p "输入 AppID (例如 108600): " appid
      if [ -n "$appid" ]; then install_or_update_game "$appid"; fi
      ;;
    3)
      list_servers
      read -p "输入要启动的 AppID: " appid
      if [ -n "$appid" ]; then start_server "$appid"; fi
      ;;
    4)
      echo "== 运行中 =="
      list_running_servers || echo "(无)"
      read -p "输入要停止的 AppID: " appid
      if [ -n "$appid" ]; then stop_server "$appid"; fi
      ;;
    5) list_servers ;;
    6)
      list_servers
      read -p "输入要备份的 AppID: " appid
      if [ -n "$appid" ]; then backup_save "$appid"; fi
      ;;
    7)
      read -p "输入 AppID (将执行 data/<AppID>/env.sh): " appid
      source_game_env "$appid"
      ;;
    8)
      # Fix: Option 8 display bloated -> used list_servers optimized
      list_servers
      read -p "输入要删除的 AppID: " appid
      if [ -z "$appid" ]; then
        echo "AppID 为空，取消。"
      else
        delete_server "$appid"
      fi
      ;;
    0) echo "退出"; exit 0 ;;
    *) echo "无效选项" ;;
  esac
  
  echo
  read -p "按回车键继续..." dummy
done
