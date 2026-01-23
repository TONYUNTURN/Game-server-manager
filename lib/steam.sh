#!/bin/bash

# ==========================================
# GSM Steam Module
# ==========================================

# Variables from Core (assumed sourced)
KNOWN_SERVERS_URL="https://raw.githubusercontent.com/TONYUNTURN/Game-server-manager/refs/heads/main/known_servers.json"
KNOWN_SERVERS_FILE="$COMMON_DIR/known_servers.json"
SERVER_CACHE_FILE="$COMMON_DIR/steam_servers_all.txt"

install_steamcmd() {
    if [ -f "$STEAMCMD_DIR/steamcmd.sh" ]; then
        return
    fi
    print_info "Installing SteamCMD..."
    mkdir -p "$STEAMCMD_DIR"
    curl -sqL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" | tar zxvf - -C "$STEAMCMD_DIR"
    print_success "SteamCMD installed."
}

# 通过 SteamCMD 获取精准名称 (Deep Inspection)
get_name_via_steamcmd() {
  local appid="$1"
  # 确保 steamcmd 可用
  install_steamcmd >/dev/null 2>&1
  
  # Must run as current user for logic, but steamcmd might update itself?
  # Assuming running as root or gsm user
  
  local info
  info=$("$STEAMCMD_DIR/steamcmd.sh" +login anonymous +app_info_print "$appid" +quit 2>/dev/null)
  
  local tmp_info="/tmp/info_$appid.txt"
  echo "$info" > "$tmp_info"
  
  local extracted
  extracted=$(awk '
    /"common"/ { inside=1 } 
    inside && /"name"/ { 
        $1=""; 
        gsub(/"/, "", $0);
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

update_known_servers() {
  # 下载并合并
  # New Logic: Just download overwriting might be safer for updates, but merging keeps local custom
  # Using the update_known_servers.py via python is cleaner, but here is bash fallback
  print_info "Checking for known_servers.json updates..."
  
  local tmp_remote="/tmp/known_servers_remote.json"
  curl -s --max-time 10 "$KNOWN_SERVERS_URL" > "$tmp_remote"
  
  if [ ! -s "$tmp_remote" ]; then
      print_warn "Cannot fetch known_servers.json from GitHub."
      rm -f "$tmp_remote"
      return
  fi
  
  if [ ! -f "$KNOWN_SERVERS_FILE" ]; then
      mv "$tmp_remote" "$KNOWN_SERVERS_FILE"
      print_success "Downloaded known_servers.json."
      return
  fi
  
  # Basic Merge: GitHub overrides local for same IDs? Or keep local?
  # Let's keep existing logic: Merge
  
  local tmp_merged="/tmp/known_servers_merged.json"
  
  # Using jq to merge: Remote items + Local items not in remote (preserve local additions)
  # Actually, usually we want Remote updates to override stale local data.
  jq -s '
    .[0].servers as $R | 
    .[1].servers as $L |
    
    ($R | map(.appid)) as $R_ids |
    
    ($L | map(select(.appid as $aid | $R_ids | index($aid) | not))) as $L_kept |
    
    { "servers": ($R + $L_kept) }
  ' "$tmp_remote" "$KNOWN_SERVERS_FILE" > "$tmp_merged" 2>/dev/null
  
  if [ -s "$tmp_merged" ]; then
      mv "$tmp_merged" "$KNOWN_SERVERS_FILE"
      echo "✅ Merged GitHub updates."
  else
      echo "⚠️  Merge failed, keeping old file."
  fi
  rm -f "$tmp_remote" "$tmp_merged"
}

get_game_name() {
  local appid="$1"
  local mode="${2:-auto}" # auto, local_only, force_remote
  
  # 1. Check known_servers.json
  if [ -f "$KNOWN_SERVERS_FILE" ]; then
      local name
      name=$(jq -r --arg id "$appid" '.servers[] | select(.appid == $id) | .name' "$KNOWN_SERVERS_FILE" 2>/dev/null)
      if [ -n "$name" ]; then
          echo "$name"
          return
      fi
  fi
  
  # 2. Check Steam Cache File
  if [ -f "$SERVER_CACHE_FILE" ]; then
      local name
      name=$(grep "^$appid" "$SERVER_CACHE_FILE" | cut -f2-)
      if [ -n "$name" ]; then
          echo "$name"
          return
      fi
  fi
  
  [ "$mode" == "local_only" ] && { echo "AppID $appid"; return; }

  # 3. Last Resort: SteamCMD Deep Inspection (Slow)
  # WARNING: This IS slow and will hang the UI if called in a loop (like list_servers).
  # We should only do this if explicitly requested or if we are sure we want to wait.
  # For dashboard, we prefer "AppID X" over hanging.
  
  if [ "$mode" == "force_remote" ]; then
      local name
      name=$(get_name_via_steamcmd "$appid")
      if [ -n "$name" ]; then
         echo "$name"
      else
         echo "AppID $appid"
      fi
  else
      # Default behavior: Don't hang. Return AppID.
      # Users can run "Update Server List" (Option 5) to populate cache.
      echo "AppID $appid"
  fi
}

install_or_update_game() {
  local appid="$1"
  print_header "Installing/Updating AppID $appid"
  
  install_steamcmd
  
  local name
  name=$(get_game_name "$appid")
  print_info "Game: $name"
  
  local install_dir="$SERVERS_DIR/$appid"
  mkdir -p "$install_dir"
  
  # Permissions: If running as root, we should chown this dir to GSM_USER before steamcmd
  if [ "$(id -u)" -eq 0 ]; then
     chown "$GSM_USER:$GSM_GROUP" "$install_dir"
     # Run steamcmd as GSM_USER
     # Need to make sure steamcmd itself is owned by GSM_USER
     chown -R "$GSM_USER:$GSM_GROUP" "$STEAMCMD_DIR"
     
     print_info "Running SteamCMD as user $GSM_USER..."
     su - "$GSM_USER" -c "$STEAMCMD_DIR/steamcmd.sh +force_install_dir \"$install_dir\" +login anonymous +app_update \"$appid\" validate +quit"
  else
     "$STEAMCMD_DIR/steamcmd.sh" +force_install_dir "$install_dir" +login anonymous +app_update "$appid" validate +quit
  fi
  
  print_success "SteamCMD finished."
  
  # If name was unknown, try to fetch it now and save it
  if [[ "$name" == *"Unknown"* ]]; then
      local new_name
      new_name=$(get_name_via_steamcmd "$appid")
      if [ -n "$new_name" ]; then
          print_info "Identified name: $new_name"
          # Call helper to save? 
          # We need to export save_known_server logic or put it here.
          # For now, let's leave it.
      fi
  fi
}

save_known_server() {
  local name="$1"
  local appid="$2"
  # Logic to append to json
  if [ ! -f "$KNOWN_SERVERS_FILE" ]; then echo '{"servers": []}' > "$KNOWN_SERVERS_FILE"; fi

  # Check exist
  if jq -e --arg id "$appid" '.servers[] | select(.appid == $id)' "$KNOWN_SERVERS_FILE" >/dev/null 2>&1; then
    return
  fi

  local name_clean
  name_clean=$(echo "$name" | sed 's/[^a-zA-Z0-9 ]//g' | tr 'A-Z' 'a-z')
  local k1=""
  local word_count
  word_count=$(echo "$name_clean" | awk '{print NF}')
  if [ "$word_count" -gt 1 ]; then
      k1=$(echo "$name_clean" | awk '{ for(i=1;i<=NF;i++) printf substr($i,1,1) }')
  else
      k1=$(echo "$name_clean" | awk '{ print substr($1,1,3) }')
  fi
  
  local tmp_json
  tmp_json=$(mktemp)
  jq --arg nm "$name" --arg id "$appid" --arg k "$k1" \
     '.servers += [{"name": $nm, "appid": $id, "keywords": [$k]}]' \
     "$KNOWN_SERVERS_FILE" > "$tmp_json" && mv "$tmp_json" "$KNOWN_SERVERS_FILE"
     
  # Ensure ownership if root
  if [ "$(id -u)" -eq 0 ]; then
     chown "$GSM_USER:$GSM_GROUP" "$KNOWN_SERVERS_FILE"
  fi
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
