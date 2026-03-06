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
    
    # Set defaults for optional variables
    ARCGIS_INSTALL_DIR="${ARCGIS_INSTALL_DIR:-/opt/esri/arcgis}"
    ARCGIS_DATA_DIR="${ARCGIS_DATA_DIR:-/opt/esri/data}"
    ARCGIS_CONFIG_STORE="${ARCGIS_CONFIG_STORE:-/opt/esri/data/config-store}"
    ARCGIS_SERVER_DIRS="${ARCGIS_SERVER_DIRS:-/opt/esri/data/server-dirs}"
    ARCGIS_PORTAL_CONTENT="${ARCGIS_PORTAL_CONTENT:-/opt/esri/data/portal-content}"
    ARCGIS_RUN_AS_USER="${ARCGIS_RUN_AS_USER:-arcgis}"
    ARCGIS_ADMIN_SECURITY_QUESTION_INDEX="${ARCGIS_ADMIN_SECURITY_QUESTION_INDEX:-1}"
    WEB_ADAPTOR_SERVER_CONTEXT="${WEB_ADAPTOR_SERVER_CONTEXT:-server}"
    WEB_ADAPTOR_PORTAL_CONTEXT="${WEB_ADAPTOR_PORTAL_CONTEXT:-portal}"
    
    export ARCGIS_INSTALL_DIR ARCGIS_DATA_DIR ARCGIS_CONFIG_STORE ARCGIS_SERVER_DIRS ARCGIS_PORTAL_CONTENT
    export ARCGIS_RUN_AS_USER ARCGIS_ADMIN_SECURITY_QUESTION_INDEX WEB_ADAPTOR_SERVER_CONTEXT WEB_ADAPTOR_PORTAL_CONTEXT
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
    
    # Check if FQDN already has any IP mapping in hosts file
    if grep -qE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+.*${ARCGIS_FQDN}" /etc/hosts 2>/dev/null; then
        local existing_ip=$(grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+.*${ARCGIS_FQDN}" /etc/hosts | head -1 | awk '{print $1}')
        log "Hosts file already configured: ${ARCGIS_FQDN} → ${existing_ip}"
    else
        # Add new entry
        log "Adding hosts entry: $hosts_entry"
        echo "$hosts_entry" >> /etc/hosts
    fi
    
    # Verify the entry resolves locally
    local resolved_ip=$(getent hosts "$ARCGIS_FQDN" 2>/dev/null | awk '{print $1}')
    if [[ -n "$resolved_ip" ]]; then
        log "Verified: ${ARCGIS_FQDN} resolves to ${resolved_ip} locally"
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
    
    local cert_dir="/etc/letsencrypt/live/${ARCGIS_FQDN}"
    local cert_file="${cert_dir}/fullchain.pem"
    local staging_flag=""
    
    if [[ "${LETSENCRYPT_STAGING:-false}" == "true" ]]; then
        log_warn "Using Let's Encrypt STAGING server (certificates will NOT be trusted)"
        staging_flag="--staging"
    fi
    
    # Check if certificate already exists and is still valid
    if [[ -f "$cert_file" ]]; then
        # Get expiry date and calculate days remaining
        local expiry_epoch=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
        local expiry_date=$(date -d "$expiry_epoch" +%s 2>/dev/null || echo 0)
        local now=$(date +%s)
        local days_remaining=$(( (expiry_date - now) / 86400 ))
        
        if [[ $days_remaining -gt 30 ]]; then
            log "Certificate valid for ${days_remaining} more days - skipping renewal check"
            log "  Expires: $expiry_epoch"
            
            # Still need to ensure keystores and hooks are set up
            CERT_PATH="$cert_dir"
            create_arcgis_keystore
            install_renewal_hook
            return 0
        else
            log "Certificate expires in ${days_remaining} days - will attempt renewal"
        fi
    else
        log "No existing certificate found - obtaining new certificate"
    fi
    
    log "Obtaining SSL certificate for ${ARCGIS_FQDN}..."
    
    # Check if Cloudflare API token is available for DNS challenge
    if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        log "Using Cloudflare DNS challenge"
        setup_ssl_cloudflare "$staging_flag"
    else
        log "Using HTTP-01 challenge (standalone mode)"
        setup_ssl_http01 "$staging_flag"
    fi
    
    # Set up certificate paths
    CERT_PATH="/etc/letsencrypt/live/${ARCGIS_FQDN}"
    
    # Create PKCS12 keystore for ArcGIS (only if needed)
    create_arcgis_keystore
    
    # Install renewal hook (idempotent)
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
    local cert_dir="/etc/letsencrypt/live/${ARCGIS_FQDN}"
    local keystore_dir="/opt/esri/ssl"
    local keystore_file="${keystore_dir}/arcgis.pfx"
    local keystore_password="${ARCGIS_ADMIN_PASSWORD}"
    
    # Check if keystore already exists and is up-to-date
    if [[ -f "$keystore_file" ]]; then
        local cert_time=$(stat -c %Y "${cert_dir}/fullchain.pem" 2>/dev/null || echo 0)
        local keystore_time=$(stat -c %Y "$keystore_file" 2>/dev/null || echo 0)
        
        if [[ $keystore_time -ge $cert_time ]]; then
            log "PKCS12 keystore already up-to-date: $keystore_file"
            return 0
        fi
        log "Certificate newer than keystore, regenerating..."
    fi
    
    log "Creating PKCS12 keystore for ArcGIS..."
    
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
    local hook_file="/etc/letsencrypt/renewal-hooks/deploy/arcgis-ssl-update.sh"
    
    # Check if already installed
    if [[ -f "$hook_file" ]] && [[ -f "/opt/esri/scripts/ssl-renewal-hook.sh" ]]; then
        log "Certificate renewal hook already installed"
        return 0
    fi
    
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
# Tomcat Installation and Configuration
# =============================================================================
install_tomcat() {
    log_section "Installing Apache Tomcat"
    
    # Disable any conflicting pre-installed Tomcat services
    for svc in tomcat10 tomcat9 tomcat8; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log "Stopping conflicting service: $svc"
            systemctl stop "$svc" || true
            systemctl disable "$svc" || true
        fi
    done
    
    # Check if Tomcat is already installed
    if [[ -d "/opt/tomcat" ]] && [[ -f "/opt/tomcat/bin/catalina.sh" ]]; then
        log "Tomcat already installed at /opt/tomcat"
        return 0
    fi
    
    local tomcat_version="10.1.34"
    local tomcat_url="https://dlcdn.apache.org/tomcat/tomcat-10/v${tomcat_version}/bin/apache-tomcat-${tomcat_version}.tar.gz"
    local tomcat_dir="/opt/tomcat"
    local download_dir="/tmp"
    
    log "Installing OpenJDK 17..."
    apt-get install -y -qq openjdk-17-jdk
    
    # Set JAVA_HOME
    export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))
    echo "JAVA_HOME=${JAVA_HOME}" > /etc/environment
    
    log "Downloading Tomcat ${tomcat_version}..."
    wget -q -O "${download_dir}/tomcat.tar.gz" "$tomcat_url" || {
        # Fallback to archive if latest not available
        tomcat_url="https://archive.apache.org/dist/tomcat/tomcat-10/v${tomcat_version}/bin/apache-tomcat-${tomcat_version}.tar.gz"
        wget -q -O "${download_dir}/tomcat.tar.gz" "$tomcat_url"
    }
    
    log "Extracting Tomcat..."
    mkdir -p "$tomcat_dir"
    tar -xzf "${download_dir}/tomcat.tar.gz" -C "$tomcat_dir" --strip-components=1
    rm -f "${download_dir}/tomcat.tar.gz"
    
    # Create tomcat user if not exists
    if ! id "tomcat" &>/dev/null; then
        useradd -r -M -U -d "$tomcat_dir" -s /bin/false tomcat
    fi
    
    # Set ownership
    chown -R tomcat:tomcat "$tomcat_dir"
    chmod +x ${tomcat_dir}/bin/*.sh
    
    # Allow Java to bind to privileged ports (80, 443) as non-root
    configure_java_privileged_ports
    
    log "Tomcat installed to $tomcat_dir"
}

configure_java_privileged_ports() {
    # Find the Java binary
    local java_bin=$(readlink -f $(which java))
    
    if [[ -z "$java_bin" ]] || [[ ! -f "$java_bin" ]]; then
        log_warn "Could not find Java binary to set capabilities"
        return 1
    fi
    
    # Check if capability is already set
    if getcap "$java_bin" 2>/dev/null | grep -q 'cap_net_bind_service'; then
        log "Java already has cap_net_bind_service capability"
        return 0
    fi
    
    log "Configuring Java to bind to privileged ports..."
    
    # Install libcap2-bin if not present
    apt-get install -y -qq libcap2-bin 2>/dev/null || true
    
    # Grant capability to bind to privileged ports
    setcap 'cap_net_bind_service=+ep' "$java_bin"
    log "Granted cap_net_bind_service to: $java_bin"
}

configure_tomcat_ssl() {
    log_section "Configuring Tomcat SSL"
    
    # Ensure Java can bind to privileged ports (needed even if Tomcat already installed)
    configure_java_privileged_ports
    
    local tomcat_dir="/opt/tomcat"
    local cert_dir="/etc/letsencrypt/live/${ARCGIS_FQDN}"
    local keystore_file="${tomcat_dir}/conf/keystore.p12"
    local keystore_password="${ARCGIS_ADMIN_PASSWORD}"
    
    # Check if Tomcat keystore already exists and is up-to-date
    local needs_keystore=true
    if [[ -f "$keystore_file" ]]; then
        local cert_time=$(stat -c %Y "${cert_dir}/fullchain.pem" 2>/dev/null || echo 0)
        local keystore_time=$(stat -c %Y "$keystore_file" 2>/dev/null || echo 0)
        
        if [[ $keystore_time -ge $cert_time ]]; then
            log "Tomcat SSL keystore already up-to-date"
            needs_keystore=false
        fi
    fi
    
    if [[ "$needs_keystore" == "true" ]]; then
        log "Creating Tomcat SSL keystore..."
        openssl pkcs12 -export \
            -in "${cert_dir}/fullchain.pem" \
            -inkey "${cert_dir}/privkey.pem" \
            -out "$keystore_file" \
            -name tomcat \
            -password "pass:${keystore_password}"
        
        chown tomcat:tomcat "$keystore_file"
        chmod 640 "$keystore_file"
    fi
    
    # Backup original server.xml
    if [[ ! -f "${tomcat_dir}/conf/server.xml.orig" ]]; then
        cp "${tomcat_dir}/conf/server.xml" "${tomcat_dir}/conf/server.xml.orig"
    fi
    
    # Check if server.xml already configured for our ports
    if grep -q 'Connector port="443"' "${tomcat_dir}/conf/server.xml" 2>/dev/null; then
        log "Tomcat server.xml already configured"
        return 0
    fi
    
    # Configure server.xml with SSL connector
    log "Configuring Tomcat server.xml..."
    cat > "${tomcat_dir}/conf/server.xml" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<Server port="8005" shutdown="SHUTDOWN">
  <Listener className="org.apache.catalina.startup.VersionLoggerListener" />
  <Listener className="org.apache.catalina.core.AprLifecycleListener" SSLEngine="on" />
  <Listener className="org.apache.catalina.core.JreMemoryLeakPreventionListener" />
  <Listener className="org.apache.catalina.mbeans.GlobalResourcesLifecycleListener" />
  <Listener className="org.apache.catalina.core.ThreadLocalLeakPreventionListener" />

  <GlobalNamingResources>
    <Resource name="UserDatabase" auth="Container"
              type="org.apache.catalina.UserDatabase"
              description="User database that can be updated and saved"
              factory="org.apache.catalina.users.MemoryUserDatabaseFactory"
              pathname="conf/tomcat-users.xml" />
  </GlobalNamingResources>

  <Service name="Catalina">
    <!-- HTTP connector - redirect to HTTPS -->
    <Connector port="80" protocol="HTTP/1.1"
               connectionTimeout="20000"
               redirectPort="443" />

    <!-- HTTPS connector -->
    <Connector port="443" protocol="org.apache.coyote.http11.Http11NioProtocol"
               maxThreads="150" SSLEnabled="true"
               scheme="https" secure="true">
        <SSLHostConfig>
            <Certificate certificateKeystoreFile="conf/keystore.p12"
                         certificateKeystorePassword="${keystore_password}"
                         certificateKeystoreType="PKCS12"
                         certificateKeyAlias="tomcat" />
        </SSLHostConfig>
    </Connector>

    <Engine name="Catalina" defaultHost="localhost">
      <Realm className="org.apache.catalina.realm.LockOutRealm">
        <Realm className="org.apache.catalina.realm.UserDatabaseRealm"
               resourceName="UserDatabase"/>
      </Realm>

      <Host name="localhost" appBase="webapps"
            unpackWARs="true" autoDeploy="true">
        <Valve className="org.apache.catalina.valves.AccessLogValve" directory="logs"
               prefix="localhost_access_log" suffix=".txt"
               pattern="%h %l %u %t &quot;%r&quot; %s %b" />
      </Host>
    </Engine>
  </Service>
</Server>
EOF
    
    chown tomcat:tomcat "${tomcat_dir}/conf/server.xml"
    
    log "Tomcat SSL configured"
}

create_tomcat_service() {
    # Check if service already exists and is properly configured
    if [[ -f "/etc/systemd/system/tomcat.service" ]] && systemctl is-enabled tomcat &>/dev/null; then
        log "Tomcat systemd service already configured"
        return 0
    fi
    
    log "Creating Tomcat systemd service..."
    
    local java_home=$(dirname $(dirname $(readlink -f $(which java))))
    
    # Create PID directory
    mkdir -p /opt/tomcat/temp
    chown tomcat:tomcat /opt/tomcat/temp
    
    cat > /etc/systemd/system/tomcat.service << EOF
[Unit]
Description=Apache Tomcat Web Application Container
After=network.target

[Service]
Type=forking
PIDFile=/opt/tomcat/temp/tomcat.pid

Environment=JAVA_HOME=${java_home}
Environment=CATALINA_PID=/opt/tomcat/temp/tomcat.pid
Environment=CATALINA_HOME=/opt/tomcat
Environment=CATALINA_BASE=/opt/tomcat
Environment='CATALINA_OPTS=-Xms512M -Xmx2048M -server -XX:+UseParallelGC'
Environment='JAVA_OPTS=-Djava.awt.headless=true -Djava.security.egd=file:/dev/./urandom'

ExecStart=/opt/tomcat/bin/startup.sh
ExecStop=/opt/tomcat/bin/shutdown.sh

User=tomcat
Group=tomcat
UMask=0007
RestartSec=10
Restart=on-failure
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable tomcat
    
    log "Tomcat service created"
}

check_and_free_ports() {
    log "Checking ports 80 and 443..."
    
    # If Tomcat is already running on these ports, that's fine
    if systemctl is-active --quiet tomcat 2>/dev/null; then
        if ss -tlnp | grep ':443 ' | grep -q 'java'; then
            log "Tomcat is already running on ports 80/443"
            return 0
        fi
    fi
    
    local port_80_pid=$(ss -tlnp | grep ':80 ' | grep -oP 'pid=\K[0-9]+' | head -1)
    local port_443_pid=$(ss -tlnp | grep ':443 ' | grep -oP 'pid=\K[0-9]+' | head -1)
    
    if [[ -n "$port_80_pid" ]]; then
        local process_name=$(ps -p $port_80_pid -o comm= 2>/dev/null)
        log_warn "Port 80 is in use by $process_name (PID: $port_80_pid)"
        
        # Try to stop common services
        if systemctl is-active --quiet nginx 2>/dev/null; then
            log "Stopping nginx..."
            systemctl stop nginx
            systemctl disable nginx 2>/dev/null || true
        elif systemctl is-active --quiet apache2 2>/dev/null; then
            log "Stopping apache2..."
            systemctl stop apache2
            systemctl disable apache2 2>/dev/null || true
        fi
    fi
    
    if [[ -n "$port_443_pid" ]]; then
        local process_name=$(ps -p $port_443_pid -o comm= 2>/dev/null)
        log_warn "Port 443 is in use by $process_name (PID: $port_443_pid)"
        
        # Try to stop common services
        if systemctl is-active --quiet nginx 2>/dev/null; then
            log "Stopping nginx..."
            systemctl stop nginx
            systemctl disable nginx 2>/dev/null || true
        elif systemctl is-active --quiet apache2 2>/dev/null; then
            log "Stopping apache2..."
            systemctl stop apache2
            systemctl disable apache2 2>/dev/null || true
        fi
    fi
    
    # Verify ports are free
    sleep 2
    if ss -tlnp | grep -qE ':80 |:443 '; then
        log_error "Ports 80 or 443 are still in use. Please free them manually:"
        ss -tlnp | grep -E ':80 |:443 '
        exit 1
    fi
    
    log "Ports 80 and 443 are available"
}

start_tomcat() {
    log "Starting Tomcat..."
    
    # Check if Tomcat is already running properly
    if systemctl is-active --quiet tomcat && ss -tlnp | grep -q ':443 '; then
        log "Tomcat is already running (port 443 listening)"
        return 0
    fi
    
    # Stop any existing tomcat first
    systemctl stop tomcat 2>/dev/null || true
    sleep 2
    
    # Kill any stale Tomcat processes
    pkill -f 'catalina' 2>/dev/null || true
    sleep 1
    
    # Clean up stale PID file
    rm -f /opt/tomcat/temp/tomcat.pid
    
    systemctl start tomcat
    
    # Wait for Tomcat to fully start
    local max_wait=30
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        sleep 2
        waited=$((waited + 2))
        
        if systemctl is-active --quiet tomcat; then
            # Also verify port 443 is listening
            if ss -tlnp | grep -q ':443 '; then
                log "Tomcat started successfully (port 443 listening)"
                return 0
            fi
        fi
        log "Waiting for Tomcat... ${waited}s"
    done
    
    log_error "Tomcat failed to start properly"
    log "Checking Tomcat logs..."
    tail -50 /opt/tomcat/logs/catalina.out 2>/dev/null || true
    journalctl -u tomcat --no-pager -n 20
    exit 1
}

# =============================================================================
# Web Adaptor Installation
# =============================================================================
install_web_adaptor() {
    log_section "Installing ArcGIS Web Adaptor"
    
    local wa_installer_dir="/opt/esri/installers/WebAdaptor"
    local wa_setup="${wa_installer_dir}/WebAdaptor/Setup"
    local wa_install_dir="/opt/esri/webadaptor"
    
    # Check if Web Adaptor is already installed
    if [[ -d "${wa_install_dir}/java" ]]; then
        log "Web Adaptor already installed at ${wa_install_dir}"
        return 0
    fi
    
    # Check for Web Adaptor installer
    if [[ ! -f "$wa_setup" ]]; then
        # Try to find it elsewhere
        wa_setup=$(find /opt/esri -path "*/WebAdaptor/Setup" -type f 2>/dev/null | head -1)
        if [[ -z "$wa_setup" ]]; then
            log_error "Web Adaptor installer not found!"
            log_error "Please place the Web Adaptor installer in /opt/esri/installers/WebAdaptor/"
            exit 1
        fi
    fi
    
    log "Installing Web Adaptor from: $wa_setup"
    chmod +x "$wa_setup"
    
    # Create the install directory (required by installer)
    mkdir -p "$wa_install_dir"
    chown "$ARCGIS_RUN_AS_USER:$ARCGIS_RUN_AS_USER" "$wa_install_dir"
    
    # Install Web Adaptor silently
    sudo -u "$ARCGIS_RUN_AS_USER" "$wa_setup" -m silent -l yes -d "$wa_install_dir" \
        2>&1 | tee -a "$LOG_FILE"
    
    log "Web Adaptor installed to $wa_install_dir"
}

deploy_web_adaptor_wars() {
    log_section "Deploying Web Adaptor WAR Files to Tomcat"
    
    local wa_install_dir="/opt/esri/webadaptor"
    local tomcat_webapps="/opt/tomcat/webapps"
    
    # Find the WAR file - path varies by version (e.g., arcgis/webadaptor12.0/java/arcgis.war)
    local wa_war
    wa_war=$(find "$wa_install_dir" -name "arcgis.war" -type f 2>/dev/null | head -1)
    
    if [[ -z "$wa_war" || ! -f "$wa_war" ]]; then
        log_error "Web Adaptor WAR file not found under: $wa_install_dir"
        log_error "Run: find $wa_install_dir -name '*.war' to locate it"
        exit 1
    fi
    
    log "Found WAR file at: $wa_war"
    
    # Deploy two instances of Web Adaptor: one for Server, one for Portal
    local server_context="${WEB_ADAPTOR_SERVER_CONTEXT:-server}"
    local portal_context="${WEB_ADAPTOR_PORTAL_CONTEXT:-portal}"
    local need_restart=false
    
    # Deploy Server Web Adaptor
    if [[ ! -d "${tomcat_webapps}/${server_context}" ]]; then
        log "Deploying Server Web Adaptor as /${server_context}"
        cp "$wa_war" "${tomcat_webapps}/${server_context}.war"
        chown tomcat:tomcat "${tomcat_webapps}/${server_context}.war"
        need_restart=true
    else
        log "Server Web Adaptor already deployed at /${server_context}"
    fi
    
    # Deploy Portal Web Adaptor
    if [[ ! -d "${tomcat_webapps}/${portal_context}" ]]; then
        log "Deploying Portal Web Adaptor as /${portal_context}"
        cp "$wa_war" "${tomcat_webapps}/${portal_context}.war"
        chown tomcat:tomcat "${tomcat_webapps}/${portal_context}.war"
        need_restart=true
    else
        log "Portal Web Adaptor already deployed at /${portal_context}"
    fi
    
    # Only restart if we deployed new WARs, or if Tomcat isn't listening on 443
    if [[ "$need_restart" == "true" ]] || ! ss -tln 2>/dev/null | grep -q ":443 "; then
        log "Restarting Tomcat to deploy Web Adaptors..."
        systemctl stop tomcat || true
        sleep 2
        
        # Kill any stale processes holding Tomcat ports
        fuser -k 8005/tcp 2>/dev/null || true
        fuser -k 80/tcp 2>/dev/null || true
        fuser -k 443/tcp 2>/dev/null || true
        sleep 3
        
        # Start Tomcat
        systemctl start tomcat
        sleep 5
        
        # Wait for HTTPS port to be ready
        local port_wait=0
        while ! ss -tln 2>/dev/null | grep -q ":443 "; do
            if [[ $port_wait -ge 30 ]]; then
                log_warn "Tomcat HTTPS port 443 not listening after 30 seconds"
                break
            fi
            sleep 2
            port_wait=$((port_wait + 2))
        done
        
        # Wait for WARs to be extracted
        local max_wait=60
        local waited=0
        while [[ ! -d "${tomcat_webapps}/${server_context}" ]] || [[ ! -d "${tomcat_webapps}/${portal_context}" ]]; do
            if [[ $waited -ge $max_wait ]]; then
                log_error "Timed out waiting for Web Adaptor WARs to deploy"
                exit 1
            fi
            sleep 5
            waited=$((waited + 5))
            log "  Waiting for WAR deployment... ${waited}s"
        done
    else
        log "Tomcat already running with Web Adaptors deployed"
    fi
    
    if ss -tln 2>/dev/null | grep -q ":443 "; then
        log "Tomcat HTTPS listening on port 443"
    fi
    
    log "Web Adaptor WAR files deployed successfully"
}

configure_web_adaptor_server() {
    log_section "Configuring Web Adaptor for ArcGIS Server"
    
    local server_context="${WEB_ADAPTOR_SERVER_CONTEXT:-server}"
    local admin_url="https://${ARCGIS_FQDN}:6443/arcgis/admin"
    local wa_url="https://${ARCGIS_FQDN}/${server_context}"
    local tomcat_webapps="/opt/tomcat/webapps"
    
    # Wait for ArcGIS Server to be ready
    local server_url="https://${ARCGIS_FQDN}:6443/arcgis/rest/info?f=json"
    if ! wait_for_service "$server_url" "ArcGIS Server" 30 10; then
        log_error "ArcGIS Server not responding. Cannot configure Web Adaptor."
        exit 1
    fi
    
    # Check if already registered via REST API
    local token_response=$(curl -sk -X POST "${admin_url}/generateToken" \
        -d "username=${ARCGIS_ADMIN_USER}" \
        -d "password=${ARCGIS_ADMIN_PASSWORD}" \
        -d "client=requestip" \
        -d "f=json" 2>/dev/null)
    
    local token=$(echo "$token_response" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    
    if [[ -z "$token" ]]; then
        log_error "Could not obtain Server admin token"
        exit 1
    fi
    
    # Check existing Web Adaptors
    local existing=$(curl -sk "${admin_url}/system/webadaptors?token=${token}&f=json" 2>/dev/null)
    if echo "$existing" | grep -q "\"webAdaptorURL\":\"${wa_url}\""; then
        log "Server Web Adaptor already registered at ${wa_url}"
        return 0
    fi
    
    log "Registering Web Adaptor with ArcGIS Server using arcgis-wareg.jar..."
    log "  Web Adaptor URL: ${wa_url}"
    log "  Server Admin URL: ${admin_url}"
    
    # Find the arcgis-wareg.jar registration tool
    local wareg_jar
    wareg_jar=$(find "${tomcat_webapps}/${server_context}" -name "arcgis-wareg.jar" -type f 2>/dev/null | head -1)
    
    if [[ -z "$wareg_jar" || ! -f "$wareg_jar" ]]; then
        log_error "arcgis-wareg.jar not found in Web Adaptor deployment"
        exit 1
    fi
    
    log "  Using: ${wareg_jar}"
    
    # Find JRE for running the tool
    local java_exe
    java_exe=$(find /opt/esri/arcgis/server -name "java" -path "*/bin/java" -type f 2>/dev/null | head -1)
    if [[ -z "$java_exe" ]]; then
        java_exe="java"
    fi
    
    # Register using arcgis-wareg.jar (the official tool)
    # Note: REST API registration doesn't work properly and causes federation issues
    if "$java_exe" -jar "$wareg_jar" \
        -m server \
        -w "${wa_url}" \
        -g "https://${ARCGIS_FQDN}:6443" \
        -u "${ARCGIS_ADMIN_USER}" \
        -p "${ARCGIS_ADMIN_PASSWORD}" \
        -a true; then
        log "Server Web Adaptor registered successfully"
    else
        log_error "Failed to register Server Web Adaptor via arcgis-wareg.jar"
        exit 1
    fi
}

configure_web_adaptor_portal() {
    log_section "Configuring Web Adaptor for Portal"
    
    local portal_context="${WEB_ADAPTOR_PORTAL_CONTEXT:-portal}"
    local portal_admin_url="https://${ARCGIS_FQDN}:7443/arcgis/portaladmin"
    local sharing_url="https://${ARCGIS_FQDN}:7443/arcgis/sharing/rest"
    local wa_url="https://${ARCGIS_FQDN}/${portal_context}"
    local tomcat_webapps="/opt/tomcat/webapps"
    
    # Wait for Portal to be ready
    local portal_url="https://${ARCGIS_FQDN}:7443/arcgis/portaladmin/healthCheck?f=json"
    if ! wait_for_service "$portal_url" "Portal for ArcGIS" 30 10; then
        log_error "Portal not responding. Cannot configure Web Adaptor."
        exit 1
    fi
    
    # Portal uses the sharing API for token generation
    local token_response=$(curl -sk -X POST "${sharing_url}/generateToken" \
        -d "username=${ARCGIS_ADMIN_USER}" \
        -d "password=${ARCGIS_ADMIN_PASSWORD}" \
        -d "client=referer" \
        -d "referer=https://${ARCGIS_FQDN}" \
        -d "f=json" 2>/dev/null)
    
    local token=$(echo "$token_response" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    
    if [[ -z "$token" ]]; then
        log_error "Could not obtain Portal admin token"
        exit 1
    fi
    
    # Check existing Web Adaptors
    local existing=$(curl -sk -H "Referer: https://${ARCGIS_FQDN}" \
        "${portal_admin_url}/system/webadaptors?token=${token}&f=json" 2>/dev/null)
    if echo "$existing" | grep -q "\"webAdaptorURL\":\"${wa_url}\""; then
        log "Portal Web Adaptor already registered at ${wa_url}"
        return 0
    fi
    
    log "Registering Web Adaptor with Portal for ArcGIS using arcgis-wareg.jar..."
    log "  Web Adaptor URL: ${wa_url}"
    log "  Portal Admin URL: ${portal_admin_url}"
    
    # Find the arcgis-wareg.jar registration tool
    local wareg_jar
    wareg_jar=$(find "${tomcat_webapps}/${portal_context}" -name "arcgis-wareg.jar" -type f 2>/dev/null | head -1)
    
    if [[ -z "$wareg_jar" || ! -f "$wareg_jar" ]]; then
        log_error "arcgis-wareg.jar not found in Web Adaptor deployment"
        exit 1
    fi
    
    log "  Using: ${wareg_jar}"
    
    # Find JRE for running the tool
    local java_exe
    java_exe=$(find /opt/esri/arcgis/portal -name "java" -path "*/bin/java" -type f 2>/dev/null | head -1)
    if [[ -z "$java_exe" ]]; then
        java_exe="java"
    fi
    
    # Register using arcgis-wareg.jar (the official tool)
    # Note: REST API registration doesn't work properly and causes federation issues
    if "$java_exe" -jar "$wareg_jar" \
        -m portal \
        -w "${wa_url}" \
        -g "https://${ARCGIS_FQDN}:7443" \
        -u "${ARCGIS_ADMIN_USER}" \
        -p "${ARCGIS_ADMIN_PASSWORD}"; then
        log "Portal Web Adaptor registered successfully"
    else
        log_error "Failed to register Portal Web Adaptor via arcgis-wareg.jar"
        exit 1
    fi
}

# =============================================================================
# Post-Configuration Functions
# =============================================================================

configure_web_context_urls() {
    log_section "Configuring WebContextURLs for ArcGIS Components"
    
    local server_context="${WEB_ADAPTOR_SERVER_CONTEXT:-server}"
    local portal_context="${WEB_ADAPTOR_PORTAL_CONTEXT:-portal}"
    
    # Configure Server WebContextURL
    log "Setting Server WebContextURL..."
    local server_admin_url="https://${ARCGIS_FQDN}:6443/arcgis/admin"
    
    local token_response=$(curl -sk -X POST "${server_admin_url}/generateToken" \
        -d "username=${ARCGIS_ADMIN_USER}" \
        -d "password=${ARCGIS_ADMIN_PASSWORD}" \
        -d "client=requestip" \
        -d "f=json" 2>/dev/null)
    
    local token=$(echo "$token_response" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    
    if [[ -n "$token" ]]; then
        local response=$(curl -sk -X POST "${server_admin_url}/system/properties/update" \
            -d "WebContextURL=https://${ARCGIS_FQDN}/${server_context}" \
            -d "token=${token}" \
            -d "f=json" 2>/dev/null)
        
        if echo "$response" | grep -q '"status":"success"'; then
            log "  Server WebContextURL set to https://${ARCGIS_FQDN}/${server_context}"
        else
            log_warn "  Server WebContextURL update response: $response"
        fi
    fi
    
    # Configure Portal WebContextURL
    log "Setting Portal WebContextURL..."
    local portal_admin_url="https://${ARCGIS_FQDN}:7443/arcgis/portaladmin"
    local sharing_url="https://${ARCGIS_FQDN}:7443/arcgis/sharing/rest"
    
    token_response=$(curl -sk -X POST "${sharing_url}/generateToken" \
        -d "username=${ARCGIS_ADMIN_USER}" \
        -d "password=${ARCGIS_ADMIN_PASSWORD}" \
        -d "client=referer" \
        -d "referer=https://${ARCGIS_FQDN}" \
        -d "f=json" 2>/dev/null)
    
    token=$(echo "$token_response" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    
    if [[ -n "$token" ]]; then
        local response=$(curl -sk -X POST "${portal_admin_url}/system/properties/update" \
            -H "Referer: https://${ARCGIS_FQDN}" \
            -d "WebContextURL=https://${ARCGIS_FQDN}/${portal_context}" \
            -d "token=${token}" \
            -d "f=json" 2>/dev/null)
        
        if echo "$response" | grep -q '"status":"success"'; then
            log "  Portal WebContextURL set to https://${ARCGIS_FQDN}/${portal_context}"
        else
            log_warn "  Portal WebContextURL update response: $response"
        fi
    fi
    
    log "WebContextURLs configured"
}

configure_jre_trust_stores() {
    log_section "Configuring JRE Trust Stores for Cross-Component SSL Trust"
    
    # This ensures Server and Portal can trust each other's SSL certificates
    # Required for federation and secure communication between components
    
    local arcgis_install="/opt/esri/arcgis"
    local ssl_cert="/opt/esri/ssl/arcgis.crt"
    local keystore_pass="changeit"
    
    if [[ ! -f "$ssl_cert" ]]; then
        log_warn "SSL certificate not found at $ssl_cert - skipping trust store configuration"
        return 0
    fi
    
    # Find all JRE cacerts files in ArcGIS installation
    local cacerts_files=$(find "$arcgis_install" -name "cacerts" -path "*/security/*" -type f 2>/dev/null)
    
    for cacerts in $cacerts_files; do
        log "Importing certificate into: $cacerts"
        
        # Find keytool in the same JRE
        local jre_dir=$(dirname "$(dirname "$cacerts")")
        local keytool="${jre_dir}/bin/keytool"
        
        if [[ ! -f "$keytool" ]]; then
            keytool=$(dirname "$jre_dir")/bin/keytool
        fi
        
        if [[ ! -f "$keytool" ]]; then
            log_warn "  keytool not found for $cacerts"
            continue
        fi
        
        # Remove existing if present, then add
        "$keytool" -delete -alias "arcgis-ssl" -keystore "$cacerts" -storepass "$keystore_pass" 2>/dev/null || true
        
        if "$keytool" -importcert -trustcacerts -alias "arcgis-ssl" \
            -file "$ssl_cert" -keystore "$cacerts" \
            -storepass "$keystore_pass" -noprompt 2>/dev/null; then
            log "  Certificate imported successfully"
        else
            log_warn "  Failed to import certificate"
        fi
    done
    
    log "JRE trust stores configured"
}

configure_tomcat_root_redirect() {
    log_section "Configuring Tomcat Root Redirect to Portal"
    
    local tomcat_root="/opt/tomcat/webapps/ROOT"
    local portal_context="${WEB_ADAPTOR_PORTAL_CONTEXT:-portal}"
    
    if [[ ! -d "$tomcat_root" ]]; then
        log_warn "Tomcat ROOT webapp not found at $tomcat_root"
        return 0
    fi
    
    # Create a JSP that redirects to Portal
    cat > "${tomcat_root}/index.jsp" << 'REDIRECT_EOF'
<%@ page language="java" %>
<%
    response.sendRedirect("/portal");
%>
REDIRECT_EOF
    
    # Update redirect URL if using custom portal context
    if [[ "$portal_context" != "portal" ]]; then
        sed -i "s|/portal|/${portal_context}|g" "${tomcat_root}/index.jsp"
    fi
    
    chown tomcat:tomcat "${tomcat_root}/index.jsp"
    
    log "Root URL (https://${ARCGIS_FQDN}/) now redirects to /${portal_context}"
}

federate_server_with_portal() {
    log_section "Federating ArcGIS Server with Portal"
    
    local portal_context="${WEB_ADAPTOR_PORTAL_CONTEXT:-portal}"
    local server_context="${WEB_ADAPTOR_SERVER_CONTEXT:-server}"
    local portal_admin_url="https://${ARCGIS_FQDN}:7443/arcgis"
    local server_admin_url="https://${ARCGIS_FQDN}:6443/arcgis"
    local server_services_url="https://${ARCGIS_FQDN}/${server_context}"
    
    # Check if already federated
    log "Checking current federation status..."
    local portal_token
    portal_token=$(curl -sk -X POST "${portal_admin_url}/sharing/rest/generateToken" \
        -d "username=${ARCGIS_ADMIN_USER}" \
        -d "password=${ARCGIS_ADMIN_PASS}" \
        -d "client=referer" \
        -d "referer=https://${ARCGIS_FQDN}" \
        -d "f=json" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    
    if [[ -z "$portal_token" ]]; then
        log "ERROR: Failed to get Portal token for federation check"
        return 1
    fi
    
    local fed_status
    fed_status=$(curl -sk "${portal_admin_url}/portaladmin/federation/servers?token=${portal_token}&f=json")
    
    if echo "$fed_status" | grep -q "\"url\":\"${server_services_url}\""; then
        log "Server is already federated with Portal"
        return 0
    fi
    
    # Federate Server with Portal using REST API
    # Key parameters: Referer header and privatePortalUrl are required to avoid class cast exception
    log "Federating Server with Portal via REST API..."
    log "  Services URL: ${server_services_url}"
    log "  Admin URL: ${server_admin_url}"
    
    local fed_result
    fed_result=$(curl -sk -X POST "${portal_admin_url}/portaladmin/federation/servers/federate" \
        -H "Referer: https://${ARCGIS_FQDN}" \
        -d "url=${server_services_url}" \
        -d "adminUrl=${server_admin_url}" \
        -d "username=${ARCGIS_ADMIN_USER}" \
        -d "password=${ARCGIS_ADMIN_PASS}" \
        -d "privatePortalUrl=${portal_admin_url}" \
        -d "token=${portal_token}" \
        -d "f=json")
    
    # Check for errors
    if echo "$fed_result" | grep -q '"error"'; then
        local error_msg
        error_msg=$(echo "$fed_result" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
        log "ERROR: Federation failed: ${error_msg}"
        log "Full response: ${fed_result}"
        return 1
    fi
    
    # Verify federation succeeded
    sleep 5
    fed_status=$(curl -sk "${portal_admin_url}/portaladmin/federation/servers?token=${portal_token}&f=json")
    
    if echo "$fed_status" | grep -q "\"url\":\"${server_services_url}\""; then
        local server_id
        server_id=$(echo "$fed_status" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
        log "Federation successful! Server ID: ${server_id}"
        log "Server role: FEDERATED_SERVER"
    else
        log "WARNING: Federation may have failed. Check Portal > Organization > Settings > Servers"
        return 1
    fi
}

# =============================================================================
# ArcGIS Enterprise Builder Installation
# =============================================================================
extract_installer() {
    log_section "Extracting ArcGIS Enterprise Builder"
    
    local extract_dir="/opt/esri/builder"
    local setup_binary="${extract_dir}/EnterpriseBuilder/Setup"
    
    # Check if already extracted
    if [[ -f "$setup_binary" ]]; then
        log "Installer already extracted at: $extract_dir"
        return 0
    fi
    
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
    log_section "Phase 1: Installing ArcGIS Enterprise Builder Software"
    
    local builder_dir="/opt/esri/builder"
    local setup_binary="${builder_dir}/EnterpriseBuilder/Setup"
    
    # Check if already installed
    if [[ -f "${ARCGIS_INSTALL_DIR}/server/startserver.sh" ]]; then
        log "ArcGIS Enterprise software already installed at ${ARCGIS_INSTALL_DIR}"
        return 0
    fi
    
    if [[ ! -f "$setup_binary" ]]; then
        log_error "Setup binary not found at: $setup_binary"
        log "Contents of builder directory:"
        ls -laR "$builder_dir" | head -50
        exit 1
    fi
    
    chmod +x "$setup_binary"
    
    log "Running Enterprise Builder silent installation..."
    log "Install directory: $ARCGIS_INSTALL_DIR"
    log "Server license: $ARCGIS_SERVER_LICENSE"
    log "This may take 15-30 minutes..."
    
    # Run the silent installer as the arcgis user
    # Per Esri docs: ./Setup -m silent -l yes -s /path/to/server.prvc -d /install/path
    sudo -u "$ARCGIS_RUN_AS_USER" "$setup_binary" \
        -m silent \
        -l yes \
        -s "$ARCGIS_SERVER_LICENSE" \
        -d "$ARCGIS_INSTALL_DIR" \
        2>&1 | tee -a "$LOG_FILE"
    
    local install_exit_code=${PIPESTATUS[0]}
    
    if [[ $install_exit_code -ne 0 ]]; then
        log_error "Enterprise Builder installation failed with exit code: $install_exit_code"
        log "Check $LOG_FILE for details"
        exit 1
    fi
    
    log "Software installation completed successfully"
}

start_arcgis_services() {
    log_section "Starting ArcGIS Services"
    
    local server_start="${ARCGIS_INSTALL_DIR}/server/startserver.sh"
    local portal_start="${ARCGIS_INSTALL_DIR}/portal/startportal.sh"
    local datastore_start="${ARCGIS_INSTALL_DIR}/datastore/startdatastore.sh"
    
    # Start ArcGIS Server
    if [[ -f "$server_start" ]]; then
        log "Starting ArcGIS Server..."
        chmod +x "$server_start"
        sudo -u "$ARCGIS_RUN_AS_USER" "$server_start" 2>&1 | tee -a "$LOG_FILE" || true
    else
        log_warn "Server start script not found: $server_start"
    fi
    
    # Start Portal for ArcGIS
    if [[ -f "$portal_start" ]]; then
        log "Starting Portal for ArcGIS..."
        chmod +x "$portal_start"
        sudo -u "$ARCGIS_RUN_AS_USER" "$portal_start" 2>&1 | tee -a "$LOG_FILE" || true
    else
        log_warn "Portal start script not found: $portal_start"
    fi
    
    # Start ArcGIS Data Store
    if [[ -f "$datastore_start" ]]; then
        log "Starting ArcGIS Data Store..."
        chmod +x "$datastore_start"
        sudo -u "$ARCGIS_RUN_AS_USER" "$datastore_start" 2>&1 | tee -a "$LOG_FILE" || true
    else
        log_warn "Data Store start script not found: $datastore_start"
    fi
    
    # Wait for services to be ready
    # Note: Before configurebasedeployment runs, REST endpoints won't respond with currentVersion
    # So we just check that ports are listening
    log "Waiting for services to initialize..."
    sleep 30
    
    # Check Server port
    local max_wait=30
    local count=0
    while ! ss -tln 2>/dev/null | grep -q ":6443 "; do
        count=$((count + 1))
        if [[ $count -ge $max_wait ]]; then
            log_warn "ArcGIS Server port 6443 not listening after ${max_wait} attempts"
            break
        fi
        log "  Waiting for ArcGIS Server port 6443... ($count/$max_wait)"
        sleep 10
    done
    
    if ss -tln 2>/dev/null | grep -q ":6443 "; then
        log "ArcGIS Server is listening on port 6443"
    fi
    
    # Check Portal port
    count=0
    while ! ss -tln 2>/dev/null | grep -q ":7443 "; do
        count=$((count + 1))
        if [[ $count -ge $max_wait ]]; then
            log_warn "Portal for ArcGIS port 7443 not listening after ${max_wait} attempts"
            break
        fi
        log "  Waiting for Portal for ArcGIS port 7443... ($count/$max_wait)"
        sleep 10
    done
    
    if ss -tln 2>/dev/null | grep -q ":7443 "; then
        log "Portal for ArcGIS is listening on port 7443"
    fi
    
    log "ArcGIS services startup complete"
}

configure_base_deployment() {
    log_section "Phase 2: Configuring ArcGIS Enterprise Base Deployment"
    
    # Check if already configured by testing if Portal site exists
    local portal_check=$(curl -sk "https://${ARCGIS_FQDN}:7443/arcgis/portaladmin/healthCheck?f=json" 2>/dev/null)
    if echo "$portal_check" | grep -q '"status"'; then
        log "Base deployment already configured (Portal responding)"
        return 0
    fi
    
    # The configurebasedeployment tool is installed to the server tools directory
    local config_tool="${ARCGIS_INSTALL_DIR}/server/tools/configurebasedeployment/configurebasedeployment.sh"
    
    if [[ ! -f "$config_tool" ]]; then
        log_warn "configurebasedeployment.sh not found at expected location: $config_tool"
        log "Searching for configurebasedeployment..."
        config_tool=$(find "$ARCGIS_INSTALL_DIR" -name "configurebasedeployment.sh" -type f 2>/dev/null | head -1)
        if [[ -z "$config_tool" ]]; then
            log_error "Could not find configurebasedeployment.sh tool"
            log "You may need to run configuration manually via the browser at:"
            log "  https://${ARCGIS_FQDN}:6443/arcgis/enterprise"
            exit 1
        fi
        log "Found at: $config_tool"
    fi
    
    chmod +x "$config_tool"
    
    log "Configuring base deployment..."
    log "FQDN: $ARCGIS_FQDN"
    log "Admin user: $ARCGIS_ADMIN_USER"
    log "This may take 30-45 minutes..."
    
    # Per Esri docs, the configurebasedeployment tool parameters:
    # -fn: first name, -ln: last name, -u: username, -p: password, -e: email
    # -qi: question index (1-14), -qa: question answer
    # -ws: server web adaptor URL, -wp: portal web adaptor URL
    # -d: content directory, -lf: portal license file, -ut: user type (optional)
    
    local content_dir="${ARCGIS_INSTALL_DIR}/portal/usr/arcgisportal/content"
    local server_wa_url="https://${ARCGIS_FQDN}/${WEB_ADAPTOR_SERVER_CONTEXT}"
    local portal_wa_url="https://${ARCGIS_FQDN}/${WEB_ADAPTOR_PORTAL_CONTEXT}"
    
    # Ensure content directory exists
    mkdir -p "$content_dir"
    chown -R "$ARCGIS_RUN_AS_USER:$ARCGIS_RUN_AS_USER" "$content_dir"
    
    sudo -u "$ARCGIS_RUN_AS_USER" "$config_tool" \
        -fn "$ARCGIS_ADMIN_FIRSTNAME" \
        -ln "$ARCGIS_ADMIN_LASTNAME" \
        -u "$ARCGIS_ADMIN_USER" \
        -p "$ARCGIS_ADMIN_PASSWORD" \
        -e "$ARCGIS_ADMIN_EMAIL" \
        -qi "$ARCGIS_ADMIN_SECURITY_QUESTION_INDEX" \
        -qa "$ARCGIS_ADMIN_SECURITY_ANSWER" \
        -ws "$server_wa_url" \
        -wp "$portal_wa_url" \
        -d "$content_dir" \
        -lf "$ARCGIS_PORTAL_LICENSE" \
        2>&1 | tee -a "$LOG_FILE"
    
    local config_exit_code=${PIPESTATUS[0]}
    
    if [[ $config_exit_code -ne 0 ]]; then
        log_error "Base deployment configuration failed with exit code: $config_exit_code"
        log "Check $LOG_FILE for details"
        exit 1
    fi
    
    log "Base deployment configuration completed successfully"
}

# =============================================================================
# Post-Installation Configuration
# =============================================================================
wait_for_service() {
    local url="$1"
    local service_name="$2"
    local max_attempts="${3:-30}"
    local wait_seconds="${4:-10}"
    
    log "Waiting for $service_name to be ready..."
    
    for ((i=1; i<=max_attempts; i++)); do
        if curl -sk --connect-timeout 5 "$url" > /dev/null 2>&1; then
            log "  $service_name is ready"
            return 0
        fi
        log "  Attempt $i/$max_attempts - $service_name not ready yet, waiting ${wait_seconds}s..."
        sleep "$wait_seconds"
    done
    
    log_warn "$service_name did not become ready after $((max_attempts * wait_seconds)) seconds"
    return 1
}

import_ssl_certificate() {
    log_section "Importing SSL Certificate into ArcGIS Enterprise"
    
    local cert_file="/opt/esri/ssl/arcgis.pfx"
    local cert_password="${ARCGIS_ADMIN_PASSWORD}"
    
    if [[ ! -f "$cert_file" ]]; then
        log_warn "Certificate file not found: $cert_file"
        log_warn "SSL certificate import skipped. You may need to import manually."
        return 1
    fi
    
    # Wait for Portal to be ready (can take several minutes after config)
    local portal_admin_url="https://${ARCGIS_FQDN}:7443/arcgis/portaladmin"
    if ! wait_for_service "${portal_admin_url}/healthCheck?f=json" "Portal for ArcGIS" 30 10; then
        log_warn "Portal not responding. SSL certificate import will need to be done manually."
        return 1
    fi
    
    # Import certificate to Portal
    log "Importing certificate to Portal for ArcGIS..."
    
    # Generate token
    local token_response=$(curl -sk -X POST "${portal_admin_url}/generateToken" \
        -d "username=${ARCGIS_ADMIN_USER}" \
        -d "password=${ARCGIS_ADMIN_PASSWORD}" \
        -d "client=referer" \
        -d "referer=${portal_admin_url}" \
        -d "f=json" 2>/dev/null)
    
    local token=$(echo "$token_response" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    
    if [[ -n "$token" ]]; then
        # Import SSL certificate to Portal
        local import_response=$(curl -sk -X POST "${portal_admin_url}/machines/${ARCGIS_FQDN}/sslCertificates/importExistingServerCertificate" \
            -F "certFile=@${cert_file}" \
            -F "certPassword=${cert_password}" \
            -F "alias=${ARCGIS_FQDN}" \
            -F "token=${token}" \
            -F "f=json" 2>/dev/null)
        
        if echo "$import_response" | grep -q '"status":"success"\|"success":true'; then
            log "  Certificate imported to Portal successfully"
        else
            log_warn "  Portal certificate import response: $import_response"
        fi
        
        # Update Portal to use the new certificate
        curl -sk -X POST "${portal_admin_url}/machines/${ARCGIS_FQDN}/sslCertificates/update" \
            -d "webServerCertificateAlias=${ARCGIS_FQDN}" \
            -d "token=${token}" \
            -d "f=json" > /dev/null 2>&1
        
        log "Certificate configured for Portal"
    else
        log_warn "Could not get Portal token. Response: $token_response"
        log_warn "Manual certificate import may be required."
    fi
    
    # Wait for Server to be ready  
    local server_admin_url="https://${ARCGIS_FQDN}:6443/arcgis/admin"
    if ! wait_for_service "${server_admin_url}/healthCheck?f=json" "ArcGIS Server" 20 10; then
        log_warn "Server not responding. SSL certificate import will need to be done manually."
        return 1
    fi
    
    # Import certificate to Server
    log "Importing certificate to ArcGIS Server..."
    
    token_response=$(curl -sk -X POST "${server_admin_url}/generateToken" \
        -d "username=${ARCGIS_ADMIN_USER}" \
        -d "password=${ARCGIS_ADMIN_PASSWORD}" \
        -d "client=referer" \
        -d "referer=${server_admin_url}" \
        -d "f=json" 2>/dev/null)
    
    token=$(echo "$token_response" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    
    if [[ -n "$token" ]]; then
        # Import SSL certificate to Server
        local import_response=$(curl -sk -X POST "${server_admin_url}/machines/${ARCGIS_FQDN}/sslCertificates/importExistingServerCertificate" \
            -F "certFile=@${cert_file}" \
            -F "certPassword=${cert_password}" \
            -F "alias=${ARCGIS_FQDN}" \
            -F "token=${token}" \
            -F "f=json" 2>/dev/null)
        
        if echo "$import_response" | grep -q '"status":"success"\|"success":true'; then
            log "  Certificate imported to Server successfully"
        else
            log_warn "  Server certificate import response: $import_response"
        fi
        
        # Update Server to use the new certificate
        curl -sk -X POST "${server_admin_url}/machines/${ARCGIS_FQDN}/edit" \
            -d "webServerCertificateAlias=${ARCGIS_FQDN}" \
            -d "token=${token}" \
            -d "f=json" > /dev/null 2>&1
        
        log "Certificate configured for Server"
    else
        log_warn "Could not get Server token. Response: $token_response"
        log_warn "Manual certificate import may be required."
    fi
    
    log "SSL certificate import completed"
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
    
    # SSL Setup (before Tomcat so cert is ready)
    setup_ssl_certificate
    
    # Tomcat Installation and SSL Configuration
    check_and_free_ports
    install_tomcat
    configure_tomcat_ssl
    create_tomcat_service
    start_tomcat
    
    # ArcGIS Installation - Phase 1: Install software
    extract_installer
    run_enterprise_builder
    
    # Start ArcGIS services (required before Phase 2)
    start_arcgis_services
    
    # Web Adaptor Installation
    install_web_adaptor
    deploy_web_adaptor_wars
    
    # ArcGIS Installation - Phase 2: Configure base deployment
    # This requires ArcGIS services running and Web Adaptors to be reachable
    configure_base_deployment
    
    # Register Web Adaptors with ArcGIS components
    configure_web_adaptor_server
    configure_web_adaptor_portal
    
    # Configure WebContextURLs (required for proper routing)
    configure_web_context_urls
    
    # Configure Tomcat root redirect to Portal
    configure_tomcat_root_redirect
    
    # Post-installation
    import_ssl_certificate
    configure_jre_trust_stores
    configure_firewall
    
    # Verification
    verify_installation
    
    # Federate Server with Portal
    federate_server_with_portal
    
    print_summary
}

# Run main function
main "$@"
