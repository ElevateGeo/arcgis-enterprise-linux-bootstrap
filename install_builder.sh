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
PORTAL_STOP="$ESRI_BASE/arcgis/portal/stopportal.sh"
SERVER_START="$ESRI_BASE/arcgis/server/startserver.sh"
SERVER_STOP="$ESRI_BASE/arcgis/server/stopserver.sh"
DS_START=$(find "$ESRI_BASE/arcgis/datastore" -name "startdatastore.sh" 2>/dev/null | head -1 || true)
DS_STOP=$(find "$ESRI_BASE/arcgis/datastore" -name "stopdatastore.sh" 2>/dev/null | head -1 || true)

# Always stop first for a clean-state restart — avoids stale process warnings
# that indicate the prior configurebasedeployment run left services mid-flight.
echo "Stopping ArcGIS services for clean restart..."
[[ -n "$DS_STOP" ]] && sudo -u "$ARCGIS_USER" "$DS_STOP" 2>/dev/null || true
[[ -f "$SERVER_STOP" ]] && sudo -u "$ARCGIS_USER" "$SERVER_STOP" 2>/dev/null || true
[[ -f "$PORTAL_STOP" ]] && sudo -u "$ARCGIS_USER" "$PORTAL_STOP" 2>/dev/null || true
echo "Waiting 20s for processes to fully exit..."
sleep 20

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
# Portal tokens are issued by sharing/rest/generateToken.
# The portaladmin API *consumes* those tokens — it does not issue them.
# Returns the token string on success, empty string on failure (never exits).
_portal_token() {
  local resp tok
  resp=$("${CURL_ADM[@]}" -X POST \
    "https://localhost:7443/arcgis/sharing/rest/generateToken" \
    -d "username=$ADMIN_USER&password=$ADMIN_PASS&client=requestip&expiration=120&f=json" \
    2>/dev/null || true)
  tok=$(echo "$resp" | jq -r '.token // empty' 2>/dev/null || true)
  if [[ -n "$tok" ]]; then echo "$tok"; return 0; fi
  # Print response to stderr for diagnosis, return empty (not exit)
  echo "  [_portal_token] sharing/rest/generateToken response: $resp" >&2
  echo ""
  return 0   # always return 0 — callers check for empty string, not exit code
}

_server_token() {
  local resp tok
  resp=$("${CURL_ADM[@]}" -X POST \
    "https://localhost:6443/arcgis/admin/generateToken" \
    -d "username=$ADMIN_USER&password=$ADMIN_PASS&client=requestip&expiration=120&f=json" \
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
echo ">>> Step 5a: Creating Portal site..."

# Strategy: try to get a token first. A valid token means Portal is already
# initialized with the current credentials — skip createNewSite.
# If no token, Portal is either uninitialized or mid-startup; call createNewSite.
# createNewSite is idempotent — it errors distinctly when already configured.
echo "  Checking if Portal is already initialized (attempting token)..."
PTOKEN=$(_portal_token)

if [[ -n "$PTOKEN" ]]; then
  echo "  Portal already initialized and credentials verified."
else
  echo "  No token — Portal not yet initialized. Calling createNewSite..."
  CONTENT_STORE=$(printf \
    '{"type":"fileStore","provider":"FileSystem","connectionString":{"rootDir":"%s"}}' \
    "$ESRI_BASE/arcgis/usr/arcgisusr")

  CREATE_RESULT=$("${CURL_ADM[@]}" -X POST \
    "https://localhost:7443/arcgis/portaladmin/createNewSite" \
    --data-urlencode "username=$ADMIN_USER" \
    --data-urlencode "password=$ADMIN_PASS" \
    --data-urlencode "fullname=$ADMIN_FIRST $ADMIN_LAST" \
    --data-urlencode "email=$EMAIL" \
    --data-urlencode "description=" \
    --data-urlencode "securityQuestionId=1" \
    --data-urlencode "securityQuestionAns=Blue" \
    --data-urlencode "contentStore=$CONTENT_STORE" \
    -d "f=json" 2>/dev/null)
  echo "  createNewSite result: $CREATE_RESULT"

  # code 499 "Token Required" from createNewSite means Portal IS already
  # initialized (that endpoint only requires auth on an existing site).
  # A prior run (e.g. configurebasedeployment) created the Portal site but
  # the credentials in .env don't match what was used.
  CREATE_CODE=$(echo "$CREATE_RESULT" | jq -r '.error.code // empty' 2>/dev/null || true)
  if [[ "$CREATE_CODE" == "499" ]] || echo "$CREATE_RESULT" | grep -qi 'already configured\|already initialized'; then
    echo "ERROR: Portal is already initialized but token generation failed." >&2
    echo "  ADMIN_USER/ADMIN_PASS in .env likely don't match the Portal's stored credentials." >&2
    echo "  Options:" >&2
    echo "    1. Update ADMIN_USER/ADMIN_PASS in .env to match the credentials used during initial Portal setup." >&2
    echo "    2. Run with --wipe to destroy and fully reinstall (DESTRUCTIVE — all data lost)." >&2
    exit 1
  fi

  if echo "$CREATE_RESULT" | grep -q '"error"'; then
    echo "ERROR: Portal createNewSite failed. See result above." >&2; exit 1
  fi

  echo "  Portal site creation started. Waiting for it to become ready (up to 12 min)..."
  PTOKEN=$(_wait_portal_token 72) || {
    echo "ERROR: Portal never became ready after createNewSite." >&2; exit 1
  }
  echo "  Portal site ready."
fi

# ---------- Step 5b: Apply Portal license ----------
echo ">>> Step 5b: Applying Portal license..."
PTOKEN=$(_portal_token)
LIC_RESULT=$("${CURL_ADM[@]}" -X POST \
  "https://localhost:7443/arcgis/portaladmin/license/importLicense?token=$PTOKEN&f=json" \
  -F "file=@$PORTAL_LIC" 2>/dev/null)
echo "  License import result: $LIC_RESULT"
if echo "$LIC_RESULT" | grep -q '"error"'; then
  echo "  WARNING: License import returned an error (may already be licensed)."
fi

# ---------- Step 5c: Create ArcGIS Server site ----------
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
  echo "  Waiting 30s for Server site to initialise..."
  sleep 30
fi

# ---------- Step 5d: Configure ArcGIS Data Store ----------
echo ">>> Step 5d: Configuring ArcGIS Data Store..."
DS_TOOL=$(find "$ESRI_BASE/arcgis/datastore" -name "configuredatastore.sh" 2>/dev/null | head -1 || true)
if [[ -n "$DS_TOOL" ]]; then
  set +e
  sudo -u "$ARCGIS_USER" "$DS_TOOL" \
    --server-url "https://localhost:6443/arcgis" \
    --username "$ADMIN_USER" --password "$ADMIN_PASS" \
    --stores relational 2>&1
  set -e
else
  echo "  WARNING: configuredatastore.sh not found — skipping DataStore configuration."
fi

# ---------- Step 5e: Federate ArcGIS Server with Portal ----------
echo ">>> Step 5e: Federating ArcGIS Server with Portal..."
PTOKEN=$(_portal_token)

SERVERS_JSON=$("${CURL_ADM[@]}" \
  "https://localhost:7443/arcgis/portaladmin/federation/servers?f=json&token=$PTOKEN" 2>/dev/null || echo '{}')

if echo "$SERVERS_JSON" | jq -e '.servers | length > 0' >/dev/null 2>&1; then
  echo "  Server is already federated with Portal."
else
  echo "  Registering Server with Portal federation..."
  FED_RESULT=$("${CURL_ADM[@]}" -X POST \
    "https://localhost:7443/arcgis/portaladmin/federation/servers/register" \
    -d "url=https://$DOMAIN/server&adminUrl=https://localhost:6443/arcgis&isHosted=true&serverType=ArcGIS&f=json&token=$PTOKEN")
  echo "  Federation result: $FED_RESULT"
  if echo "$FED_RESULT" | grep -q '"error"'; then
    echo "  WARNING: Federation returned an error (may already be federated or credentials issue)."
  else
    echo "  Waiting 30s for federation handshake to complete..."
    sleep 30
  fi
fi

# ---------- Step 5f: Register Portal web adaptor ----------
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

# ---------- Step 5g: Register Server web adaptor ----------
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
    WA_RESULT=$("${CURL_ADM[@]}" -X POST \
      "https://localhost:6443/arcgis/admin/system/webadaptors/register" \
      -d "webAdaptorURL=https://${DOMAIN}/server&description=NGINX+Reverse+Proxy&httpPort=80&httpsPort=443&f=json&token=$STOKEN")
    echo "  Server web adaptor result: $WA_RESULT"
  fi
fi

echo ""
echo "========================================"
echo "ArcGIS Enterprise configuration complete"
echo "  Portal : https://$DOMAIN/portal/home/"
echo "  Server : https://$DOMAIN/server/rest/services"
echo "========================================"
echo "DONE."
