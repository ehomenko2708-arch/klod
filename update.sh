#!/bin/bash
cd /home/bot/claude-bot
git pull origin claude/complete-vps-setup-GckMu
systemctl restart claude-bot
