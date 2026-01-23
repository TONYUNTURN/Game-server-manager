#!/bin/bash

# ==========================================
# GSM Tuning Module
# ==========================================

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
  
  if [ "$(id -u)" -ne 0 ]; then
      print_error "Tuning requires root privileges."
      return 1
  fi
  
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
  
  if [ "$(id -u)" -ne 0 ]; then
      print_error "Tuning requires root privileges."
      return 1
  fi
  
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

run_full_tuning() {
    tuning_sys_net
    tuning_memory
    print_success "System Performance Tuning Completed."
}
