#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <MACHINE> <LEVEL>"
    echo "<MACHINE> is 'server' or 'workstation'"
    echo "<LEVEL> is '1' or '2'"
    echo "Example: sudo bash openscap_rocky.sh server 2"
    exit 1
fi

MACHINE=$1
LEVEL=$2
PROFILE=""

if [[ "$MACHINE" == "server" ]]; then
    if [[ "$LEVEL" == 1 ]]; then
        PROFILE="xccdf_org.ssgproject.content_profile_cis_server_l1"
    elif [[ "$LEVEL" == 2 ]]; then
        PROFILE="xccdf_org.ssgproject.content_profile_cis"
    else
        echo "Error: LEVEL must be '1' or '2'"
        exit 1
    fi
elif [[ "$MACHINE" == "workstation" ]]; then
    if [[ "$LEVEL" == 1 ]]; then
        PROFILE="xccdf_org.ssgproject.content_profile_cis_workstation_l1"
    elif [[ "$LEVEL" == 2 ]]; then
        PROFILE="xccdf_org.ssgproject.content_profile_cis_workstation_l2"
    else
        echo "Error: LEVEL must be '1' or '2'"
        exit 1    
    fi
else
    echo "Error: MACHINE must be 'server' or 'workstation'"
    exit 1    
fi

sudo dnf install -y openscap-scanner scap-security-guide

mkdir -p /root/openscap

sudo oscap xccdf eval \
    --profile "${PROFILE}" \
    --results "/root/openscap/results-${MACHINE}-level${LEVEL}.xml" \
    --report "/root/openscap/report-${MACHINE}-level${LEVEL}.html" \
    /usr/share/xml/scap/ssg/content/ssg-rl10-ds.xml