if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <MACHINE> <LEVEL>"
    echo "<MACHINE> is 'server' or 'workstation'"
    echo "<LEVEL> is '1' or '2'"
    echo "Example: sudo bash openscap_ubuntu.sh server 2"
    exit 1
fi

MACHINE=$1
LEVEL=$2

if [[ "$MACHINE" != "server" && "$MACHINE" != "workstation" ]]; then
    echo "Error: MACHINE must be 'server' or 'workstation'"
    exit 1
fi

if [[ "$LEVEL" != "1" && "$LEVEL" != "2" ]]; then
    echo "Error: LEVEL must be '1' or '2'"
    exit 1
fi

sudo apt install ssg-debderived -y
sudo oscap xccdf eval \
    --profile "xccdf_org.ssgproject.content_profile_cis_level${LEVEL}_${MACHINE}" \
    --results /var/log/results.xml \
    --report /var/log/report.html \
    /usr/share/xml/scap/ssg/content/ssg-ubuntu2404-ds.xml