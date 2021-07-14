#!/bin/bash

############################################################################
#
# clean_sde.sh
#
# This is a simple script that cleans up the SDE directory by removing
# driver logs, model logs, PCAP files, i.e. the files created by running
# various components.
#
# It does not remove any build artifacts!
#
###########################################################################

if [ -z $SDE ]; then
    echo "WARNING: \$SDE is not set. Trying current directory"
    if [ -d ./packages -a -f run_switchd.sh ]; then
        echo "   INFO: Using $PWD as \$SDE"
        SDE=$PWD
    else
        echo "  ERROR: $PWD does not seem to contain BF SDE. Exiting"
        exit 1
    fi
fi

echo "   INFO: Cleaning up work files in $SDE. "
echo "         This requires sudo privileges."

sudo rm -rf bf_drivers.log* *.pcap ptf.log ptf.pcap model*.log pcap_output
