#!/bin/bash
#
# Seraphix Scanner Setup Script
# Installs TruffleHog and Python dependencies for secret scanning
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Banner
echo -e "${PURPLE}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    🔍 Seraphix Scanner Setup                 ║"
echo "║           Installing dependencies for all modules            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_progress() {
    echo -e "${CYAN}🔄 $1${NC}"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to detect OS
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "cygwin" ]] || [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "win32" ]]; then
        echo "windows"
    else
        echo "unknown"
    fi
}

# Function to install Python dependencies
install_python_deps() {
    log_progress "Installing Python dependencies..."
    
    if ! command_exists python3 && ! command_exists python; then
        log_warning "Python is not installed. Skipping Python package installation."
        log_info "Python utilities won't work without Python 3.7+ and required packages."
        return 0
    fi
    
    # Try python3 first, then python
    PYTHON_CMD="python3"
    if ! command_exists python3; then
        PYTHON_CMD="python"
    fi
    
    log_info "Using Python: $($PYTHON_CMD --version)"
    
    # Install required packages
    log_progress "Installing Python packages (requests, colorama)..."
    if $PYTHON_CMD -m pip install --upgrade pip requests colorama; then
        log_success "Python dependencies installed successfully"
    else
        log_warning "Failed to install Python packages. Python utilities may not work."
        log_info "You can manually install with: $PYTHON_CMD -m pip install requests colorama"
    fi
}

# Function to install TruffleHog
install_trufflehog() {
    log_progress "Checking TruffleHog installation..."
    
    if command_exists trufflehog; then
        log_success "TruffleHog is already installed"
        log_info "Version: $(trufflehog --version 2>/dev/null || echo 'Version check failed')"
        return 0
    fi
    
    log_warning "TruffleHog not found. Installing..."
    
    local os=$(detect_os)
    local installed=false
    
    # Try Go installation first (works on all platforms)
    if command_exists go; then
        log_progress "Installing TruffleHog via Go..."
        if go install github.com/trufflesecurity/trufflehog/v3@latest; then
            log_success "TruffleHog installed via Go"
            installed=true
        else
            log_warning "Go installation failed, trying other methods..."
        fi
    fi
    
    # Platform-specific installations
    if [ "$installed" = false ]; then
        case $os in
            "linux")
                log_progress "Installing TruffleHog via curl (Linux)..."
                if curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh | sh -s -- -b /usr/local/bin; then
                    log_success "TruffleHog installed via curl"
                    installed=true
                fi
                ;;
            "macos")
                if command_exists brew; then
                    log_progress "Installing TruffleHog via Homebrew..."
                    if brew install trufflehog; then
                        log_success "TruffleHog installed via Homebrew"
                        installed=true
                    fi
                else
                    log_progress "Installing TruffleHog via curl (macOS)..."
                    if curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh | sh -s -- -b /usr/local/bin; then
                        log_success "TruffleHog installed via curl"
                        installed=true
                    fi
                fi
                ;;
            "windows")
                log_warning "Windows detected. Please install TruffleHog manually:"
                log_info "1. Visit: https://github.com/trufflesecurity/trufflehog/releases"
                log_info "2. Download the Windows binary"
                log_info "3. Add it to your PATH"
                log_info "4. Or use WSL/Git Bash for automated installation"
                ;;
            *)
                log_warning "Unknown OS. Please install TruffleHog manually:"
                log_info "Visit: https://github.com/trufflesecurity/trufflehog#installation"
                ;;
        esac
    fi
    
    # Verify installation
    if command_exists trufflehog; then
        log_success "TruffleHog installation verified"
        log_info "Version: $(trufflehog --version 2>/dev/null || echo 'Version check failed')"
    elif [ "$os" != "windows" ]; then
        log_error "TruffleHog installation failed. Please install manually."
        log_info "Visit: https://github.com/trufflesecurity/trufflehog#installation"
        exit 1
    fi
}

# Function to verify Git installation
check_git() {
    log_progress "Checking Git installation..."
    
    if command_exists git; then
        log_success "Git is installed"
        log_info "Version: $(git --version)"
    else
        log_error "Git is not installed. Please install Git first."
        exit 1
    fi
}

# Function to check additional shell script dependencies
check_shell_dependencies() {
    log_progress "Checking shell script dependencies..."
    
    local missing_tools=()
    local optional_tools=()
    
    # Required tools
    for tool in curl jq; do
        if command_exists "$tool"; then
            log_success "$tool is installed"
        else
            missing_tools+=("$tool")
        fi
    done
    
    # Optional but recommended tools
    if command_exists bc; then
        log_success "bc is installed (used for floating-point calculations)"
    else
        optional_tools+=("bc")
    fi
    
    if command_exists parallel; then
        log_success "GNU parallel is installed (optional, for faster processing)"
    else
        optional_tools+=("parallel")
    fi
    
    # Report missing required tools
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        echo ""
        log_info "Installation instructions:"
        for tool in "${missing_tools[@]}"; do
            case $tool in
                curl)
                    log_info "  curl: Usually pre-installed. Install with: apt-get install curl (Ubuntu/Debian) or brew install curl (macOS)"
                    ;;
                jq)
                    log_info "  jq: JSON processor. Install with: apt-get install jq (Ubuntu/Debian) or brew install jq (macOS)"
                    ;;
            esac
        done
        exit 1
    fi
    
    # Report optional missing tools
    if [ ${#optional_tools[@]} -gt 0 ]; then
        log_warning "Optional tools not found: ${optional_tools[*]}"
        log_info "These are not required but provide better functionality:"
        for tool in "${optional_tools[@]}"; do
            case $tool in
                bc)
                    log_info "  bc: Calculator for floating-point math. Install with: apt-get install bc (Ubuntu/Debian) or brew install bc (macOS)"
                    ;;
                parallel)
                    log_info "  parallel: GNU parallel for faster processing. Install with: apt-get install parallel (Ubuntu/Debian) or brew install parallel (macOS)"
                    ;;
            esac
        done
        echo ""
    fi
}

# Function to show scanner modules
show_scanners() {
    echo ""
    log_info "Available scanner modules:"
    echo -e "  ${GREEN}🚀 force-push-scanner/${NC}  - Database-driven force-push scanning"
    echo -e "  ${GREEN}🏢 org-scanner/${NC}         - Organization-based scanning"
    echo -e "  ${GREEN}📦 repo-scanner/${NC}        - Repository-specific scanning"
    echo ""
    log_info "Usage examples:"
    echo -e "  ${CYAN}cd force-push-scanner && ./force_push_secret_scanner.sh${NC}"
    echo -e "  ${CYAN}cd org-scanner && ./scan_org.sh microsoft${NC}"
    echo -e "  ${CYAN}cd repo-scanner && ./scan_repo_simple.sh owner/repo${NC}"
}

# Main installation process
main() {
    log_info "Starting Seraphix Scanner setup..."
    echo ""
    
    # Check prerequisites
    check_git
    echo ""
    check_shell_dependencies
    echo ""
    
    # Install dependencies
    install_python_deps
    echo ""
    install_trufflehog
    echo ""
    
    # Show completion message
    echo -e "${GREEN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    🎉 Setup Complete!                       ║"
    echo "║            All scanner dependencies installed               ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    show_scanners
    
    log_success "Setup completed successfully!"
    log_info "You can now use any of the scanner modules."
}

# Parse command line arguments
case "${1:-}" in
    "--help"|"-h")
        echo "Seraphix Scanner Setup Script"
        echo ""
        echo "Usage: $0 [options]"
        echo ""
        echo "Options:"
        echo "  --help, -h            Show this help message"
        echo "  --python-only         Install only Python dependencies"
        echo "  --trufflehog-only     Install only TruffleHog"
        echo ""
        echo "This script checks and installs all dependencies for Seraphix scanners:"
        echo ""
        echo "Required Dependencies:"
        echo "  - Git (version control)"
        echo "  - curl (HTTP client for API calls)"
        echo "  - jq (JSON processor for parsing results)"
        echo "  - TruffleHog (secret scanner)"
        echo "  - Python 3.7+ with packages:"
        echo "    • requests (for GitHub API utilities)"
        echo "    • colorama (for colored terminal output)"
        echo ""
        echo "Optional Dependencies (recommended):"
        echo "  - bc (calculator for floating-point math)"
        echo "  - GNU parallel (for faster parallel processing)"
        echo ""
        exit 0
        ;;
    "--python-only")
        log_info "Installing Python dependencies only..."
        install_python_deps
        log_success "Python dependencies installation complete!"
        exit 0
        ;;
    "--trufflehog-only")
        log_info "Installing TruffleHog only..."
        install_trufflehog
        log_success "TruffleHog installation complete!"
        exit 0
        ;;
    "")
        # No arguments, run full installation
        main
        ;;
    *)
        log_error "Unknown option: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
esac