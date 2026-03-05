#!/bin/bash
# =============================================================================
# ArcGIS Enterprise Single-Machine Bootstrap Installer
# =============================================================================
# This script provides a single-command installation of ArcGIS Enterprise
# on a Linux VM following Esri's recommendations for single-machine deployment.
#
# Usage: sudo ./install.sh
#
# Prerequisites:
#   - Ubuntu 24.x
#   - .env file configured (copy from .env.example)
#   - License files in place
#   - Installer tarball in place
#   - Port 80 and 443 open for Let's Encrypt verification
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/install.log"

# =============================================================================
# Logging Functions
# =============================================================================
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${GREEN}[${timestamp}]${NC} $1"
    echo "[${timestamp}] $1" >> "$LOG_FILE"
}

log_warn() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${YELLOW}[${timestamp}] WARNING:${NC} $1"
    echo "[${timestamp}] WARNING: $1" >> "$LOG_FILE"
}

log_error() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${RED}[${timestamp}] ERROR:${NC} $1" >&2
    echo "[${timestamp}] ERROR: $1" >> "$LOG_FILE"
}

log_section() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "" >> "$LOG_FILE"
    echo "========================================" >> "$LOG_FILE"
    echo "$1" >> "$LOG_FILE"
    echo "========================================" >> "$LOG_FILE"
}

# =============================================================================
# Validation Functions
# =============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

load_env() {
    local env_file="${SCRIPT_DIR}/.env"
    
    if [[ ! -f "$env_file" ]]; then
        log_error ".env file not found!"
        log_error "Please copy .env.example to .env and configure it:"
        log_error "  cp .env.example .env"
        log_error "  nano .env"
        exit 1
    fi
    
    log "Loading configuration from .env"
    set -a
    source "$env_file"
    set +a
}

# =============================================================================
# Auto-Discovery Functions
# =============================================================================
auto_discover_fqdn() {
    if [[ -n "${ARCGIS_FQDN:-}" ]]; then
        log "Using configured FQDN: $ARCGIS_FQDN"
        return
    fi
    
    log "Auto-detecting FQDN..."
    
    # Try hostname -f first
    local detected_fqdn=$(hostname -f 2>/dev/null)
    
    if [[ -z "$detected_fqdn" ]]; then
        detected_fqdn=$(hostname 2>/dev/null)
    fi
    
    # Warn if it looks like a cloud internal hostname
    if [[ "$detected_fqdn" =~ \.(internal|local|cloudapp|compute|amazonaws|googleusercontent)\. ]]; then
        log_warn "Detected FQDN '$detected_fqdn' appears to be an internal cloud hostname"
        log_warn "For production, set ARCGIS_FQDN in .env to your public domain (e.g., gis.example.com)"
        log_warn "Proceeding with detected hostname..."
    fi
    
    if [[ -n "$detected_fqdn" ]]; then
        ARCGIS_FQDN="$detected_fqdn"
        export ARCGIS_FQDN
        log "  Auto-detected FQDN: $ARCGIS_FQDN"
    fi
}

auto_discover_files() {
    log "Auto-discovering license files and installer..."
    
    local license_dir="${ARCGIS_LICENSE_DIR:-/opt/esri/licenses}"
    local installer_dir="${ARCGIS_INSTALLER_DIR:-/opt/esri/installers}"
    
    # Auto-discover Server license (.prvc file)
    if [[ -z "${ARCGIS_SERVER_LICENSE:-}" ]]; then
        local server_license=$(find "$license_dir" -maxdepth 1 -name "*.prvc" -type f 2>/dev/null | head -1)
        if [[ -n "$server_license" ]]; then
            ARCGIS_SERVER_LICENSE="$server_license"
            log "  Found Server license: $server_license"
        fi
    else
        log "  Using configured Server license: $ARCGIS_SERVER_LICENSE"
    fi
    
    # Auto-discover Portal license (Portal*.json or *Portal*.json)
    if [[ -z "${ARCGIS_PORTAL_LICENSE:-}" ]]; then
        local portal_license=$(find "$license_dir" -maxdepth 1 -name "*Portal*.json" -type f 2>/dev/null | head -1)
        if [[ -n "$portal_license" ]]; then
            ARCGIS_PORTAL_LICENSE="$portal_license"
            log "  Found Portal license: $portal_license"
        fi
    else
        log "  Using configured Portal license: $ARCGIS_PORTAL_LICENSE"
    fi
    
    # Auto-discover Enterprise Builder installer tarball
    if [[ -z "${ARCGIS_INSTALLER_TAR:-}" ]]; then
        local installer=$(find "$installer_dir" -maxdepth 1 -name "ArcGIS_Enterprise_Builder_Linux*.tar.gz" -type f 2>/dev/null | head -1)
        if [[ -n "$installer" ]]; then
            ARCGIS_INSTALLER_TAR="$installer"
            log "  Found installer: $installer"
        fi
    else
        log "  Using configured installer: $ARCGIS_INSTALLER_TAR"
    fi
    
    # Export for subprocesses
    export ARCGIS_SERVER_LICENSE ARCGIS_PORTAL_LICENSE ARCGIS_INSTALLER_TAR
}

validate_config() {
    log "Validating configuration..."
    
    local required_vars=(
        "ARCGIS_FQDN"
        "ARCGIS_ADMIN_USER"
        "ARCGIS_ADMIN_PASSWORD"
        "ARCGIS_ADMIN_EMAIL"
        "ARCGIS_RUN_AS_USER"
        "LETSENCRYPT_EMAIL"
    )
    
    local missing=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required configuration variables:"
        for var in "${missing[@]}"; do
            log_error "  - $var"
        done
        exit 1
    fi
    
    # Validate auto-discovered/configured files exist
    if [[ -z "${ARCGIS_SERVER_LICENSE:-}" ]]; then
        log_error "Server license not found. Place a .prvc file in /opt/esri/licenses/ or set ARCGIS_SERVER_LICENSE in .env"
        exit 1
    fi
    if [[ ! -f "$ARCGIS_SERVER_LICENSE" ]]; then
        log_error "Server license file not found: $ARCGIS_SERVER_LICENSE"
        exit 1
    fi
    
    if [[ -z "${ARCGIS_PORTAL_LICENSE:-}" ]]; then
        log_error "Portal license not found. Place a *Portal*.json file in /opt/esri/licenses/ or set ARCGIS_PORTAL_LICENSE in .env"
        exit 1
    fi
    if [[ ! -f "$ARCGIS_PORTAL_LICENSE" ]]; then
        log_error "Portal license file not found: $ARCGIS_PORTAL_LICENSE"
        exit 1
    fi
    
    if [[ -z "${ARCGIS_INSTALLER_TAR:-}" ]]; then
        log_error "Installer not found. Place ArcGIS_Enterprise_Builder_Linux*.tar.gz in /opt/esri/installers/ or set ARCGIS_INSTALLER_TAR in .env"
        exit 1
    fi
    
    if [[ ! -f "$ARCGIS_INSTALLER_TAR" ]]; then
        log_error "Installer tarball not found: $ARCGIS_INSTALLER_TAR"
        exit 1
    fi
    
    # Validate password strength
    if [[ ${#ARCGIS_ADMIN_PASSWORD} -lt 8 ]]; then
        log_error "Admin password must be at least 8 characters"
        exit 1
    fi
    
    log "Configuration validated successfully"
}

# =============================================================================
# System Preparation
# =============================================================================
install_system_dependencies() {
    log_section "Installing System Dependencies"
    
    log "Updating package lists..."
    apt-get update -qq
    
    log "Installing required packages..."
    apt-get install -y -qq \
        curl \
        wget \
        unzip \
        tar \
        fontconfig \
        libfreetype6 \
        libxrender1 \
        libxtst6 \
        gettext \
        cifs-utils \
        certbot \
        openssl \
        net-tools \
        ca-certificates
    
    log "System dependencies installed"
}

configure_system_limits() {
    log_section "Configuring System Limits"
    
    # ArcGIS recommended ulimits
    cat > /etc/security/limits.d/99-arcgis.conf << 'EOF'
# ArcGIS Enterprise recommended limits
* soft nofile 65535
* hard nofile 65535
* soft nproc 25059
* hard nproc 25059
arcgis soft nofile 65535
arcgis hard nofile 65535
arcgis soft nproc 25059
arcgis hard nproc 25059
EOF

    # Ensure PAM limits are enabled
    if ! grep -q "pam_limits.so" /etc/pam.d/common-session 2>/dev/null; then
        echo "session required pam_limits.so" >> /etc/pam.d/common-session
    fi
    
    log "System limits configured"
}

configure_hosts_file() {
    log_section "Configuring Hosts File"
    
    # ArcGIS components communicate with each other using the FQDN.
    # The machine must resolve its own FQDN locally to avoid hairpin NAT
    # (traffic going out to internet and back).
    
    local hosts_entry="127.0.0.1 ${ARCGIS_FQDN}"
    
    if grep -q "^127\.0\.0\.1.*${ARCGIS_FQDN}" /etc/hosts 2>/dev/null; then
        log "Hosts file already configured for ${ARCGIS_FQDN}"
    elif grep -q "${ARCGIS_FQDN}" /etc/hosts 2>/dev/null; then
        # FQDN exists but not pointing to 127.0.0.1 - update it
        log_warn "Updating existing hosts entry for ${ARCGIS_FQDN}"
        sed -i "/${ARCGIS_FQDN}/d" /etc/hosts
        echo "$hosts_entry" >> /etc/hosts
        log "Updated: $hosts_entry"
    else
        # Add new entry
        log "Adding hosts entry: $hosts_entry"
        echo "$hosts_entry" >> /etc/hosts
    fi
    
    # Verify the entry
    if getent hosts "$ARCGIS_FQDN" | grep -q "127.0.0.1"; then
        log "Verified: ${ARCGIS_FQDN} resolves to 127.0.0.1 locally"
    else
        log_warn "Could not verify hosts resolution. Check /etc/hosts manually."
    fi
}

create_arcgis_user() {
    log_section "Creating ArcGIS User"
    
    if id "$ARCGIS_RUN_AS_USER" &>/dev/null; then
        log "User '$ARCGIS_RUN_AS_USER' already exists"
    else
        log "Creating user '$ARCGIS_RUN_AS_USER'..."
        useradd -m -s /bin/bash "$ARCGIS_RUN_AS_USER"
        log "User created"
    fi
}

create_directories() {
    log_section "Creating Directory Structure"
    
    local dirs=(
        "$ARCGIS_INSTALL_DIR"
        "$ARCGIS_DATA_DIR"
        "$ARCGIS_CONFIG_STORE"
        "$ARCGIS_SERVER_DIRS"
        "$ARCGIS_PORTAL_CONTENT"
        "/opt/esri/builder"
        "/opt/esri/ssl"
        "/opt/esri/scripts"
    )
    
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log "Created: $dir"
        fi
    done
    
    # Set ownership
    chown -R "$ARCGIS_RUN_AS_USER:$ARCGIS_RUN_AS_USER" /opt/esri
    
    log "Directory structure created"
}

# =============================================================================
# SSL Certificate Management
# =============================================================================
setup_ssl_certificate() {
    log_section "Setting up SSL Certificate (Let's Encrypt)"
    
    local staging_flag=""
    if [[ "${LETSENCRYPT_STAGING:-false}" == "true" ]]; then
        log_warn "Using Let's Encrypt STAGING server (certificates will NOT be trusted)"
        staging_flag="--staging"
    fi
    
    log "Obtaining SSL certificate for ${ARCGIS_FQDN}..."
    
    # Check if Cloudflare API token is available for DNS challenge
    if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        log "Using Cloudflare DNS challenge (CLOUDFLARE_API_TOKEN detected)"
        setup_ssl_cloudflare "$staging_flag"
    else
        log "Using HTTP-01 challenge (standalone mode)"
        setup_ssl_http01 "$staging_flag"
    fi
    
    log "SSL certificate obtained successfully"
    
    # Set up certificate paths
    CERT_PATH="/etc/letsencrypt/live/${ARCGIS_FQDN}"
    
    # Create PKCS12 keystore for ArcGIS
    create_arcgis_keystore
    
    # Install renewal hook
    install_renewal_hook
}

setup_ssl_http01() {
    local staging_flag="$1"
    
    # HTTP-01 challenge: requires port 80 open to internet
    certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --email "$LETSENCRYPT_EMAIL" \
        --domains "$ARCGIS_FQDN" \
        $staging_flag \
        --preferred-challenges http
}

setup_ssl_cloudflare() {
    local staging_flag="$1"
    
    # Install Cloudflare DNS plugin if not present
    if ! command -v certbot &> /dev/null || ! certbot plugins 2>/dev/null | grep -q "dns-cloudflare"; then
        log "Installing certbot Cloudflare DNS plugin..."
        apt-get install -y -qq python3-certbot-dns-cloudflare 2>/dev/null || \
            pip3 install certbot-dns-cloudflare 2>/dev/null || \
            snap install certbot-dns-cloudflare 2>/dev/null || true
    fi
    
    # Create Cloudflare credentials file
    local cf_creds="/etc/letsencrypt/cloudflare.ini"
    mkdir -p /etc/letsencrypt
    cat > "$cf_creds" << EOF
# Cloudflare API token for Let's Encrypt DNS challenge
dns_cloudflare_api_token = ${CLOUDFLARE_API_TOKEN}
EOF
    chmod 600 "$cf_creds"
    
    # DNS-01 challenge: uses Cloudflare API to create TXT record
    certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials "$cf_creds" \
        --dns-cloudflare-propagation-seconds 30 \
        --non-interactive \
        --agree-tos \
        --email "$LETSENCRYPT_EMAIL" \
        --domains "$ARCGIS_FQDN" \
        $staging_flag
    
    log "Certificate obtained via Cloudflare DNS challenge"
}

create_arcgis_keystore() {
    log "Creating PKCS12 keystore for ArcGIS..."
    
    local cert_dir="/etc/letsencrypt/live/${ARCGIS_FQDN}"
    local keystore_dir="/opt/esri/ssl"
    local keystore_file="${keystore_dir}/arcgis.pfx"
    local keystore_password="${ARCGIS_ADMIN_PASSWORD}"
    
    # Create PKCS12 file from Let's Encrypt certificates
    openssl pkcs12 -export \
        -in "${cert_dir}/fullchain.pem" \
        -inkey "${cert_dir}/privkey.pem" \
        -out "$keystore_file" \
        -name "$ARCGIS_FQDN" \
        -password "pass:${keystore_password}"
    
    # Set permissions
    chmod 640 "$keystore_file"
    chown "${ARCGIS_RUN_AS_USER}:${ARCGIS_RUN_AS_USER}" "$keystore_file"
    
    # Save keystore password for renewal script
    echo "$keystore_password" > "${keystore_dir}/.keystore_password"
    chmod 600 "${keystore_dir}/.keystore_password"
    chown root:root "${keystore_dir}/.keystore_password"
    
    log "PKCS12 keystore created at: $keystore_file"
}

install_renewal_hook() {
    log "Installing certificate renewal hook..."
    
    # Copy renewal script
    cp "${SCRIPT_DIR}/scripts/ssl-renewal-hook.sh" /opt/esri/scripts/
    chmod +x /opt/esri/scripts/ssl-renewal-hook.sh
    
    # Create certbot renewal hook
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > "/etc/letsencrypt/renewal-hooks/deploy/arcgis-ssl-update.sh" << 'HOOK'
#!/bin/bash
# ArcGIS Enterprise SSL Certificate Renewal Hook
# This script is called by certbot after successful certificate renewal

/opt/esri/scripts/ssl-renewal-hook.sh
HOOK
    
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/arcgis-ssl-update.sh
    
    # Set up automatic renewal timer (should already be there from certbot)
    systemctl enable certbot.timer 2>/dev/null || true
    systemctl start certbot.timer 2>/dev/null || true
    
    log "Renewal hook installed"
}

# =============================================================================
# ArcGIS Enterprise Builder Installation
# =============================================================================
extract_installer() {
    log_section "Extracting ArcGIS Enterprise Builder"
    
    local extract_dir="/opt/esri/builder"
    
    log "Extracting installer tarball..."
    tar -xzf "$ARCGIS_INSTALLER_TAR" -C "$extract_dir"
    
    chown -R "$ARCGIS_RUN_AS_USER:$ARCGIS_RUN_AS_USER" "$extract_dir"
    
    log "Installer extracted to: $extract_dir"
}

generate_properties_file() {
    log_section "Generating Enterprise Builder Properties File"
    
    local props_file="/opt/esri/builder/enterprise.properties"
    
    # Generate properties file from template with variable substitution
    cat > "$props_file" << EOF
# =============================================================================
# ArcGIS Enterprise Builder Configuration
# Generated: $(date)
# =============================================================================

# Deployment Configuration
DEPLOYMENT_MODE=INSTALL
AGREE_TO_EULA=yes

# Machine Configuration  
FQDN=${ARCGIS_FQDN}

# Installation User
RUN_AS_USER=${ARCGIS_RUN_AS_USER}

# Installation Directories
INSTALLDIR=${ARCGIS_INSTALL_DIR}

# Server Configuration
SERVER_LICENSE_FILE=${ARCGIS_SERVER_LICENSE}
SERVER_ADMIN_USERNAME=${ARCGIS_ADMIN_USER}
SERVER_ADMIN_PASSWORD=${ARCGIS_ADMIN_PASSWORD}
SERVER_CONFIG_STORE_DIR=${ARCGIS_CONFIG_STORE}
SERVER_DIRECTORIES_ROOT=${ARCGIS_SERVER_DIRS}

# Portal Configuration
PORTAL_LICENSE_FILE=${ARCGIS_PORTAL_LICENSE}
PORTAL_ADMIN_USERNAME=${ARCGIS_ADMIN_USER}
PORTAL_ADMIN_PASSWORD=${ARCGIS_ADMIN_PASSWORD}
PORTAL_ADMIN_EMAIL=${ARCGIS_ADMIN_EMAIL}
PORTAL_ADMIN_FULL_NAME=${ARCGIS_ADMIN_FIRSTNAME} ${ARCGIS_ADMIN_LASTNAME}
PORTAL_ADMIN_FIRST_NAME=${ARCGIS_ADMIN_FIRSTNAME}
PORTAL_ADMIN_LAST_NAME=${ARCGIS_ADMIN_LASTNAME}
PORTAL_ADMIN_SECURITY_QUESTION_INDEX=${ARCGIS_ADMIN_SECURITY_QUESTION_INDEX:-1}
PORTAL_ADMIN_SECURITY_ANSWER=${ARCGIS_ADMIN_SECURITY_ANSWER}
PORTAL_CONTENT_DIR=${ARCGIS_PORTAL_CONTENT}

# Data Store Configuration
DATA_STORE_TYPES=relational,tileCache

# Web Adaptor Configuration
WEB_SERVER_TYPE=TOMCAT
WEB_ADAPTOR_PORT=443
SERVER_WEB_ADAPTOR_NAME=${WEB_ADAPTOR_SERVER_CONTEXT:-server}
PORTAL_WEB_ADAPTOR_NAME=${WEB_ADAPTOR_PORTAL_CONTEXT:-portal}

# SSL Configuration
# Initial setup uses self-signed, we'll import Let's Encrypt cert after
SSL_CERTIFICATE_FILE=/opt/esri/ssl/arcgis.pfx
SSL_CERTIFICATE_PASSWORD=${ARCGIS_ADMIN_PASSWORD}
SSL_CERTIFICATE_ALIAS=${ARCGIS_FQDN}
EOF

    chmod 600 "$props_file"
    chown "$ARCGIS_RUN_AS_USER:$ARCGIS_RUN_AS_USER" "$props_file"
    
    log "Properties file generated: $props_file"
}

run_enterprise_builder() {
    log_section "Running ArcGIS Enterprise Builder"
    
    local builder_dir="/opt/esri/builder"
    local props_file="${builder_dir}/enterprise.properties"
    
    # Find the setup script
    local setup_script=$(find "$builder_dir" -name "Setup.sh" -o -name "setup.sh" | head -1)
    
    if [[ -z "$setup_script" ]]; then
        # Try to find in extracted directory
        setup_script=$(find "$builder_dir" -name "*.sh" -path "*Builder*" | head -1)
    fi
    
    if [[ -z "$setup_script" ]]; then
        log_error "Could not find Enterprise Builder setup script"
        log "Contents of builder directory:"
        ls -la "$builder_dir"
        exit 1
    fi
    
    log "Found setup script: $setup_script"
    chmod +x "$setup_script"
    
    log "Starting ArcGIS Enterprise installation..."
    log "This will take 30-60 minutes. Check $LOG_FILE for details."
    
    # Run the installer
    cd "$(dirname "$setup_script")"
    
    # The Enterprise Builder command-line mode
    if [[ -f "${builder_dir}/ArcGISEnterpriseBuilder/EnterpriseBuilder.sh" ]]; then
        sudo -u "$ARCGIS_RUN_AS_USER" "${builder_dir}/ArcGISEnterpriseBuilder/EnterpriseBuilder.sh" \
            -f "$props_file" \
            2>&1 | tee -a "$LOG_FILE"
    else
        # Alternative: Look for the standard pattern
        local eb_script=$(find "$builder_dir" -name "EnterpriseBuilder.sh" -o -name "enterprisebuilder.sh" | head -1)
        if [[ -n "$eb_script" ]]; then
            chmod +x "$eb_script"
            sudo -u "$ARCGIS_RUN_AS_USER" "$eb_script" -f "$props_file" 2>&1 | tee -a "$LOG_FILE"
        else
            log_warn "Could not find EnterpriseBuilder.sh, attempting alternative installation..."
            # Run Setup.sh with silent mode
            sudo -u "$ARCGIS_RUN_AS_USER" "$setup_script" -l yes -a "$props_file" 2>&1 | tee -a "$LOG_FILE"
        fi
    fi
    
    log "ArcGIS Enterprise installation completed"
}

# =============================================================================
# Post-Installation Configuration
# =============================================================================
import_ssl_certificate() {
    log_section "Importing SSL Certificate into ArcGIS Enterprise"
    
    local arcgis_home="${ARCGIS_INSTALL_DIR}"
    local cert_file="/opt/esri/ssl/arcgis.pfx"
    local cert_password="${ARCGIS_ADMIN_PASSWORD}"
    
    # Wait for services to be ready
    log "Waiting for ArcGIS services to start..."
    sleep 30
    
    # Import certificate to Portal
    log "Importing certificate to Portal for ArcGIS..."
    local portal_admin_url="https://${ARCGIS_FQDN}:7443/arcgis/portaladmin"
    
    # Generate token
    local token_response=$(curl -sk -X POST "${portal_admin_url}/generateToken" \
        -d "username=${ARCGIS_ADMIN_USER}" \
        -d "password=${ARCGIS_ADMIN_PASSWORD}" \
        -d "client=referer" \
        -d "referer=${portal_admin_url}" \
        -d "f=json")
    
    local token=$(echo "$token_response" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    
    if [[ -n "$token" ]]; then
        # Import SSL certificate to Portal
        curl -sk -X POST "${portal_admin_url}/machines/${ARCGIS_FQDN}/sslCertificates/importExistingServerCertificate" \
            -F "certFile=@${cert_file}" \
            -F "certPassword=${cert_password}" \
            -F "alias=${ARCGIS_FQDN}" \
            -F "token=${token}" \
            -F "f=json"
        
        # Update Portal to use the new certificate
        curl -sk -X POST "${portal_admin_url}/machines/${ARCGIS_FQDN}/sslCertificates/update" \
            -d "webServerCertificateAlias=${ARCGIS_FQDN}" \
            -d "token=${token}" \
            -d "f=json"
        
        log "Certificate imported to Portal"
    else
        log_warn "Could not get Portal token. Manual certificate import may be required."
    fi
    
    # Import certificate to Server
    log "Importing certificate to ArcGIS Server..."
    local server_admin_url="https://${ARCGIS_FQDN}:6443/arcgis/admin"
    
    token_response=$(curl -sk -X POST "${server_admin_url}/generateToken" \
        -d "username=${ARCGIS_ADMIN_USER}" \
        -d "password=${ARCGIS_ADMIN_PASSWORD}" \
        -d "client=referer" \
        -d "referer=${server_admin_url}" \
        -d "f=json")
    
    token=$(echo "$token_response" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    
    if [[ -n "$token" ]]; then
        # Import SSL certificate to Server
        curl -sk -X POST "${server_admin_url}/machines/${ARCGIS_FQDN}/sslCertificates/importExistingServerCertificate" \
            -F "certFile=@${cert_file}" \
            -F "certPassword=${cert_password}" \
            -F "alias=${ARCGIS_FQDN}" \
            -F "token=${token}" \
            -F "f=json"
        
        # Update Server to use the new certificate
        curl -sk -X POST "${server_admin_url}/machines/${ARCGIS_FQDN}/edit" \
            -d "webServerCertificateAlias=${ARCGIS_FQDN}" \
            -d "token=${token}" \
            -d "f=json"
        
        log "Certificate imported to Server"
    else
        log_warn "Could not get Server token. Manual certificate import may be required."
    fi
}

configure_firewall() {
    log_section "Configuring Firewall"
    
    # Check if ufw is available
    if command -v ufw &> /dev/null; then
        log "Configuring UFW firewall..."
        
        ufw allow 80/tcp comment 'HTTP for Let'\''s Encrypt'
        ufw allow 443/tcp comment 'HTTPS'
        ufw allow 6443/tcp comment 'ArcGIS Server Admin'
        ufw allow 7443/tcp comment 'Portal Admin'
        
        log "Firewall rules configured"
    else
        log_warn "UFW not found. Please manually configure firewall rules."
    fi
}

# =============================================================================
# Status and Health Check
# =============================================================================
verify_installation() {
    log_section "Verifying Installation"
    
    local success=true
    
    # Check Portal
    log "Checking Portal for ArcGIS..."
    local portal_status=$(curl -sk "https://${ARCGIS_FQDN}:7443/arcgis/portaladmin/healthCheck?f=json" 2>/dev/null)
    if echo "$portal_status" | grep -q '"status"'; then
        log "  Portal: OK"
    else
        log_warn "  Portal: May need more time to start"
        success=false
    fi
    
    # Check Server
    log "Checking ArcGIS Server..."
    local server_status=$(curl -sk "https://${ARCGIS_FQDN}:6443/arcgis/admin/healthCheck?f=json" 2>/dev/null)
    if echo "$server_status" | grep -q '"status"'; then
        log "  Server: OK"
    else
        log_warn "  Server: May need more time to start"
        success=false
    fi
    
    # Check Web Adaptors
    log "Checking Web Adaptors..."
    local wa_portal=$(curl -sk "https://${ARCGIS_FQDN}/${WEB_ADAPTOR_PORTAL_CONTEXT:-portal}/home/" -o /dev/null -w "%{http_code}" 2>/dev/null)
    local wa_server=$(curl -sk "https://${ARCGIS_FQDN}/${WEB_ADAPTOR_SERVER_CONTEXT:-server}/rest/services" -o /dev/null -w "%{http_code}" 2>/dev/null)
    
    if [[ "$wa_portal" == "200" ]] || [[ "$wa_portal" == "302" ]]; then
        log "  Portal Web Adaptor: OK"
    else
        log_warn "  Portal Web Adaptor: HTTP $wa_portal"
    fi
    
    if [[ "$wa_server" == "200" ]] || [[ "$wa_server" == "302" ]]; then
        log "  Server Web Adaptor: OK"
    else
        log_warn "  Server Web Adaptor: HTTP $wa_server"
    fi
    
    echo ""
    if [[ "$success" == "true" ]]; then
        log "Installation verification complete!"
    else
        log_warn "Some services may need additional time to start."
        log "Run this script with --verify to check again."
    fi
}

print_summary() {
    log_section "Installation Complete!"
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           ArcGIS Enterprise Installation Complete            ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BLUE}Portal for ArcGIS:${NC}"
    echo -e "    URL:      https://${ARCGIS_FQDN}/${WEB_ADAPTOR_PORTAL_CONTEXT:-portal}/home"
    echo -e "    Admin:    https://${ARCGIS_FQDN}:7443/arcgis/portaladmin"
    echo ""
    echo -e "  ${BLUE}ArcGIS Server:${NC}"
    echo -e "    REST:     https://${ARCGIS_FQDN}/${WEB_ADAPTOR_SERVER_CONTEXT:-server}/rest/services"
    echo -e "    Admin:    https://${ARCGIS_FQDN}:6443/arcgis/admin"
    echo ""
    echo -e "  ${BLUE}Login Credentials:${NC}"
    echo -e "    Username: ${ARCGIS_ADMIN_USER}"
    echo -e "    Password: (from your .env file)"
    echo ""
    echo -e "  ${BLUE}SSL Certificate:${NC}"
    echo -e "    Issuer:   Let's Encrypt"
    echo -e "    Auto-renewal: Enabled (via certbot timer)"
    echo ""
    echo -e "  ${BLUE}Log file:${NC} ${LOG_FILE}"
    echo ""
    echo -e "${YELLOW}Note: Services may take a few minutes to fully initialize.${NC}"
    echo ""
}

# =============================================================================
# Main Execution
# =============================================================================
main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║     ArcGIS Enterprise Single-Machine Bootstrap Installer     ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Handle command line arguments
    case "${1:-}" in
        --verify)
            load_env
            verify_installation
            exit 0
            ;;
        --ssl-only)
            load_env
            setup_ssl_certificate
            import_ssl_certificate
            exit 0
            ;;
        --help)
            echo "Usage: sudo $0 [OPTION]"
            echo ""
            echo "Options:"
            echo "  (none)      Full installation"
            echo "  --verify    Verify installation status"
            echo "  --ssl-only  Only setup/renew SSL certificate"
            echo "  --help      Show this help"
            exit 0
            ;;
    esac
    
    # Pre-flight checks
    check_root
    load_env
    auto_discover_fqdn
    auto_discover_files
    validate_config
    
    # System preparation
    install_system_dependencies
    configure_system_limits
    configure_hosts_file
    create_arcgis_user
    create_directories
    
    # SSL Setup (before ArcGIS so cert is ready)
    setup_ssl_certificate
    
    # ArcGIS Installation
    extract_installer
    generate_properties_file
    run_enterprise_builder
    
    # Post-installation
    import_ssl_certificate
    configure_firewall
    
    # Verification
    verify_installation
    print_summary
}

# Run main function
main "$@"
