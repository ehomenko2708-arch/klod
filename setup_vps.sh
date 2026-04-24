#!/usr/bin/env bash
# VPS initial setup script for Ubuntu 24.04 LTS (DigitalOcean)
# Run once as root: bash setup_vps.sh [your-username] [your-ssh-public-key]
#
# Usage:
#   bash setup_vps.sh                          # interactive mode
#   bash setup_vps.sh myuser "ssh-ed25519 ..." # non-interactive

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "Run this script as root."

# ── Parameters ───────────────────────────────────────────────────────────────
NEW_USER="${1:-}"
SSH_KEY="${2:-}"
SSH_PORT=22    # change here if you want a custom SSH port

if [[ -z "$NEW_USER" ]]; then
  read -rp "Enter new sudo username (leave blank to skip user creation): " NEW_USER
fi
if [[ -n "$NEW_USER" && -z "$SSH_KEY" ]]; then
  read -rp "Paste your SSH public key (leave blank to skip): " SSH_KEY
fi

# ── 1. System update ─────────────────────────────────────────────────────────
info "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get autoremove -y -qq

# ── 2. Install essential tools ────────────────────────────────────────────────
info "Installing essential tools..."
apt-get install -y -qq \
  curl wget git vim htop tmux \
  ufw fail2ban unattended-upgrades \
  net-tools dnsutils ca-certificates \
  software-properties-common apt-transport-https \
  build-essential

# ── 3. Create sudo user ───────────────────────────────────────────────────────
if [[ -n "$NEW_USER" ]]; then
  if id "$NEW_USER" &>/dev/null; then
    warn "User '$NEW_USER' already exists — skipping creation."
  else
    info "Creating user '$NEW_USER'..."
    adduser --disabled-password --gecos "" "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    # Allow sudo without password for this user
    echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$NEW_USER"
    chmod 440 "/etc/sudoers.d/$NEW_USER"
    info "User '$NEW_USER' created with passwordless sudo."
  fi

  if [[ -n "$SSH_KEY" ]]; then
    info "Installing SSH public key for '$NEW_USER'..."
    SSH_DIR="/home/$NEW_USER/.ssh"
    mkdir -p "$SSH_DIR"
    echo "$SSH_KEY" >> "$SSH_DIR/authorized_keys"
    chown -R "$NEW_USER:$NEW_USER" "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    chmod 600 "$SSH_DIR/authorized_keys"
    info "SSH key installed."
  fi
fi

# ── 4. SSH hardening ──────────────────────────────────────────────────────────
info "Hardening SSH configuration..."
SSHD_CONF="/etc/ssh/sshd_config"
cp "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%Y%m%d%H%M%S)"

# Apply settings safely (add or replace)
_sshd_set() {
  local key="$1" val="$2"
  if grep -qE "^#?\\s*${key}" "$SSHD_CONF"; then
    sed -i "s|^#\?\\s*${key}.*|${key} ${val}|" "$SSHD_CONF"
  else
    echo "${key} ${val}" >> "$SSHD_CONF"
  fi
}

_sshd_set "Port"                    "$SSH_PORT"
_sshd_set "PermitRootLogin"         "prohibit-password"
_sshd_set "PasswordAuthentication" "no"
_sshd_set "PubkeyAuthentication"   "yes"
_sshd_set "AuthorizedKeysFile"     ".ssh/authorized_keys"
_sshd_set "X11Forwarding"          "no"
_sshd_set "AllowTcpForwarding"     "no"
_sshd_set "MaxAuthTries"           "3"
_sshd_set "LoginGraceTime"         "20"
_sshd_set "ClientAliveInterval"    "300"
_sshd_set "ClientAliveCountMax"    "2"

# Keep root key-based login available if no new user was created
if [[ -z "$NEW_USER" ]]; then
  _sshd_set "PermitRootLogin" "prohibit-password"
fi

sshd -t && systemctl restart ssh
info "SSH hardened and restarted."

# ── 5. Firewall (UFW) ─────────────────────────────────────────────────────────
info "Configuring UFW firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp comment "SSH"
ufw allow 80/tcp   comment "HTTP"
ufw allow 443/tcp  comment "HTTPS"
ufw --force enable
ufw status verbose
info "UFW enabled."

# ── 6. Fail2ban ───────────────────────────────────────────────────────────────
info "Configuring fail2ban..."
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = $SSH_PORT
EOF

systemctl enable fail2ban
systemctl restart fail2ban
info "Fail2ban enabled."

# ── 7. Automatic security updates ─────────────────────────────────────────────
info "Enabling automatic security updates..."
cat > /etc/apt/apt.conf.d/50unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Packages "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades-local <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

systemctl enable unattended-upgrades
info "Automatic security updates enabled."

# ── 8. System limits & kernel tweaks ─────────────────────────────────────────
info "Applying sysctl security tweaks..."
cat > /etc/sysctl.d/99-vps-hardening.conf <<'EOF'
# Disable IP forwarding (not a router)
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0

# Protect against SYN flood
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Log spoofed, source-routed, and redirect packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.all.rp_filter = 1

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
EOF

sysctl --system -q
info "Sysctl tweaks applied."

# ── 9. Timezone ───────────────────────────────────────────────────────────────
info "Setting timezone to UTC..."
timedatectl set-timezone UTC

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  VPS setup complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "  Server IP  : $(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
echo "  SSH port   : $SSH_PORT"
[[ -n "$NEW_USER" ]] && echo "  Sudo user  : $NEW_USER"
echo "  Firewall   : UFW active (22, 80, 443)"
echo "  Fail2ban   : active"
echo "  Auto-updates: enabled"
echo ""
if [[ -n "$NEW_USER" && -n "$SSH_KEY" ]]; then
  echo -e "${YELLOW}Connect with:${NC}"
  echo "  ssh $NEW_USER@$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}') -p $SSH_PORT"
elif [[ -z "$NEW_USER" ]]; then
  echo -e "${YELLOW}Root SSH (key-only) is still allowed.${NC}"
  echo "  Make sure your SSH public key is in /root/.ssh/authorized_keys"
fi
echo ""
warn "Root password login is now DISABLED. Ensure key-based access works before closing this session!"
