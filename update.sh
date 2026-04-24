#!/bin/bash
cd /home/bot/claude-bot
git pull origin claude/bot-auto-deployment-AUHtZ
systemctl restart claude-bot
