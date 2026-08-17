if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <MACHINE>"
    echo "<MACHINE> is 'server' or 'workstation'"
    echo "Example: sudo bash openscap_ubuntu.sh server"
    exit 1
fi

MACHINE=$1

if [[ "$MACHINE" != "server" && "$MACHINE" != "workstation" ]]; then
    echo "Error: MACHINE must be 'server' or 'workstation'"
    exit 1
fi

sudo apt install ssg-debderived -y
sudo oscap xccdf eval \
    --profile "xccdf_org.ssgproject.content_profile_cis_level1_${MACHINE}" \
    --results "/var/log/results-openscap-${MACHINE}-level1.xml" \
    --report "/var/log/report-openscap-${MACHINE}-level1.html" \
    /usr/share/xml/scap/ssg/content/ssg-ubuntu2404-ds.xml

sudo oscap xccdf eval \
    --profile "xccdf_org.ssgproject.content_profile_cis_level2_${MACHINE}" \
    --results "/var/log/results-openscap-${MACHINE}-level2.xml" \
    --report "/var/log/report-openscap-${MACHINE}-level2.html" \
    /usr/share/xml/scap/ssg/content/ssg-ubuntu2404-ds.xml