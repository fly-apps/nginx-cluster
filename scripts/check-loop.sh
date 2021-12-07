#!/bin/bash
set -e

echo "Checking for new peer instances every 5 seconds." 
sleep 5
while true; do    
    /fly/check-nodes.sh    
    sleep 5
done