#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# ArcGIS Enterprise 12.0 Linux Builder Bootstrap
# ==============================================================================
# This script uses the ArcGIS Enterprise Builder to install the base deployment
# components and then configures them using the 'createsite' utility.
#
# Prerequisite: The Builder installer tar.gz must be in /opt/esri/installers
# pattern: ArcGIS_Enterprise_Builder_Linux_*.tar.gz
# ==============================================================================

ESRI_BASE="/opt/esri"
INSTALLERS="$ESRI_BASE/installers"
ARCGIS_USER="arcgis"
ENV_FILE=".env"
TOMCAT_HOME="/opt/tomcat10"
TOMCAT_USER="tomcat"

# ---------- Usage & Helpers ----------
usage() {
  echo "Usage: sudo ./install_builder.sh [--wipe] [--yes]"
  exit 1
}

WIPE_EXISTING=0
WIPE_YES=0
for arg in "$@"; do
  case "$arg" in
    --wipe) WIPE_EXISTING=1 ;;
    --yes) WIPE_YES=1 ;;
    --help|-h) usage ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Must be run as root (sudo)."
  exit 1
fi

# ---------- Wipe Function ----------
wipe_existing_enterprise() {
  echo ""
  echo "!!! WIPE MODE ENABLED !!!"
  
  if (( WIPE_YES == 0 )); then
    read -rp "Type WIPE to confirm deletion of $ESRI_BASE/arcgis: " _confirm
    [[ "$_confirm" != "WIPE" ]] && echo "Cancelled." && exit 1
  fi

  echo "Stopping services..."
  systemctl stop arcgisportal arcgisserver arcgisdatastore tomcat10 2>/dev/null || true
  pkill -u "$ARCGIS_USER" 2>/dev/null || true

  echo "Removing installation directories..."
  rm -rf "$ESRI_BASE/arcgis" 2>/dev/null || true
  
  # Cleanup Tomcat deployments
  rm -rf "$TOMCAT_HOME/webapps/portal" "$TOMCAT_HOME/webapps/server" \
         "$TOMCAT_HOME/webapps/portal.war" "$TOMCAT_HOME/webapps/server.war" 2>/dev/null || true

  # Cleanup InstallAnywhere registry to prevent "phantom" installs
  # Previous installs (manual or Builder) leave .com.zerog.registry.xml in multiple locations.
  # If these are not removed, the Builder will skip components it thinks are "already installed".
  # Remove ArcGIS init.d / systemd service definitions.
  # CheckPreviousInstallation (InstallAnywhere custom action) inspects these to
  # determine if a prior install exists — even if /opt/esri/arcgis is gone.
  echo "Removing ArcGIS service definitions..."
  rm -f /etc/init.d/arcgisportal /etc/init.d/arcgisserver /etc/init.d/arcgisdatastore 2>/dev/null || true
  rm -f /etc/systemd/system/arcgisportal.service \
        /etc/systemd/system/arcgisserver.service \
        /etc/systemd/system/arcgisdatastore.service 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true

  # Remove all InstallAnywhere registry entries.
  # Search targeted directories rather than `find /` (avoids /proc /sys hangs).
  echo "Removing InstallAnywhere registry entries..."
  for _dir in /home /root /opt /var /tmp /etc; do
    find "$_dir" -name ".com.zerog.registry.xml" -delete 2>/dev/null || true
    find "$_dir" -name "com.zerog.iap.xml" -delete 2>/dev/null || true
  done

  # Also wipe any Esri user-level property files that record install state.
  rm -f /home/"$ARCGIS_USER"/.ESRI* /home/"$ARCGIS_USER"/.esri* 2>/dev/null || true

  echo "Wipe complete."
}

if (( WIPE_EXISTING == 1 )); then
  wipe_existing_enterprise
fi

# ---------- Configuration ----------
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

prompt_val() {
  local var="$1"; local msg="$2"; local def="${3:-}"
  if [[ -z "${!var:-}" ]]; then
    read -rp "$msg [$def]: " val
    export "$var"="${val:-$def}"
    echo "$var='${!var}'" >> "$ENV_FILE"
  fi
}

prompt_val DOMAIN "Domain (FQDN)" "gis.elevategeo.dev"
prompt_val EMAIL "Admin Email" "admin@elevategeo.dev"
prompt_val ADMIN_USER "Admin Username" "siteadmin"
prompt_val ADMIN_PASS "Admin Password" # secret
prompt_val ADMIN_FIRST "Admin First" "Site"
prompt_val ADMIN_LAST "Admin Last" "Admin"
prompt_val CF_API_TOKEN "Cloudflare API Token" 

mkdir -p "$ESRI_BASE/licenses"
PORTAL_LIC=$(find "$ESRI_BASE/licenses" -name "ArcGIS_Enterprise_Portal*.json" | head -1)
SERVER_LIC=$(find "$ESRI_BASE/licenses" -name "*.prvc" | head -1)

if [[ -z "$PORTAL_LIC" || -z "$SERVER_LIC" ]]; then
  echo "ERROR: Missing licenses in $ESRI_BASE/licenses"
  echo "DEBUG: Listing $ESRI_BASE/licenses:"
  ls -l "$ESRI_BASE/licenses" 2>/dev/null || echo "  (directory not found or empty)"
  exit 1
fi

echo "DEBUG: Found Portal License: $PORTAL_LIC"
echo "DEBUG: Found Server License: $SERVER_LIC"

# ==============================================================================
# Step 1: System Prep

# ==============================================================================
# Step 1: System Prep
# ==============================================================================
echo ">>> Step 1: System Preparation"

apt-get update -qq
apt-get install -y nginx certbot python3-certbot-dns-cloudflare tar unzip curl jq

# User
id -u "$ARCGIS_USER" &>/dev/null || useradd -m -s /bin/bash "$ARCGIS_USER"

# Limits (Esri required)
# nofile must be >= 65536 (not 65535) per ArcGIS Data Store DIAG029 check.
cat > /etc/security/limits.d/arcgis.conf <<EOF
$ARCGIS_USER soft nofile 65536
$ARCGIS_USER hard nofile 65536
$ARCGIS_USER soft nproc 25059
$ARCGIS_USER hard nproc 25059
EOF

# Apply to the running kernel immediately so that subprocesses spawned in this
# session (via sudo -u arcgis) also inherit the raised limit.
ulimit -Sn 65536
ulimit -Hn 65536

grep -q "vm.max_map_count" /etc/sysctl.conf || echo "vm.max_map_count=262144" >> /etc/sysctl.conf
sysctl -p >/dev/null 2>&1 || true

# Hosts: Ensure FQDN resolves to private IP
HOSTNAME=$(hostname)
HOST_IP=$(hostname -I | awk '{print $1}')
FQDN=$(hostname -f)
[[ "$FQDN" == "$HOSTNAME" && -n "$DOMAIN" ]] && FQDN="$DOMAIN"

sed -i "/$HOSTNAME/d" /etc/hosts
sed -i "/$FQDN/d" /etc/hosts
# Also remove any existing DOMAIN entry so we don't duplicate it
[[ -n "$DOMAIN" ]] && sed -i "/[[:space:]]${DOMAIN}\b/d" /etc/hosts
echo "127.0.0.1 localhost" >> /etc/hosts
echo "$HOST_IP $FQDN $HOSTNAME" >> /etc/hosts
# Ensure the public domain resolves locally so ArcGIS tools can reach native ports
[[ -n "$DOMAIN" && "$DOMAIN" != "$FQDN" ]] && echo "$HOST_IP $DOMAIN" >> /etc/hosts

# ==============================================================================
# Step 2: NGINX Setup
# ==============================================================================
# The ArcGIS Enterprise Builder does NOT require a Java Web Adaptor or Tomcat.
# NGINX proxies directly to the native ArcGIS services:
#   /portal/ -> Portal for ArcGIS (HTTPS :7443, context /arcgis/)
#   /server/ -> ArcGIS Server     (HTTPS :6443, context /arcgis/)
# NGINX terminates the public TLS cert; proxy_ssl_verify off accepts ArcGIS
# self-signed internal certs.
# ==============================================================================
echo ">>> Step 2: Web Server Setup (NGINX)"

cat > /etc/nginx/sites-available/arcgis <<NGINX_EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    client_max_body_size 2G;
    proxy_read_timeout   600s;
    proxy_connect_timeout 60s;

    # Common proxy headers for ArcGIS
    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_ssl_verify   off;
    proxy_ssl_session_reuse on;

    # Portal for ArcGIS: /portal/ -> https://localhost:7443/arcgis/
    location /portal/ {
        proxy_pass https://127.0.0.1:7443/arcgis/;
    }

    # ArcGIS Server: /server/ -> https://localhost:6443/arcgis/
    location /server/ {
        proxy_pass https://127.0.0.1:6443/arcgis/;
    }

    location / {
        return 302 /portal/home/;
    }
}
NGINX_EOF

ln -sf /etc/nginx/sites-available/arcgis /etc/nginx/sites-enabled/arcgis
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
echo "NGINX configured: https://$DOMAIN/portal -> :7443, https://$DOMAIN/server -> :6443"

# ==============================================================================
# Step 3: Install Builder
# ==============================================================================
echo ">>> Step 3: Running Enterprise Builder Installer"

BUILDER_TAR=$(find "$INSTALLERS" -name "ArcGIS_Enterprise_Builder_Linux_*.tar.gz" | head -1)
[[ -z "$BUILDER_TAR" ]] && echo "ERROR: Builder installer not found." && exit 1

EXTRACT_DIR="$ESRI_BASE/builder_extract"
if [[ ! -f "$EXTRACT_DIR/EnterpriseBuilder/Setup" ]]; then
  echo "Extracting $(basename "$BUILDER_TAR")..."
  mkdir -p "$EXTRACT_DIR"
  chown "$ARCGIS_USER:$ARCGIS_USER" "$EXTRACT_DIR"
  sudo -u "$ARCGIS_USER" tar -xzf "$BUILDER_TAR" -C "$EXTRACT_DIR"
fi

# Find the Setup script dynamically (handles varying extract folder names)
SETUP_SCRIPT=$(find "$EXTRACT_DIR" -maxdepth 3 -name "Setup" -type f | head -1)

if [[ -z "$SETUP_SCRIPT" ]]; then
  echo "ERROR: Could not find 'Setup' script in $EXTRACT_DIR"
  echo "Contents of $EXTRACT_DIR:"
  ls -R "$EXTRACT_DIR"
  exit 1
fi

echo "Found installer at: $SETUP_SCRIPT"

# Only run installer if components are missing or EMPTY
# Check specifically for a known binary (startserver.sh) to confirm successful install
if [[ ! -f "$ESRI_BASE/arcgis/server/startserver.sh" || ! -f "$ESRI_BASE/arcgis/portal/startportal.sh" || $WIPE_EXISTING -eq 1 ]]; then
  echo "Running Setup..."
  
  # Ensure strict permissions on the install dir before starting
  mkdir -p "$ESRI_BASE/arcgis"
  chown -R "$ARCGIS_USER:$ARCGIS_USER" "$ESRI_BASE/arcgis"
  
  # Note: Builder installs all components. Takes time.
  # Builder Setup does NOT support -a flag directly.
  # Use 'bash -c' to ensure correct environment (HOME, CWD) for the installer.
  echo "Invoking installer as $ARCGIS_USER (forcing clean env)..."
  # Explicitly raise the file-handle limit inside the subprocess so the ArcGIS
  # installer diagnostics (DIAG029) see >= 65536, regardless of PAM session state.
  sudo -u "$ARCGIS_USER" bash -c "ulimit -Sn 65536; ulimit -Hn 65536; cd ~; export HOME=~; \"$SETUP_SCRIPT\" -m silent -l yes -d \"$ESRI_BASE/arcgis\""
fi

echo "Post-install directory structure:"
ls "$ESRI_BASE/arcgis" 2>/dev/null

echo "Server directory contents:"
ls -la "$ESRI_BASE/arcgis/server" 2>/dev/null

# Read installer logs from the hidden .Setup directory
SETUP_LOG_DIR="$ESRI_BASE/arcgis/server/.Setup"
if [[ -d "$SETUP_LOG_DIR" ]]; then
  echo "--- Server installer logs ($SETUP_LOG_DIR) ---"
  ls -la "$SETUP_LOG_DIR"
  for f in "$SETUP_LOG_DIR"/*.log "$SETUP_LOG_DIR"/*.txt; do
    [[ -f "$f" ]] || continue
    echo "\n=== $(basename $f) ==="
    tail -80 "$f"
  done
fi

# Also check /tmp for any ia_ prefixed install logs (InstallAnywhere temp)
echo "--- Recent InstallAnywhere temp logs in /tmp ---"
find /tmp -name "ia_*" -newer "$SETUP_SCRIPT" 2>/dev/null | while read f; do
  echo "=== $f ==="; tail -30 "$f"; done || true

echo "Checking authorization status..."
# Check for authorizeSoftware tool in standard locations
# Enterprise Builder installs server to server/ and portal to portal/
AUTH_TOOL=$(find "$ESRI_BASE/arcgis" -name "authorizeSoftware" -type f 2>/dev/null | head -1)

if [[ -z "$AUTH_TOOL" ]]; then
  echo "WARNING: authorizeSoftware not found."
  echo "Installation of ArcGIS Server appears to have been silently skipped."
  echo "Cannot continue — Server component is not installed." >&2
  exit 1
else
  echo "Found authorization tool at: $AUTH_TOOL"
  # Check if already authorized, or force re-authorization
  if ! sudo -u "$ARCGIS_USER" "$AUTH_TOOL" -s | grep -q "Congratulations"; then
      echo "Applying license to ArcGIS Server..."
      # Create proper ecp registration file if needed, or just pass prvc
      sudo -u "$ARCGIS_USER" "$AUTH_TOOL" -f "$SERVER_LIC" -e "$EMAIL"
  else
      echo "ArcGIS Server is already authorized."
  fi
fi

ls -la "$ESRI_BASE/arcgis/server/tools" 2>/dev/null

# ==============================================================================
# Step 4: (Skipped - Web Adaptor not required with Enterprise Builder)
# ==============================================================================
# The ArcGIS Enterprise Builder does not ship a Java Web Adaptor (arcgis.war).
# NGINX proxies directly to the native ArcGIS ports configured in Step 2.
echo ">>> Step 4: Skipped (no Java Web Adaptor needed with Builder; NGINX proxies natively)"

# ==============================================================================
# Step 5: Configure Enterprise Deployment (configurebasedeployment)
# ==============================================================================
# The Enterprise Builder ships its own configuration tool:
#   server/tools/configurebasedeployment/configurebasedeployment.sh
# This is the correct tool for an Enterprise (Portal + Server + DataStore)
# deployment. It configures all components together in one pass.
# 'createsite.sh' is the standalone ArcGIS Server-only tool — not for use here.
# ==============================================================================
# ==============================================================================
# Pre-Step 5: Ensure all ArcGIS services are running before configuration
# ==============================================================================
# configurebasedeployment connects to Portal on :7443 and Server on :6443.
# The Builder installer starts Server automatically, but NOT Portal or DataStore.
# We must start them and wait until Portal's admin endpoint responds.
echo ">>> Pre-Step 5: Starting ArcGIS Services"

PORTAL_START="$ESRI_BASE/arcgis/portal/startportal.sh"
SERVER_START="$ESRI_BASE/arcgis/server/startserver.sh"
DS_START=$(find "$ESRI_BASE/arcgis/datastore" -name "startdatastore.sh" 2>/dev/null | head -1 || true)

[[ -f "$PORTAL_START" ]] && sudo -u "$ARCGIS_USER" "$PORTAL_START" || echo "Portal start script not found — skipping"
[[ -f "$SERVER_START" ]] && sudo -u "$ARCGIS_USER" "$SERVER_START" || echo "Server start script not found — skipping"
[[ -n "$DS_START" ]] && sudo -u "$ARCGIS_USER" "$DS_START" || echo "DataStore start script not found — skipping"

echo "Waiting for Portal to become available on :7443 (up to 5 min)..."
PORTAL_UP=0
for i in $(seq 1 30); do
  HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://localhost:7443/arcgis/portaladmin/" 2>/dev/null || true)
  if [[ "$HTTP_CODE" =~ ^[234] ]]; then
    echo "Portal is up (HTTP $HTTP_CODE)."
    PORTAL_UP=1
    break
  fi
  echo "  Portal not ready yet (HTTP ${HTTP_CODE:-none}), attempt $i/30 — sleeping 10s..."
  sleep 10
done

if [[ $PORTAL_UP -eq 0 ]]; then
  echo "ERROR: Portal did not become available within 5 minutes. Check /opt/esri/arcgis/portal/.Setup/ logs."
  exit 1
fi

echo "Waiting for Server to become available on :6443 (up to 3 min)..."
for i in $(seq 1 18); do
  HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://localhost:6443/arcgis/rest/info" 2>/dev/null || true)
  # 200/302 = fully up; 500 = process is up but site not yet created (normal pre-configure state)
  if [[ "$HTTP_CODE" =~ ^[2345] && "$HTTP_CODE" != "000" ]]; then
    echo "Server is up (HTTP $HTTP_CODE)."
    break
  fi
  echo "  Server not ready yet (HTTP ${HTTP_CODE:-none}), attempt $i/18 — sleeping 10s..."
  sleep 10
done

echo ">>> Step 5: Configuring Enterprise Deployment (configurebasedeployment)"

CONFIG_TOOL=$(find "$ESRI_BASE/arcgis" -name "configurebasedeployment.sh" 2>/dev/null | head -1 || true)
if [[ -z "$CONFIG_TOOL" ]]; then
  echo "ERROR: configurebasedeployment.sh not found under $ESRI_BASE/arcgis"
  echo "Available tools:"
  find "$ESRI_BASE/arcgis/server/tools" -maxdepth 3 2>/dev/null || true
  exit 1
fi
echo "Using configuration tool: $CONFIG_TOOL"

PROPS_FILE="$ESRI_BASE/configurebasedeployment.properties"
cat > "$PROPS_FILE" <<EOF
WEBGIS_ADMIN_FIRSTNAME=$ADMIN_FIRST
WEBGIS_ADMIN_LASTNAME=$ADMIN_LAST
WEBGIS_ADMIN_USERNAME=$ADMIN_USER
WEBGIS_ADMIN_PASSWORD=$ADMIN_PASS
WEBGIS_ADMIN_PASSWORD_ENCRYPTED=false
WEBGIS_ADMIN_EMAIL=$EMAIL
WEBGIS_ADMIN_SECURITY_QUESTION_INDEX=1
WEBGIS_ADMIN_SECURITY_QUESTION_ANSWER=Blue
WEBGIS_CONTENT_DIRECTORY=$ESRI_BASE/arcgis/usr/arcgisusr
PORTAL_LICENSE_FILE=$PORTAL_LIC
SERVER_LICENSE_FILE=$SERVER_LIC
DATA_STORE_TYPES=RELATIONAL
EOF
chown "$ARCGIS_USER:$ARCGIS_USER" "$PROPS_FILE"
chmod 600 "$PROPS_FILE"

echo "Running configurebasedeployment..."
sudo -u "$ARCGIS_USER" "$CONFIG_TOOL" -f "$PROPS_FILE"

echo "DONE."
