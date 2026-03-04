#!/bin/bash
# =============================================================================
# ArcGIS Enterprise SSL Certificate Renewal Hook
# =============================================================================
# This script is called automatically by certbot after successful renewal.
# It recreates the PKCS12 keystore and imports the new certificate into
# ArcGIS Portal and Server.
#
# Location: /opt/esri/scripts/ssl-renewal-hook.sh
# Called by: /etc/letsencrypt/renewal-hooks/deploy/arcgis-ssl-update.sh
# =============================================================================

set -euo pipefail

LOG_FILE="/var/log/arcgis-ssl-renewal.log"
CONFIG_DIR="/opt/esri/ssl"

# Logging function
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] $1" >> "$LOG_FILE"
}

log_error() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] ERROR: $1" >> "$LOG_FILE"
}

# Load configuration
load_config() {
    # Try to source the .env file from common locations
    local env_locations=(
        "/opt/esri/arcgis-bootstrap/.env"
        "/root/arcgis-enterprise-linux-bootstrap/.env"
        "/home/*/arcgis-enterprise-linux-bootstrap/.env"
    )
    
    for env_file in "${env_locations[@]}"; do
        # Handle glob expansion
        for expanded_file in $env_file; do
            if [[ -f "$expanded_file" ]]; then
                log "Loading configuration from: $expanded_file"
                set -a
                source "$expanded_file"
                set +a
                return 0
            fi
        done
    done
    
    # Fallback: try to read from saved config
    if [[ -f "${CONFIG_DIR}/renewal.conf" ]]; then
        log "Loading configuration from: ${CONFIG_DIR}/renewal.conf"
        source "${CONFIG_DIR}/renewal.conf"
        return 0
    fi
    
    log_error "Could not find configuration file"
    return 1
}

# Get the keystore password
get_keystore_password() {
    if [[ -f "${CONFIG_DIR}/.keystore_password" ]]; then
        cat "${CONFIG_DIR}/.keystore_password"
    else
        echo "${ARCGIS_ADMIN_PASSWORD:-}"
    fi
}

# Recreate the PKCS12 keystore from renewed certificates
recreate_keystore() {
    log "Recreating PKCS12 keystore..."
    
    local cert_dir="/etc/letsencrypt/live/${ARCGIS_FQDN}"
    local keystore_file="${CONFIG_DIR}/arcgis.pfx"
    local keystore_password=$(get_keystore_password)
    
    if [[ -z "$keystore_password" ]]; then
        log_error "Keystore password not found"
        return 1
    fi
    
    # Backup existing keystore
    if [[ -f "$keystore_file" ]]; then
        cp "$keystore_file" "${keystore_file}.backup.$(date +%Y%m%d%H%M%S)"
    fi
    
    # Create new PKCS12 file
    openssl pkcs12 -export \
        -in "${cert_dir}/fullchain.pem" \
        -inkey "${cert_dir}/privkey.pem" \
        -out "$keystore_file" \
        -name "$ARCGIS_FQDN" \
        -password "pass:${keystore_password}"
    
    # Set permissions
    chmod 640 "$keystore_file"
    chown "${ARCGIS_RUN_AS_USER:-arcgis}:${ARCGIS_RUN_AS_USER:-arcgis}" "$keystore_file"
    
    log "PKCS12 keystore recreated successfully"
}

# Import certificate into Portal for ArcGIS
import_to_portal() {
    log "Importing certificate to Portal for ArcGIS..."
    
    local portal_admin_url="https://${ARCGIS_FQDN}:7443/arcgis/portaladmin"
    local cert_file="${CONFIG_DIR}/arcgis.pfx"
    local cert_password=$(get_keystore_password)
    
    # Get admin credentials
    local admin_user="${ARCGIS_ADMIN_USER:-admin}"
    local admin_pass="${ARCGIS_ADMIN_PASSWORD:-}"
    
    if [[ -z "$admin_pass" ]]; then
        admin_pass="$cert_password"
    fi
    
    # Generate token
    local token_response=$(curl -sk -X POST "${portal_admin_url}/generateToken" \
        -d "username=${admin_user}" \
        -d "password=${admin_pass}" \
        -d "client=referer" \
        -d "referer=${portal_admin_url}" \
        -d "expiration=10" \
        -d "f=json" 2>/dev/null)
    
    local token=$(echo "$token_response" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    
    if [[ -z "$token" ]]; then
        log_error "Failed to get Portal admin token"
        return 1
    fi
    
    # Delete existing certificate if it exists (to avoid alias conflict)
    curl -sk -X POST "${portal_admin_url}/machines/${ARCGIS_FQDN}/sslCertificates/${ARCGIS_FQDN}/delete" \
        -d "token=${token}" \
        -d "f=json" 2>/dev/null || true
    
    # Import new certificate
    local import_response=$(curl -sk -X POST \
        "${portal_admin_url}/machines/${ARCGIS_FQDN}/sslCertificates/importExistingServerCertificate" \
        -F "certFile=@${cert_file}" \
        -F "certPassword=${cert_password}" \
        -F "alias=${ARCGIS_FQDN}" \
        -F "token=${token}" \
        -F "f=json" 2>/dev/null)
    
    if echo "$import_response" | grep -q '"status":"success"'; then
        log "Certificate imported to Portal successfully"
    else
        log_error "Portal certificate import response: $import_response"
    fi
    
    # Update Portal to use the certificate
    curl -sk -X POST "${portal_admin_url}/security/sslCertificates/update" \
        -d "webServerCertificateAlias=${ARCGIS_FQDN}" \
        -d "token=${token}" \
        -d "f=json" 2>/dev/null
    
    log "Portal SSL configuration updated"
}

# Import certificate into ArcGIS Server
import_to_server() {
    log "Importing certificate to ArcGIS Server..."
    
    local server_admin_url="https://${ARCGIS_FQDN}:6443/arcgis/admin"
    local cert_file="${CONFIG_DIR}/arcgis.pfx"
    local cert_password=$(get_keystore_password)
    
    # Get admin credentials
    local admin_user="${ARCGIS_ADMIN_USER:-admin}"
    local admin_pass="${ARCGIS_ADMIN_PASSWORD:-}"
    
    if [[ -z "$admin_pass" ]]; then
        admin_pass="$cert_password"
    fi
    
    # Generate token
    local token_response=$(curl -sk -X POST "${server_admin_url}/generateToken" \
        -d "username=${admin_user}" \
        -d "password=${admin_pass}" \
        -d "client=referer" \
        -d "referer=${server_admin_url}" \
        -d "expiration=10" \
        -d "f=json" 2>/dev/null)
    
    local token=$(echo "$token_response" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    
    if [[ -z "$token" ]]; then
        log_error "Failed to get Server admin token"
        return 1
    fi
    
    # Delete existing certificate if it exists
    curl -sk -X POST "${server_admin_url}/machines/${ARCGIS_FQDN}/sslCertificates/${ARCGIS_FQDN}/delete" \
        -d "token=${token}" \
        -d "f=json" 2>/dev/null || true
    
    # Import new certificate
    local import_response=$(curl -sk -X POST \
        "${server_admin_url}/machines/${ARCGIS_FQDN}/sslCertificates/importExistingServerCertificate" \
        -F "certFile=@${cert_file}" \
        -F "certPassword=${cert_password}" \
        -F "alias=${ARCGIS_FQDN}" \
        -F "token=${token}" \
        -F "f=json" 2>/dev/null)
    
    if echo "$import_response" | grep -q '"status":"success"'; then
        log "Certificate imported to Server successfully"
    else
        log_error "Server certificate import response: $import_response"
    fi
    
    # Update Server machine to use the new certificate
    curl -sk -X POST "${server_admin_url}/machines/${ARCGIS_FQDN}/edit" \
        -d "webServerCertificateAlias=${ARCGIS_FQDN}" \
        -d "token=${token}" \
        -d "f=json" 2>/dev/null
    
    log "Server SSL configuration updated"
}

# Restart ArcGIS services if needed
restart_services_if_needed() {
    log "Checking if services need restart..."
    
    # For most cert updates, ArcGIS should pick up the new cert without restart
    # But if there are issues, uncomment the following:
    
    # local arcgis_home="${ARCGIS_INSTALL_DIR:-/opt/esri/arcgis}"
    # 
    # if [[ -f "${arcgis_home}/portal/tools/stopportal.sh" ]]; then
    #     log "Restarting Portal..."
    #     sudo -u "${ARCGIS_RUN_AS_USER:-arcgis}" "${arcgis_home}/portal/tools/stopportal.sh"
    #     sleep 5
    #     sudo -u "${ARCGIS_RUN_AS_USER:-arcgis}" "${arcgis_home}/portal/tools/startportal.sh"
    # fi
    # 
    # if [[ -f "${arcgis_home}/server/tools/stopserver.sh" ]]; then
    #     log "Restarting Server..."
    #     sudo -u "${ARCGIS_RUN_AS_USER:-arcgis}" "${arcgis_home}/server/tools/stopserver.sh"
    #     sleep 5
    #     sudo -u "${ARCGIS_RUN_AS_USER:-arcgis}" "${arcgis_home}/server/tools/startserver.sh"
    # fi
    
    log "Services do not need restart - certificate is updated via Admin API"
}

# Main execution
main() {
    log "========================================="
    log "SSL Certificate Renewal Hook Started"
    log "========================================="
    
    # Load configuration
    if ! load_config; then
        log_error "Failed to load configuration, exiting"
        exit 1
    fi
    
    # Recreate keystore
    if ! recreate_keystore; then
        log_error "Failed to recreate keystore"
        exit 1
    fi
    
    # Wait a moment for keystore to be written
    sleep 2
    
    # Import to Portal
    import_to_portal || log_error "Portal import had issues"
    
    # Import to Server
    import_to_server || log_error "Server import had issues"
    
    # Check if restart needed
    restart_services_if_needed
    
    log "SSL Certificate Renewal Hook Completed"
    log "========================================="
}

# Run main
main "$@"
