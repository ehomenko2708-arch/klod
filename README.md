# VPS Setup

One-command initial setup for a fresh Ubuntu 24.04 LTS DigitalOcean droplet.

## What it does

| Step | Action |
|------|--------|
| 1 | Updates & upgrades all system packages |
| 2 | Installs essential tools (curl, git, vim, htop, tmux, …) |
| 3 | Creates a sudo user with passwordless sudo |
| 4 | Installs your SSH public key for that user |
| 5 | Hardens SSH (disables password auth, root password login, X11, TCP forwarding) |
| 6 | Configures UFW firewall (allow 22/80/443, deny everything else) |
| 7 | Enables fail2ban (SSH brute-force protection) |
| 8 | Enables automatic security updates |
| 9 | Applies sysctl hardening (SYN-flood protection, martian packet logging, …) |
| 10 | Sets timezone to UTC |

## Usage

### Copy & run in one command (paste into your VPS console)

```bash
curl -fsSL https://raw.githubusercontent.com/ehomenko2708-arch/klod/main/setup_vps.sh | bash -s -- YOUR_USERNAME "YOUR_SSH_PUBLIC_KEY"
```

Replace:
- `YOUR_USERNAME` — the new sudo user you want to create (e.g. `deploy`)
- `YOUR_SSH_PUBLIC_KEY` — your public key string (contents of `~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub` on your local machine)

**Get your local SSH public key:**
```bash
# On your LOCAL machine:
cat ~/.ssh/id_ed25519.pub
# or
cat ~/.ssh/id_rsa.pub
```

### Interactive mode (prompts for username and key)

```bash
bash setup_vps.sh
```

### Non-interactive (arguments)

```bash
bash setup_vps.sh myuser "ssh-ed25519 AAAA...xyz user@laptop"
```

## After setup

Connect to your server as the new user:

```bash
ssh YOUR_USERNAME@YOUR_SERVER_IP
```

Root password login is disabled after the script runs — make sure your SSH key works **before** closing the console session.

## Firewall ports opened by default

| Port | Protocol | Purpose |
|------|----------|---------|
| 22   | TCP      | SSH |
| 80   | TCP      | HTTP |
| 443  | TCP      | HTTPS |

To open additional ports:
```bash
sudo ufw allow PORT/tcp
```
