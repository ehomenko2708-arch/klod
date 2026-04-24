#!/bin/bash
cd /root/klod
git pull origin claude/complete-vps-setup-GckMu
pm2 restart klod-bot
