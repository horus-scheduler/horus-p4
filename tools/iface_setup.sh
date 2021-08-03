#!/bin/bash

#
# iface_setup.sh
#
# Setup a set of interfaces to be used with a model
#
# Usage:
#   iface_setup iface_1 [ iface_2 ... ]
#
# The script performs the necessary setup on the interfaces to tbe used with
# a switch model. This typical setup includes the following:
#   -- No protocols should be setup on the interface. This means not assigning
#      any protocol addresses (neither IPv4, nor IPv6) to the interface.
#          -- This will prevent the standard Linux stack from forwarding
#             packets between these interfaces (especially if you can't globally
#             disable IP routing)
#          -- In case of IPv6, this will also prevent Linux stack from
#             sending ICMPv6 router advertizement messages periodically
#  -- Disable all HW acceleration on the interfaces
#          -- This is critical, otherwise you will see strange behavior that
#             depends on protocols, packet size and timing. For example, in
#             case of TCP, HW acceleration might result in the model receiving
#             one huge (e.g. 10K bytes long) TCP packet instead of 10 1K packets
#             The problem is that the model will not be able to send such a long
#             packet out.
#
# Uncomment for debugging
#set -x

MTU=10240

function print_help() {
    cat <<EOF

Usage:
   sudo iface_setup.sh [-h] [-m mtu] iface_0 [ iface_1 ... ]

Options:
    -h, --help         Print this message
    -m mtu, --mtu mtu  Set the specified MTU on all specified interfaces

EOF
}

function help_mtu() {
    cat <<EOF
ERROR: Failed to set MTU to $MTU on interface $iface
       Different interfaces support different maximum MTU settings. 
       Find out what's appropriate for interface $iface and use
       -m <mtu> parameter when running this script

EOF
}

function help_root() {
    cat <<EOF
ERROR: This script is supposed to be run as root, e.g. using sudo
EOF
}

function interface_configure() {
    iface=$1; shift

    ip link set dev $iface up
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    ip address flush dev $iface 
    sysctl net.ipv6.conf.$iface.disable_ipv6=1 &> /dev/null
    ip link set dev $iface up mtu $MTU
    if [ $? -ne 0 ]; then
        help_mtu
        return 1
    fi
    
    TOE_OPTIONS="rx tx sg tso ufo gso gro lro rxvlan txvlan rxhash"
    for TOE_OPTION in $TOE_OPTIONS; do
       /sbin/ethtool --offload $iface "$TOE_OPTION" off &> /dev/null
    done

    return 0
}    


#
# Main
#

# Parse options
opts=`getopt -o m:h -l help -lmtu: -- "$@"`

if [ $? != 0 ]; then
    # Option parsing failed, probably due to unknown options
    print_help
    exit 1
fi
eval set -- "$opts"

while true; do
    case "$1" in
        -h|--help) print_help; exit 0;;
        -m|--mtu)  MTU=$2; shift 2;;
        --) shift; break;;
    esac
done

if [ $# -lt 1 ]; then
    # No interfaces has been specified
    print_help
    exit 1
fi

# Check that we are running as root
if [ $UID -ne 0 ]; then
    help_root
    exit 1
fi

for iface in "$@"; do
    interface_configure $iface
    if [ $? -ne 0 ]; then
       exit 1
    fi
    echo "Interface $iface configured"
done
