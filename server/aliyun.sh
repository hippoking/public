#!/usr/bin/env bash

# ============================================================
# Aliyun/Alibabacloud Linux Aegis/Assist/CloudMonitor Uninstall Script
# OS: RHEL/Rocky/AlmaLinux/Ubuntu/Debian
# ============================================================

set -u

# define color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# confirmation prompt for uninstalling a component
confirm_uninstall() {
    local component="$1"
    local answer
    read -r -p "${component} detected, uninstall?[Y/n] " answer
    case "$answer" in
        [nN][oO]|[nN])
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# Check root privileges
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root. Please use sudo bash $0"
   exit 1
fi

# ============================================================
# Pre-uninstall confirmation: Disable Aegis self-protection and malicious host behavior prevention
# ============================================================
log_warn "Please open the Aliyun/AlibabaCloud Security Center->Asset Center->Host, find your instance, and disable Self-Protection Status and Malicious Host Behavior Prevention"

echo ""
read -r -p "Confirm that the above protections have been disabled before proceeding? [y/N] " CONFIRM
case "$CONFIRM" in
    [yY][eE][sS]|[yY])
        log_info "Confirmed, continuing with uninstallation..."
        ;;
    *)
        log_error "Not confirmed, exiting script. Please complete the console settings and run again."
        exit 1
        ;;
esac

log_info "Starting to process Aliyun/AlibabaCloud monitoring components..."

# ------------------------------------------------------------
# 1. Uninstall Aegis / Aliyundun
# ------------------------------------------------------------
log_info ">>> Checking Aegis..."

AEGIS_INSTALLED=0
if [[ -d "/usr/local/aegis" ]] || pgrep -f "AliYunDun" &> /dev/null || systemctl list-unit-files 2>/dev/null | grep -q "aegis"; then
    AEGIS_INSTALLED=1
fi

if [[ $AEGIS_INSTALLED -eq 1 ]]; then
    if confirm_uninstall "Aegis"; then
        log_info "Starting to uninstall Aegis..."

        if command -v wget &> /dev/null; then
            log_info "Downloading and executing Aegis official uninstall script..."
            wget -q "http://update2.aegis.aliyun.com/download/uninstall.sh" -O /tmp/uninstall_aegis.sh
            if [[ -s /tmp/uninstall_aegis.sh ]]; then
                chmod +x /tmp/uninstall_aegis.sh
                bash /tmp/uninstall_aegis.sh
            else
                log_warn "Failed to download Aegis uninstall script, attempting to clean up manually."
            fi
            rm -f /tmp/uninstall_aegis.sh
        else
            log_warn "wget not found, skipping Aegis official uninstall script download."
        fi

        log_info "Cleaning up Aegis residuals..."
        if [[ -f /etc/systemd/system/aegis.service ]]; then
            systemctl stop aegis 2>/dev/null
            systemctl disable aegis 2>/dev/null
            rm -f /etc/systemd/system/aegis.service
        fi
        rm -rf /usr/local/aegis
        rm -rf /usr/local/share/aegis
        log_info "Aegis processing completed."
    else
        log_warn "Skipped Aegis uninstallation."
    fi
else
    log_info "Aegis not detected, skipping."
fi

# ------------------------------------------------------------
# 2. Uninstall Aliyun Assist 
# ------------------------------------------------------------
log_info ">>> Checking Aliyun Assist..."

ASSIST_INSTALLED=0
if [[ -d "/usr/local/share/aliyun-assist" ]] \
   || [[ -d "/usr/local/share/assist-daemon" ]] \
   || pgrep -f "aliyun-service" &> /dev/null \
   || pgrep -f "aliyun_assist" &> /dev/null \
   || systemctl list-unit-files 2>/dev/null | grep -q "aliyun.service"; then
    ASSIST_INSTALLED=1
fi
if [[ $ASSIST_INSTALLED -eq 0 ]]; then
    if command -v rpm &> /dev/null && rpm -qa 2>/dev/null | grep -q "aliyun_assist"; then
        ASSIST_INSTALLED=1
    elif command -v dpkg &> /dev/null && dpkg -l 2>/dev/null | grep -q "aliyun-assist"; then
        ASSIST_INSTALLED=1
    fi
fi

if [[ $ASSIST_INSTALLED -eq 1 ]]; then
    if confirm_uninstall "Aliyun Assist"; then
        log_info "Starting to uninstall Aliyun Assist..."

        if command -v rpm &> /dev/null; then
            log_info "Detected RPM package manager..."
            rpm -qa | grep aliyun_assist | xargs -r rpm -e --nodeps 2>/dev/null
        elif command -v dpkg &> /dev/null; then
            log_info "Detected DEB package manager..."
            apt-get purge -y aliyun-assist 2>/dev/null
        fi

        if [[ -f /usr/local/share/assist-daemon/assist_daemon ]]; then
            log_info "Deleting Aliyun Assist daemon..."
            /usr/local/share/assist-daemon/assist_daemon --delete 2>/dev/null || true
        fi

        if [[ -f /etc/systemd/system/aliyun.service ]]; then
            systemctl stop aliyun.service 2>/dev/null
            systemctl disable aliyun.service 2>/dev/null
            rm -rf /etc/systemd/system/aliyun.service
        fi

        log_info "Cleaning up Aliyun Assist residuals..."
        rm -rf /usr/local/share/aliyun-assist
        rm -rf /usr/local/share/assist-daemon
        rm -f /etc/systemd/system/aliyun.service
        rm -f /etc/init.d/aliyun-service
        systemctl daemon-reload 2>/dev/null
        log_info "Aliyun Assist processing completed."
    else
        log_warn "Skipped Aliyun Assist uninstallation."
    fi
else
    log_info "Aliyun Assist not detected, skipping."
fi

# ------------------------------------------------------------
# 3. Uninstall cloud monitor (CloudMonitor)
# ------------------------------------------------------------
log_info ">>> Checking cloud monitor (CloudMonitor)..."

CLOUDMONITOR_DIR="/usr/local/cloudmonitor"

if [[ -d "$CLOUDMONITOR_DIR" ]]; then
    if confirm_uninstall "Cloud Monitor (CloudMonitor)"; then
        log_info "Starting to uninstall cloud monitor..."

        if [[ -f "$CLOUDMONITOR_DIR/cloudmonitorCtl.sh" ]]; then
            log_info "Executing cloud monitor's built-in uninstall script..."
            bash "$CLOUDMONITOR_DIR/cloudmonitorCtl.sh" stop 2>/dev/null
            bash "$CLOUDMONITOR_DIR/cloudmonitorCtl.sh" uninstall 2>/dev/null
        fi

        if pgrep -f "argusagent" &> /dev/null; then
            log_info "Found residual argusagent process, forcefully terminating..."
            systemctl stop cloudmonitor 2>/dev/null
            systemctl disable cloudmonitor 2>/dev/null
            pkill -9 -f "argusagent" 2>/dev/null
        fi

        rm -rf "$CLOUDMONITOR_DIR"
    else
        log_warn "Skipped cloud monitor uninstallation."
    fi
else
    log_info "Cloud monitor not detected, skipping."
fi

# clean up systemd service files (only meaningful if uninstallation was performed, here we clean up any residuals)
rm -f /etc/systemd/system/cloudmonitor.service
rm -rf /etc/cloudmonitor
log_info "Cloud monitor processing completed."
systemctl daemon-reload 2>/dev/null

# ------------------------------------------------------------
# 4. Verification and Cleanup
# ------------------------------------------------------------
echo ""
log_info "========== Verification Results =========="

echo -n "Checking Aegis process (AliYunDun): "
if pgrep -f "AliYunDun" &> /dev/null; then
    log_error "Residual process found"
else
    echo -e "${GREEN}Aegis uninstallation completed.${NC}"
fi

echo -n "Checking Aliyun Assist process (aliyun-service): "
if pgrep -f "aliyun-service" &> /dev/null || pgrep -f "aliyun_assist" &> /dev/null; then
    log_error "Residual process found"
else
    echo -e "${GREEN}Aliyun Assist uninstallation completed.${NC}"
fi

echo -n "Checking cloud monitor process (argusagent): "
if pgrep -f "argusagent" &> /dev/null; then
    log_error "Residual process found"
else
    echo -e "${GREEN}Cloud monitor uninstallation completed.${NC}"
fi

echo ""
log_info "Script execution completed."
log_warn "It is recommended to run 'ps aux | grep -E \"aegis|AliYunDun|aliyun-service|assist|argusagent\"' for final confirmation."