#!/usr/bin/env bash
# Interactive initial setup for Debian/Ubuntu.
# Usage: sudo bash server/debian.sh
#
# Each optional task asks for confirmation; Enter means "no" except for apt-get
# upgrade, which defaults to "yes". Package lists refresh automatically. Changes are applied
# immediately and persisted where appropriate. Existing UFW rules are retained; SSH port changes replace previous ports. Root expansion means the filesystem mounted at /, not /root.
# Backups are created under /tmp/debian-setup only when needed.
#
# Stop on unhandled command failures, unset variables, or failed pipeline stages.
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Report an unrecoverable error and stop before any later tasks run.
die() {
    echo "Error: $*" >&2
    exit 1
}
# Return success only for an explicit y/yes response (case insensitive).
confirm() {
    local answer
    if ! read -r -p "$* [y/N]: " answer; then
        die 'Input closed.'
    fi

    case "$answer" in
        [yY]|[yY][eE][sS])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}
# Read an answer into the caller's variable named by the second argument.
# read -r preserves backslashes; quoted arguments prevent shell word splitting.
ask() {
    local prompt="$1"
    local destination="$2"

    if ! read -r -p "$prompt" "${destination?}"; then
        die 'Input closed.'
    fi
}
# Validate syntax before arithmetic. 10# treats leading zeros as decimal.
valid_port() {
    local port="$1"

    if [[ ! $port =~ ^[0-9]{1,5}$ ]]; then
        return 1
    fi

    if (( 10#$port < 1 || 10#$port > 65535 )); then
        return 1
    fi

    return 0
}
# Install packages for an approved task using the lists refreshed at startup.
install_packages() {
    apt-get install -y "$@"
}

# Check prerequisites before asking questions or changing the server.
if [[ $EUID -ne 0 ]]; then
    die "Run as root: sudo bash $0"
fi
if [[ $# -ne 0 ]]; then
    die "Usage: $0"
fi
if [[ ! -t 0 ]]; then
    die 'Run interactively in a terminal.'
fi
# shellcheck source=/dev/null
source /etc/os-release
if [[ $ID != debian && $ID != ubuntu ]]; then
    die 'Only Debian and Ubuntu are supported.'
fi
if [[ ! -d /run/systemd/system ]]; then
    die 'A running systemd system is required.'
fi
backup_dir="/tmp/debian-setup/$(date +%Y%m%d-%H%M%S)-$$"
# Preserve ownership, modes, and absolute path structure for manual restoration.
# Restrict backup access because SSH/firewall configuration may be sensitive.
backup() {
    (
        umask 077
        mkdir -p "$backup_dir"
    )
    cp -a --parents "$1" "$backup_dir/"
}

# Refresh package lists automatically before configuration.
# Offer to upgrade installed packages, defaulting to yes.
update_system() {
    local answer
    echo 'Refreshing package lists with apt-get update...'
    apt-get update

    echo 'Upgrading packages may restart services and require a reboot.'
    ask 'Run apt-get upgrade to upgrade installed packages? [Y/n]: ' answer
    case "$answer" in
        ''|[yY]|[yY][eE][sS])
            # Keep APT interactive for reviewing changes and configuration-file
            # questions. Do not automatically reboot after the upgrade.
            apt-get upgrade
            ;;
        *)
            echo 'Skipping package upgrades.'
            ;;
    esac

    if [[ -f /var/run/reboot-required ]]; then
        echo 'A reboot is required. Reboot manually when convenient.'
    fi
}

# 1. Disable IPv6 only when the kernel exposes IPv6 controls and an address exists.
# Never disable it from an IPv6 SSH session, since that could sever access.
configure_ipv6() {
    # Without this sysctl control, IPv6 may be unsupported, disabled at boot,
    # or hidden by the environment; this function cannot disable it via sysctl.
    if [[ ! -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
        return
    fi
    # No interface has an IPv6 address, so there is no active IPv6 address
    # configuration to disable. Skip silently without asking the user.
    if ! ip -6 address show | grep -q 'inet6 '; then
        return
    fi
    # Disabling IPv6 during an IPv6 SSH connection could disconnect the user.
    # Make this change from an IPv4 SSH connection or a local console instead.
    if [[ ${SSH_CONNECTION:-} == *:* ]]; then
        return
    fi
    ip -6 address show
    if ! confirm 'Ipv6 detected. Disable IPv6 now and persist across reboots?'; then
        return 0
    fi
    local config=/etc/sysctl.d/70-disable-ipv6.conf
    if [[ -e $config ]]; then
        backup "$config"
    fi
    # "all" affects existing interfaces; "default" covers future interfaces.
    cat > "$config" <<'CONFIG'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
CONFIG
    # Apply only this file, without reloading unrelated sysctl settings.
    sysctl -p "$config"
}

# 2. Avoid creating duplicate swap when a file/partition is active or configured.
# Use a fully allocated file on supported filesystems, with root-only access.
configure_swap() {
    if ! confirm 'Create a swap file if no existing swap is detected?'; then
        return 0
    fi

    # Include inactive swap partitions and persistent swap entries as well.
    if [[ -n $(swapon --show --noheadings) ]] \
        || lsblk -nr -o FSTYPE | grep -qx swap \
        || awk '$1 !~ /^#/ && $3 == "swap" { found=1 } END { exit !found }' /etc/fstab; then
        echo 'Existing swap detected; skipping creation.'
        return
    fi
    local size filesystem available
    ask 'Swap size in GiB [2]: ' size
    size=${size:-2}
    if [[ ! $size =~ ^[1-9][0-9]{0,3}$ ]]; then
        die 'Swap size must be an integer from 1 to 9999 GiB.'
    fi
    filesystem=$(findmnt -n -o FSTYPE -T /)
    case $filesystem in
        ext4|ext3|ext2|xfs)
            ;;
        *)
            echo "Swap file creation on $filesystem is unsupported by this script; skipping."
            return
            ;;
    esac
    if [[ -e /swapfile || -L /swapfile ]]; then
        die '/swapfile already exists; leaving it untouched.'
    fi
    available=$(df -Pk / | awk 'NR==2 {print $4}')
    # df reports KiB; reserve another GiB for normal system operation.
    if (( available <= size * 1048576 + 1048576 )); then
        die 'Insufficient disk space (requires an additional 1 GiB free).'
    fi
    # Writing zeros avoids sparse-file holes that swapon would reject.
    (
        umask 077
        dd if=/dev/zero of=/swapfile bs=1M count="$((size * 1024))" status=progress
    )
    mkswap /swapfile
    swapon /swapfile
    # Persist only after swapon succeeds, so a failed activation is not saved.
    backup /etc/fstab
    echo '/swapfile none swap sw 0 0' >> /etc/fstab

    # Swap creation and memory tuning are separate choices. Declining tuning
    # leaves the new swap enabled and keeps the current swappiness unchanged.
    echo 'The swap file is now active and configured to persist after reboot.'
    echo "Current vm.swappiness: $(sysctl -n vm.swappiness)"
    echo 'The kernel default of 60 is a general-purpose setting, also used on desktops.'
    echo 'A value of 10 reduces the preference for swapping application memory.'
    echo 'This can suit servers with sufficient RAM and slower disk-backed swap.'
    echo 'The best value depends on the workload; 10 is not always better for every server.'
    if ! confirm 'Set vm.swappiness to 10 now and persist across reboots?'; then
        return 0
    fi

    if [[ -e /etc/sysctl.d/70-swappiness.conf ]]; then
        backup /etc/sysctl.d/70-swappiness.conf
    fi
    # A value of 10 reduces the kernel's preference for swapping anonymous memory.
    echo 'vm.swappiness = 10' > /etc/sysctl.d/70-swappiness.conf
    sysctl -p /etc/sysctl.d/70-swappiness.conf
}

# 3. Replace SSH ports with one custom port, then validate before reloading.
# Common drop-in files are handled too. If another Include or ListenAddress
# still exposes a different port, restore the original files and stop.
configure_ssh() {
    if [[ ! -x /usr/sbin/sshd || ! -f /etc/ssh/sshd_config ]]; then
        #echo 'OpenSSH server not installed; skipping.'
        return
    fi
    # Socket-activated SSH needs separate listener management.
    if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        #echo 'SSH socket activation detected. Port changes are unsupported by this script; skipping.'
        return
    fi

    local port file staged effective_config
    local -a config_files=(/etc/ssh/sshd_config)
    /usr/sbin/sshd -t
    effective_config=$(/usr/sbin/sshd -T)
    # Read the effective configuration so implicit defaults and Include files
    # are accounted for. Leave an already-customized SSH port unchanged.
    if ! echo "$effective_config" | grep -qx 'port 22'; then
        return
    fi
    if ! confirm 'SSH uses default port 22. Want to use another port?'; then
        return 0
    fi
    ask 'Custom SSH port [2222]: ' port
    port=${port:-2222}
    if ! valid_port "$port"; then
        die 'Invalid SSH port.'
    fi
    port=$((10#$port))
    # Reusing an existing SSH port is fine; reject a port owned by another service.
    if ss -H -ltn "sport = :$port" | grep -q .; then
        if ! /usr/sbin/sshd -T | grep -qx "port $port"; then
            echo "Port $port is already in use; skipping."
            return
        fi
    fi
    echo "New SSH connections will use only port $port."
    echo 'Allow this port in any provider firewall before continuing.'
    if ! confirm 'Apply the SSH port change?'; then
        return 0
    fi

    # Allow the new port before reloading if UFW is already active.
    if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
        ufw insert 1 allow "$port/tcp"
    fi
    for file in /etc/ssh/sshd_config.d/*.conf; do
        if [[ -f $file ]]; then
            config_files+=("$file")
        fi
    done
    # Back up every affected file before editing any of them.
    for file in "${config_files[@]}"; do
        backup "$file"
    done
    for file in "${config_files[@]}"; do
        staged=$(mktemp /etc/ssh/sshd-port.XXXXXX)
        {
            if [[ $file == /etc/ssh/sshd_config ]]; then
                echo "Port $port"
            fi
            # Port accepts either whitespace or '=' as its separator.
            sed -E '/^[[:space:]]*[Pp][Oo][Rr][Tt]([[:space:]]|=)/d' "$file"
        } > "$staged"
        # Write through the existing file to preserve its mode and ownership.
        cat "$staged" > "$file"
        rm -f "$staged"
    done

    # Check both Port and explicit ListenAddress ports. No reload occurs unless
    # all effective listeners use the requested port, including external Includes.
    if /usr/sbin/sshd -t && effective_config=$(/usr/sbin/sshd -T) \
        && echo "$effective_config" | awk -v port="$port" '
            $1 == "port" && $2 != port { invalid = 1 }
            $1 == "listenaddress" {
                address = $2
                sub(/^.*:/, "", address)
                if (address != port) invalid = 1
            }
            END { exit invalid }
        '; then
        if systemctl reload ssh.service; then
            # Do not reopen the old connection port in the later firewall step.
            ssh_port_changed=true
            echo "SSH now uses only port $port. Reconnect with: ssh -p $port user@server"
            return
        fi
    fi

    for file in "${config_files[@]}"; do
        cp -a "$backup_dir$file" "$file"
    done
    die 'SSH validation or reload failed; original configuration restored. Check external Include/ListenAddress settings.'
}

# 4. Whitelisted sources can access every port; public port rules allow anyone.
# Preserve previous rules and add SSH allows before enabling the deny policy.
configure_firewall() {
    # Installation is optional and separate from applying firewall policy.
    # Declining installation skips this task because UFW is required below.
    if ! command -v ufw >/dev/null; then
        echo 'UFW is not installed.'
        if ! confirm 'Install UFW?'; then
            return 0
        fi
        install_packages ufw
    else
        echo 'UFW is already installed.'
    fi

    # An installed UFW does not imply permission to change or enable its rules.
    if ! confirm 'Configure UFW with default incoming deny and default outgoing allow?'; then
        return 0
    fi
    local ips ports item port protocol ssh_port
    local -a whitelist opened ssh_ports
    ask 'Whitelist IPs/CIDRs (space-separated; all ports allowed; blank for none): ' ips
    ask 'Public ports (space-separated, e.g. 80/tcp 443/tcp 53/udp; blank for none): ' ports
    read -r -a whitelist <<< "$ips"
    read -r -a opened <<< "$ports"
    # Validate everything before modifying firewall policy.
    for item in "${opened[@]}"; do
        # Split PORT/protocol without evaluating user input as shell code.
        port=${item%/*}
        protocol=${item#*/}
        if ! valid_port "$port" || [[ $protocol != tcp && $protocol != udp ]]; then
            die "Invalid port: $item (use PORT/tcp or PORT/udp)"
        fi
    done
    for item in "${whitelist[@]}"; do
        if [[ $item == -* ]]; then
            die "Invalid whitelist address: $item"
        fi
        # Let UFW validate IPv4/IPv6 and CIDR syntax without applying the rule.
        ufw --dry-run allow from "$item" to any >/dev/null
    done
    if [[ -x /usr/sbin/sshd ]]; then
        /usr/sbin/sshd -t
        mapfile -t ssh_ports < <(/usr/sbin/sshd -T | awk '$1 == "port" {print $2}')
    fi
    # Include the actual connection port, including socket-activated SSH.
    if [[ -n ${SSH_CONNECTION:-} && $ssh_port_changed == false ]]; then
        ssh_port=${SSH_CONNECTION##* }
        if ! valid_port "$ssh_port"; then
            die 'Cannot determine current SSH port.'
        fi
        ssh_ports+=("$ssh_port")
    fi
    echo "SSH ports allowed publicly: ${ssh_ports[*]:-(none detected)}"
    echo 'Existing UFW rules will be retained. Whitelisted addresses receive access to all ports.'
    if ! confirm 'Apply these rules and enable UFW?'; then
        return 0
    fi
    backup /etc/ufw
    for ssh_port in "${ssh_ports[@]}"; do
        ufw insert 1 allow "$ssh_port/tcp"
    done
    for item in "${whitelist[@]}"; do
        ufw insert 1 allow from "$item" to any
    done
    for item in "${opened[@]}"; do
        ufw insert 1 allow "$item"
    done
    ufw default deny incoming
    ufw default allow outgoing
    ufw --force enable
    ufw status verbose
}

# 5. Grow only a plain root partition with a supported online-grow filesystem.
# Device-mapper/LVM, RAID, and encryption require layout-specific handling.
# Partition growth consumes contiguous free space immediately after the partition.
expand_root() {
    local device filesystem type parent number output status
    local partition_path disk_path start size end boundary sibling sibling_start
    device=$(findmnt -n -o SOURCE /)
    filesystem=$(findmnt -n -o FSTYPE /)
    device=$(readlink -f "$device")
    if [[ ! -b $device ]]; then
        #echo 'Root is not a block device; skipping expansion.'
        return
    fi
    type=$(lsblk -dn -o TYPE "$device")
    if [[ $type != part ]]; then
        #echo 'Root is not a plain partition (LVM/RAID/encryption unsupported); skipping.'
        return
    fi
    case $filesystem in
        ext2|ext3|ext4|xfs)
            ;;
        *)
            #echo "Root filesystem $filesystem is unsupported; skipping."
            return
            ;;
    esac
    parent=$(lsblk -dn -o PKNAME "$device")
    number=$(cat "/sys/class/block/${device##*/}/partition")
    # sysfs supplies the partition number for both SATA and NVMe device names.
    if [[ ! -b /dev/$parent || ! $number =~ ^[0-9]+$ ]]; then
        # Skip expansion silently when the root partition cannot be identified.
        return 0
    fi

    # Check the kernel's partition geometry before installing any tools. sysfs
    # reports starts and sizes in 512-byte sectors, even on 4K-sector disks.
    # Only the gap immediately after this partition can be used for growth;
    # free space elsewhere on the disk does not help.
    partition_path="/sys/class/block/${device##*/}"
    disk_path="/sys/class/block/$parent"
    if [[ ! -r $partition_path/start || ! -r $partition_path/size || ! -r $disk_path/size ]]; then
        return 0
    fi
    start=$(cat "$partition_path/start")
    size=$(cat "$partition_path/size")
    end=$((start + size))
    boundary=$(cat "$disk_path/size")

    # A later partition limits growth, even if there is unused space beyond it.
    for sibling in "$disk_path"/*/partition; do
        if [[ ! -f $sibling ]]; then
            continue
        fi
        sibling_start=$(cat "${sibling%/partition}/start")
        if (( sibling_start >= end && sibling_start < boundary )); then
            boundary=$sibling_start
        fi
    done

    # Ignore gaps of 10 MiB or less, matching growpart's default minimum growth.
    # This is a preliminary check; growpart's dry run below also accounts for
    # partition-table constraints and reserved metadata before any disk writes.
    if (( boundary - end <= 20480 )); then
        return 0
    fi
    if ! command -v growpart >/dev/null; then
        echo 'Free space detected immediately after the root partition.'
        if ! confirm 'Install cloud-guest-utils to verify and perform root partition expansion?'; then
            return 0
        fi
        install_packages cloud-guest-utils
    fi
    # growpart returns 1 for no available space and 2 for other errors.
    status=0
    # -N is a dry run: inspect available growth without writing a partition table.
    if output=$(growpart -N "/dev/$parent" "$number" 2>&1); then
        status=0
    else
        status=$?
    fi
    echo "$output"
    if (( status > 1 )); then
        die 'Unable to check root partition expansion.'
    fi
    if (( status == 1 )); then
        return 0
    fi
    if ! confirm "Grow root partition $device if space is available, then expand $filesystem on /?"; then
        return 0
    fi
    backup /etc/fstab
    # Save the partition table before changing its boundaries.
    sfdisk --dump "/dev/$parent" > "$backup_dir/partition-table.sfdisk"
    if (( status == 0 )); then
        growpart "/dev/$parent" "$number"
    fi
    if [[ $filesystem == xfs ]]; then
        # XFS grows through its mount point; ext filesystems use the device.
        if ! command -v xfs_growfs >/dev/null; then
            install_packages xfsprogs
        fi
        xfs_growfs /
    else
        if ! command -v resize2fs >/dev/null; then
            install_packages e2fsprogs
        fi
        resize2fs "$device"
    fi
    df -h /
}

ssh_port_changed=false

# Run in order so the firewall sees any SSH port added in the preceding task.
# Declining a task returns success and allows the remaining tasks to proceed.
update_system
configure_ipv6
configure_swap
configure_ssh
configure_firewall
expand_root
echo
echo "Setup complete. Backups, if created: $backup_dir"
