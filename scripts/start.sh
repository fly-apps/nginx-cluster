#!/bin/bash
set -e

### Detect cache disk size
mount=$(df -h | grep /data || echo "")
size=$(echo "$mount" | awk '{ printf "%.0f", $2 }')

echo "Setting cache size: ${size}GB"

if [ size == "0" ]; then
    size="10"
fi
sed -i "s/{CACHE_SIZE}/${size}g/" /etc/nginx/nginx.conf

# find other nodes
/fly/check-nodes.sh

exec nginx -c /etc/nginx/nginx.conf