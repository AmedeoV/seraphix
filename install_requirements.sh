#!/bin/bash
#
# Seraphix Scanner Setup Script
# Installs all dependencies required for all scanner modules
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
echo "║              Installing dependencies for all modules         ║"
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
        log_error "Python is not installed. Please install Python 3.7+ first."
        exit 1
    fi
    
    # Try python3 first, then python
    PYTHON_CMD="python3"
    if ! command_exists python3; then
        PYTHON_CMD="python"
    fi
    
    log_info "Using Python: $($PYTHON_CMD --version)"
    
    # Install Python packages
    if [ -f "requirements.txt" ]; then
        log_progress "Installing from requirements.txt..."
        $PYTHON_CMD -m pip install --upgrade pip
        $PYTHON_CMD -m pip install -r requirements.txt
        log_success "Python dependencies installed successfully"
    else
        log_error "requirements.txt not found"
        exit 1
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
    
    # Install dependencies
    install_python_deps
    echo ""
    install_trufflehog
    echo ""
    
    # Show completion message
    echo -e "${GREEN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    🎉 Setup Complete!                       ║"
    echo "║         All Seraphix scanner dependencies installed         ║"
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
        echo "  --help, -h     Show this help message"
        echo "  --python-only  Install only Python dependencies"
        echo "  --trufflehog-only  Install only TruffleHog"
        echo ""
        echo "This script installs all dependencies for Seraphix scanners:"
        echo "  - Python packages (colorama, requests, GitPython)"
        echo "  - TruffleHog secret scanner"
        echo ""
        exit 0
        ;;
    "--python-only")
        log_info "Installing Python dependencies only..."
        check_git
        install_python_deps
        log_success "Python dependencies installed!"
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