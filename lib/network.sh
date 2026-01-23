#!/bin/bash

# ==========================================
# GSM Network & Update Module
# ==========================================

check_network() {
  print_info "Checking network connectivity..."
  
  if curl -s --head --max-time 3 "https://store.steampowered.com/" >/dev/null; then
    return 0
  fi
  
  if curl -s --max-time 3 "https://api.steampowered.com/ISteamWebAPI/GetAPIList/v1/" >/dev/null; then
    return 0
  fi

  print_warn "Cannot connect to Steam network."
  read -p "Continue anyway? (y/n): " force
  if [ "$force" = "y" ]; then return 0; fi
  return 1
}

update_self() {
  print_header "Update GSM"
  local remote_url="https://raw.githubusercontent.com/TONYUNTURN/Game-server-manager/refs/heads/main/gsm.sh"
  local tmp_file="/tmp/gsm_update_$$"
  
  print_info "Downloading latest version..."
  if curl -L -s --max-time 10 "$remote_url" > "$tmp_file"; then
     if [ ! -s "$tmp_file" ]; then
        print_error "Download failed."
        rm -f "$tmp_file"
        return
     fi
     
     if ! bash -n "$tmp_file"; then
        print_error "Syntax error in downloaded script."
        rm -f "$tmp_file"
        return
     fi
     
     print_success "Update downloaded. Applying..."
     cp "$0" "${0}.bak"
     mv "$tmp_file" "$0"
     chmod +x "$0"
     
     # TODO: Also update libs? Currently repo structure is single file vs our new split.
     # WARNING: If upstream is still monolithic, this update will REVERT our modularization.
     # For now, let's warn about that or disable it if we are on the modular branch.
     
     print_warn "NOTE: Upstream update might revert modular structure if not merged yet."
     print_success "Done. Restarting..."
     sleep 1
     exec "$0"
  else
     print_error "Download failed."
     rm -f "$tmp_file"
  fi
}
