#!/usr/bin/env bash
# Install GOST 3.3.0 by default, or a specific version: sudo bash gost.sh 3.3.1
# Requires Linux x86_64 with an x86-64-v3 capable CPU and systemd.
set -euo pipefail

# Print an error message and exit
die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

# Allow zero or one argument
if [[ $# -gt 1 ]]; then
    die "Usage: $0 [version]"
fi

# Require root privileges
if [[ $EUID -ne 0 ]]; then
    die "Run this script as root: sudo bash $0"
fi

[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'Only Linux x86_64 is supported.'

release_base='https://github.com/go-gost/gost/releases'
version=${1:-3.3.0}
version=${version#v}
[[ $version =~ ^3\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "Invalid GOST v3 version: $version"

archive="gost_${version}_linux_amd64v3.tar.gz"
download_url="$release_base/download/v$version"
work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT

printf 'Downloading GOST %s (linux_amd64v3)...\n' "$version"
curl --fail --silent --show-error --location --retry 3 \
    "$download_url/$archive" --output "$work_dir/$archive"
curl --fail --silent --show-error --location --retry 3 \
    "$download_url/checksums.txt" --output "$work_dir/checksums.txt"
(
    cd "$work_dir"
    # Check only the selected archive, not all the other release assets.
    awk -v archive="$archive" '$2 == archive { print; found = 1 } END { if (!found) exit 1 }' \
        checksums.txt > selected-checksum.txt
    sha256sum --check selected-checksum.txt
)
tar -xzf "$work_dir/$archive" -C "$work_dir" gost
# Execute before changing the installation to catch incompatible CPUs/binaries.
"$work_dir/gost" -V

install -d -m 0755 /etc/gost
# Rename a staged binary so upgrades also work while the service is running.
install -m 0755 "$work_dir/gost" /etc/gost/gost.new
mv -f /etc/gost/gost.new /etc/gost/gost

if [[ ! -e /etc/gost/config.json ]]; then
    (umask 077; cat > /etc/gost/config.json <<'CONFIG'
{
  "services": [
    {
      "name": "socks5",
      "addr": "127.0.0.1:1080",
      "handler": { "type": "socks5" },
      "listener": { "type": "tcp" }
    }
  ]
}
CONFIG
    )
fi

cat > /etc/systemd/system/gost.service <<'SERVICE'
[Unit]
Description=GOST
Documentation=https://gost.run/
Wants=network.target
After=network.target

[Service]
Type=simple
ExecStart=/etc/gost/gost -C /etc/gost/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SERVICE
chmod 0644 /etc/systemd/system/gost.service

systemctl daemon-reload
systemctl enable gost.service
systemctl restart gost.service
systemctl --no-pager --full status gost.service
printf '\nGOST installed. Edit /etc/gost/config.json, then run: systemctl restart gost\n'
