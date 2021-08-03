#!/bin/bash

usage() {
    echo `basename $0` "ingress|egress" "<path-to-power.json>"
}

if [ -z `which jq` ]; then
    cat <<EOF
ERROR: This script uses jq tool, which is not present on your system. 
       Install using 
               sudo apt get jq
       or a similar command or download from https://stedolan.github.io/jq/
EOF
    exit 1
fi

case $1 in
    ingress|egress) ;;
    *) usage; exit 1 ;;
esac

if [ -z $2 ]; then
    usage
    exit 1
fi
  
jq "            
[.stage_characteristics[] 
|
if .gress == \"$1\" then 
   .cycles_contribute_to_latency 
else 
   0 
end
] 
| add" $2

exit 0
