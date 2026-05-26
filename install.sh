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
# MAIN AUTO-INSTALL FUNCTION
#===============================================================================
auto_install() {
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
# Only run if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    auto_install "$@"
fi