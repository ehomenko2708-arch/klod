#!/bin/bash
# One-time VPS setup — run as root on the server
set -e

REPO="https://github.com/ehomenko2708-arch/klod.git"
BRANCH="claude/complete-vps-setup-GckMu"
DIR="/root/klod"

echo "[1/6] Installing Node.js, npm, git..."
apt-get update -qq
apt-get install -y -qq nodejs npm git

echo "[2/6] Installing PM2..."
npm install -g pm2

echo "[3/6] Cloning repository..."
if [ -d "$DIR/.git" ]; then
  cd "$DIR" && git pull origin "$BRANCH"
else
  git clone -b "$BRANCH" "$REPO" "$DIR"
fi

echo "[4/6] Creating .env..."
if [ ! -f "$DIR/.env" ]; then
  cat > "$DIR/.env" <<EOF
ANTHROPIC_API_KEY=your_anthropic_api_key_here
TELEGRAM_BOT_TOKEN=your_telegram_bot_token_here
EOF
  echo "  !! Edit $DIR/.env and add your real keys before starting the bot !!"
fi

echo "[5/6] Installing dependencies and starting bot..."
cd "$DIR"
npm install
chmod +x update.sh
pm2 start bot.js --name "klod-bot"
pm2 save
pm2 startup | tail -1 | bash || true

echo "[6/6] Setting up cron (auto-update every 5 min)..."
(crontab -l 2>/dev/null; echo "*/5 * * * * /root/klod/update.sh >> /root/klod/update.log 2>&1") | crontab -

echo ""
echo "Done! Bot is running."
pm2 status
