#!/usr/bin/env bash
# =============================================================================
# deploy-modified-files.sh — Deploy Mistral AI OpenStack Integration Files
# =============================================================================
# Copies all modified files from the openstack/modified directory to their
# correct system locations. Run this script after cloning the OpenStack repo
# to deploy the Mistral AI integration modifications.
#
# Usage:
#   sudo bash deploy-modified-files.sh           # Deploy all files
#   sudo bash deploy-modified-files.sh --check   # Check what would be copied
#
# Files deployed:
#   - Installation scripts (13-19)
#   - Modified core scripts (11-octavia.sh)  
#   - AI agent and tools (/opt/mistral-openstack)
#   - Configuration files (/etc/octavia)
#   - Updated documentation (README.md)
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODIFIED_DIR="$SCRIPT_DIR/modified"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (sudo)"
        exit 1
    fi
}

check_modified_dir() {
    if [[ ! -d "$MODIFIED_DIR" ]]; then
        log_error "Modified files directory not found: $MODIFIED_DIR"
        log_info "Make sure you're running this from the OpenStack repository root"
        exit 1
    fi
}

copy_file() {
    local src="$1"
    local dst="$2"
    local description="$3"
    
    if [[ "${DRY_RUN:-}" == "true" ]]; then
        log_info "[DRY RUN] Would copy: $src → $dst ($description)"
        return
    fi
    
    # Create destination directory if it doesn't exist
    local dst_dir
    dst_dir="$(dirname "$dst")"
    if [[ ! -d "$dst_dir" ]]; then
        mkdir -p "$dst_dir"
        log_info "Created directory: $dst_dir"
    fi
    
    # Copy file
    if cp "$src" "$dst"; then
        log_success "Copied: $description"
    else
        log_error "Failed to copy: $src → $dst"
        return 1
    fi
    
    # Set appropriate permissions
    if [[ "$dst" == *.sh ]]; then
        chmod +x "$dst"
    fi
}

copy_directory() {
    local src="$1"
    local dst="$2"
    local description="$3"
    
    if [[ "${DRY_RUN:-}" == "true" ]]; then
        log_info "[DRY RUN] Would copy directory: $src → $dst ($description)"
        return
    fi
    
    # Create destination parent directory
    local dst_parent
    dst_parent="$(dirname "$dst")"
    mkdir -p "$dst_parent"
    
    # Copy directory recursively
    if cp -r "$src" "$dst"; then
        log_success "Copied directory: $description"
    else
        log_error "Failed to copy directory: $src → $dst"
        return 1
    fi
}

deploy_installation_scripts() {
    log_info "Deploying installation scripts..."
    
    local scripts_dir="$SCRIPT_DIR/scripts"
    
    # Copy all Mistral AI scripts (13-19)
    for script in "$MODIFIED_DIR/scripts"/1[3-9]-*.sh; do
        if [[ -f "$script" ]]; then
            local script_name
            script_name="$(basename "$script")"
            copy_file "$script" "$scripts_dir/$script_name" "Mistral AI script: $script_name"
        fi
    done
    
    # Copy modified Octavia script
    if [[ -f "$MODIFIED_DIR/scripts/11-octavia.sh" ]]; then
        copy_file "$MODIFIED_DIR/scripts/11-octavia.sh" "$scripts_dir/11-octavia.sh" "Modified Octavia installation script"
    fi
}

deploy_ai_components() {
    log_info "Deploying AI agent components..."
    
    # Deploy main AI directory
    if [[ -d "$MODIFIED_DIR/opt/mistral-openstack" ]]; then
        # Remove existing installation if present
        if [[ -d "/opt/mistral-openstack" && "${DRY_RUN:-}" != "true" ]]; then
            log_warning "Removing existing /opt/mistral-openstack installation"
            rm -rf /opt/mistral-openstack
        fi
        
        copy_directory "$MODIFIED_DIR/opt/mistral-openstack" "/opt/mistral-openstack" "AI agent and tools"
        
        # Set ownership if mistral user exists
        if [[ "${DRY_RUN:-}" != "true" ]] && id mistral >/dev/null 2>&1; then
            chown -R mistral:mistral /opt/mistral-openstack
            log_success "Set ownership: mistral:mistral"
        fi
    fi
}

deploy_configuration_files() {
    log_info "Deploying configuration files..."
    
    # Octavia configuration
    if [[ -f "$MODIFIED_DIR/etc/octavia/octavia.conf" ]]; then
        copy_file "$MODIFIED_DIR/etc/octavia/octavia.conf" "/etc/octavia/octavia.conf" "Octavia configuration"
        
        # Set ownership if octavia user exists
        if [[ "${DRY_RUN:-}" != "true" ]] && id octavia >/dev/null 2>&1; then
            chown octavia:octavia /etc/octavia/octavia.conf
            chmod 640 /etc/octavia/octavia.conf
        fi
    fi
    
    # Octavia policy file
    if [[ -f "$MODIFIED_DIR/etc/octavia/policy.yaml" ]]; then
        copy_file "$MODIFIED_DIR/etc/octavia/policy.yaml" "/etc/octavia/policy.yaml" "Octavia policy configuration"
        
        # Set ownership if octavia user exists
        if [[ "${DRY_RUN:-}" != "true" ]] && id octavia >/dev/null 2>&1; then
            chown octavia:octavia /etc/octavia/policy.yaml
            chmod 644 /etc/octavia/policy.yaml
        fi
    fi
}

deploy_documentation() {
    log_info "Deploying documentation..."
    
    # Main README
    if [[ -f "$MODIFIED_DIR/README.md" ]]; then
        copy_file "$MODIFIED_DIR/README.md" "$SCRIPT_DIR/README.md" "Updated project README"
    fi
}

show_summary() {
    log_info ""
    log_success "=== Deployment Summary ==="
    log_info "✓ Installation scripts: scripts/1[1,3-9]-*.sh"
    log_info "✓ AI agent and tools: /opt/mistral-openstack/"
    log_info "✓ Configuration files: /etc/octavia/"
    log_info "✓ Documentation: README.md"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Run: sudo bash scripts/13-mistral-ai-core.sh"
    log_info "  2. Run: sudo bash scripts/14-mistral-ai-compute.sh"
    log_info "  3. Run: sudo bash scripts/15-mistral-ai-network.sh"
    log_info "  4. Run: sudo bash scripts/16-mistral-ai-loadbalancer.sh"
    log_info "  5. Run: sudo bash scripts/17-mistral-ai-quota.sh"
    log_info "  6. Run: sudo bash scripts/18-mistral-ai-agent.sh"
    log_info "  7. Run: sudo bash scripts/19-mistral-ai-horizon.sh"
    log_info ""
    log_info "Set MISTRAL_API_KEY environment variable before using the AI agent."
}

# ── Main Execution ────────────────────────────────────────────────────────────

# Handle dry-run mode
if [[ "${1:-}" == "--check" ]]; then
    export DRY_RUN=true
    log_info "Running in dry-run mode - no files will be copied"
    log_info ""
fi

# Validate environment
if [[ "${DRY_RUN:-}" != "true" ]]; then
    check_root
fi
check_modified_dir

log_info "Starting deployment of Mistral AI OpenStack integration files"
log_info "Source directory: $MODIFIED_DIR"
log_info ""

# Deploy components
deploy_installation_scripts
deploy_ai_components  
deploy_configuration_files
deploy_documentation

# Summary
if [[ "${DRY_RUN:-}" == "true" ]]; then
    log_info ""
    log_info "Dry-run complete. Run without --check to actually deploy files."
else
    show_summary
fi