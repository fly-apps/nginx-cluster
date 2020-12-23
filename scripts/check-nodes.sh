#!/bin/bash
set -e

ips="127.0.0.1"

if [ "$FLY_APP_NAME" != "" ]; then
    # get IPs for nginx's in the same region
    ips=$(dig aaaa $FLY_REGION.$FLY_APP_NAME.internal @fdaa::3 +short | awk '{ printf "[%s]\n", $1 }')
fi

if [ -z "$ips" ]; then
    ips=$(grep fly-local-6pn /etc/hosts | awk '{ printf "[%s]", $1 }') # extract local ip
fi

changes=""
for i in $ips; do
    if grep -q -F "server $i:8081" /etc/nginx/nginx.conf; then
        echo "ip: $i is already in nginx.conf"
        continue
    fi
    echo "adding node: $i"
    changes="$changes\n$i"
    sed -i "s/# shard-upstream/server $i:8081 max_fails=5 fail_timeout=1s;\\n        # shard-upstream/" /etc/nginx/nginx.conf
done

if [ "$changes" != "" ]; then
    if ps aux | grep -q nginx | grep -v grep; then
        echo "Reloading nginx"
        nginx -s reload
    fi
fi