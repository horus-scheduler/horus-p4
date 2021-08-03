#!/bin/bash

for intf in `ip link show | cut -d: -f2 | grep port`; do
    sudo ip link delete $intf
done
