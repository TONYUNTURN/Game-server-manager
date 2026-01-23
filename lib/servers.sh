#!/bin/bash

# ==========================================
# GSM Server Operations
# ==========================================

start_server() {
  local appid="$1"
  local install_dir="$SERVERS_DIR/$appid"
  
  if [ ! -d "$install_dir" ]; then
    print_error "Server not installed or directory missing: $install_dir"
    return
  fi

  # Check if running
  if screen -list | grep -q "game-$appid"; then
    print_warn "Server $appid is already running (screen: game-$appid)."
    return
  fi
  
  # --- Find Start Command Logic ---
  local start_cmd=""
  local saved_cmd
  # get_saved_start_cmd logic (inline here or helper?)
  saved_cmd=$(jq -r --arg id "$appid" '.servers[] | select(.appid == $id) | .cmd // empty' "$KNOWN_SERVERS_FILE" 2>/dev/null)
  
  if [ -n "$saved_cmd" ]; then
      if [ -f "$install_dir/$saved_cmd" ] || [[ "$saved_cmd" == /* ]]; then
         start_cmd="$saved_cmd"
         print_info "Using saved start command: $start_cmd"
      fi
  fi
  
  if [ -z "$start_cmd" ]; then
      print_info "Scanning for start scripts..."
      local scripts=()
      while IFS= read -r file; do
          scripts+=("$file")
      done < <(find "$install_dir" -maxdepth 2 -type f \( -name "*.sh" -o -name "*.x86" -o -name "*.x86_64" -o -executable \) | head -n 20)
      
      if [ ${#scripts[@]} -eq 0 ]; then
          print_error "No executable scripts found in $install_dir"
          return
      fi
      
      echo "Select start script:"
      local i=0
      for s in "${scripts[@]}"; do
          i=$((i+1))
          local rel_path="${s#$install_dir/}"
          echo " [$i] $rel_path"
      done
      
      read -p "Choice: " choice
      if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -le "$i" ] && [ "$choice" -gt 0 ]; then
          start_cmd="${scripts[$((choice-1))]}"
          # Save it? 
          local rel_to_save="${start_cmd#$install_dir/}"
          
          # save_start_cmd logic inline
          local tmp_json=$(mktemp)
          jq --arg id "$appid" --arg c "$rel_to_save" \
           '(.servers |= map(if .appid == $id then . + {"cmd": $c} else . end))' \
           "$KNOWN_SERVERS_FILE" > "$tmp_json" && mv "$tmp_json" "$KNOWN_SERVERS_FILE"
           # Ensure ownership
           [ "$(id -u)" -eq 0 ] && chown "$GSM_USER:$GSM_GROUP" "$KNOWN_SERVERS_FILE"
      else
          print_error "Invalid selection."
          return
      fi
  fi
  
  # --- Execution ---
  local cmd_name=$(basename "$start_cmd")
  local cmd_dir=$(dirname "$start_cmd")
  
  # Inject Env
  local env_file="$DATA_DIR/$appid/env.sh"
  local env_inject=""
  if [ -f "$env_file" ]; then
      print_info "Loading environment: $env_file"
      env_inject="source \"$env_file\" &&"
  fi
  
  print_info "Starting server..."
  
  # Handling User
  if [ "$(id -u)" -eq 0 ]; then
      # Run as GSM_USER
      # Ensure data dir ownership
      mkdir -p "$DATA_DIR/$appid"
      chown -R "$GSM_USER:$GSM_GROUP" "$DATA_DIR/$appid"
      chown -R "$GSM_USER:$GSM_GROUP" "$install_dir"
      
      # Using runuser/su to start screen
      # Note: screen needs TTY usually. 'screen -dmS' works in background.
      su - "$GSM_USER" -c "cd \"$cmd_dir\" && screen -dmS \"game-$appid\" bash -c \"$env_inject ./$cmd_name; exec bash\""
  else
      cd "$cmd_dir"
      screen -dmS "game-$appid" bash -c "$env_inject ./$cmd_name; exec bash"
  fi
  
  print_success "Server started in screen session: game-$appid"
  print_info "Use 'screen -r game-$appid' to view."
}

stop_server() {
  local appid="$1"
  if ! screen -list | grep -q "game-$appid"; then
     print_warn "Server $appid is not running."
     return
  fi
  
  print_info "Stopping game-$appid..."
  
  if [ "$(id -u)" -eq 0 ]; then
     # Need to send command as the user who owns the screen
     su - "$GSM_USER" -c "screen -S game-$appid -X quit"
  else
     screen -S "game-$appid" -X quit
  fi
  print_success "Stopped."
}

delete_server() {
  local appid="$1"
  print_warn "DELETING SERVER $appid. This is irreversible."
  read -p "Are you sure? (y/n): " sure
  if [ "$sure" != "y" ]; then return; fi
  
  read -p "Create backup before delete? (y/n): " backup
  if [ "$backup" == "y" ]; then
      backup_save "$appid"
  fi
  
  stop_server "$appid"
  
  rm -rf "$SERVERS_DIR/$appid"
  # Don't delete data dir automatically unless requested?
  # Old script said "files and data directories".
  rm -rf "$DATA_DIR/$appid"
  
  print_success "Deleted."
}

backup_save() {
  local appid="$1"
  local target_dir="$DATA_DIR/$appid"
  if [ ! -d "$target_dir" ]; then
    echo "No data found: $target_dir"
    return
  fi
  
  local dest="${target_dir}/../backup_${appid}_$(date +%Y%m%d%H%M%S).tar.gz"
  
  if [ "$(id -u)" -eq 0 ]; then
      tar -czf "$dest" -C "$target_dir" .
      chown "$GSM_USER:$GSM_GROUP" "$dest"
  else
      tar -czf "$dest" -C "$target_dir" .
  fi
  
  print_success "Backup: $dest"
}
