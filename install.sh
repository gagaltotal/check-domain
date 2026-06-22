#!/usr/bin/env bash
set -euo pipefail

#===============================================================================
# COLORS & LOGGING
#===============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[+]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[!]${NC}    $*"; }
log_error()   { echo -e "${RED}[-]${NC}    $*"; }
log_step()    { echo -e "${CYAN}[>>]${NC}   $*"; }

#===============================================================================
# APP CONFIGURATION
#===============================================================================
APP_NAME="check-domain"
APP_DESCRIPTION="Domain Checker Service"
APP_MAIN_SCRIPT="check.py"
INSTALL_DIR="/opt/${APP_NAME}"
APP_USER="${APP_NAME}"
APP_GROUP="${APP_NAME}"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"

## =============================================================================
## Banner
## =============================================================================
banner() {
echo -e "${GREEN}
 ██████╗██████╗     ██╗███╗   ██╗███████╗████████╗ █████╗ ██╗     ██╗     ███████╗██████╗ 
██╔════╝██╔══██╗    ██║████╗  ██║██╔════╝╚══██╔══╝██╔══██╗██║     ██║     ██╔════╝██╔══██╗
██║     ██║  ██║    ██║██╔██╗ ██║███████╗   ██║   ███████║██║     ██║     █████╗  ██████╔╝
██║     ██║  ██║    ██║██║╚██╗██║╚════██║   ██║   ██╔══██║██║     ██║     ██╔══╝  ██╔══██╗
╚██████╗██████╔╝    ██║██║ ╚████║███████║   ██║   ██║  ██║███████╗███████╗███████╗██║  ██║
 ╚═════╝╚═════╝     ╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝╚═╝  ╚═╝
Installation Script for ${APP_NAME} - ${APP_DESCRIPTION} - Version 1.0
Author: GhostGTR666 - Gagaltotal666
"
}

#===============================================================================
# PACKAGE MANAGER DETECTION
#===============================================================================
detect_pkg_manager() {
    local -A pkg_managers=(
        ["apt-get"]="apt"
        ["dnf"]="dnf"
        ["yum"]="yum"
        ["pacman"]="pacman"
        ["apk"]="apk"
        ["zypper"]="zypper"
    )
    
    for cmd in "${!pkg_managers[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            echo "${pkg_managers[$cmd]}"
            return 0
        fi
    done
    
    echo "unknown"
    return 1
}

#===============================================================================
# PACKAGE NAME MAPPING PER DISTRO
#===============================================================================
get_package_names() {
    local pkg_manager="$1"
    
    case "$pkg_manager" in
        apt)
            # Debian/Ubuntu/Mint/Pop!_OS
            echo "python3 python3-pip python3-venv golang-go"
            ;;
        dnf)
            # Fedora/RHEL 8+/CentOS 8+
            echo "python3 python3-pip python3-virtualenv golang"
            ;;
        yum)
            # RHEL 7/CentOS 7/Amazon Linux
            echo "python3 python3-pip python-virtualenv golang"
            ;;
        pacman)
            # Arch/Manjaro/EndeavourOS
            echo "python python-pip python-virtualenv go"
            ;;
        apk)
            # Alpine Linux
            echo "python3 py3-pip go"
            ;;
        zypper)
            # openSUSE
            echo "python3 python3-pip python3-virtualenv go"
            ;;
        *)
            echo ""
            ;;
    esac
}

#===============================================================================
# CHECK IF PACKAGE IS INSTALLED
#===============================================================================
is_package_installed() {
    local pkg="$1"
    local pkg_manager="$2"
    
    case "$pkg_manager" in
        apt)
            dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"
            ;;
        dnf|yum)
            rpm -q "$pkg" &>/dev/null
            ;;
        pacman)
            pacman -Qi "$pkg" &>/dev/null
            ;;
        apk)
            apk info -e "$pkg" &>/dev/null
            ;;
        zypper)
            zypper search --installed-only --match-exact "$pkg" &>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

#===============================================================================
# INSTALL PACKAGES
#===============================================================================
install_packages() {
    local pkg_manager="$1"
    shift
    local -a packages=("$@")
    
    [[ ${#packages[@]} -eq 0 ]] && return 0
    
    case "$pkg_manager" in
        apt)
            sudo apt-get update -qq
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}"
            ;;
        dnf)
            sudo dnf install -y --setopt=install_weak_deps=False "${packages[@]}"
            ;;
        yum)
            sudo yum install -y -q "${packages[@]}"
            ;;
        pacman)
            sudo pacman -Sy --noconfirm --needed "${packages[@]}"
            ;;
        apk)
            sudo apk update --quiet
            sudo apk add --quiet "${packages[@]}"
            ;;
        zypper)
            sudo zypper --non-interactive install --no-recommends "${packages[@]}"
            ;;
        *)
            log_error "Unsupported package manager: $pkg_manager"
            return 1
            ;;
    esac
}

#===============================================================================
# ENSURE GO BIN IN PATH
#===============================================================================
ensure_go_path() {
    local go_bin_paths=(
        "$HOME/go/bin"
        "/usr/local/go/bin"
        "$GOPATH/bin"
    )
    
    for path in "${go_bin_paths[@]}"; do
        if [[ -d "$path" ]] && [[ ":${PATH}:" != *":${path}:"* ]]; then
            export PATH="${path}:${PATH}"
        fi
    done
}

#===============================================================================
# CHECK VENV MODULE AVAILABLE
#===============================================================================
ensure_venv_module() {
    if ! python3 -c "import venv" &>/dev/null; then
        log_warn "Python venv module not available, attempting to install..."
        
        local pkg_manager
        pkg_manager=$(detect_pkg_manager)
        
        case "$pkg_manager" in
            apt)    sudo apt-get install -y -qq python3-venv ;;
            dnf)    sudo dnf install -y python3-virtualenv ;;
            yum)    sudo yum install -y python-virtualenv ;;
            pacman) sudo pacman -S --noconfirm python-virtualenv ;;
            apk)    sudo apk add py3-virtualenv ;;
            zypper) sudo zypper --non-interactive install python3-virtualenv ;;
        esac
        
        # Re-check
        if ! python3 -c "import venv" &>/dev/null; then
            log_error "Failed to install Python venv module."
            return 1
        fi
    fi
    return 0
}

#===============================================================================
# INSTALL SUBFINDER
#===============================================================================
install_subfinder() {
    ensure_go_path
    
    # Check if already installed
    if command -v subfinder &>/dev/null; then
        local version
        version=$(subfinder -version 2>/dev/null | head -1 || echo "unknown")
        log_info "subfinder is already installed ($version)"
        return 0
    fi
    
    # Check if Go is available
    if ! command -v go &>/dev/null; then
        log_error "Go is not installed. Cannot install subfinder."
        log_info "Install Go first or install subfinder manually from:"
        log_info "https://github.com/projectdiscovery/subfinder/releases"
        return 1
    fi
    
    log_info "Installing subfinder via go install..."
    
    if GO111MODULE=on go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest 2>&1; then
        ensure_go_path
        
        # Verify installation
        if command -v subfinder &>/dev/null; then
            local version
            version=$(subfinder -version 2>/dev/null | head -1 || echo "unknown")
            log_success "subfinder installed successfully ($version)"
        else
            log_warn "subfinder was installed but not found in PATH"
            log_info "Add this to your shell config:"
            log_info "    export PATH=\"\$HOME/go/bin:\$PATH\""
            return 1
        fi
    else
        log_error "Failed to install subfinder via go install"
        log_info "Try manual installation from: https://github.com/projectdiscovery/subfinder/releases"
        return 1
    fi
}

#===============================================================================
# UPDATE SUBFINDER
#===============================================================================
update_subfinder() {
    ensure_go_path
    
    if ! command -v subfinder &>/dev/null; then
        log_warn "subfinder is not installed."
        log_info "Use 'install_subfinder' to install it first."
        return 1
    fi
    
    if ! command -v go &>/dev/null; then
        log_error "Go is not installed. Cannot update subfinder."
        return 1
    fi
    
    log_info "Updating subfinder..."
    
    if GO111MODULE=on go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest 2>&1; then
        ensure_go_path
        log_success "subfinder updated successfully"
    else
        log_error "Failed to update subfinder"
        return 1
    fi
}

#===============================================================================
# SETUP PYTHON VENV & DEPENDENCIES
#===============================================================================
setup_python_env() {
    log_step "Setting up Python environment..."
    
    # Ensure venv module is available
    if ! ensure_venv_module; then
        return 1
    fi
    
    # Create venv if not exists
    if [[ ! -d ".venv" ]]; then
        log_info "Creating Python virtual environment..."
        if ! python3 -m venv .venv; then
            log_error "Failed to create virtual environment"
            return 1
        fi
        log_success "Virtual environment created at .venv/"
    else
        log_info "Virtual environment already exists"
    fi
    
    # Verify activation script exists
    local activate_script=".venv/bin/activate"
    if [[ ! -f "$activate_script" ]]; then
        log_error "Virtual environment activation script not found"
        log_error "Try removing .venv directory and run again"
        return 1
    fi
    
    # Activate venv
    source "$activate_script"
    log_info "Virtual environment activated"
    
    # Upgrade pip (NO --user flag inside venv!)
    log_info "Upgrading pip..."
    if ! python3 -m pip install --upgrade pip --quiet 2>&1; then
        log_warn "Failed to upgrade pip, continuing anyway..."
    fi
    
    # Install requirements if exists
    if [[ -f "requirements.txt" ]]; then
        log_info "Installing Python dependencies from requirements.txt..."
        if python3 -m pip install -r requirements.txt 2>&1; then
            log_success "Python dependencies installed"
        else
            log_error "Failed to install Python dependencies"
            return 1
        fi
    else
        log_warn "requirements.txt not found - skipping Python dependency installation"
    fi
    
    return 0
}

#===============================================================================
# CREATE SYSTEM USER
#===============================================================================
create_app_user() {
    log_step "Creating application user..."
    
    if id "$APP_USER" &>/dev/null; then
        log_info "User '$APP_USER' already exists"
        return 0
    fi
    
    if sudo useradd --system --no-create-home --shell /usr/sbin/nologin --group "$APP_GROUP" "$APP_USER" 2>/dev/null; then
        log_success "User '$APP_USER' created"
    elif sudo adduser --system --no-create-home --shell /usr/sbin/nologin --group "$APP_GROUP" "$APP_USER" 2>/dev/null; then
        log_success "User '$APP_USER' created"
    else
        log_warn "Could not create user, using current user"
        APP_USER="$(whoami)"
        APP_GROUP="$(id -gn)"
    fi
}

#===============================================================================
# INSTALL APPLICATION FILES
#===============================================================================
install_app_files() {
    log_step "Installing application files to $INSTALL_DIR..."
    
    sudo mkdir -p "$INSTALL_DIR"
    
    local SOURCE_DIR
    SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    if command -v rsync &>/dev/null; then
        sudo rsync -a \
            --exclude='.venv' \
            --exclude='.git' \
            --exclude='__pycache__' \
            --exclude='*.pyc' \
            --exclude='.env' \
            "$SOURCE_DIR/" "$INSTALL_DIR/"
    else
        sudo cp -r "$SOURCE_DIR"/* "$INSTALL_DIR/" 2>/dev/null || true
        sudo rm -rf "$INSTALL_DIR/.venv" "$INSTALL_DIR/.git" 2>/dev/null || true
        find "$INSTALL_DIR" -type d -name '__pycache__' -exec sudo rm -rf {} + 2>/dev/null || true
        find "$INSTALL_DIR" -type f -name '*.pyc' -delete 2>/dev/null || true
    fi
    
    log_success "Files installed to $INSTALL_DIR"
}

#===============================================================================
# SETUP VENV IN INSTALL DIR
#===============================================================================
setup_install_venv() {
    log_step "Setting up Python environment in $INSTALL_DIR..."
    
    cd "$INSTALL_DIR"
    
    if [[ ! -d ".venv" ]]; then
        log_info "Creating virtual environment..."
        if ! sudo python3 -m venv .venv; then
            log_error "Failed to create venv"
            return 1
        fi
        log_success "Virtual environment created"
    fi
    
    sudo .venv/bin/pip install --upgrade pip --quiet 2>&1 || true
    
    if [[ -f "requirements.txt" ]]; then
        log_info "Installing dependencies from requirements.txt..."
        if sudo .venv/bin/pip install -r requirements.txt 2>&1; then
            log_success "Dependencies installed"
        else
            log_error "Failed to install dependencies"
            return 1
        fi
    fi
    
    return 0
}

#===============================================================================
# FIND SUBFINDER PATH
#===============================================================================
find_subfinder_path() {
    local -a paths=(
        "$HOME/go/bin/subfinder"
        "/usr/local/go/bin/subfinder"
        "/usr/local/bin/subfinder"
        "/usr/bin/subfinder"
    )
    
    for p in "${paths[@]}"; do
        [[ -x "$p" ]] && echo "$p" && return 0
    done
    
    command -v subfinder 2>/dev/null && return 0
    
    echo ""
    return 1
}

#===============================================================================
# CREATE SYSTEMD SERVICE FILE
#===============================================================================
create_service_file() {
    log_step "Creating systemd service..."
    
    if [[ ! -f "$INSTALL_DIR/$APP_MAIN_SCRIPT" ]]; then
        log_error "Main script not found: $INSTALL_DIR/$APP_MAIN_SCRIPT"
        return 1
    fi
    
    local SUBFINDER_PATH
    SUBFINDER_PATH=$(find_subfinder_path)
    
    local ENV_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    if [[ -n "$SUBFINDER_PATH" ]]; then
        ENV_PATH="$(dirname "$SUBFINDER_PATH"):${ENV_PATH}"
        log_info "subfinder found: $SUBFINDER_PATH"
    else
        log_warn "subfinder not found"
    fi
    
    sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=${APP_DESCRIPTION}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${INSTALL_DIR}
Environment="PATH=${ENV_PATH}"
Environment="PYTHONUNBUFFERED=1"
ExecStart=${INSTALL_DIR}/.venv/bin/python ${INSTALL_DIR}/${APP_MAIN_SCRIPT}
Restart=on-failure
RestartSec=10
StartLimitIntervalSec=60
StartLimitBurst=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${APP_NAME}

[Install]
WantedBy=multi-user.target
EOF

    [[ -f "$SERVICE_FILE" ]] && log_success "Service file created: $SERVICE_FILE" && return 0
    
    log_error "Failed to create service file"
    return 1
}

#===============================================================================
# SET PERMISSIONS
#===============================================================================
set_permissions() {
    log_step "Setting permissions..."
    sudo chown -R "$APP_USER:$APP_GROUP" "$INSTALL_DIR"
    sudo find "$INSTALL_DIR" -type d -exec chmod 755 {} \;
    sudo find "$INSTALL_DIR" -type f -exec chmod 644 {} \;
    sudo find "$INSTALL_DIR" -name "*.py" -exec chmod 755 {} \;
    
    # Handle .env file if exists
    if [[ -f "$INSTALL_DIR/.env" ]]; then
        sudo chmod 600 "$INSTALL_DIR/.env"
        sudo chown "$APP_USER:$APP_GROUP" "$INSTALL_DIR/.env"
    fi
    
    log_success "Permissions set"
}

#===============================================================================
# ENABLE AND START SERVICE
#===============================================================================
enable_service() {
    log_step "Enabling service..."
    
    sudo systemctl daemon-reload
    sudo systemctl enable "$APP_NAME.service" 2>&1 && log_success "Service enabled"
    
    echo ""
    read -p "$(echo -e "${CYAN}[?]${NC}   Start service now? [y/N]: ")" -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        sudo systemctl start "$APP_NAME.service" && {
            log_success "Service started!"
            echo ""
            log_info "Status:  sudo systemctl status $APP_NAME"
            log_info "Logs:    sudo journalctl -u $APP_NAME -f"
        } || {
            log_error "Failed to start. Check logs:"
            log_info "sudo journalctl -u $APP_NAME -n 50"
        }
    fi
}

#===============================================================================
# INSTALL AS SERVICE (MAIN FUNCTION)
#===============================================================================
install_as_service() {
    banner
    echo ""
    echo "========================================"
    echo "  Install ${APP_NAME} as Systemd Service"
    echo "========================================"
    echo ""
    
    local pkg_manager
    pkg_manager=$(detect_pkg_manager)
    
    [[ "$pkg_manager" == "unknown" ]] && { log_error "Unsupported package manager"; return 1; }
    
    log_success "Package manager: $pkg_manager"
    
    local pkg_list
    pkg_list=$(get_package_names "$pkg_manager")
    
    local -a missing=()
    for pkg in $pkg_list; do
        is_package_installed "$pkg" "$pkg_manager" || missing+=("$pkg")
    done
    
    [[ ${#missing[@]} -gt 0 ]] && {
        log_step "Installing ${#missing[@]} package(s)..."
        install_packages "$pkg_manager" "${missing[@]}" || { log_error "Failed to install packages"; return 1; }
        log_success "Packages installed"
    } || log_success "All packages installed"
    
    echo ""
    log_step "Installing subfinder..."
    install_subfinder || log_warn "Subfinder skipped"
    
    create_app_user
    install_app_files
    setup_install_venv || return 1
    set_permissions
    create_service_file || return 1
    enable_service
    
    echo ""
    log_success "========================================"
    log_success "  Installation Complete!"
    log_success "========================================"
    echo ""
    log_info "Service:  $APP_NAME"
    log_info "Path:     $INSTALL_DIR"
    log_info "Script:   $APP_MAIN_SCRIPT"
    echo ""
    log_info "Commands:"
    log_info "  sudo systemctl status  $APP_NAME"
    log_info "  sudo systemctl restart $APP_NAME"
    log_info "  sudo systemctl stop    $APP_NAME"
    log_info "  sudo systemctl start   $APP_NAME"
    log_info "  sudo journalctl -u $APP_NAME -f"
    echo ""
}

#===============================================================================
# UNINSTALL SERVICE
#===============================================================================
uninstall_service() {
    log_step "Uninstalling $APP_NAME..."
    
    sudo systemctl is-active --quiet "$APP_NAME" && sudo systemctl stop "$APP_NAME"
    sudo systemctl is-enabled --quiet "$APP_NAME" && sudo systemctl disable "$APP_NAME"
    [[ -f "$SERVICE_FILE" ]] && { sudo rm -f "$SERVICE_FILE"; log_success "Service file removed"; }
    sudo systemctl daemon-reload
    
    read -p "$(echo -e "${CYAN}[?]${NC}   Remove $INSTALL_DIR? [y/N]: ")" -r r
    [[ "$r" =~ ^[Yy]$ ]] && { sudo rm -rf "$INSTALL_DIR"; log_success "Files removed"; }
    
    read -p "$(echo -e "${CYAN}[?]${NC}   Remove user '$APP_USER'? [y/N]: ")" -r r
    [[ "$r" =~ ^[Yy]$ ]] && id "$APP_USER" &>/dev/null && { sudo userdel "$APP_USER" 2>/dev/null || sudo deluser "$APP_USER" 2>/dev/null; log_success "User removed"; }
    
    log_success "Uninstall complete!"
}

#===============================================================================
# SERVICE HELPERS
#===============================================================================
service_status()  { sudo systemctl status "$APP_NAME.service"; }
service_logs()    { sudo journalctl -u "$APP_NAME" -n "${1:-100}" --no-pager; }
service_follow()  { sudo journalctl -u "$APP_NAME" -f; }
service_restart() { sudo systemctl restart "$APP_NAME" && log_success "Restarted"; }
service_stop()    { sudo systemctl stop "$APP_NAME" && log_success "Stopped"; }
service_start()   { sudo systemctl start "$APP_NAME" && log_success "Started"; }

#===============================================================================
# MAIN AUTO-INSTALL FUNCTION
#===============================================================================
auto_install() {
    banner
    echo ""
    echo "========================================"
    echo "    Auto Installation Script"
    echo "    Universal Linux Support"
    echo "========================================"
    echo ""
    
    # Detect package manager
    local pkg_manager
    pkg_manager=$(detect_pkg_manager)
    
    if [[ "$pkg_manager" == "unknown" ]]; then
        log_error "Unsupported or no package manager detected!"
        log_error "Supported: apt (Debian/Ubuntu), dnf (Fedora), yum (RHEL/CentOS),"
        log_error "           pacman (Arch), apk (Alpine), zypper (openSUSE)"
        log_info "Please install manually: python3, pip, venv, golang"
        return 1
    fi
    
    log_success "Detected package manager: $pkg_manager"
    
    # Get package names for this distro
    local pkg_list
    pkg_list=$(get_package_names "$pkg_manager")
    
    if [[ -z "$pkg_list" ]]; then
        log_error "Could not determine package names for $pkg_manager"
        return 1
    fi
    
    # Find missing packages
    local -a missing_packages=()
    for pkg in $pkg_list; do
        if ! is_package_installed "$pkg" "$pkg_manager"; then
            missing_packages+=("$pkg")
        fi
    done
    
    # Install missing packages
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        log_step "Installing ${#missing_packages[@]} missing package(s)..."
        log_info "Packages: ${missing_packages[*]}"
        
        if ! install_packages "$pkg_manager" "${missing_packages[@]}"; then
            log_error "Failed to install packages"
            return 1
        fi
        log_success "All packages installed"
    else
        log_success "All system packages are already installed"
    fi
    
    # Install subfinder
    echo ""
    log_step "Installing subfinder..."
    install_subfinder || log_warn "Subfinder installation skipped (non-critical)"
    
    # Setup Python environment
    echo ""
    if setup_python_env; then
        echo ""
        log_success "========================================"
        log_success "  Setup completed successfully!"
        log_success "========================================"
        echo ""
        log_info "To activate the environment, run:"
        log_info "    source .venv/bin/activate"
        echo ""
    else
        log_error "Setup completed with errors"
        return 1
    fi
}

#===============================================================================
# ENTRY POINT
#===============================================================================
show_help() {
    banner
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  install     Setup venv locally (development)"
    echo "  service     Install as systemd service (production)"
    echo "  uninstall   Remove service and files"
    echo "  status      Show service status"
    echo "  logs [N]    Show last N logs (default: 100)"
    echo "  follow      Follow logs real-time"
    echo "  restart     Restart service"
    echo "  stop        Stop service"
    echo "  start       Start service"
    echo "  help        Show this help"
    echo ""
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-install}" in
        install)   auto_install ;;
        service)   install_as_service ;;
        uninstall) uninstall_service ;;
        status)    service_status ;;
        logs)      service_logs "${2:-100}" ;;
        follow)    service_follow ;;
        restart)   service_restart ;;
        stop)      service_stop ;;
        start)     service_start ;;
        help|--help|-h) show_help ;;
        *)         log_error "Unknown command: $1"; show_help; exit 1 ;;
    esac
fi