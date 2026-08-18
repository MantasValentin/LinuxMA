#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <MACHINE>"
    echo "<MACHINE> is 'server' or 'workstation'"
    echo "Example: sudo bash openscap_rocky_full.sh server"
    exit 1
fi

MACHINE=$1
PROFILE_1=""
PROFILE_2=""

if [[ "$MACHINE" == "server" ]]; then
    PROFILE_1="xccdf_org.ssgproject.content_profile_cis_server_l1"
    PROFILE_2="xccdf_org.ssgproject.content_profile_cis"
elif [[ "$MACHINE" == "workstation" ]]; then
    PROFILE_1="xccdf_org.ssgproject.content_profile_cis_workstation_l1"
    PROFILE_2="xccdf_org.ssgproject.content_profile_cis_workstation_l2"
else
    echo "Error: MACHINE must be 'server' or 'workstation'"
    exit 1    
fi

sudo dnf install -y openscap-scanner scap-security-guide

mkdir /root/openscap

sudo oscap xccdf eval \
    --profile "${PROFILE_1}" \
    --results "/root/openscap/results-${MACHINE}-level1.xml" \
    --report "/root/openscap/report-${MACHINE}-level1.html" \
    /usr/share/xml/scap/ssg/content/ssg-rl10-ds.xml

sudo oscap xccdf eval \
    --profile "${PROFILE_2}" \
    --results "/root/openscap/results-${MACHINE}-level2.xml" \
    --report "/root/openscap/report-${MACHINE}-level2.html" \
    /usr/share/xml/scap/ssg/content/ssg-rl10-ds.xml