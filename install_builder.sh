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
  echo "Usage: sudo ./install_builder.sh [--wipe] [--reset-sites] [--yes] [--steps STEP[,STEP...]]"
  echo "  --wipe        Remove all ArcGIS software and reinstall from scratch"
  echo "  --reset-sites Reset Portal/Server/DataStore sites (keeps software, re-runs site creation)"
  echo "  --yes         Skip confirmation prompts"
  echo "  --steps       Run only specified steps: 1 2 3 4 pre5 5a 5b 5c 5d 5e 5f 5g"
  echo "  Example: sudo ./install_builder.sh --reset-sites --steps 5a,5b,5c"
  exit 1
}

WIPE_EXISTING=0
RESET_SITES=0
WIPE_YES=0
RUN_STEPS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wipe)        WIPE_EXISTING=1 ;;
    --reset-sites) RESET_SITES=1 ;;
    --yes)         WIPE_YES=1 ;;
    --steps)       IFS=',' read -ra RUN_STEPS <<< "${2:-}"; shift ;;
    --steps=*)     IFS=',' read -ra RUN_STEPS <<< "${1#--steps=}" ;;
    --help|-h)     usage ;;
  esac
  shift
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

  # Wipe Portal/Server/DataStore user-level state that persists outside the
  # install directory. Portal in particular stores its init state & content
  # store pointers under the arcgis user's home; if these survive, Portal
  # considers itself already configured after a fresh reinstall.
  rm -rf /home/"$ARCGIS_USER"/.arcgis* 2>/dev/null || true
  rm -rf /home/"$ARCGIS_USER"/arcgis* 2>/dev/null || true
  rm -rf /home/"$ARCGIS_USER"/.com.esri* 2>/dev/null || true

  echo "Wipe complete."
}

if (( WIPE_EXISTING == 1 )); then
  wipe_existing_enterprise
fi

# ---------- Reset Sites Function ----------
# Resets Portal/Server/DataStore site configuration WITHOUT reinstalling software.
# Use when sites are corrupted or need to be recreated with different credentials.
reset_arcgis_sites() {
  echo ""
  echo "!!! RESET SITES MODE !!!"
  echo "This will delete Portal, Server, and DataStore site configurations."
  echo "Software will NOT be reinstalled, but sites must be recreated (steps 5a-5g)."
  
  if (( WIPE_YES == 0 )); then
    read -rp "Type RESET to confirm: " _confirm
    [[ "$_confirm" != "RESET" ]] && echo "Cancelled." && exit 1
  fi

  echo "Stopping ArcGIS services..."
  systemctl stop arcgisportal arcgisserver arcgisdatastore 2>/dev/null || true
  # Give processes time to terminate gracefully
  sleep 5
  
  # Kill Portal's internal PostgreSQL explicitly
  echo "Stopping Portal PostgreSQL processes..."
  pkill -9 -f "arcgisportal.*postgres" 2>/dev/null || true
  pkill -9 -f "postgres.*arcgisportal" 2>/dev/null || true
  sleep 2
  
  # Force kill any remaining ArcGIS processes
  pkill -9 -u "$ARCGIS_USER" 2>/dev/null || true
  sleep 3

  echo "Resetting Portal site (clearing entire usr/arcgisportal)..."
  # Portal stores ALL site state in usr/arcgisportal/ - clear everything
  # This includes: db/ (PostgreSQL), content/, etc/, index/, security/, logs/
  rm -rf "$ESRI_BASE/arcgis/portal/usr/arcgisportal" 2>/dev/null || true
  # Recreate the directory structure that Portal expects
  mkdir -p "$ESRI_BASE/arcgis/portal/usr/arcgisportal"
  chown -R "$ARCGIS_USER":"$ARCGIS_USER" "$ESRI_BASE/arcgis/portal/usr/arcgisportal"
  
  # Remove user-level Portal state from home directory
  rm -rf /home/"$ARCGIS_USER"/.arcgis* 2>/dev/null || true
  rm -rf /home/"$ARCGIS_USER"/.com.esri* 2>/dev/null || true
  rm -rf /home/"$ARCGIS_USER"/.ESRI* 2>/dev/null || true
  rm -rf /home/"$ARCGIS_USER"/arcgis* 2>/dev/null || true

  echo "Resetting Server site..."
  # Server stores site config in usr/ subdirectories
  rm -rf "$ESRI_BASE/arcgis/server/usr/config-store" 2>/dev/null || true
  rm -rf "$ESRI_BASE/arcgis/server/usr/directories" 2>/dev/null || true
  rm -rf "$ESRI_BASE/arcgis/server/usr/arcgisserver" 2>/dev/null || true
  mkdir -p "$ESRI_BASE/arcgis/server/usr"
  chown -R "$ARCGIS_USER":"$ARCGIS_USER" "$ESRI_BASE/arcgis/server/usr"

  echo "Resetting DataStore..."
  rm -rf "$ESRI_BASE/arcgis/datastore/usr/arcgisdatastore" 2>/dev/null || true
  mkdir -p "$ESRI_BASE/arcgis/datastore/usr"
  chown -R "$ARCGIS_USER":"$ARCGIS_USER" "$ESRI_BASE/arcgis/datastore/usr"

  # Clean up the shared content directory
  rm -rf "$ESRI_BASE/arcgis/usr" 2>/dev/null || true
  mkdir -p "$ESRI_BASE/arcgis/usr/arcgisusr"
  chown -R "$ARCGIS_USER":"$ARCGIS_USER" "$ESRI_BASE/arcgis/usr"

  echo "Starting Portal service (may take up to 2 minutes for first start)..."
  systemctl start arcgisportal 2>/dev/null || true
  
  # Wait for Portal to start and verify it's truly uninitialized
  echo "Waiting for Portal to start and verifying reset..."
  _RESET_OK=0
  for _rv in $(seq 1 24); do  # 4 minutes max
    sleep 10
    _RESP=$(curl -sk "https://localhost:7443/arcgis/portaladmin/?f=json" 2>/dev/null || true)
    if echo "$_RESP" | grep -q '"status":"error"'; then
      if echo "$_RESP" | grep -qi 'not been initialized\|create a new site'; then
        echo "  Portal is uninitialized (reset successful)."
        _RESET_OK=1
        break
      fi
    fi
    echo "  Waiting for Portal to report uninitialized state ($_rv/24)..."
  done
  
  if [[ $_RESET_OK -eq 0 ]]; then
    echo "WARNING: Could not verify Portal reset. Response: ${_RESP:0:200}"
  fi
  
  systemctl start arcgisserver 2>/dev/null || true
  # Don't start DataStore yet - it needs Server to be configured first

  echo "Reset complete. Run steps 5a-5g to recreate sites."
}

if (( RESET_SITES == 1 )); then
  reset_arcgis_sites
fi

# ---------- Step selector ----------
# If --steps is provided, only the named steps run; otherwise all steps run.
# "pre5" (service stop/start/wait) auto-runs whenever any 5x step is selected.
step_enabled() {
  local step="$1"
  [[ ${#RUN_STEPS[@]} -eq 0 ]] && return 0         # no filter → run all
  if [[ "$step" == "pre5" ]]; then
    for s in "${RUN_STEPS[@]}"; do [[ "$s" == 5* ]] && return 0; done
    return 1
  fi
  for s in "${RUN_STEPS[@]}"; do [[ "$s" == "$step" ]] && return 0; done
  return 1
}

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
if step_enabled "1"; then
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
fi # end step 1

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
if step_enabled "2"; then
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
        proxy_set_header X-Forwarded-Host  \$host;
        proxy_set_header X-Forwarded-Port  443;
        # Rewrite Location headers from the internal address back to the public path
        proxy_redirect https://127.0.0.1:7443/arcgis/ /portal/;
        proxy_redirect https://127.0.0.1:7443/        /portal/;
    }

    # ArcGIS Server: /server/ -> https://localhost:6443/arcgis/
    location /server/ {
        proxy_pass https://127.0.0.1:6443/arcgis/;
        proxy_set_header X-Forwarded-Host  \$host;
        proxy_set_header X-Forwarded-Port  443;
        proxy_redirect https://127.0.0.1:6443/arcgis/ /server/;
        proxy_redirect https://127.0.0.1:6443/        /server/;
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
fi # end step 2

# ==============================================================================
# Step 3: Install Builder
# ==============================================================================
if step_enabled "3"; then
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
  # Pass -a to authorize Server during installation (avoids "NO_AUTH_FILE_SUPPLIED" in log).
  # Use 'bash -c' to ensure correct environment (HOME, CWD) for the installer.
  echo "Invoking installer as $ARCGIS_USER (forcing clean env)..."
  # Explicitly raise the file-handle limit inside the subprocess so the ArcGIS
  # installer diagnostics (DIAG029) see >= 65536, regardless of PAM session state.
  sudo -u "$ARCGIS_USER" bash -c "ulimit -Sn 65536; ulimit -Hn 65536; cd ~; export HOME=~; \"$SETUP_SCRIPT\" -m silent -l yes -d \"$ESRI_BASE/arcgis\" -s \"$SERVER_LIC\""
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
fi # end step 3

# ==============================================================================
# Step 4: (Skipped - Web Adaptor not required with Enterprise Builder)
# ==============================================================================
# The ArcGIS Enterprise Builder does not ship a Java Web Adaptor (arcgis.war).
# NGINX proxies directly to the native ArcGIS ports configured in Step 2.
if step_enabled "4"; then
echo ">>> Step 4: Skipped (no Java Web Adaptor needed with Builder; NGINX proxies natively)"
fi # end step 4

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
if step_enabled "pre5"; then
echo ">>> Pre-Step 5: Starting ArcGIS Services"

PORTAL_START="$ESRI_BASE/arcgis/portal/startportal.sh"
PORTAL_STOP="$ESRI_BASE/arcgis/portal/stopportal.sh"
SERVER_START="$ESRI_BASE/arcgis/server/startserver.sh"
SERVER_STOP="$ESRI_BASE/arcgis/server/stopserver.sh"
DS_START=$(find "$ESRI_BASE/arcgis/datastore" -name "startdatastore.sh" 2>/dev/null | head -1 || true)
DS_STOP=$(find "$ESRI_BASE/arcgis/datastore" -name "stopdatastore.sh" 2>/dev/null | head -1 || true)

# Start only services that are not already responding — independently.
# Checking them as a group means one downed service (e.g. Server left stopped by a
# prior failed step 5e) triggers a full restart including a healthy Portal.
_PORTAL_HTTP=$(curl -sk -o /dev/null -w '%{http_code}' "https://localhost:7443/arcgis/portaladmin/" 2>/dev/null || true)
_SERVER_HTTP=$(curl -sk -o /dev/null -w '%{http_code}' "https://localhost:6443/arcgis/rest/info" 2>/dev/null || true)

if [[ "$_PORTAL_HTTP" =~ ^[234] ]]; then
  echo "Portal already running (HTTP $_PORTAL_HTTP) — skipping Portal start."
else
  echo "Starting Portal for ArcGIS..."
  [[ -f "$PORTAL_START" ]] && sudo -u "$ARCGIS_USER" "$PORTAL_START" || echo "Portal start script not found — skipping"
fi

if [[ "$_SERVER_HTTP" == "200" || "$_SERVER_HTTP" == "302" ]]; then
  echo "Server already running (HTTP $_SERVER_HTTP) — skipping Server start."
else
  # HTTP 500 means the process is running but REST services failed to load.
  # The most common cause: security-config.json was deleted by a previous failed step 5e run.
  # If a .bak copy exists (written by step 5e before it deleted the original), restore it now
  # so the server can start successfully. Step 5e will then patch + restart as normal.
  _SEC_BAK_PRE=$(find "$ESRI_BASE/arcgis" \
    -name "security-config.json.bak" -path "*/config-store/security/*" 2>/dev/null \
    | head -1 || true)
  [[ -z "$_SEC_BAK_PRE" ]] && _SEC_BAK_PRE=$(find "$ESRI_BASE/arcgis" \
    -name "security-config.json.bak" 2>/dev/null | head -1 || true)
  if [[ -n "$_SEC_BAK_PRE" ]]; then
    _SEC_MAIN_PRE="${_SEC_BAK_PRE%.bak}"
    if [[ ! -f "$_SEC_MAIN_PRE" ]]; then
      echo "  Restoring missing security-config.json from backup before Server start..."
      cp -p "$_SEC_BAK_PRE" "$_SEC_MAIN_PRE" 2>/dev/null || true
      # Fix ownership — backup was created as root; ArcGIS Server runs as arcgis.
      # A root-owned config file will cause startup failures (HTTP 500) because the
      # server process cannot write locks or updates to a file owned by root.
      chown "$ARCGIS_USER:$ARCGIS_USER" "$_SEC_MAIN_PRE" 2>/dev/null || true
      chmod 600 "$_SEC_MAIN_PRE" 2>/dev/null || true
    fi
  fi
  # Stop first to kill any stale processes; startserver.sh refuses to start otherwise.
  echo "Server not healthy (HTTP ${_SERVER_HTTP:-000}) — stopping any stale processes before starting..."
  [[ -f "$SERVER_STOP" ]] && sudo -u "$ARCGIS_USER" "$SERVER_STOP" >/dev/null 2>&1 || true
  sleep 5
  echo "Starting ArcGIS Server..."
  [[ -f "$SERVER_START" ]] && sudo -u "$ARCGIS_USER" "$SERVER_START" || echo "Server start script not found — skipping"
fi

_DS_HTTP=$(curl -sk -o /dev/null -w '%{http_code}' "https://localhost:2443/arcgis/datastoreadmin" 2>/dev/null || true)
if [[ "$_DS_HTTP" =~ ^[234] ]]; then
  echo "DataStore already running (HTTP $_DS_HTTP) — skipping DataStore start."
else
  echo "Starting ArcGIS Data Store..."
  [[ -n "$DS_START" ]] && sudo -u "$ARCGIS_USER" "$DS_START" || echo "DataStore start script not found — skipping"
fi

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

  echo "Waiting for Server to become available on :6443 (up to 5 min)..."
_SERVER_WAIT_UP=0
for i in $(seq 1 30); do
  HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://localhost:6443/arcgis/rest/info" 2>/dev/null || true)
  # Accept any response that is not 000 (connection refused / process not running yet).
  # HTTP 500 is normal before site creation on a fresh install (step 5c creates the site).
  # HTTP 500 caused by a broken security-config is handled and recovered inside step 5e.
  if [[ -n "$HTTP_CODE" && "$HTTP_CODE" != "000" ]]; then
    echo "Server is up (HTTP $HTTP_CODE)."
    _SERVER_WAIT_UP=1
    break
  fi
  echo "  Server not ready yet (HTTP ${HTTP_CODE:-none}), attempt $i/30 — sleeping 10s..."
  sleep 10
done
if [[ $_SERVER_WAIT_UP -eq 0 ]]; then
  echo "ERROR: Server process did not respond within 5 minutes."
  echo "  Check logs at: $ESRI_BASE/arcgis/usr/arcgisusr/arcgisserver/logs/"
  exit 1
fi
fi # end pre-step 5

# ==============================================================================
# Step 5: Configure Enterprise via REST APIs
# ==============================================================================
# configurebasedeployment.sh requires a true ArcGIS Web Adaptor (Java EE WAR)
# for its web adaptor validation handshake. NGINX as a plain reverse proxy
# cannot satisfy that internal handshake and the tool always fails at the
# "register the Portal with the Web Adaptor" step.
#
# Instead we drive the full configuration via the ArcGIS REST Admin APIs:
#   5a  Create Portal site (portaladmin/createNewSite)
#   5b  Apply Portal license (portaladmin/license/importLicense)
#   5c  Create ArcGIS Server site (createsite.sh)
#   5d  Configure ArcGIS Data Store — relational (configuredatastore.sh)
#   5e  Federate ArcGIS Server with Portal (portaladmin/federation/servers/register)
#   5f  Register NGINX as Portal web adaptor (portaladmin/system/webadaptors/register)
#   5g  Register NGINX as Server web adaptor (admin/system/webadaptors/register)
# ==============================================================================

CURL_ADM=(curl -sk --noproxy '*' --connect-timeout 10 --max-time 90)

# ---------- Token helpers ----------
# Portal tokens can be generated via:
#   1. /sharing/rest/generateToken (primary user-facing endpoint)
#   2. /portaladmin/generateToken (admin endpoint, works during startup)
#
# Per Esri's Chef cookbook, use client=referer with referer='referer' (literal string).
# Always returns 0; callers check for empty string.
_portal_token() {
  local resp tok
  local _ep _token_host
  # Try multiple host variations
  for _token_host in "localhost:7443" "$DOMAIN:7443" "${DOMAIN^^}:7443" "${DOMAIN,,}:7443"; do
    # Try both endpoints - portaladmin first (often works during startup when sharing/rest doesn't)
    for _ep in "portaladmin/generateToken" "sharing/rest/generateToken"; do
      # Per Esri cookbook: use literal 'referer' as the referer value
      resp=$("${CURL_ADM[@]}" --post301 --post302 -L -X POST \
        "https://${_token_host}/arcgis/${_ep}" \
        -H "Referer: referer" \
        --data-urlencode "username=$ADMIN_USER" \
        --data-urlencode "password=$ADMIN_PASS" \
        -d "client=referer" -d "referer=referer" \
        -d "expiration=600" -d "f=json" \
        2>/dev/null || true)
      tok=$(echo "$resp" | jq -r '.token // empty' 2>/dev/null || true)
      if [[ -n "$tok" ]]; then echo "$tok"; return 0; fi
    done
  done
  echo "  [_portal_token] All generateToken attempts failed. Last response: $resp" >&2
  echo ""
  return 0   # callers check for empty string, not exit code
}

# ---------------------------------------------------------------------------
# Check if Portal site exists (per Esri cookbook logic)
# Returns 0 (true) if site exists (error.code == 499), 1 (false) otherwise
# ---------------------------------------------------------------------------
_portal_site_exists() {
  local resp code status
  resp=$("${CURL_ADM[@]}" "https://localhost:7443/arcgis/portaladmin/?f=json" 2>/dev/null || true)
  
  # Check for error.code == 499 (Token Required) - this means site IS initialized
  code=$(echo "$resp" | jq -r '.error.code // empty' 2>/dev/null || true)
  if [[ "$code" == "499" ]]; then
    echo "  [site_exists] Portal site exists (error.code=499, token required)" >&2
    return 0
  fi
  
  # Check status field - if "error" with "not initialized" message, site doesn't exist
  status=$(echo "$resp" | jq -r '.status // empty' 2>/dev/null || true)
  if [[ "$status" == "error" ]]; then
    echo "  [site_exists] Portal site does NOT exist (status=error)" >&2
    echo "  [site_exists] Response: ${resp:0:200}" >&2
    return 1
  fi
  
  # If we get a valid response without error, site exists
  if echo "$resp" | jq -e '.version' >/dev/null 2>&1; then
    echo "  [site_exists] Portal site exists (got version info)" >&2
    return 0
  fi
  
  echo "  [site_exists] Unknown state. Response: ${resp:0:200}" >&2
  return 1
}

_server_token() {
  local resp tok
  resp=$("${CURL_ADM[@]}" --post301 --post302 -L -X POST \
    "https://localhost:6443/arcgis/admin/generateToken" \
    -H "Referer: https://localhost:6443/arcgis/admin" \
    --data-urlencode "username=$ADMIN_USER" \
    --data-urlencode "password=$ADMIN_PASS" \
    -d "client=referer" -d "referer=https://localhost:6443/arcgis/admin" \
    -d "expiration=120" -d "f=json" \
    2>/dev/null || true)
  tok=$(echo "$resp" | jq -r '.token // empty' 2>/dev/null || true)
  if [[ -n "$tok" ]]; then echo "$tok"; return 0; fi
  echo "  [_server_token] generateToken response: $resp" >&2
  echo ""
  return 0   # always return 0 — callers check for empty string
}

# Polls until Portal sharing/rest/generateToken returns a token, up to max_tries*10s.
# Prints the token on stdout on success; exits with error if never ready.
_wait_portal_token() {
  local max_tries="${1:-72}"  # 72 × 10s = 12 min
  local tok
  for i in $(seq 1 "$max_tries"); do
    tok=$(_portal_token)
    if [[ -n "$tok" ]]; then echo "$tok"; return 0; fi
    echo "    Waiting for Portal to accept tokens (attempt $i/$max_tries)..."
    sleep 10
  done
  return 1
}

# ---------- Step 5a: Create Portal site ----------
if step_enabled "5a"; then
echo ">>> Step 5a: Creating Portal site..."

# Per Esri's Chef cookbook, the correct flow is:
#   1. Check if site exists via /portaladmin/?f=json (error.code 499 = exists)
#   2. If site exists, get token
#   3. If site doesn't exist, call createNewSite
#   4. Wait for site to fully initialize (site_exists returns true)
#   5. Then get token
PTOKEN=""

# First, check if Portal's admin endpoint is reachable at all
echo "  Waiting for Portal admin endpoint to be reachable..."
_PORTAL_UP=0
for _pu in $(seq 1 60); do
  _PCHECK=$("${CURL_ADM[@]}" "https://localhost:7443/arcgis/portaladmin/?f=json" 2>/dev/null || true)
  if [[ -n "$_PCHECK" ]] && echo "$_PCHECK" | grep -q '{'; then
    _PORTAL_UP=1
    echo "  Portal admin endpoint is reachable."
    break
  fi
  echo "    Portal not reachable yet (attempt $_pu/60) — sleeping 10s..."
  sleep 10
done

if [[ $_PORTAL_UP -eq 0 ]]; then
  echo "ERROR: Portal admin endpoint never became reachable within 10 minutes." >&2
  echo "  Check if Portal service is running: systemctl status arcgisportal" >&2
  exit 1
fi

# Check if site already exists (per Esri cookbook: error.code 499 means site exists)
echo "  Checking if Portal site already exists..."
if _portal_site_exists; then
  echo "  Portal site already exists. Attempting to get token..."
  PTOKEN=$(_portal_token 2>/dev/null) || PTOKEN=""
  if [[ -n "$PTOKEN" ]]; then
    echo "  Successfully obtained token — Portal is ready."
  else
    echo "  WARNING: Site exists but cannot get token. This may indicate:"
    echo "    - Credentials mismatch (different admin account was used to create the site)"
    echo "    - Portal is still initializing internally"
    echo "  Will retry token acquisition for up to 5 minutes..."
    for _tok_retry in $(seq 1 30); do
      PTOKEN=$(_portal_token 2>/dev/null) || PTOKEN=""
      if [[ -n "$PTOKEN" ]]; then
        echo "  Token obtained on retry $_tok_retry."
        break
      fi
      echo "    Token retry $_tok_retry/30 — sleeping 10s..."
      sleep 10
    done
    if [[ -z "$PTOKEN" ]]; then
      echo "ERROR: Portal site exists but cannot authenticate." >&2
      echo "  This usually means Portal's internal state is corrupted." >&2
      echo "  To fix: run with --reset-sites to clear and recreate Portal site." >&2
      exit 1
    fi
  fi
else
  # Site doesn't exist — create it
  echo "  Portal site does not exist. Creating new site..."
  echo "  NOTE: createNewSite can take 3-5 minutes. Please wait..."
  
  CONTENT_STORE=$(printf \
    '{"type":"fileStore","provider":"FileSystem","connectionString":{"rootDir":"%s"}}' \
    "$ESRI_BASE/arcgis/usr/arcgisusr")

  # Call createNewSite with LONG timeout (600s = 10 min) - this operation can take several minutes
  # Using separate curl call instead of CURL_ADM to avoid the 90s max-time limit
  _CREATE_SUCCESS=0
  for _cns in $(seq 1 30); do
    echo "    createNewSite attempt $_cns/30 (timeout: 10 min)..."
    CREATE_RESULT=$(curl -sk --noproxy '*' --connect-timeout 30 --max-time 600 \
      -X POST "https://localhost:7443/arcgis/portaladmin/createNewSite" \
      -H "Referer: https://localhost:7443/arcgis" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-urlencode "username=$ADMIN_USER" \
      --data-urlencode "password=$ADMIN_PASS" \
      --data-urlencode "fullname=$ADMIN_FIRST $ADMIN_LAST" \
      --data-urlencode "email=$EMAIL" \
      --data-urlencode "description=" \
      --data-urlencode "securityQuestionIdx=1" \
      --data-urlencode "securityQuestionAns=$ADMIN_SECURITY_ANSWER" \
      --data-urlencode "contentStore=$CONTENT_STORE" \
      --data-urlencode "f=json" \
      2>/dev/null || true)

    # Empty or non-JSON → Portal not ready yet
    if [[ -z "$CREATE_RESULT" ]] || ! echo "$CREATE_RESULT" | grep -q '{'; then
      echo "    createNewSite: no response yet — sleeping 30s..."
      sleep 30
      # Re-check if site now exists (request may have triggered init)
      if _portal_site_exists 2>/dev/null; then
        echo "    Site now exists after empty response - checking if we can get token..."
        _CHECK_TOK=$(_portal_token 2>/dev/null) || _CHECK_TOK=""
        if [[ -n "$_CHECK_TOK" ]] && [[ ! "$_CHECK_TOK" =~ ^\[_portal_token\] ]]; then
          echo "    Token obtained! Site was created successfully."
          _CREATE_SUCCESS=1
          break
        fi
      fi
      continue
    fi

    echo "  createNewSite response: ${CREATE_RESULT:0:300}"

    # Check for errors
    CREATE_CODE=$(echo "$CREATE_RESULT" | jq -r '.error.code // empty' 2>/dev/null || true)
    CREATE_MSG=$(echo "$CREATE_RESULT" | jq -r '.error.message // empty' 2>/dev/null || true)
    
    # Success response or status=success
    if echo "$CREATE_RESULT" | jq -e '.status == "success"' >/dev/null 2>&1; then
      echo "  createNewSite succeeded!"
      _CREATE_SUCCESS=1
      break
    fi
    
    # Error 499 = Token Required - this could be:
    # 1. Previous createNewSite attempt (empty response) actually triggered init
    # 2. Portal auto-initialized from leftover state
    # Try to get a token - if it works, site was created with our credentials
    if [[ "$CREATE_CODE" == "499" ]]; then
      echo "  createNewSite returned 499 (Token Required). Checking if site initialized with our credentials..."
      sleep 5  # Give Portal a moment
      _CHECK_TOK=$(_portal_token 2>/dev/null) || _CHECK_TOK=""
      if [[ -n "$_CHECK_TOK" ]] && [[ ! "$_CHECK_TOK" =~ ^\[_portal_token\] ]]; then
        echo "  Token obtained! Site was created successfully."
        _CREATE_SUCCESS=1
        break
      fi
      # Token failed - but site might still be initializing. Wait and retry.
      echo "  Cannot get token yet. Portal may still be initializing (up to 3 more minutes)..."
      for _499_wait in $(seq 1 18); do
        sleep 10
        _CHECK_TOK=$(_portal_token 2>/dev/null) || _CHECK_TOK=""
        if [[ -n "$_CHECK_TOK" ]] && [[ ! "$_CHECK_TOK" =~ ^\[_portal_token\] ]]; then
          echo "  Token obtained after waiting! Site is ready."
          _CREATE_SUCCESS=1
          break 2
        fi
        echo "    Still waiting for token ($_499_wait/18)..."
      done
      # If still no token after 3 minutes, it's corrupted
      echo ""
      echo "ERROR: Portal returned 499 but cannot authenticate with provided credentials." >&2
      echo "  This usually means Portal auto-initialized incorrectly." >&2
      echo "" >&2
      echo "  To fix (Builder installation - no systemd):" >&2
      echo "    sudo -u arcgis /opt/esri/arcgis/portal/stopportal.sh" >&2
      echo "    sudo pkill -9 -f postgres" >&2
      echo "    sudo rm -rf /opt/esri/arcgis/portal/usr/arcgisportal/*" >&2
      echo "    sudo -u arcgis /opt/esri/arcgis/portal/startportal.sh" >&2
      echo "    sleep 120" >&2
      echo "    sudo ./install_builder.sh --steps 5a,5b,5c,5d,5e" >&2
      exit 1
    fi
    
    # "already configured" or similar
    if echo "$CREATE_RESULT" | grep -qi 'already configured\|already initialized\|already exists'; then
      echo "  createNewSite: site already configured"
      _CREATE_SUCCESS=1
      break
    fi
    
    # Any other error
    if [[ -n "$CREATE_CODE" ]]; then
      echo "ERROR: createNewSite failed with code $CREATE_CODE: $CREATE_MSG" >&2
      exit 1
    fi
    
    # Got a response but unclear status - treat as success and continue
    echo "  createNewSite returned, waiting for site to fully initialize..."
    _CREATE_SUCCESS=1
    break
  done

  if [[ $_CREATE_SUCCESS -eq 0 ]]; then
    echo "ERROR: createNewSite never succeeded." >&2
    exit 1
  fi

  # Wait for site to be fully initialized (site_exists returns true)
  echo "  Waiting for Portal site to be fully initialized (up to 10 min)..."
  _SITE_READY=0
  for _sr in $(seq 1 60); do
    if _portal_site_exists; then
      _SITE_READY=1
      echo "  Portal site is now initialized."
      break
    fi
    echo "    Site initialization check $_sr/60 — sleeping 10s..."
    sleep 10
  done

  if [[ $_SITE_READY -eq 0 ]]; then
    echo "ERROR: Portal site did not become ready within 10 minutes after createNewSite." >&2
    exit 1
  fi

  # Now get token
  echo "  Waiting for Portal to accept tokens (up to 5 min)..."
  for _tok in $(seq 1 30); do
    PTOKEN=$(_portal_token 2>&1) || PTOKEN=""
    # Check if we got a valid token (not error message)
    if [[ -n "$PTOKEN" ]] && [[ ! "$PTOKEN" =~ ^\[_portal_token\] ]]; then
      echo "  Successfully obtained token."
      break
    fi
    # Show diagnostic info every 5 attempts
    if (( _tok % 5 == 0 )); then
      _DIAG=$("${CURL_ADM[@]}" "https://localhost:7443/arcgis/portaladmin/?f=json" 2>/dev/null || true)
      echo "    [diag] portaladmin: ${_DIAG:0:150}"
    fi
    echo "    Token attempt $_tok/30 — sleeping 10s..."
    sleep 10
  done

  if [[ -z "$PTOKEN" ]] || [[ "$PTOKEN" =~ ^\[_portal_token\] ]]; then
    echo "ERROR: Portal site created but cannot get token." >&2
    echo "  This usually means Portal's internal database is corrupted." >&2
    echo "  Run with --reset-sites to clear Portal state and retry." >&2
    echo "  Check Portal logs at /opt/esri/arcgis/portal/usr/arcgisportal/logs/" >&2
    exit 1
  fi
fi

echo "  Step 5a complete. Portal site is ready."
fi # end step 5a

# ---------- Step 5b: Apply Portal license ----------
if step_enabled "5b"; then
echo ">>> Step 5b: Applying Portal license..."
PTOKEN=$(_portal_token)
LIC_RESULT=$("${CURL_ADM[@]}" -X POST \
  "https://localhost:7443/arcgis/portaladmin/license/importLicense?token=$PTOKEN&f=json" \
  -F "file=@$PORTAL_LIC" 2>/dev/null)
echo "  License import result: $LIC_RESULT"
if echo "$LIC_RESULT" | grep -q '"error"'; then
  echo "  WARNING: License import returned an error (may already be licensed)."
fi
fi # end step 5b

# ---------- Step 5c: Create ArcGIS Server site ----------
if step_enabled "5c"; then
echo ">>> Step 5c: Creating ArcGIS Server site..."

# Server returns HTTP 200 with currentVersion when site exists; 302/error when not yet configured
SERVER_INFO=$("${CURL_ADM[@]}" "https://localhost:6443/arcgis/admin/?f=json" 2>/dev/null || echo '{}')

if echo "$SERVER_INFO" | jq -e '.currentVersion' >/dev/null 2>&1; then
  echo "  Server site already exists."
else
  CREATESITE_TOOL="$ESRI_BASE/arcgis/server/tools/createsite/createsite.sh"
  [[ ! -f "$CREATESITE_TOOL" ]] && echo "ERROR: createsite.sh not found." >&2 && exit 1
  echo "  Running createsite.sh..."
  sudo -u "$ARCGIS_USER" "$CREATESITE_TOOL" \
    -u "$ADMIN_USER" -p "$ADMIN_PASS" \
    -d "$ESRI_BASE/arcgis/server/usr"
  echo "  Waiting for Server site to become ready (HTTP 200, up to 10 min)..."
  _cs_up=0
  for _ci in $(seq 1 60); do
    _ccode=$(curl -sk -o /dev/null -w "%{http_code}" \
      "https://localhost:6443/arcgis/rest/info?f=json" 2>/dev/null || true)
    if [[ "$_ccode" == "200" ]]; then
      echo "  Server site ready (HTTP 200)."
      _cs_up=1; break
    fi
    echo "  Server not ready yet (HTTP ${_ccode:-000}), attempt $_ci/60 — sleeping 10s..."
    sleep 10
  done
  if [[ $_cs_up -eq 0 ]]; then
    echo "  ERROR: Server site did not become ready within 10 minutes. Check logs at:"
    echo "    $ESRI_BASE/arcgis/usr/arcgisusr/arcgisserver/logs/"
    exit 1
  fi
fi
fi # end step 5c

# ---------- Step 5d: Configure ArcGIS Data Store ----------
if step_enabled "5d"; then
echo ">>> Step 5d: Configuring ArcGIS Data Store..."
DS_TOOL=$(find "$ESRI_BASE/arcgis/datastore" -name "configuredatastore.sh" 2>/dev/null | head -1 || true)
if [[ -n "$DS_TOOL" ]]; then
  # positional args: <serverHostname> <serverAdmin> <serverAdminPassword> <dataDir> [options]
  DS_DATA_DIR="$ESRI_BASE/arcgis/datastore/usr/arcgisdatastore"
  mkdir -p "$DS_DATA_DIR"
  chown "$ARCGIS_USER:$ARCGIS_USER" "$DS_DATA_DIR"
  set +e
  sudo -u "$ARCGIS_USER" "$DS_TOOL" \
    localhost "$ADMIN_USER" "$ADMIN_PASS" \
    "$DS_DATA_DIR" --stores relational 2>&1
  set -e
else
  echo "  WARNING: configuredatastore.sh not found — skipping DataStore configuration."
fi
fi # end step 5d

# ---------- Step 5e: Federate ArcGIS Server with Portal ----------
if step_enabled "5e"; then
echo ">>> Step 5e: Federating ArcGIS Server with Portal..."
PTOKEN=$(_portal_token)

SERVERS_JSON=$("${CURL_ADM[@]}" \
  "https://localhost:7443/arcgis/portaladmin/federation/servers?f=json&token=$PTOKEN" 2>/dev/null || echo '{}')

FED_COUNT=$(echo "$SERVERS_JSON" | jq -r '.servers | length' 2>/dev/null || echo '0')
if [[ "$FED_COUNT" =~ ^[1-9] ]]; then
  echo "  Server is already federated with Portal ($FED_COUNT server(s))."
else
  echo "  Federating Server with Portal..."

  # ── 5e-i: Ensure server is healthy (HTTP 200) before proceeding ──────────────
  # A previous failed step 5e may have left the server broken (HTTP 500) because
  # security-config.json was missing or root-owned. Fix it now if needed.
  _SRV_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
    "https://localhost:6443/arcgis/rest/info?f=json" 2>/dev/null || true)
  if [[ "$_SRV_CODE" != "200" ]]; then
    echo "  Server not at HTTP 200 (got ${_SRV_CODE:-000}) — attempting recovery..."
    # Find security-config.json; if missing, restore from .bak with correct ownership.
    _SEC_RECOVER=$(find "$ESRI_BASE/arcgis" \
      -name "security-config.json" -path "*/config-store/security/*" 2>/dev/null | head -1 || true)
    if [[ -z "$_SEC_RECOVER" ]]; then
      _SEC_RECOVER=$(find "$ESRI_BASE/arcgis" \
        -name "security-config.json" 2>/dev/null | head -1 || true)
    fi
    if [[ -z "$_SEC_RECOVER" ]]; then
      # File is genuinely missing — look for a backup left by a previous run.
      _SEC_BAK_R=$(find "$ESRI_BASE/arcgis" \
        -name "security-config.json.bak" -path "*/config-store/security/*" 2>/dev/null | head -1 || true)
      [[ -z "$_SEC_BAK_R" ]] && _SEC_BAK_R=$(find "$ESRI_BASE/arcgis" \
        -name "security-config.json.bak" 2>/dev/null | head -1 || true)
      if [[ -n "$_SEC_BAK_R" ]]; then
        _SEC_RECOVER="${_SEC_BAK_R%.bak}"
        echo "  Restoring security-config.json from backup: $_SEC_BAK_R"
        cp -p "$_SEC_BAK_R" "$_SEC_RECOVER" 2>/dev/null || true
      else
        echo "  ERROR: security-config.json is missing and no backup found."
        echo "  Expected: $ESRI_BASE/arcgis/usr/arcgisusr/arcgisserver/config-store/security/security-config.json"
        exit 1
      fi
    fi
    # Always ensure the file is owned by arcgis, not root.
    # A root-owned config causes ArcGIS Server to fail writes at startup → HTTP 500.
    chown "$ARCGIS_USER:$ARCGIS_USER" "$_SEC_RECOVER" 2>/dev/null || true
    chmod 600 "$_SEC_RECOVER" 2>/dev/null || true
    echo "  Restarting ArcGIS Server to recover health..."
    sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/server/stopserver.sh" >/dev/null 2>&1 || true
    sleep 10
    sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/server/startserver.sh" >/dev/null 2>&1 || true
    echo "  Waiting for Server to recover (up to 5 min)..."
    _rec_up=0
    for _ri in $(seq 1 30); do
      _rcode=$(curl -sk -o /dev/null -w "%{http_code}" \
        "https://localhost:6443/arcgis/rest/info?f=json" 2>/dev/null || true)
      if [[ "$_rcode" == "200" ]]; then echo "  Server recovered (HTTP 200)."; _rec_up=1; break; fi
      echo "  Server not ready (HTTP $_rcode), waiting 10s..."
      sleep 10
    done
    if [[ $_rec_up -eq 0 ]]; then
      echo "  ERROR: Server did not recover to HTTP 200. Check logs at:"
      echo "    $ESRI_BASE/arcgis/usr/arcgisusr/arcgisserver/logs/"
      exit 1
    fi
  fi

  # ── 5e-ii: Fix ClassCastException for contentSecurityPolicy via REST ──────────
  # ArcGIS Server persists contentSecurityPolicy as a JSONObject in security-config.json.
  # Portal's federation handler calls GET /admin/security/config and does:
  #   String csp = (String) secConfig.get("contentSecurityPolicy") → ClassCastException.
  #
  # FIX: POST to security/config/update while the server is running at HTTP 200.
  # The REST endpoint receives contentSecurityPolicy as a form parameter (always a String
  # from Java's perspective) and stores it in the JVM's SecurityConfig as java.lang.String.
  # Portal then reads back a String from the JVM → cast succeeds → no ClassCastException.
  # No stop/restart is required — this is a pure in-memory JVM state update via REST.
  #
  # IMPORTANT: do NOT include portalProperties in this POST.
  # Setting portalProperties="" (String) causes Server's own federation validation to do:
  #   (JSONObject)secConfig.get("portalProperties") → ClassCastException on the server side.
  # Omit it so it remains null/absent, which is handled gracefully.
  STOKEN=$(_server_token)
  if [[ -z "$STOKEN" ]]; then
    echo "  ERROR: Could not get Server admin token."
    exit 1
  fi
  CUR_SEC=$("${CURL_ADM[@]}" \
    "https://localhost:6443/arcgis/admin/security/config?f=json&token=$STOKEN" 2>/dev/null || echo '{}')
  HTTPS_PROTOS=$(echo "$CUR_SEC" | jq -r '.httpsProtocols // "TLSv1.2,TLSv1.3"' 2>/dev/null)
  CIPHER_SUITES=$(echo "$CUR_SEC" | jq -r '.cipherSuites // ""' 2>/dev/null)
  [[ -z "$HTTPS_PROTOS" || "$HTTPS_PROTOS" == "null" ]] && HTTPS_PROTOS="TLSv1.2,TLSv1.3"
  echo "  Setting contentSecurityPolicy to String in JVM via REST (httpsProtocols=$HTTPS_PROTOS)..."
  RESET_R=$("${CURL_ADM[@]}" -X POST \
    "https://localhost:6443/arcgis/admin/security/config/update" \
    --data-urlencode "authenticationMode=ARCGIS_TOKEN" \
    --data-urlencode "authenticationTier=GIS_SERVER" \
    --data-urlencode "Protocol=HTTPS" \
    --data-urlencode "httpsProtocols=$HTTPS_PROTOS" \
    --data-urlencode "cipherSuites=$CIPHER_SUITES" \
    --data-urlencode "allowDirectAccess=true" \
    --data-urlencode "virtualDirsSecurityEnabled=false" \
    --data-urlencode "HSTSEnabled=false" \
    --data-urlencode "contentSecurityPolicy=" \
    --data-urlencode "token=$STOKEN" \
    -d "f=json" 2>/dev/null)
  echo "  Security config REST update: $RESET_R"
  if echo "$RESET_R" | grep -qi '"status":"error"\|"error":{'; then
    echo "  ERROR: Security config update failed — federation would hit ClassCastException. Aborting."
    exit 1
  fi
  # Re-fetch token — the security config update may have invalidated previous tokens.
  STOKEN=$(_server_token)
  if [[ -z "$STOKEN" ]]; then
    echo "  ERROR: Could not get Server admin token after security config update."
    exit 1
  fi

  # Unregister any existing Server web adaptors. Step 5g re-registers after federation.
  echo "  Unregistering any existing Server web adaptors before federation..."
  SRV_WAS=$("${CURL_ADM[@]}" \
    "https://localhost:6443/arcgis/admin/system/webadaptors?f=json&token=$STOKEN" 2>/dev/null \
    | jq -r '.webAdaptors[]?.id // empty' 2>/dev/null || true)
  for _wa_id in $SRV_WAS; do
    echo "  Unregistering Server WA: $_wa_id"
    "${CURL_ADM[@]}" -X POST \
      "https://localhost:6443/arcgis/admin/system/webadaptors/${_wa_id}/unregister" \
      --data-urlencode "token=$STOKEN" \
      -d "f=json" 2>/dev/null || true
  done

  # adminUrl: use Server's registered machine name (uppercase FQDN), pinned to 127.0.0.1
  # in /etc/hosts so Portal's JVM resolves it to loopback, not the public Azure IP.
  # Azure hairpin NAT blocks a VM hitting its own public IP from inside the same instance.
  _SERVER_MACHINE=$(curl -sk \
    "https://localhost:6443/arcgis/admin/machines?f=json&token=$STOKEN" 2>/dev/null \
    | jq -r '.machines[0].machineName // empty' 2>/dev/null || true)
  [[ -z "$_SERVER_MACHINE" ]] && _SERVER_MACHINE=$(hostname -f 2>/dev/null | tr '[:lower:]' '[:upper:]' || echo "LOCALHOST")
  echo "  Server machine name: $_SERVER_MACHINE"
  if ! grep -qi "127\.0\.0\.1.*${_SERVER_MACHINE}" /etc/hosts 2>/dev/null; then
    echo "127.0.0.1 ${_SERVER_MACHINE} ${_SERVER_MACHINE,,}" >> /etc/hosts
    echo "  Added /etc/hosts entry: 127.0.0.1 ${_SERVER_MACHINE}"
  fi
  SERVER_ADMIN_URL="https://${_SERVER_MACHINE}:6443/arcgis"

  # Generate a fresh Portal token immediately before the federation call.
  # Any token generated before the Server restart may be stale (Portal validates
  # some tokens against Server; if Server was just restarted, old tokens 498).
  PTOKEN=$(_portal_token)
  if [[ -z "$PTOKEN" ]]; then
    echo "  ERROR: Could not get Portal admin token before federation call."
    exit 1
  fi

  echo "  Calling federation endpoint: adminUrl=$SERVER_ADMIN_URL"
  FED_RESULT=$("${CURL_ADM[@]}" -X POST \
    "https://localhost:7443/arcgis/portaladmin/federation/servers/federate" \
    --data-urlencode "url=https://$DOMAIN/server" \
    --data-urlencode "adminUrl=${SERVER_ADMIN_URL}" \
    --data-urlencode "username=$ADMIN_USER" \
    --data-urlencode "password=$ADMIN_PASS" \
    --data-urlencode "token=$PTOKEN" \
    -d "f=json")
  echo "  Federation result: $FED_RESULT"
  if echo "$FED_RESULT" | grep -qi '"status":"error"\|"error":{\|Method Not Allowed\|405'; then
    echo "  ERROR: Federation call failed — see result above."
    echo "  If you believe the server is already federated under a different URL, check:"
    echo "    https://localhost:7443/arcgis/portaladmin/federation/servers?f=json&token=<PTOKEN>"
    exit 1
  else
    echo "  Waiting 60s for federation handshake to complete..."
    sleep 60

    # Set server role to HOSTING_SERVER
    PTOKEN=$(_portal_token)
    SERVERS_JSON2=$("${CURL_ADM[@]}" \
      "https://localhost:7443/arcgis/portaladmin/federation/servers?f=json&token=$PTOKEN" 2>/dev/null || echo '{}')
    SERVER_ID=$(echo "$SERVERS_JSON2" | jq -r '.servers[] | select(.url | test("'"$DOMAIN"'")) | .id' 2>/dev/null | head -1 || true)
    if [[ -n "$SERVER_ID" ]]; then
      echo "  Setting server role to HOSTING_SERVER (id: $SERVER_ID)..."
      ROLE_RESULT=$("${CURL_ADM[@]}" -X POST \
        "https://localhost:7443/arcgis/portaladmin/federation/servers/${SERVER_ID}/update" \
        --data-urlencode "serverRole=HOSTING_SERVER" \
        --data-urlencode "serverFunction=" \
        --data-urlencode "token=$PTOKEN" \
        -d "f=json")
      echo "  Server role result: $ROLE_RESULT"
    fi
  fi
fi
fi # end step 5e

# ---------- Step 5f: Register Portal web adaptor ----------
if step_enabled "5f"; then
echo ">>> Step 5f: Registering NGINX as Portal web adaptor..."
PTOKEN=$(_portal_token)

PORTAL_WAS=$("${CURL_ADM[@]}" \
  "https://localhost:7443/arcgis/portaladmin/system/webadaptors?f=json&token=$PTOKEN" 2>/dev/null || echo '{}')

if echo "$PORTAL_WAS" | grep -qF "$DOMAIN/portal"; then
  echo "  Portal web adaptor already registered."
else
  WA_RESULT=$("${CURL_ADM[@]}" -X POST \
    "https://localhost:7443/arcgis/portaladmin/system/webadaptors/register" \
    -d "webAdaptorURL=https://${DOMAIN}/portal&description=NGINX+Reverse+Proxy&httpPort=80&httpsPort=443&isShared=false&f=json&token=$PTOKEN")
  echo "  Portal web adaptor result: $WA_RESULT"
fi
fi # end step 5f

# ---------- Step 5g: Register Server web adaptor ----------
if step_enabled "5g"; then
echo ">>> Step 5g: Registering NGINX as Server web adaptor..."
STOKEN=$(_server_token)

if [[ -z "$STOKEN" ]]; then
  echo "  WARNING: Could not get Server admin token — skipping Server web adaptor registration."
else
  SERVER_WAS=$("${CURL_ADM[@]}" \
    "https://localhost:6443/arcgis/admin/system/webadaptors?f=json&token=$STOKEN" 2>/dev/null || echo '{}')

  if echo "$SERVER_WAS" | grep -qF "$DOMAIN/server"; then
    echo "  Server web adaptor already registered."
  else
    # machineName must match the machine hostname as ArcGIS Server registered it
    SERVER_MACHINE=$("${CURL_ADM[@]}" \
      "https://localhost:6443/arcgis/admin/machines?f=json&token=$STOKEN" 2>/dev/null \
      | jq -r '.machines[0].machineName // empty' 2>/dev/null || true)
    [[ -z "$SERVER_MACHINE" ]] && SERVER_MACHINE=$(hostname -f)
    echo "  Using Server machine name: $SERVER_MACHINE"
    WA_RESULT=$("${CURL_ADM[@]}" -X POST \
      "https://localhost:6443/arcgis/admin/system/webadaptors/register" \
      -d "webAdaptorURL=https://${DOMAIN}/server&machineName=${SERVER_MACHINE}&description=NGINX+Reverse+Proxy&httpPort=80&httpsPort=443&f=json&token=$STOKEN")
    echo "  Server web adaptor result: $WA_RESULT"
  fi
fi
fi # end step 5g

echo ""
echo "========================================"
echo "ArcGIS Enterprise configuration complete"
echo "  Portal : https://$DOMAIN/portal/home/"
echo "  Server : https://$DOMAIN/server/rest/services"
echo "========================================"
echo "DONE."
