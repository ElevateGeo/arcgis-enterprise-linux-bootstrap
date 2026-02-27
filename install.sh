#!/usr/bin/env bash
set -euo pipefail

# ArcGIS components can bind to IPv4 loopback, IPv6 loopback, or both depending
# on OS/network settings. Additionally, some environments set http_proxy/https_proxy
# which can break local calls (curl will try to proxy https://127.0.0.1:6443).
# Bypass proxies for these internal REST/admin calls.
CURL_BASE=(curl -skS --noproxy '*' --connect-timeout 5 --max-time 30)

# Base install location used throughout.
ESRI_BASE="/opt/esri"

# Default internal targets. In some environments ArcGIS binds only to the
# hostname's primary IP (or 127.0.1.1) rather than 127.0.0.1. We will
# auto-discover a reachable local target during Step 10/11 and then reuse it.
SERVER_HOST_DEFAULT="127.0.0.1"
PORTAL_HOST_DEFAULT="127.0.0.1"
DATASTORE_HOST_DEFAULT="127.0.0.1"

SERVER_HOST="${SERVER_HOST:-$SERVER_HOST_DEFAULT}"
PORTAL_HOST="${PORTAL_HOST:-$PORTAL_HOST_DEFAULT}"
DATASTORE_HOST="${DATASTORE_HOST:-$DATASTORE_HOST_DEFAULT}"

LAST_READY_URL=""
LAST_READY_HOST=""
LAST_READY_BASE=""

usage() {
  cat <<'USAGE'
Usage: sudo ./install.sh [options]

Options:
  --wipe            Remove existing ArcGIS Enterprise components under /opt/esri/arcgis
                    (Portal/Server/Data Store/Web Adaptor install dirs) before installing.
                    DESTRUCTIVE: deletes existing deployment content and configuration.
  --yes             Non-interactive confirmation for --wipe.
  --help            Show this help.
USAGE
}

WIPE_EXISTING=0
WIPE_YES=0
for arg in "$@"; do
  case "$arg" in
    --wipe) WIPE_EXISTING=1 ;;
    --yes) WIPE_YES=1 ;;
    --help|-h) usage; exit 0 ;;
    *) ;;
  esac
done

wipe_existing_enterprise() {
  echo ""
  echo "!!! WIPE MODE ENABLED !!!"
  echo "This will DELETE the existing ArcGIS Enterprise deployment under: ${ESRI_BASE}/arcgis"
  echo "This includes Portal content + hosted layers/data store associations." 
  echo "If you need backups, stop now and run a proper backup (e.g., webgisdr + Data Store backups)."
  echo ""

  if (( WIPE_YES == 0 )); then
    echo "To proceed, type WIPE and press Enter:"
    read -r _confirm
    if [[ "${_confirm}" != "WIPE" ]]; then
      echo "Wipe cancelled."
      exit 1
    fi
  fi

  echo "Stopping services (best-effort)..."
  systemctl stop arcgisportal 2>/dev/null || true
  systemctl stop arcgisserver 2>/dev/null || true
  systemctl stop arcgisdatastore 2>/dev/null || true
  systemctl stop tomcat10 2>/dev/null || true

  # Some installs use init.d wrappers.
  /etc/init.d/arcgisportal stop 2>/dev/null || true
  /etc/init.d/arcgisserver stop 2>/dev/null || true
  /etc/init.d/arcgisdatastore stop 2>/dev/null || true

  # Remove Tomcat Web Adaptor deployments so Step 9 won't falsely skip.
  if [[ -d "/opt/tomcat10/webapps" ]]; then
    echo "Removing Tomcat Web Adaptor deployments (portal/server)..."
    rm -rf /opt/tomcat10/webapps/portal /opt/tomcat10/webapps/server \
      /opt/tomcat10/webapps/portal.war /opt/tomcat10/webapps/server.war \
      2>/dev/null || true
  fi

  echo "Removing ArcGIS Enterprise install directory: ${ESRI_BASE}/arcgis"
  # Remove component directories explicitly first in case /opt/esri/arcgis is a
  # symlink/bind-mount or partially recreated.
  rm -rf "${ESRI_BASE}/arcgis/server" 2>/dev/null || true
  rm -rf "${ESRI_BASE}/arcgis/portal" 2>/dev/null || true
  rm -rf "${ESRI_BASE}/arcgis/datastore" 2>/dev/null || true
  rm -rf "${ESRI_BASE}/arcgis/webadaptor"* 2>/dev/null || true
  rm -rf "${ESRI_BASE}/arcgis" 2>/dev/null || true

  # Clean up common service definitions so reinstall recreates them cleanly.
  echo "Cleaning up ArcGIS service definitions (best-effort)..."
  rm -f /etc/init.d/arcgisportal /etc/init.d/arcgisserver /etc/init.d/arcgisdatastore 2>/dev/null || true
  rm -f /etc/systemd/system/arcgisportal.service /etc/systemd/system/arcgisserver.service /etc/systemd/system/arcgisdatastore.service 2>/dev/null || true
  rm -f /lib/systemd/system/arcgisportal.service /lib/systemd/system/arcgisserver.service /lib/systemd/system/arcgisdatastore.service 2>/dev/null || true
  systemctl disable --now arcgisportal 2>/dev/null || true
  systemctl disable --now arcgisserver 2>/dev/null || true
  systemctl disable --now arcgisdatastore 2>/dev/null || true
  systemctl reset-failed arcgisportal arcgisserver arcgisdatastore 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true

  # Ensure wipe actually succeeded; if it didn't, the installer will skip and
  # we end up in a broken half-wiped state.
  if [[ -e "${ESRI_BASE}/arcgis/server" || -e "${ESRI_BASE}/arcgis/portal" || -e "${ESRI_BASE}/arcgis/datastore" ]]; then
    echo "ERROR: Wipe did not fully remove existing components under ${ESRI_BASE}/arcgis" >&2
    echo "       Check for bind mounts/symlinks, permissions, or a running process preventing deletion." >&2
    echo "       Remaining paths:" >&2
    ls -ld "${ESRI_BASE}/arcgis" "${ESRI_BASE}/arcgis/server" "${ESRI_BASE}/arcgis/portal" "${ESRI_BASE}/arcgis/datastore" 2>/dev/null >&2 || true
    exit 1
  fi

  echo "Wipe complete. Proceeding with install..."
}

# ArcGIS Enterprise 12.0 Linux Bootstrap - Full Automated Install
# This script performs a complete single-machine deployment.
#
# Follows Esri's documented installation order:
#   https://enterprise.arcgis.com/en/get-started/12.0/linux/tutorial-creating-your-first-web-gis-configuration.htm
#
# Order:
#   1. Install system dependencies
#   2. SSL certificates
#   3. NGINX reverse proxy
#   4. Create arcgis user + system tuning (ulimits, sysctl)
#   5. Extract installers
#   6. Install & authorize ArcGIS Server (authorization during install via -a flag)
#   7. Install Portal for ArcGIS (+ Web Styles if present)
#   8. Install ArcGIS Data Store
#   9. Install Web Adaptor + deploy WARs to Tomcat
#  10. Start services
#  11. Create ArcGIS Server site (requires prior authorization)
#  12. Create Portal (with JSON license via -lf flag)
#  13. Configure reverse proxy (import certs into truststores)
#  14. Federate Server with Portal & set as hosting server
#  15. Configure Data Store (relational + object) — after federation per Esri order
#  16. Configure reverse proxy URLs (WebContextURL, privatePortalURL, federation URL)

ENV_FILE=".env"

echo "=============================================="
echo " ArcGIS Enterprise 12.0 Linux Bootstrap"
echo "=============================================="

# ---------- Root check ----------
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo)"
  exit 1
fi

if (( WIPE_EXISTING == 1 )); then
  wipe_existing_enterprise
fi

# ---------- Load .env ----------
if [[ -f "$ENV_FILE" ]]; then
  # Read .env line-by-line to handle unquoted values with spaces safely.
  # Lines like KEY=value with spaces would fail with `source` if unquoted.
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip blank lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    # Strip inline comments (only outside quotes)
    line="${line%%#*}"
    # Trim trailing whitespace
    line="${line%"${line##*[![:space:]]}"}"
    # Extract key and value
    key="${line%%=*}"
    val="${line#*=}"
    # Strip surrounding quotes (single or double) if present
    val="${val#[\"\']}"
    val="${val%[\"\']}"
    export "$key=$val"
  done < "$ENV_FILE"
  echo "Loaded configuration from $ENV_FILE"
fi

# ---------- Prompt helper ----------
prompt_if_empty() {
  local var_name="$1"
  local prompt_text="$2"
  local secret="${3:-}"
  local default="${4:-}"
  local value="${!var_name:-}"

  if [[ -z "$value" ]]; then
    if [[ -n "$default" ]]; then
      prompt_text="$prompt_text [$default]"
    fi

    if [[ "$secret" == "secret" ]]; then
      read -rsp "$prompt_text: " value
      echo
    else
      read -rp "$prompt_text: " value
    fi

    # Use default if empty
    [[ -z "$value" && -n "$default" ]] && value="$default"
    [[ -z "$value" ]] && echo "ERROR: $var_name cannot be empty" && exit 1

    export "$var_name=$value"
    # Quote values in .env to handle special characters in passwords
    echo "$var_name='$value'" >> "$ENV_FILE"
  fi
}

# ---------- .env upsert helper (update existing or append new) ----------
upsert_env_var() {
  local var_name="$1"
  local value="$2"

  # Basic single-quote escaping for safety
  local escaped
  escaped=$(printf "%s" "$value" | sed "s/'/'\"'\"'/g")

  if [[ -f "$ENV_FILE" ]] && grep -q "^${var_name}=" "$ENV_FILE" 2>/dev/null; then
    python3 - "$ENV_FILE" "$var_name" "$escaped" <<'PY'
import sys

path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
out = []
replaced = False
with open(path, 'r', encoding='utf-8') as f:
    for line in f:
        if line.startswith(key + '='):
            out.append(f"{key}='{val}'\n")
            replaced = True
        else:
            out.append(line)
if not replaced:
    out.append(f"{key}='{val}'\n")
with open(path, 'w', encoding='utf-8') as f:
    f.writelines(out)
PY
  else
    echo "${var_name}='${escaped}'" >> "$ENV_FILE"
  fi

  export "$var_name=$value"
}

echo ""
echo ">>> Collecting Configuration"
echo ""

# Domain and SSL
prompt_if_empty DOMAIN "Domain (e.g., gis.example.com)"
prompt_if_empty EMAIL "Let's Encrypt / Admin email"
prompt_if_empty CF_API_TOKEN "Cloudflare API Token" secret

# Admin credentials
prompt_if_empty ADMIN_USER "Portal/Server admin username" "" "siteadmin"
prompt_if_empty ADMIN_PASS "Portal/Server admin password" secret
prompt_if_empty ADMIN_FIRST_NAME "Admin first name" "" "Site"
prompt_if_empty ADMIN_LAST_NAME "Admin last name" "" "Admin"
prompt_if_empty ADMIN_SECURITY_QUESTION "Security question index (1-14, see Esri docs)" "" "1"
prompt_if_empty ADMIN_SECURITY_ANSWER "Security answer" "" "Blue"

# License files — auto-detect from /opt/esri/licenses before prompting.
# Portal 12.0+: JSON file for user types and apps
# Server: .prvc provisioning file
mkdir -p "$ESRI_BASE/licenses"
if [[ -z "${PORTAL_LICENSE_FILE:-}" || ! -f "${PORTAL_LICENSE_FILE:-}" ]]; then
  FOUND_PORTAL_LIC=$(find "$ESRI_BASE/licenses" -name "ArcGIS_Enterprise_Portal*.json" 2>/dev/null | head -1)
  if [[ -n "${FOUND_PORTAL_LIC:-}" ]]; then
    PORTAL_LICENSE_FILE="$FOUND_PORTAL_LIC"
    echo "Auto-detected Portal license: $PORTAL_LICENSE_FILE"
  fi
fi
if [[ -z "${SERVER_LICENSE_FILE:-}" || ! -f "${SERVER_LICENSE_FILE:-}" ]]; then
  FOUND_SERVER_LIC=$(find "$ESRI_BASE/licenses" -name "*.prvc" 2>/dev/null | head -1)
  if [[ -n "${FOUND_SERVER_LIC:-}" ]]; then
    SERVER_LICENSE_FILE="$FOUND_SERVER_LIC"
    echo "Auto-detected Server license: $SERVER_LICENSE_FILE"
  fi
fi

# Only prompt if auto-detection didn't find them
prompt_if_empty PORTAL_LICENSE_FILE "Portal license file path (JSON format)" "" "/opt/esri/licenses/ArcGIS_Enterprise_Portal.json"
prompt_if_empty SERVER_LICENSE_FILE "Server license file path (.prvc)" "" "/opt/esri/licenses/server.prvc"

# ---------- Paths ----------
INSTALLERS="$ESRI_BASE/installers"
ARCGIS_USER="arcgis"

echo ""
echo ">>> Configuration Summary"
echo ""
echo "  Domain:        $DOMAIN"
echo "  Email:         $EMAIL"
echo "  Admin User:    $ADMIN_USER"
echo "  Portal Lic:    $PORTAL_LICENSE_FILE"
echo "  Server Lic:    $SERVER_LICENSE_FILE"
echo ""

# Verify installers exist
if [[ ! -d "$INSTALLERS" ]]; then
  echo "ERROR: Installers directory not found: $INSTALLERS"
  echo "Please download ArcGIS installers from My Esri and place them in $INSTALLERS"
  exit 1
fi

# Check available disk space (Portal alone needs ~15 GB to extract;
# total extracted + installed typically requires 50+ GB)
AVAIL_KB=$(df --output=avail "$ESRI_BASE" 2>/dev/null | tail -1 | tr -d ' ')
AVAIL_GB=$(( AVAIL_KB / 1048576 ))
echo "Available disk space on $ESRI_BASE: ${AVAIL_GB} GB"
if [[ $AVAIL_GB -lt 50 ]]; then
  echo "ERROR: At least 50 GB of free space is required on $ESRI_BASE."
  echo "       Currently available: ${AVAIL_GB} GB"
  echo "       Expand the disk or mount additional storage before running this script."
  exit 1
fi

# ==============================================================================
# Step 1: System Dependencies
# ==============================================================================
echo ""
echo ">>> Step 1: Installing System Dependencies"
echo ""

apt-get update

apt-get install -y nginx certbot python3-certbot-dns-cloudflare openjdk-11-jdk \
  tar unzip curl jq

# ---------------------------------------------------------------------------
# Tomcat 10.1 (required — ArcGIS Enterprise 12.0 Web Adaptor uses jakarta.servlet).
# Tomcat 9 uses javax.servlet which is INCOMPATIBLE with the 12.0 WAR.
# Ubuntu 24.04 ships Tomcat 10 but as a system package; we install from Apache
# directly for a clean, self-contained deployment.
# ---------------------------------------------------------------------------
TOMCAT_VER="10.1.34"
TOMCAT_HOME="/opt/tomcat10"
TOMCAT_USER="tomcat"
TOMCAT_WEBAPPS="$TOMCAT_HOME/webapps"
TOMCAT_SERVICE="tomcat10"

# Migration: remove old Tomcat 9 installed by previous versions of this script.
# The ArcGIS 12.0 Web Adaptor WAR requires jakarta.servlet (Tomcat 10+).
if [[ -d "/opt/tomcat9" && -f "/opt/tomcat9/bin/catalina.sh" ]]; then
  echo "Removing old Tomcat 9 (ArcGIS 12.0 requires Tomcat 10+ for jakarta.servlet)..."
  systemctl stop tomcat9 2>/dev/null || true
  systemctl disable tomcat9 2>/dev/null || true
  rm -f /etc/systemd/system/tomcat9.service
  rm -rf /opt/tomcat9
  systemctl daemon-reload
fi

if [[ -d "$TOMCAT_HOME" && -f "$TOMCAT_HOME/bin/catalina.sh" ]]; then
  echo "Tomcat 10 already installed at $TOMCAT_HOME, skipping..."
else
  echo "Installing Apache Tomcat $TOMCAT_VER (ArcGIS 12.0 Web Adaptor requires jakarta.servlet)..."

  # Remove Ubuntu's system Tomcat 10 package if present to avoid port conflicts
  if dpkg -l tomcat10 2>/dev/null | grep -q '^ii'; then
    echo "Removing system Tomcat 10 package (using manual install instead)..."
    systemctl stop tomcat10 2>/dev/null || true
    systemctl disable tomcat10 2>/dev/null || true
    apt-get remove -y tomcat10 2>/dev/null || true
  fi

  # Create tomcat user
  id "$TOMCAT_USER" &>/dev/null || useradd -r -m -d "$TOMCAT_HOME" -s /bin/false "$TOMCAT_USER"

  # Download and extract
  TOMCAT_URL="https://archive.apache.org/dist/tomcat/tomcat-10/v${TOMCAT_VER}/bin/apache-tomcat-${TOMCAT_VER}.tar.gz"
  echo "Downloading from: $TOMCAT_URL"
  curl -fsSL "$TOMCAT_URL" -o /tmp/tomcat10.tar.gz
  mkdir -p "$TOMCAT_HOME"
  tar -xzf /tmp/tomcat10.tar.gz -C "$TOMCAT_HOME" --strip-components=1
  rm -f /tmp/tomcat10.tar.gz

  # Set ownership
  chown -R "$TOMCAT_USER:$TOMCAT_USER" "$TOMCAT_HOME"
  chmod +x "$TOMCAT_HOME"/bin/*.sh

  # Create systemd service
  cat > /etc/systemd/system/tomcat10.service <<EOF
[Unit]
Description=Apache Tomcat 10
After=network.target

[Service]
Type=forking
User=$TOMCAT_USER
Group=$TOMCAT_USER
Environment="JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))"
Environment="CATALINA_HOME=$TOMCAT_HOME"
Environment="CATALINA_BASE=$TOMCAT_HOME"
Environment="CATALINA_PID=$TOMCAT_HOME/temp/tomcat.pid"
ExecStart=$TOMCAT_HOME/bin/startup.sh
ExecStop=$TOMCAT_HOME/bin/shutdown.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable tomcat10
  systemctl start tomcat10
  echo "Tomcat 10 installed and started."
fi

echo "Using Tomcat 10 at: $TOMCAT_HOME"

# --------------------------------------------------------------------------------
# /etc/hosts hygiene
#
# ArcGIS Server warns (and can behave badly) if the hostname entry in /etc/hosts
# does not match the machine's primary IP. Also, for reverse-proxy deployments,
# we often need the public FQDN to resolve locally to 127.0.0.1 to avoid hairpin
# NAT problems during federation and other internal calls.
# --------------------------------------------------------------------------------

ensure_hostname_hosts_mapping() {
  local _host _fqdn _ip
  _host=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "")
  _fqdn=$(hostname -f 2>/dev/null || echo "${_host}")
  _ip=$(hostname -I 2>/dev/null | awk '{print $1}')

  [[ -z "${_host:-}" || -z "${_ip:-}" ]] && return 0

  # If the system isn't configured with an FQDN yet, synthesize one so the
  # /etc/hosts line matches Esri's required format: <IP> <FQDN> <Machine_name>.
  if [[ -z "${_fqdn:-}" || "${_fqdn}" == "${_host}" ]]; then
    _fqdn="${_host}.localdomain"
  fi

  # If already mapped correctly, do nothing.
  if grep -Eq "^${_ip}[[:space:]]+${_fqdn}[[:space:]]+${_host}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
    return 0
  fi

  echo "Fixing /etc/hosts: mapping hostname (${_host}/${_fqdn}) to ${_ip} ..."

  # Rebuild hosts file to ensure the correct mapping appears before any stale ones.
  # Keep localhost entries, drop any lines referencing the host/fqdn, then insert
  # the correct mapping near the top.
  local _tmp
  _tmp=$(mktemp)
  awk -v h="${_host}" -v f="${_fqdn}" -v ip="${_ip}" '
    BEGIN { inserted=0 }
    # Preserve the canonical localhost lines first
    /^127\.0\.0\.1[[:space:]]/ {
      print $0
      next
    }
    # Insert the correct hostname mapping once, right after localhost entries
    inserted==0 {
      print ip "  " f " " h
      inserted=1
    }
    # Drop any existing mappings for host/fqdn (to avoid Esri mismatch warning)
    $0 ~ ("(^|[[:space:]])" h "([[:space:]]|$)") { next }
    $0 ~ ("(^|[[:space:]])" f "([[:space:]]|$)") { next }
    { print $0 }
    END {
      if (inserted==0) {
        print ip "  " f " " h
      }
    }
  ' /etc/hosts > "${_tmp}"
  cat "${_tmp}" > /etc/hosts
  rm -f "${_tmp}"
}

ensure_domain_localhost_mapping() {
  # Ensure the public domain resolves to localhost for in-VM calls.
  if ! grep -Eq "^127\.0\.0\.1[[:space:]]+${DOMAIN}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
    echo "Adding 127.0.0.1 $DOMAIN to /etc/hosts for local resolution..."
    echo "127.0.0.1  $DOMAIN" >> /etc/hosts
  fi
}

ensure_hostname_hosts_mapping
ensure_domain_localhost_mapping

# ==============================================================================
# Step 2: SSL Certificates (Cloudflare DNS validation)
# ==============================================================================
echo ""
echo ">>> Step 2: Configuring SSL Certificates"
echo ""

mkdir -p /root/.secrets/certbot
cat > /root/.secrets/certbot/cloudflare.ini <<EOF
dns_cloudflare_api_token = $CF_API_TOKEN
EOF
chmod 600 /root/.secrets/certbot/cloudflare.ini

if [[ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
  certbot certonly --dns-cloudflare \
    --dns-cloudflare-credentials /root/.secrets/certbot/cloudflare.ini \
    -d "$DOMAIN" --agree-tos -m "$EMAIL" --non-interactive
else
  echo "SSL certificate already exists, skipping..."
fi

# ==============================================================================
# Step 3: NGINX Reverse Proxy
# ==============================================================================
echo ""
echo ">>> Step 3: Configuring NGINX Reverse Proxy"
echo ""

# Using a heredoc with variable expansion disabled ('NGINX_EOF') then sed for domain
cat > /etc/nginx/sites-available/arcgis <<'NGINX_EOF'
# WebSocket support map (required for Portal real-time features)
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name __DOMAIN__;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name __DOMAIN__;

    ssl_certificate     /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    client_max_body_size 100M;
    proxy_connect_timeout 600;
    proxy_send_timeout    600;
    proxy_read_timeout    600;

    # WebSocket support (conditional Connection header)
    proxy_http_version 1.1;
    proxy_set_header Upgrade    $http_upgrade;
    proxy_set_header Connection $connection_upgrade;

    # Portal — direct reverse proxy to Portal for ArcGIS (port 7443)
    # Rewrites /portal/* → /arcgis/* on the backend
    location = /portal {
        return 301 /portal/;
    }
    location /portal/ {
      proxy_pass https://127.0.0.1:7443/arcgis/;
        proxy_ssl_verify off;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_set_header X-Forwarded-Port  443;

        # Rewrite redirect Location headers from backend → public URL
        proxy_redirect https://127.0.0.1:7443/arcgis/ https://$host/portal/;
        proxy_redirect ~*https?://[^/]+(:7443)?/arcgis/ https://$host/portal/;
    }

    # /arcgis/ — Portal generates absolute URLs with /arcgis/ prefix in its
    # OAuth pages and static assets even when WebContextURL is set to /portal/.
    # Proxy these to Portal so sign-in assets (JS/CSS) load correctly.
    location /arcgis/ {
      proxy_pass https://127.0.0.1:7443/arcgis/;
        proxy_ssl_verify off;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_set_header X-Forwarded-Port  443;

      proxy_redirect https://127.0.0.1:7443/arcgis/ https://$host/arcgis/;
        proxy_redirect ~*https?://[^/]+(:7443)?/arcgis/ https://$host/arcgis/;
    }

    # Server — direct reverse proxy to ArcGIS Server (port 6443)
    # Rewrites /server/* → /arcgis/* on the backend
    location = /server {
        return 301 /server/;
    }
    location /server/ {
      proxy_pass https://127.0.0.1:6443/arcgis/;
        proxy_ssl_verify off;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_set_header X-Forwarded-Port  443;

        # Rewrite redirect Location headers from backend → public URL
        proxy_redirect https://127.0.0.1:6443/arcgis/ https://$host/server/;
        proxy_redirect ~*https?://[^/]+(:6443)?/arcgis/ https://$host/server/;
    }

    # Default — redirect to Portal home
    location = / {
        return 302 /portal/home/;
    }
}
NGINX_EOF

# Replace domain placeholder
sed -i "s/__DOMAIN__/$DOMAIN/g" /etc/nginx/sites-available/arcgis

ln -sf /etc/nginx/sites-available/arcgis /etc/nginx/sites-enabled/arcgis
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# Ensure the public domain resolves locally so Portal/Server can reach
# their own public URLs through NGINX (federation, OAuth callbacks, etc.)
if ! grep -q "$DOMAIN" /etc/hosts 2>/dev/null; then
  echo "127.0.0.1 $DOMAIN" >> /etc/hosts
  echo "Added $DOMAIN to /etc/hosts (loopback for local federation)."
fi

# ==============================================================================
# Step 4: ArcGIS User and System Configuration
# Ref: https://enterprise.arcgis.com/en/portal/12.0/install/linux/system-requirements-portal.htm
# Ref: https://enterprise.arcgis.com/en/server/12.0/install/linux/arcgis-server-system-requirements.htm
# ==============================================================================
echo ""
echo ">>> Step 4: Creating ArcGIS User and Configuring System"
echo ""

id "$ARCGIS_USER" &>/dev/null || useradd -m -s /bin/bash "$ARCGIS_USER"
mkdir -p "$ESRI_BASE"
mkdir -p "$ESRI_BASE/licenses"
chown -R "$ARCGIS_USER:$ARCGIS_USER" "$ESRI_BASE"

# Set system limits for arcgis user (required by Esri)
cat > /etc/security/limits.d/arcgis.conf <<EOF
$ARCGIS_USER soft nofile 65536
$ARCGIS_USER hard nofile 65536
$ARCGIS_USER soft nproc  25059
$ARCGIS_USER hard nproc  25059
EOF

# Set required kernel parameters
# vm.max_map_count — required by Portal for ArcGIS and ArcGIS Data Store
# vm.swappiness    — recommended by Esri for Data Store performance
cat > /etc/sysctl.d/99-arcgis.conf <<EOF
vm.max_map_count = 262144
vm.swappiness = 1
EOF
sysctl --system > /dev/null 2>&1

# ==============================================================================
# Step 5: Extract Installers
# ==============================================================================
echo ""
echo ">>> Step 5: Extracting Installers"
echo ""

EXTRACT_MARKER="$INSTALLERS/.extracted"
if [[ -f "$EXTRACT_MARKER" ]]; then
  echo "Installers already extracted (marker found), skipping..."
else
  cd "$INSTALLERS"
  for f in *.tar.gz; do
    if [[ -f "$f" ]]; then
      echo "Extracting $f..."
      tar -xzf "$f"
    fi
  done
  chown -R "$ARCGIS_USER:$ARCGIS_USER" "$INSTALLERS"

  # Delete archives after successful extraction to reclaim disk space
  # (Portal + Server + DataStore + WA archives can total 20+ GB)
  echo "Removing .tar.gz archives to free disk space..."
  rm -f "$INSTALLERS"/*.tar.gz
  touch "$EXTRACT_MARKER"
fi

# ==============================================================================
# Step 6: Install ArcGIS Server
# Per Esri docs: Install and authorize in one step using -a flag.
# This avoids the standalone authorizeSoftware, which requires -e email for .prvc.
# Ref: https://enterprise.arcgis.com/en/server/12.0/install/linux/silently-install-arcgis-server.htm
# ==============================================================================
echo ""
echo ">>> Step 6: Installing ArcGIS Server"
echo ""

SERVER_SETUP=$(find "$INSTALLERS" -maxdepth 2 -name "Setup" -path "*Server*" -type f 2>/dev/null | head -1)
if [[ -n "$SERVER_SETUP" && ! -d "$ESRI_BASE/arcgis/server" ]]; then
  SERVER_DIR=$(dirname "$SERVER_SETUP")
  echo "Found Server installer: $SERVER_DIR"
  cd "$SERVER_DIR"

  # Authorize during install with -a flag (recommended by Esri)
  if [[ -f "$SERVER_LICENSE_FILE" ]]; then
    echo "Installing and authorizing ArcGIS Server with: $SERVER_LICENSE_FILE"
    sudo -u "$ARCGIS_USER" ./Setup -m silent -l yes -a "$SERVER_LICENSE_FILE" -d "$ESRI_BASE"
  else
    echo "Installing ArcGIS Server without license (authorize manually later)..."
    sudo -u "$ARCGIS_USER" ./Setup -m silent -l yes -d "$ESRI_BASE"
  fi
elif [[ -d "$ESRI_BASE/arcgis/server" ]]; then
  echo "ArcGIS Server already installed, skipping..."
else
  echo "WARNING: ArcGIS Server installer not found in $INSTALLERS"
fi

# ==============================================================================
# Step 7: Install Portal for ArcGIS
# Ref: https://enterprise.arcgis.com/en/portal/12.0/install/linux/install-portal-for-arcgis.htm
# ==============================================================================
echo ""
echo ">>> Step 7: Installing Portal for ArcGIS"
echo ""

PORTAL_SETUP=$(find "$INSTALLERS" -maxdepth 2 -name "Setup" -path "*Portal*" -type f 2>/dev/null | head -1)
if [[ -n "$PORTAL_SETUP" && ! -d "$ESRI_BASE/arcgis/portal" ]]; then
  PORTAL_DIR=$(dirname "$PORTAL_SETUP")
  echo "Found Portal installer: $PORTAL_DIR"
  cd "$PORTAL_DIR"
  sudo -u "$ARCGIS_USER" ./Setup -m silent -l yes -d "$ESRI_BASE"
elif [[ -d "$ESRI_BASE/arcgis/portal" ]]; then
  echo "Portal for ArcGIS already installed, skipping..."
else
  echo "WARNING: Portal for ArcGIS installer not found in $INSTALLERS"
fi

# Install Portal Web Styles (3D symbols and styles for Scene Viewer)
# Must be installed after Portal for ArcGIS, into the same directory.
# Ref: https://enterprise.arcgis.com/en/portal/12.0/install/linux/install-portal-for-arcgis.htm
WS_SETUP=$(find "$INSTALLERS" -maxdepth 2 -name "Setup" -path "*Web_Styles*" -o -name "Setup" -path "*WebStyles*" 2>/dev/null | head -1)
if [[ -n "${WS_SETUP:-}" ]]; then
  WS_DIR=$(dirname "$WS_SETUP")
  echo "Installing Portal Web Styles from: $WS_DIR"
  cd "$WS_DIR"
  sudo -u "$ARCGIS_USER" ./Setup -m silent -l yes -d "$ESRI_BASE"
else
  echo "Portal Web Styles installer not found — skipping (optional)."
fi

# ==============================================================================
# Step 8: Install ArcGIS Data Store
# Ref: https://enterprise.arcgis.com/en/data-store/12.0/install/linux/install-arcgis-data-store.htm
# ==============================================================================
echo ""
echo ">>> Step 8: Installing ArcGIS Data Store"
echo ""

DS_SETUP=$(find "$INSTALLERS" -maxdepth 2 -name "Setup" -path "*DataStore*" -type f 2>/dev/null | head -1)
if [[ -n "$DS_SETUP" && ! -d "$ESRI_BASE/arcgis/datastore" ]]; then
  DS_DIR=$(dirname "$DS_SETUP")
  echo "Found Data Store installer: $DS_DIR"
  cd "$DS_DIR"
  sudo -u "$ARCGIS_USER" ./Setup -m silent -l yes -d "$ESRI_BASE"
elif [[ -d "$ESRI_BASE/arcgis/datastore" ]]; then
  echo "ArcGIS Data Store already installed, skipping..."
else
  echo "WARNING: ArcGIS Data Store installer not found in $INSTALLERS"
fi

# ==============================================================================
# Step 9: Install Web Adaptor and Deploy WARs to Tomcat
# Ref: https://enterprise.arcgis.com/en/web-adaptor/12.0/install/java-linux/install-arcgis-web-adaptor-java-linux.htm
# ==============================================================================
echo ""
echo ">>> Step 9: Installing Web Adaptor"
echo ""

WA_SETUP=$(find "$INSTALLERS" -maxdepth 2 -name "Setup" -path "*WebAdaptor*" -type f 2>/dev/null | head -1)
# Detect existing Web Adaptor install (versioned path, e.g., webadaptor12.0)
WA_HOME=$(find "$ESRI_BASE/arcgis" -maxdepth 1 -type d -name "webadaptor*" 2>/dev/null | head -1)
if [[ -n "$WA_SETUP" && -z "$WA_HOME" ]]; then
  WA_DIR=$(dirname "$WA_SETUP")
  echo "Found Web Adaptor installer: $WA_DIR"
  cd "$WA_DIR"
  sudo -u "$ARCGIS_USER" ./Setup -m silent -l yes -d "$ESRI_BASE"
  # Re-detect after install
  WA_HOME=$(find "$ESRI_BASE/arcgis" -maxdepth 1 -type d -name "webadaptor*" 2>/dev/null | head -1)
elif [[ -n "$WA_HOME" ]]; then
  echo "Web Adaptor already installed at $WA_HOME, skipping..."
else
  echo "WARNING: Web Adaptor installer not found in $INSTALLERS"
fi

# Deploy Web Adaptor WARs to Tomcat 10 (two instances: portal and server)
WA_WAR=$(find "$ESRI_BASE" -path "*/java/arcgis.war" -type f 2>/dev/null | head -1)
if [[ -n "$WA_WAR" && -f "$TOMCAT_WEBAPPS/portal.war" && -f "$TOMCAT_WEBAPPS/server.war" ]]; then
  echo "Web Adaptor WARs already deployed, skipping..."
elif [[ -n "$WA_WAR" ]]; then
  echo "Deploying Web Adaptor WARs to Tomcat 10 from: $WA_WAR"
  cp "$WA_WAR" "$TOMCAT_WEBAPPS/portal.war"
  cp "$WA_WAR" "$TOMCAT_WEBAPPS/server.war"
  chown "$TOMCAT_USER:$TOMCAT_USER" "$TOMCAT_WEBAPPS/portal.war"
  chown "$TOMCAT_USER:$TOMCAT_USER" "$TOMCAT_WEBAPPS/server.war"
  systemctl restart "$TOMCAT_SERVICE"
  sleep 15

  # Ensure tomcat user owns all exploded content and work directory
  for WA_CTX in portal server; do
    if [[ -d "$TOMCAT_WEBAPPS/$WA_CTX" ]]; then
      chown -R "$TOMCAT_USER:$TOMCAT_USER" "$TOMCAT_WEBAPPS/$WA_CTX"
    fi
  done
  mkdir -p "$TOMCAT_HOME/work"
  chown -R "$TOMCAT_USER:$TOMCAT_USER" "$TOMCAT_HOME/work"
fi

# Grant tomcat user access to WA config directory.
# The WAR reads/writes web_adaptor.properties from the Esri install location;
# tomcat needs group access via the arcgis group.
if [[ -n "${WA_HOME:-}" && -d "${WA_HOME:-}" ]]; then
  if ! id -nG "$TOMCAT_USER" 2>/dev/null | grep -qw "$ARCGIS_USER"; then
    echo "Adding $TOMCAT_USER to $ARCGIS_USER group for Web Adaptor config access..."
    usermod -aG "$ARCGIS_USER" "$TOMCAT_USER"
  fi
  chmod -R g+rwX "$WA_HOME/java"
  # Restart Tomcat so the new group membership takes effect
  systemctl restart "$TOMCAT_SERVICE"
  sleep 10
fi

# ==============================================================================
# Helper functions — defined here so Step 10 and onwards can use them
# ==============================================================================

format_host_for_url() {
  local h="$1"
  h="${h#[}"
  h="${h%]}"
  if [[ "$h" == *":"* ]]; then
    echo "[$h]"
  else
    echo "$h"
  fi
}

server_base() { echo "https://$(format_host_for_url "${SERVER_HOST}"):6443"; }
portal_base() { echo "https://$(format_host_for_url "${PORTAL_HOST}"):7443"; }
datastore_base() { echo "https://$(format_host_for_url "${DATASTORE_HOST}"):2443"; }

url_replace_host() {
  # url_replace_host URL NEW_HOST
  python3 - "$1" "$2" <<'PY'
import sys
from urllib.parse import urlsplit, urlunsplit

url = sys.argv[1]
new_host = sys.argv[2]
p = urlsplit(url)
netloc = p.netloc
port = ''

if netloc.startswith('['):
    if ']' in netloc:
        after = netloc.split(']', 1)[1]
        if after.startswith(':'):
            port = after[1:]
else:
    if ':' in netloc:
        _, port = netloc.rsplit(':', 1)

nh = new_host.strip().strip('[]')
if ':' in nh:
    nh = f'[{nh}]'
if port:
    nh = f'{nh}:{port}'

print(urlunsplit((p.scheme, nh, p.path, p.query, p.fragment)))
PY
}

url_extract_host() {
  # url_extract_host URL -> prints host without brackets
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlsplit
p = urlsplit(sys.argv[1])
netloc = p.netloc
if netloc.startswith('['):
    h = netloc.split(']')[0][1:]
else:
    h = netloc.rsplit(':', 1)[0] if ':' in netloc else netloc
print(h)
PY
}

url_extract_base() {
  # url_extract_base URL -> prints scheme://netloc
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlsplit
p = urlsplit(sys.argv[1])
print(f"{p.scheme}://{p.netloc}")
PY
}

get_local_host_candidates() {
  # get_local_host_candidates REQUESTED_HOST -> prints unique candidates, one per line
  local requested="${1:-}"
  local req="${requested#[}"
  req="${req%]}"

  local primary_ip
  primary_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || primary_ip=""

  local h_fqdn h_short h_any
  h_fqdn=$(hostname -f 2>/dev/null || true)
  h_short=$(hostname -s 2>/dev/null || true)
  h_any=$(hostname 2>/dev/null || true)

  local -a out
  out=()
  declare -A seen
  seen=()

  _add_host() {
    local h="$1"
    [[ -z "${h:-}" ]] && return 0
    h="${h#[}"
    h="${h%]}"
    if [[ -z "${seen[$h]+x}" ]]; then
      seen[$h]=1
      out+=("$h")
    fi
  }

  _add_host "$req"
  _add_host "127.0.0.1"
  _add_host "localhost"
  _add_host "::1"
  _add_host "127.0.1.1"
  _add_host "$h_fqdn"
  _add_host "$h_short"
  _add_host "$h_any"
  _add_host "$primary_ip"

  printf '%s\n' "${out[@]}"
}

# wait_for_service URL NAME [MAX_SECONDS] [HOST_VAR_NAME]
wait_for_service() {
  local url="$1"
  local name="$2"
  local max_wait="${3:-300}"  # default 5 minutes
  local host_var_name="${4:-}"
  local elapsed=0
  local -a _hosts _urls
  local _u _resp _req_host
  local _rc
  local _last_err=""
  local _last_rc=""
  local _last_url=""
  LAST_READY_URL=""; LAST_READY_HOST=""; LAST_READY_BASE=""

  _req_host=$(url_extract_host "$url" 2>/dev/null || true)
  mapfile -t _hosts < <(get_local_host_candidates "${_req_host:-}")

  _urls=()
  local _h
  for _h in "${_hosts[@]}"; do
    _u=$(url_replace_host "$url" "$_h" 2>/dev/null || true)
    [[ -n "${_u:-}" ]] && _urls+=("$_u")
  done

  echo "Waiting for $name to be ready at $url ..."
  while (( elapsed < max_wait )); do
    for _u in "${_urls[@]}"; do
      _resp=$("${CURL_BASE[@]}" "$_u" 2>&1); _rc=$?
      if (( _rc != 0 )); then
        _last_rc="${_rc}"
        _last_url="${_u}"
        # Keep only the last few lines; curl errors can be verbose.
        _last_err=$(echo "${_resp:-}" | tail -6)
        _resp=""
      fi
      if [[ -n "${_resp:-}" ]] && echo "$_resp" | grep -qiE '"status"[[:space:]]*:[[:space:]]*"success"|"currentVersion"|<html|arcgis'; then
        LAST_READY_URL="$_u"
        LAST_READY_HOST=$(url_extract_host "$_u" 2>/dev/null || true)
        LAST_READY_BASE=$(url_extract_base "$_u" 2>/dev/null || true)
        if [[ -n "${host_var_name:-}" && -n "${LAST_READY_HOST:-}" ]]; then
          printf -v "${host_var_name}" '%s' "${LAST_READY_HOST}"
        fi
        if [[ "${LAST_READY_URL:-}" != "${url:-}" ]]; then
          echo "  Using reachable endpoint: ${LAST_READY_URL}"
        fi
        echo "$name is ready."
        return 0
      fi
    done
    sleep 10
    elapsed=$((elapsed + 10))
    (( elapsed % 30 == 0 )) && echo "  ... still waiting ($elapsed s)"
  done
  echo "WARNING: $name did not respond within ${max_wait}s"
  if [[ -n "${_last_url:-}" ]]; then
    echo "  Last curl attempt: ${_last_url} (rc=${_last_rc:-?})" >&2
    [[ -n "${_last_err:-}" ]] && printf '  Last curl error:\n%s\n' "${_last_err}" >&2
  fi
  return 1
}

# Server needs up to 8 min on first start (site creation / fresh install).
# If the process is alive but port 6443 is not responding (broken init state
# from a prior failed run), force a stop/start cycle before giving up.
wait_for_server() {
  local rest_url
  rest_url="$(server_base)/arcgis/rest/info?f=json"

  # Wait up to 4 min for a clean start (also learns the reachable host)
  wait_for_service "${rest_url}" "ArcGIS Server" 240 SERVER_HOST && return 0

  # Still not up — the process may be running but stuck (broken security
  # init state). Force a restart.
  echo "  ArcGIS Server process is running but not responding — forcing restart..."
  sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/server/stopserver.sh" > /dev/null 2>&1 || true
  _sw=0
  while pgrep -u "$ARCGIS_USER" -f "arcgis/server" > /dev/null 2>&1; do
    (( _sw >= 60 )) && { pkill -9 -u "$ARCGIS_USER" -f "arcgis/server" 2>/dev/null || true; sleep 3; break; }
    sleep 5; _sw=$((_sw+5))
  done
  sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/server/startserver.sh" > /dev/null 2>&1 || true
  echo "  Restarted. Waiting up to 5 min for Server..."
  if wait_for_service "${rest_url}" "ArcGIS Server" 300 SERVER_HOST; then
    return 0
  fi

  # Diagnostics (best-effort) to help root-cause startup issues.
  set +e
  echo "  --- ArcGIS Server startup diagnostics ---" >&2
  echo "  Proxy environment (if any):" >&2
  env | grep -iE '^(http|https|no)_proxy=' >&2 || echo "  (no proxy env vars)" >&2
  if command -v ss >/dev/null 2>&1; then
    echo "  Listening sockets (6443/6080):" >&2
    ss -ltnp 2>/dev/null | grep -E ':(6443|6080)\b' >&2 || echo "  (no listeners on 6443/6080)" >&2
  fi
  if command -v curl >/dev/null 2>&1; then
    echo "  Curl verbose probe (bypassing proxies):" >&2
    curl -vk --noproxy '*' --connect-timeout 3 --max-time 10 "https://127.0.0.1:6443/arcgis/rest/info?f=json" -o /dev/null 2>&1 | tail -80 >&2 || true
    curl -vk --noproxy '*' --connect-timeout 3 --max-time 10 "https://[::1]:6443/arcgis/rest/info?f=json" -o /dev/null 2>&1 | tail -80 >&2 || true
  fi
  if command -v getent >/dev/null 2>&1; then
    echo "  Host resolution (getent hosts localhost/hostname):" >&2
    getent hosts localhost 2>/dev/null >&2 || true
    getent hosts "$(hostname -s 2>/dev/null || hostname 2>/dev/null)" 2>/dev/null >&2 || true
    getent hosts "$(hostname -f 2>/dev/null || hostname 2>/dev/null)" 2>/dev/null >&2 || true
  fi
  command -v systemctl >/dev/null 2>&1 && systemctl status arcgisserver --no-pager -l 2>/dev/null | tail -120 >&2 || true
  command -v journalctl >/dev/null 2>&1 && journalctl -u arcgisserver --no-pager -n 120 2>/dev/null >&2 || true

  local _slog_dir _slog
  _slog_dir="$ESRI_BASE/arcgis/server/usr/logs"
  if [[ -d "${_slog_dir}" ]]; then
    _slog=$(find "${_slog_dir}" -type f \( -name "*.log" -o -name "*.log.*" \) ! -name "*.lck" 2>/dev/null | sort | tail -1)
    if [[ -n "${_slog:-}" && -f "${_slog}" ]]; then
      echo "  Latest Server log: ${_slog}" >&2
      tail -250 "${_slog}" 2>/dev/null | grep -i "error\|exception\|fatal\|warn\|bind\|port" | tail -120 >&2 || true
    fi
  fi
  echo "  --- End diagnostics ---" >&2
  set -e
  return 1
}

# ---------------------------------------------------------------------------
# Helper: wait for ArcGIS Data Store admin to be ready.
# Prefer the explicit healthCheck endpoint when available.
# ---------------------------------------------------------------------------
wait_for_datastore_admin() {
  local max_wait="${1:-600}"
  local elapsed=0
  local _resp _h
  local -a _hosts
  mapfile -t _hosts < <(get_local_host_candidates "${DATASTORE_HOST}")

  echo "Waiting for ArcGIS Data Store (admin) to be ready at $(datastore_base)/arcgis/datastoreadmin/healthCheck?f=json ..."
  while (( elapsed < max_wait )); do
    for _h in "${_hosts[@]}"; do
      # Some ArcGIS Data Store builds do NOT expose datastoreadmin/healthCheck.
      # Treat 404 as "endpoint not available" and fall back to other probes.
      _resp=$("${CURL_BASE[@]}" "https://$(format_host_for_url "${_h}"):2443/arcgis/datastoreadmin/healthCheck?f=json" 2>/dev/null) || _resp=""
      if echo "${_resp}" | grep -qi '"status"[[:space:]]*:[[:space:]]*"success"'; then
        DATASTORE_HOST="${_h}"
        echo "ArcGIS Data Store (admin) is ready."
        return 0
      fi

      # Probe the admin root as JSON (common REST pattern).
      _resp=$("${CURL_BASE[@]}" "https://$(format_host_for_url "${_h}"):2443/arcgis/datastoreadmin/?f=json" 2>/dev/null) || _resp=""
      if echo "${_resp}" | grep -qiE '"currentVersion"|"release"|"build"|"machineName"|"status"'; then
        DATASTORE_HOST="${_h}"
        echo "ArcGIS Data Store (admin) is responding."
        return 0
      fi

      # Last-resort probe: at least the web app responds with HTML.
      _resp=$("${CURL_BASE[@]}" "https://$(format_host_for_url "${_h}"):2443/arcgis/datastoreadmin/" 2>/dev/null) || _resp=""
      if echo "${_resp}" | grep -qiE 'datastoreadmin|arcgis data store|generate token'; then
        DATASTORE_HOST="${_h}"
        echo "ArcGIS Data Store (admin) is responding (HTML)."
        return 0
      fi
    done

    sleep 10
    elapsed=$((elapsed + 10))
    (( elapsed % 30 == 0 )) && echo "  ... still waiting (${elapsed} s)"
  done
  echo "WARNING: ArcGIS Data Store (admin) did not respond within ${max_wait}s"
  return 1
}

restart_datastore() {
  echo "Restarting ArcGIS Data Store..."
  if [[ -f "$ESRI_BASE/arcgis/datastore/stopdatastore.sh" ]]; then
    sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/datastore/stopdatastore.sh" > /dev/null 2>&1 || true
  fi
  local _sw=0
  while pgrep -u "$ARCGIS_USER" -f "arcgis/datastore" > /dev/null 2>&1; do
    (( _sw >= 120 )) && { pkill -9 -u "$ARCGIS_USER" -f "arcgis/datastore" 2>/dev/null || true; sleep 3; break; }
    sleep 5; _sw=$((_sw+5))
  done
  if [[ -f "$ESRI_BASE/arcgis/datastore/startdatastore.sh" ]]; then
    sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/datastore/startdatastore.sh" > /dev/null 2>&1 || true
  fi
  # Data Store admin can take several minutes after restart.
  wait_for_datastore_admin 900 || true
}

datastore_admin_diagnose() {
  set +e
  echo "  --- Data Store diagnostics ---" >&2
  echo "  Admin healthCheck (may 404 on some builds):" >&2
  "${CURL_BASE[@]}" "$(datastore_base)/arcgis/datastoreadmin/healthCheck?f=json" 2>&1 | tail -60 >&2
  echo "" >&2
  echo "  Admin root JSON probe:" >&2
  "${CURL_BASE[@]}" "$(datastore_base)/arcgis/datastoreadmin/?f=json" 2>&1 | tail -60 >&2
  echo "" >&2

  local _log_dir _latest _lck
  _log_dir="$ESRI_BASE/arcgis/datastore/usr/arcgisdatastore/logs"
  if [[ -d "${_log_dir}" ]]; then
    # Prefer real log files; ignore lock files (*.lck).
    _latest=$(find "${_log_dir}" -type f \( -name "*.log" -o -name "*.log.*" \) ! -name "*.lck" 2>/dev/null | sort | tail -1)
    if [[ -z "${_latest:-}" ]]; then
      # If only .lck exists, try the same path without the .lck suffix.
      _lck=$(find "${_log_dir}" -type f -name "*.lck" 2>/dev/null | sort | tail -1)
      [[ -n "${_lck:-}" ]] && _latest="${_lck%.lck}"
    fi
    if [[ -n "${_latest:-}" && -f "${_latest}" ]]; then
      echo "  Latest log: ${_latest}" >&2
      tail -200 "${_latest}" 2>/dev/null | grep -i "error\|exception\|warn\|fatal" | tail -60 >&2 || true
    fi
  fi
  echo "  --- End Data Store diagnostics ---" >&2
  set -e
}

# ---------------------------------------------------------------------------
# Helper: generate a Portal admin token
# ---------------------------------------------------------------------------
generate_portal_token() {
  local _resp _token

  # Try portaladmin/generateToken first (admin-scoped), then sharing/rest as fallback.
  # Use client=referer for robustness against IP changes/NAT loopbacks.
  local _h _ep
  local -a _hosts
  mapfile -t _hosts < <(get_local_host_candidates "${PORTAL_HOST}")
  for _h in "${_hosts[@]}"; do
    for _ep in \
      "https://$(format_host_for_url "${_h}"):7443/arcgis/portaladmin/generateToken" \
      "https://$(format_host_for_url "${_h}"):7443/arcgis/sharing/rest/generateToken"; do
    _resp=$("${CURL_BASE[@]}" --post301 --post302 -L -X POST "${_ep}" \
      -H "Referer: https://localhost:7443/arcgis" \
      -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" \
      -d "client=referer" -d "referer=https://localhost:7443/arcgis" \
      -d "expiration=120" -d "f=json" 2>/dev/null) || _resp=""
    _token=$(echo "$_resp" | python3 -c "
import sys,json
try:
  t=json.load(sys.stdin).get('token','')
  print(t if t else '')
except: pass" 2>/dev/null) || _token=""
    if [[ -n "$_token" && "$_token" != "None" ]]; then
      PORTAL_HOST="${_h}"
      echo "$_token"
      return 0
    fi
    done
  done

  echo "DEBUG: Portal generateToken last response: $_resp" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Helper: generate a Server admin token
# ---------------------------------------------------------------------------
generate_server_token() {
  local _resp _token
  # Use client=referer to avoid IP mismatches (e.g. 127.0.0.1 vs ::1)
  local _h _ep
  local -a _hosts
  mapfile -t _hosts < <(get_local_host_candidates "${SERVER_HOST}")
  for _h in "${_hosts[@]}"; do
    _ep="https://$(format_host_for_url "${_h}"):6443/arcgis/admin/generateToken"
    _resp=$("${CURL_BASE[@]}" -X POST "${_ep}" \
      -H "Referer: https://localhost:6443/arcgis/admin" \
      -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" \
      -d "client=referer" -d "referer=https://localhost:6443/arcgis/admin" \
      -d "expiration=60" \
      -d "f=json" 2>/dev/null) || _resp=""
    _token=$(echo "$_resp" | python3 -c "import sys,json; t=json.load(sys.stdin).get('token',''); print(t if t else '')" 2>/dev/null) || _token=""
    if [[ -n "$_token" && "$_token" != "None" ]]; then
      SERVER_HOST="${_h}"
      echo "$_token"
      return 0
    fi
  done
  echo "DEBUG: Server generateToken response: $_resp" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Helper: determine the best Server host name for Data Store registration.
#
# Using 127.0.0.1 can lead to TLS/SAN mismatches or subtle registration issues
# in some environments. Prefer the Server's own machineName from /admin/machines
# (which matches its internal identity), then fall back to hostname -f.
# ---------------------------------------------------------------------------
get_server_host_for_datastore() {
  local _tok _resp _name
  _tok=$(generate_server_token 2>/dev/null) || _tok=""
  if [[ -n "${_tok:-}" ]]; then
    _resp=$("${CURL_BASE[@]}" -H "Referer: https://localhost:6443/arcgis/admin" \
      "$(server_base)/arcgis/admin/machines?f=json&token=${_tok}" 2>/dev/null) || _resp=""
    _name=$(echo "${_resp:-}" | python3 -c "
import sys, json
try:
  data=json.load(sys.stdin)
  m=(data.get('machines') or [])
  if not m:
    print('')
  else:
    # machineName is typically a hostname (sometimes includes domain)
    print((m[0].get('machineName') or '').strip())
except Exception:
  print('')
" 2>/dev/null) || _name=""
    if [[ -n "${_name:-}" && "${_name:-}" != "None" ]]; then
      echo "${_name}"
      return 0
    fi
  fi

  _name=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "")
  [[ -n "${_name:-}" ]] && { echo "${_name}"; return 0; }
  return 1
}

# ==============================================================================
# Step 10: Start ArcGIS Services
# ==============================================================================
echo ""
echo ">>> Step 10: Starting ArcGIS Services"
echo ""

# Only start services that are not already running
if [[ -f "$ESRI_BASE/arcgis/server/startserver.sh" ]]; then
  if pgrep -u "$ARCGIS_USER" -f "arcgis/server" > /dev/null 2>&1; then
    echo "ArcGIS Server already running, skipping start."
  else
    echo "Starting ArcGIS Server..."
    sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/server/startserver.sh" || true
    # Server takes 3-5 min on first boot after site creation; wait here so
    # createsite (Step 11) doesn't immediately fail.
    wait_for_server || true
  fi
fi

if [[ -f "$ESRI_BASE/arcgis/portal/startportal.sh" ]]; then
  if pgrep -u "$ARCGIS_USER" -f "arcgis/portal" > /dev/null 2>&1; then
    echo "Portal for ArcGIS already running, skipping start."
  else
    echo "Starting Portal for ArcGIS..."
    sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/portal/startportal.sh" || true
    sleep 60
  fi
fi

if [[ -f "$ESRI_BASE/arcgis/datastore/startdatastore.sh" ]]; then
  if pgrep -u "$ARCGIS_USER" -f "arcgis/datastore" > /dev/null 2>&1; then
    echo "ArcGIS Data Store already running, skipping start."
  else
    echo "Starting ArcGIS Data Store..."
    sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/datastore/startdatastore.sh" || true
    sleep 30
  fi
fi

# Confirm services are ready before proceeding to site creation
# (Server was already waited on in Step 10 if it was just started;
#  these calls return immediately if the service is already up.)
wait_for_server || true
wait_for_service "$(portal_base)/arcgis/portaladmin/healthCheck?f=json" "Portal for ArcGIS" 300 PORTAL_HOST || true

# ==============================================================================
# Step 11: Create ArcGIS Server Site
# Per Esri docs: Server must be authorized BEFORE site creation.
# Authorization was done during install (Step 6) via the -a flag.
# Uses Esri's createsite.sh CLI tool when available, REST API as fallback.
# Ref: https://enterprise.arcgis.com/en/server/12.0/install/linux/silently-install-arcgis-server.htm
# ==============================================================================
echo ""
echo ">>> Step 11: Creating ArcGIS Server Site"
echo ""

CREATESITE_TOOL="$ESRI_BASE/arcgis/server/tools/createsite/createsite.sh"
SERVER_ADMIN_URL="$(server_base)/arcgis/admin"

# Config-store and directories can be overridden (and persisted) via .env.
# When we recreate the Server site, we will allocate fresh empty folders.
SERVER_CS="${SERVER_CONFIG_STORE:-$ESRI_BASE/arcgis/server/usr/config-store}"
SERVER_DIRS="${SERVER_DIRECTORIES:-$ESRI_BASE/arcgis/server/usr/directories}"
SERVER_SITE_RECREATED=0

# ---------------------------------------------------------------------------
# Helper: test if Server admin is TRULY healthy.
# Three-layer probe:
#   1. /admin/info returns currentVersion  (site exists)
#   2. generate_server_token returns a token (auth layer responds)
#   3. /admin/security/config with that token returns valid config
#      — this is the call that fails with "SecurityConfig null" when the
#      security subsystem is broken. /admin/info and even generateToken can
#      succeed in the broken state; /admin/security/config does not.
# ---------------------------------------------------------------------------
server_admin_is_healthy() {
  local _info _tok _sec

  # On a secured site, /admin/info can return 499 without a token.
  # Always generate a token first, then validate /admin/info using it.
  _tok=$(generate_server_token 2>/dev/null) || return 1
  [[ -n "$_tok" ]] || return 1

  _info=$("${CURL_BASE[@]}" -H "Referer: https://localhost:6443/arcgis/admin" \
    "$SERVER_ADMIN_URL/info?f=json&token=$_tok" 2>/dev/null) || return 1
  echo "$_info" | grep -qiE '"currentVersion"|"currentversion"' || return 1

  # /admin/security/config must return a valid config (not an error).
  # A broken SecurityConfig causes this endpoint to return {"error": ...}.
  _sec=$("${CURL_BASE[@]}" -H "Referer: https://localhost:6443/arcgis/admin" \
    "$SERVER_ADMIN_URL/security/config?f=json&token=$_tok" 2>/dev/null) || return 1
  echo "$_sec" | grep -q '"error"' && return 1
  # Must contain authenticationTier or allowedAdminAccessIPs — any real key
  echo "$_sec" | grep -qE '"authenticationTier"|"allowedAdminAccessIPs"|"virtualDirsSecurityEnabled"' || return 1
  return 0
}

server_site_exists() {
  local _rest _info

  # Prefer the unauthenticated REST probe if available.
  _rest=$("${CURL_BASE[@]}" "$(server_base)/arcgis/rest/info?f=json" 2>/dev/null) || _rest=""
  echo "$_rest" | grep -qiE '"currentVersion"|"currentversion"' && return 0

  # Admin endpoint may require a token and respond with 499 if missing;
  # that still indicates the admin endpoint is alive and the site exists.
  _info=$("${CURL_BASE[@]}" -H "Referer: https://localhost:6443/arcgis/admin" \
    "$SERVER_ADMIN_URL/info?f=json" 2>/dev/null) || _info=""
  echo "$_info" | grep -qiE '"currentVersion"|"currentversion"' && return 0
  echo "$_info" | grep -q '"code"\s*:\s*499' && return 0
  return 1
}

server_admin_diagnose() {
  # This is called on failure paths; don't let set -e abort before printing.
  set +e

  _curl_diag() {
    local _label="$1"; shift
    local _out _rc
    _out=$("$@" 2>&1); _rc=$?
    echo "  ${_label} (curl rc=${_rc})" >&2
    if [[ -n "${_out:-}" ]]; then
      echo "${_out}" >&2
    else
      echo "  (no output)" >&2
    fi
    echo "" >&2
  }

  echo "  --- Server admin diagnostics ---" >&2
  _curl_diag "/admin/info (no token)" "${CURL_BASE[@]}" \
    -H "Referer: https://localhost:6443/arcgis/admin" \
    "$SERVER_ADMIN_URL/info?f=json"

  _curl_diag "generateToken" "${CURL_BASE[@]}" -X POST \
    "$(server_base)/arcgis/admin/generateToken" \
    -H "Referer: https://localhost:6443/arcgis/admin" \
    -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" \
    -d "client=referer" -d "referer=https://localhost:6443/arcgis/admin" \
    -d "expiration=60" -d "f=json"

  local _tok
  _tok=$(generate_server_token 2>/dev/null) || _tok=""
  if [[ -n "${_tok:-}" ]]; then
    _curl_diag "/admin/info (with token)" "${CURL_BASE[@]}" \
      -H "Referer: https://localhost:6443/arcgis/admin" \
      "$SERVER_ADMIN_URL/info?f=json&token=$_tok"
  fi
  echo "  /admin/security/config (token present: $([[ -n "${_tok:-}" ]] && echo yes || echo no))" >&2
  if [[ -n "${_tok:-}" ]]; then
    _curl_diag "/admin/security/config" "${CURL_BASE[@]}" \
      -H "Referer: https://localhost:6443/arcgis/admin" \
      "$SERVER_ADMIN_URL/security/config?f=json&token=$_tok"
  fi
  echo "  --- End diagnostics ---" >&2

  set -e
}

# ---------------------------------------------------------------------------
# Wipe the config-store so createsite.sh starts from a clean slate.
# Called when admin is known-broken regardless of whether /admin/info works.
# ---------------------------------------------------------------------------
wipe_server_config_store() {
  local _cs_path="$1"
  local _dirs_path="$2"

  echo "  Stopping Server to wipe config-store..."
  sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/server/stopserver.sh" > /dev/null 2>&1 || true
  local _sw=0
  while pgrep -u "$ARCGIS_USER" -f "arcgis/server" > /dev/null 2>&1; do
    (( _sw >= 90 )) && { pkill -9 -u "$ARCGIS_USER" -f "arcgis/server" 2>/dev/null || true; sleep 3; break; }
    sleep 5; _sw=$((_sw+5))
  done

  # Wipe Config Store
  if [[ -d "$_cs_path" ]]; then
    # Use find -delete to safely remove dotfiles without touching '.'/'..'.
    find "$_cs_path" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    echo "  Config-store wiped."
  fi
  mkdir -p "$_cs_path"
  chown -R "$ARCGIS_USER:$ARCGIS_USER" "$_cs_path"

  # Wipe Server Directories (critical for clean createsite)
  if [[ -d "$_dirs_path" ]]; then
    find "$_dirs_path" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    echo "  Server directories wiped."
  fi
  mkdir -p "$_dirs_path"
  chown -R "$ARCGIS_USER:$ARCGIS_USER" "$_dirs_path"

  echo "  Starting Server with fresh config-store and directories..."
  sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/server/startserver.sh" > /dev/null 2>&1 || true
  # Wait for REST endpoint, which is what createsite.sh checks internally.
  # /admin/info may not respond on a fresh (no-site) Server instance.
  wait_for_server || echo "  WARNING: Server did not come up within expected time after wipe."
}


create_server_site() {
  # create_server_site DO_WIPE(0|1)
  local do_wipe="${1:-0}"

  if (( do_wipe == 1 )); then
    echo "  Server site exists but admin remains unhealthy — wiping config-store to force fresh recreation."
    SERVER_SITE_RECREATED=1
    wipe_server_config_store "$SERVER_CS" "$SERVER_DIRS"
    # wipe_server_config_store restarts Server; re-learn the reachable host.
    wait_for_server || true
    SERVER_ADMIN_URL="$(server_base)/arcgis/admin"
  else
    echo "  No existing Server site detected — creating a new site..."
  fi

  # Allocate fresh empty folders for createsite so it never reuses stale content.
  # This avoids createsite.sh failing with:
  #   "configuration store location provided contains files that may be from a different version"
  _ts=$(date +%s)
  SERVER_CS="$ESRI_BASE/arcgis/server/usr/config-store.site.$_ts"
  SERVER_DIRS="$ESRI_BASE/arcgis/server/usr/directories.site.$_ts"
  mkdir -p "$SERVER_CS" "$SERVER_DIRS"
  chown -R "$ARCGIS_USER:$ARCGIS_USER" "$SERVER_CS" "$SERVER_DIRS"
  upsert_env_var SERVER_CONFIG_STORE "$SERVER_CS"
  upsert_env_var SERVER_DIRECTORIES "$SERVER_DIRS"
  echo "  Using fresh Server config-store: $SERVER_CS"
  echo "  Using fresh Server directories:  $SERVER_DIRS"

  # Give Server a moment to finish starting before createsite.
  sleep 20

  # Now create (or recreate) the site.
  _cs_rc=0
  if [[ -f "$CREATESITE_TOOL" ]]; then
    echo "Creating ArcGIS Server site using createsite.sh..."
    chmod +x "$CREATESITE_TOOL"
    _cs_out=$(sudo -u "$ARCGIS_USER" "$CREATESITE_TOOL" \
      -u "$ADMIN_USER" \
      -p "$ADMIN_PASS" \
      -d "$SERVER_DIRS" \
      -c "$SERVER_CS" 2>&1) || _cs_rc=$?
    echo "$_cs_out"
    if (( _cs_rc != 0 )); then
      echo "  WARNING: createsite.sh exited with code $_cs_rc — will still wait for health check."
    fi
  else
    echo "Creating ArcGIS Server site via REST API..."
    "${CURL_BASE[@]}" -X POST "$SERVER_ADMIN_URL/createNewSite" \
      -d "username=$ADMIN_USER" \
      -d "password=$ADMIN_PASS" \
      -d "configStoreConnection={\"connectionString\":\"$SERVER_CS\",\"type\":\"FILESYSTEM\"}" \
      -d "directories={\"directories\":[{\"name\":\"arcgiscache\",\"physicalPath\":\"$ESRI_BASE/arcgis/server/usr/directories/arcgiscache\",\"directoryType\":\"CACHE\"},{\"name\":\"arcgisjobs\",\"physicalPath\":\"$ESRI_BASE/arcgis/server/usr/directories/arcgisjobs\",\"directoryType\":\"JOBS\"},{\"name\":\"arcgisoutput\",\"physicalPath\":\"$ESRI_BASE/arcgis/server/usr/directories/arcgisoutput\",\"directoryType\":\"OUTPUT\"},{\"name\":\"arcgissystem\",\"physicalPath\":\"$ESRI_BASE/arcgis/server/usr/directories/arcgissystem\",\"directoryType\":\"SYSTEM\"}]}" \
      -d "f=json" || true
  fi

  # Wait for admin to be fully operational (token generation must succeed)
  echo "  Waiting for Server admin to be fully ready after site creation..."
  _elapsed=0
  while (( _elapsed < 900 )); do
    if server_admin_is_healthy; then
      echo "  Server admin is healthy."
      break
    fi
    sleep 15; _elapsed=$((_elapsed + 15))
    if (( _elapsed % 60 == 0 )); then
      _rest_probe=$("${CURL_BASE[@]}" "$(server_base)/arcgis/rest/info?f=json" 2>/dev/null || true)
      _tok_probe=$(generate_server_token 2>/dev/null || true)
      _rest_ok=no
      echo "${_rest_probe:-}" | grep -qiE '"currentVersion"|"currentversion"' && _rest_ok=ok
      echo "  ... still waiting for Server admin (${_elapsed}s) [rest=${_rest_ok} token=$([[ -n "${_tok_probe:-}" ]] && echo ok || echo no)]"
    fi
  done
  if ! server_admin_is_healthy; then
    echo "  ERROR: Server admin did not become healthy within 900s. Check Server logs." >&2
    server_admin_diagnose
    echo "  Aborting next steps because the Server site is not usable (Data Store + federation will fail)." >&2
    exit 1
  fi
}

# Determine Server state and act accordingly:
#   Healthy  = /admin/info + token generation both succeed → skip
#   Unhealthy site exists → wait; then wipe+recreate
#   No site yet → create

if ! wait_for_server; then
  echo "ERROR: ArcGIS Server REST endpoint is not reachable on any local address. Cannot create site." >&2
  echo "       Fix ArcGIS Server startup/binding first, then rerun." >&2
  exit 1
fi
SERVER_ADMIN_URL="$(server_base)/arcgis/admin"

if server_admin_is_healthy; then
  echo "ArcGIS Server site exists and admin is healthy, skipping..."
else
  if server_site_exists; then
    echo "  Server site exists but admin is not fully healthy yet — waiting before taking destructive action..."
    _elapsed=0
    while (( _elapsed < 900 )); do
      if server_admin_is_healthy; then
        echo "  Server admin is healthy."
        break
      fi
      sleep 15; _elapsed=$((_elapsed + 15))
      (( _elapsed % 60 == 0 )) && echo "  ... still waiting for Server admin (${_elapsed}s)"
    done

    if ! server_admin_is_healthy; then
      create_server_site 1
    fi
  else
    create_server_site 0
  fi
fi

# ==============================================================================
# Step 12: Create Portal
# Per Esri docs: Portal 12.0 requires the JSON license file during creation.
# The license file authorizes user types and apps.
# Ref: https://enterprise.arcgis.com/en/portal/12.0/install/linux/create-a-single-machine-portal.htm
# ==============================================================================
echo ""
echo ">>> Step 12: Creating Portal"
echo ""

PORTAL_ADMIN_URL="$(portal_base)/arcgis/portaladmin"
PORTAL_INFO=$(${CURL_BASE[@]} "$PORTAL_ADMIN_URL?f=json" 2>/dev/null || echo "")
if echo "$PORTAL_INFO" | grep -q "currentVersion"; then
  echo "Portal already configured, skipping..."
else
  echo "Creating Portal site..."
  cd "$ESRI_BASE/arcgis/portal/tools/createportal"

  # Build command array
  PORTAL_CMD=(./createportal.sh
    -fn "$ADMIN_FIRST_NAME"
    -ln "$ADMIN_LAST_NAME"
    -u  "$ADMIN_USER"
    -p  "$ADMIN_PASS"
    -e  "$EMAIL"
    -qi "$ADMIN_SECURITY_QUESTION"
    -qa "$ADMIN_SECURITY_ANSWER"
    -d  "$ESRI_BASE/arcgis/portal/usr/arcgisportal"
  )

  # Per Esri docs: import the JSON license file during portal creation with -lf
  if [[ -f "$PORTAL_LICENSE_FILE" ]]; then
    echo "Using license file: $PORTAL_LICENSE_FILE"
    PORTAL_CMD+=(-lf "$PORTAL_LICENSE_FILE")
  else
    echo "WARNING: No Portal license file provided."
    echo "Portal will be created without a license — import it manually via Portal Admin."
  fi

  sudo -u "$ARCGIS_USER" "${PORTAL_CMD[@]}" || true
  sleep 60
fi

# ==============================================================================
# Step 13: Configure Reverse Proxy Integration
# NGINX proxies directly to Portal (7443) and Server (6443) — no Web Adaptor
# WAR in the request path.  We set WebContextURL so each component generates
# correct public-facing URLs.
# Ref: https://enterprise.arcgis.com/en/portal/12.0/administer/linux/using-a-reverse-proxy-server-with-portal-for-arcgis.htm
# Ref: https://enterprise.arcgis.com/en/server/12.0/administer/linux/using-a-reverse-proxy-server-with-arcgis-server.htm
# ==============================================================================
echo ""
echo ">>> Step 13: Configuring Reverse Proxy Integration"
echo ""

# Import the Let's Encrypt INTERMEDIATE CA into all Java truststores.
#
# IMPORTANT — import chain.pem (the intermediate CA), NOT fullchain.pem.
# fullchain.pem starts with the leaf/domain cert which changes every 90 days.
# chain.pem contains only the CA intermediate(s) which are stable for years.
# Importing the intermediate means any renewed leaf cert signed by the same CA
# is automatically trusted — no truststore update needed on renewal.
#
# On renewal certbot replaces the symlinks; NGINX reloads via the deploy hook
# installed below. Java truststores need no action unless Let's Encrypt rotates
# to a new intermediate (rare — they announce it months in advance).
# ---------------------------------------------------------------------------
LE_CHAIN="/etc/letsencrypt/live/$DOMAIN/chain.pem"   # intermediate CA only
LE_ALIAS="letsencrypt-intermediate"                   # stable alias, not domain-specific
if [[ -f "$LE_CHAIN" ]]; then
  echo "Importing Let's Encrypt intermediate CA into all Java truststores..."
  # Get fingerprint of the current intermediate so we can detect CA rotation
  _NEW_FP=$(openssl x509 -in "$LE_CHAIN" -fingerprint -sha256 -noout 2>/dev/null | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]') || _NEW_FP=""

  while IFS= read -r CACERTS_FILE; do
    KEYTOOL_BIN=$(dirname "$CACERTS_FILE")/../bin/keytool
    [[ ! -x "$KEYTOOL_BIN" ]] && KEYTOOL_BIN="keytool"

    # Check if the SAME intermediate is already present (compare fingerprint)
    _CUR_FP=$("$KEYTOOL_BIN" -list -keystore "$CACERTS_FILE" -storepass changeit \
      -alias "$LE_ALIAS" -v 2>/dev/null \
      | grep -i 'SHA-256\|SHA256' | head -1 \
      | grep -oP '[0-9A-Fa-f:]{95}' | tr -d ':' | tr '[:upper:]' '[:lower:]') || _CUR_FP=""

    if [[ -n "$_NEW_FP" && "$_CUR_FP" == "$_NEW_FP" ]]; then
      echo "  Already imported: $CACERTS_FILE"
    else
      # Remove stale entry (different intermediate or missing) then re-import
      "$KEYTOOL_BIN" -delete -keystore "$CACERTS_FILE" -storepass changeit \
        -alias "$LE_ALIAS" > /dev/null 2>&1 || true
      echo "  Importing into: $CACERTS_FILE"
      "$KEYTOOL_BIN" -importcert -trustcacerts -keystore "$CACERTS_FILE" \
        -storepass changeit -alias "$LE_ALIAS" \
        -file "$LE_CHAIN" -noprompt 2>/dev/null || true
    fi
  done < <(find /opt/esri /usr/lib/jvm /etc/ssl -name "cacerts" -type f 2>/dev/null | sort -u)
fi

# ---------------------------------------------------------------------------
# Install a certbot deploy hook so NGINX reloads automatically after every
# renewal. Java truststores don't need updating unless the CA intermediate
# changes (handled above on the next install.sh run).
# ---------------------------------------------------------------------------
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK_EOF'
#!/bin/bash
# Reload NGINX to pick up the renewed certificate.
systemctl reload nginx || systemctl restart nginx
HOOK_EOF
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
echo "  Certbot deploy hook installed: /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh"

# If ArcGIS binds to a non-127.0.0.1 local address (common when hostname is
# mapped to the primary IP), update the reverse-proxy upstreams so NGINX can
# reach Portal/Server reliably.
if [[ -f "/etc/nginx/sites-available/arcgis" ]]; then
  _PORTAL_UP="https://$(format_host_for_url "${PORTAL_HOST}"):7443"
  _SERVER_UP="https://$(format_host_for_url "${SERVER_HOST}"):6443"
  python3 - "$_PORTAL_UP" "$_SERVER_UP" <<'PY'
import sys

portal_up = sys.argv[1]
server_up = sys.argv[2]
path = '/etc/nginx/sites-available/arcgis'

with open(path, 'r', encoding='utf-8') as f:
    txt = f.read()

txt2 = txt.replace('https://127.0.0.1:7443', portal_up)
txt2 = txt2.replace('https://127.0.0.1:6443', server_up)

if txt2 != txt:
    with open(path, 'w', encoding='utf-8') as f:
        f.write(txt2)
PY

  nginx -t && systemctl reload nginx
fi

# ==============================================================================
# Step 14: Federate Server with Portal
#
# Esri-documented order for a reverse-proxy / cloud deployment:
#   1. Set Server WebContextURL (so Server self-references the public URL)
#   2. Federate — use the REVERSE PROXY URL as adminUrl so Portal uses the
#      trusted Let's Encrypt cert rather than Server's self-signed cert on
#      port 6443. Esri docs explicitly state: "if your ArcGIS Server is
#      hosted in a cloud environment, use the Web Adaptor or load balancer
#      URL in this field instead."
#   3. Promote federated server to Hosting Server role.
#   4. Set Portal WebContextURL / privatePortalURL (Step 16).
#
# Ref: https://enterprise.arcgis.com/en/portal/12.0/administer/linux/federate-an-arcgis-server-site-with-your-portal.htm
# Ref: https://enterprise.arcgis.com/en/server/12.0/deploy/linux/using-a-reverse-proxy-server-with-arcgis-server.htm
# ==============================================================================
echo ""
echo ">>> Step 14: Federating Server with Portal"
echo ""

wait_for_service "$(portal_base)/arcgis/portaladmin/healthCheck?f=json" "Portal" 300 PORTAL_HOST || true
PORTAL_ADMIN_URL="$(portal_base)/arcgis/portaladmin"

# Check if already federated — idempotency gate
PREV_TOKEN=$(generate_portal_token 2>/dev/null) || PREV_TOKEN=""
EXISTING_FEDERATION=""
if [[ -n "${PREV_TOKEN:-}" ]]; then
  EXISTING_FEDERATION=$("${CURL_BASE[@]}" \
    -H "Referer: https://localhost:7443/arcgis" \
    "${PORTAL_ADMIN_URL}/federation/servers?f=json&token=$PREV_TOKEN" \
    2>/dev/null) || EXISTING_FEDERATION=""
fi

HAS_FEDERATION=0
if echo "$EXISTING_FEDERATION" | python3 -c \
    "import sys,json; s=json.load(sys.stdin).get('servers',[]); exit(0 if s else 1)" 2>/dev/null; then
  HAS_FEDERATION=1
fi

# If Portal thinks a server is federated, validate it. Stale federation commonly
# shows up as "Could not decrypt token" when validating server sites.
FEDERATION_VALID=1
VALIDATE_JSON=""
if (( HAS_FEDERATION == 1 )); then
  _val_tok="$PREV_TOKEN"
  [[ -z "${_val_tok:-}" ]] && _val_tok=$(generate_portal_token 2>/dev/null) || true
  if [[ -n "${_val_tok:-}" ]]; then
    # Try POST validate (preferred), then GET validate as a fallback.
    VALIDATE_JSON=$("${CURL_BASE[@]}" --max-time 180 -X POST \
      -H "Referer: https://localhost:7443/arcgis" \
      "${PORTAL_ADMIN_URL}/federation/servers/validate" \
      -d "token=${_val_tok}" -d "f=json" 2>/dev/null) || VALIDATE_JSON=""
    # Some Portal builds return HTML 405 for POST validate. If the response is not
    # valid JSON, treat it as empty so we fall back to GET.
    if [[ -n "${VALIDATE_JSON:-}" ]]; then
      if ! echo "${VALIDATE_JSON:-}" | python3 -c "import sys,json; json.load(sys.stdin)" >/dev/null 2>&1; then
        VALIDATE_JSON=""
      fi
    fi
    if [[ -z "${VALIDATE_JSON:-}" ]]; then
      VALIDATE_JSON=$("${CURL_BASE[@]}" --max-time 180 \
        -H "Referer: https://localhost:7443/arcgis" \
        "${PORTAL_ADMIN_URL}/federation/servers/validate?token=${_val_tok}&f=json" \
        2>/dev/null) || VALIDATE_JSON=""
    fi

    # JSON-aware validation: treat any issuesFound/status=error/decrypt-token as invalid.
    # If validate returns an error, treat as invalid unless clearly unsupported/not found.
    if echo "${VALIDATE_JSON:-}" | python3 -c "
import sys, json

raw = sys.stdin.read() or ''
raw_l = raw.lower()

def has_decrypt(s: str) -> bool:
  s = s.lower()
  return ('decrypt token' in s) or ('could not decrypt' in s)

try:
  data = json.loads(raw)
except Exception:
  # Unknown/garbled response: treat as invalid so we don't silently skip.
  sys.exit(2)

err = data.get('error')
if err:
  msg = str(err.get('message') or '')
  # Unsupported validate endpoint -> allow skip
  unsupported = any(x in msg.lower() for x in ['not found','unsupported','does not exist'])
  if unsupported:
    sys.exit(0)
  # Any other error -> invalid
  sys.exit(1)

if has_decrypt(raw_l):
  sys.exit(1)

# If the response doesn't contain any of the expected fields, it's not a
# meaningful validation result; treat as unknown so we force re-federation.
if not any(k in data for k in ['servers','results','issuesFound','status']):
  sys.exit(2)

# Common shapes:
# - {'status':'success','issuesFound':false,...}
# - {'servers':[{'issuesFound':true,'messages':[...]}]}
if str(data.get('status','')).lower() == 'error':
  sys.exit(1)
if data.get('issuesFound') is True:
  sys.exit(1)

servers = data.get('servers') or data.get('results') or []
if isinstance(servers, list):
  for s in servers:
    if not isinstance(s, dict):
      continue
    if s.get('issuesFound') is True:
      sys.exit(1)
    if str(s.get('status','')).lower() == 'error':
      sys.exit(1)
    msgs = s.get('messages') or s.get('message') or ''
    if isinstance(msgs, list):
      if any(has_decrypt(str(m)) for m in msgs):
        sys.exit(1)
    else:
      if has_decrypt(str(msgs)):
        sys.exit(1)

sys.exit(0)
"; then
      FEDERATION_VALID=1
    else
      FEDERATION_VALID=0
    fi
  fi
fi

if (( HAS_FEDERATION == 1 && SERVER_SITE_RECREATED == 0 && FEDERATION_VALID == 1 )); then
  echo "Server is already federated with Portal (validated), skipping..."
else
  if (( HAS_FEDERATION == 1 )); then
    if (( SERVER_SITE_RECREATED == 1 )); then
      echo "Server was recreated in Step 11 — existing federation is stale. Unfederating then re-federating..."
    else
      echo "Existing federation appears unhealthy/stale — unfederating then re-federating..."
      [[ -n "${VALIDATE_JSON:-}" ]] && echo "  Validate result: ${VALIDATE_JSON}"
    fi
    TOKEN_UNFED=$(generate_portal_token 2>/dev/null) || TOKEN_UNFED=""
    if [[ -n "${TOKEN_UNFED:-}" ]]; then
      # Unfederate all existing federated servers (single-machine base deployment expects one).
      echo "$EXISTING_FEDERATION" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for s in data.get('servers', []):
    sid = s.get('id')
    if sid:
        print(sid)
" | while read -r sid; do
        [[ -z "${sid:-}" ]] && continue
        echo "  Unfederating server id: $sid"
        "${CURL_BASE[@]}" --max-time 300 -X POST \
          -H "Referer: https://localhost:7443/arcgis" \
          "${PORTAL_ADMIN_URL}/federation/servers/$sid/unfederate" \
          -d "token=$TOKEN_UNFED" -d "f=json" 2>/dev/null || true
      done
    else
      echo "WARNING: Could not get Portal token to unfederate. Proceeding to attempt federation anyway."
    fi
  fi

  TOKEN=$(generate_portal_token 2>/dev/null) || TOKEN=""

  if [[ -z "${TOKEN:-}" ]]; then
    echo "WARNING: Could not get Portal token. Federation must be done manually."
    echo "See: https://enterprise.arcgis.com/en/portal/12.0/administer/linux/federate-an-arcgis-server-site-with-your-portal.htm"
  else

    # ------------------------------------------------------------------
    # Step 14a: Set Server WebContextURL (pre-federation)
    # ------------------------------------------------------------------
    # DISABLED: Setting WebContextURL before federation causes ClassCastException 
    # (JSONObject cannot be cast to String) during federation on 11.x/12.x in 
    # some environments. We will set WebContextURL in Step 16 (post-federation).
    
    # SERVER_TOKEN_FED=$(generate_server_token 2>/dev/null) || SERVER_TOKEN_FED=""
    # if [[ -n "$SERVER_TOKEN_FED" ]]; then
    #   echo "  Setting Server WebContextURL = https://$DOMAIN/server (pre-federation)..."
    #   _WCU_RESULT=$(curl -sk -X POST \
    #     "https://localhost:6443/arcgis/admin/system/properties/update" \
    #     -d "properties={\"WebContextURL\":\"https://$DOMAIN/server\"}" \
    #     -d "token=$SERVER_TOKEN_FED" \
    #     -d "f=json" 2>/dev/null) || _WCU_RESULT=""
    #   echo "  Server WebContextURL result: $_WCU_RESULT"
    # else
    #   echo "  WARNING: Cannot get Server token to set WebContextURL — continuing anyway."
    # fi

    # ------------------------------------------------------------------
    # Step 14c: Federate.
    #
    # We use the public URL for both 'url' and 'adminUrl', assuming local
    # DNS resolution (via /etc/hosts) routes this to localhost/127.0.0.1.
    # This avoids ClassCastException issues caused by protocol mismatches
    # or unexpected URL patterns (e.g. using localhost directly).
    # ------------------------------------------------------------------
    echo "  Services URL: https://$DOMAIN/server"
    echo "  Admin URL:    https://$DOMAIN/server"

    # Refresh the Portal token immediately before calling federate.
    TOKEN=$(generate_portal_token 2>/dev/null) || TOKEN=""
    FEDERATE_RESULT=""
    if [[ -z "${TOKEN:-}" ]]; then
      echo "ERROR: Could not refresh Portal token before federation. Aborting."
    else

    FEDERATE_RESULT=$("${CURL_BASE[@]}" --max-time 300 -X POST \
      "${PORTAL_ADMIN_URL}/federation/servers/federate" \
      -H "Referer: https://localhost:7443/arcgis" \
      -d "url=https://$DOMAIN/server" \
      -d "adminUrl=https://$DOMAIN/server" \
      -d "username=$ADMIN_USER" \
      -d "password=$ADMIN_PASS" \
      -d "token=$TOKEN" \
      -d "f=json" 2>/dev/null) || FEDERATE_RESULT=""
    echo "Federation result: $FEDERATE_RESULT"

    fi  # token refresh check

    if echo "$FEDERATE_RESULT" | grep -q '"error"'; then
      echo "ERROR: Federation failed. See output above."
      echo "You can federate manually: Portal Admin → Organization → Settings → Servers → Add server"
      echo "  Services URL: https://$DOMAIN/server"
      echo "  Admin URL:    https://$DOMAIN/server"
      # Print recent Server logs to help diagnose
      _SERVER_LOG_DIR=$(find "$ESRI_BASE/arcgis/server/usr/logs" -maxdepth 3 \
        -type d -name "server" 2>/dev/null | head -1) || _SERVER_LOG_DIR=""
      if [[ -n "$_SERVER_LOG_DIR" ]]; then
        echo ""
        echo "  --- Recent ArcGIS Server log entries ---"
        ls -t "$_SERVER_LOG_DIR"/*.log 2>/dev/null | head -1 \
          | xargs -r tail -200 2>/dev/null \
          | grep -i "error\|exception\|federation\|security\|warn" | tail -40 || true
        echo "  --- End Server log ---"
      fi
    else
      echo "  Federation successful."
      sleep 10
      echo "  Federation successful. (Hosting server role will be set after Data Store registration in Step 15.)"
    fi

  fi  # TOKEN check
fi  # EXISTING_FEDERATION check

# ==============================================================================
# Step 15: Configure Data Store
# Per Esri docs: Base deployment requires BOTH a relational data store AND an
# object store as of ArcGIS Enterprise 12.0.
# DataStore is registered AFTER federation (Esri's documented order).
# Ref: https://enterprise.arcgis.com/en/get-started/12.0/linux/base-arcgis-enterprise-deployment.htm
# Ref: https://enterprise.arcgis.com/en/data-store/12.0/install/linux/create-data-store.htm
# ==============================================================================
echo ""
echo ">>> Step 15: Configuring Data Store"
echo ""

if [[ -d "$ESRI_BASE/arcgis/datastore/tools" ]]; then
  cd "$ESRI_BASE/arcgis/datastore/tools"

  # Data Store can take a while to initialize its admin endpoint after startup.
  # If it's not responsive, restart once before attempting configuration.
  if ! wait_for_datastore_admin 900; then
    restart_datastore
  fi
  if ! wait_for_datastore_admin 180; then
    echo "ERROR: ArcGIS Data Store admin endpoint is not responding; cannot safely configure stores." >&2
    datastore_admin_diagnose
    exit 1
  fi

  # Describe existing stores once for idempotency checks.
  DS_DESCRIBE=""
  if [[ -x ./describedatastore.sh ]]; then
    DS_DESCRIBE=$(sudo -u "$ARCGIS_USER" ./describedatastore.sh 2>/dev/null || true)
  fi

  datastore_store_already_configured() {
    # Returns 0 if the given store appears configured/started already.
    # This avoids calling configuredatastore.sh on an already-initialized store
    # (which can return opaque errors like "Method argument cannot be null").
    local _store="$1"
    # NOTE: Do not use a heredoc with python '-' here; '-' consumes stdin for the
    # script itself, which would discard the describedatastore text.
    printf "%s" "${DS_DESCRIBE:-}" | python3 -c '
import re, sys
store = sys.argv[1] if len(sys.argv) > 1 else ""
txt = sys.stdin.read() or ""

def block(start_pat, end_pat=None):
  m = re.search(start_pat, txt, flags=re.M)
  if not m:
    return ""
  s = txt[m.start():]
  if end_pat:
    m2 = re.search(end_pat, s, flags=re.M)
    if m2:
      s = s[:m2.start()]
  return s

if store == "relational":
  sec = block(r"^Information for relational data store\b.*$", r"^Information for object store\b")
  if not sec:
    sys.exit(1)
  status = re.search(r"^Data store status\.+\s*(\S+)\s*$", sec, flags=re.M)
  owning = re.search(r"^Owning system URL\.+\s*(.+)\s*$", sec, flags=re.M)
  status_val = (status.group(1).strip() if status else "").lower()
  owning_val = (owning.group(1).strip() if owning else "").strip().strip("\"")
  sys.exit(0 if (status_val == "started" and owning_val) else 1)

if store == "object":
  sec = block(r"^Information for object store\b.*$")
  if not sec:
    sys.exit(1)
  owning = re.search(r"^Owning system URL\.+\s*(.+)\s*$", sec, flags=re.M)
  owning_val = (owning.group(1).strip() if owning else "").strip().strip("\"")
  sys.exit(0 if owning_val else 1)

sys.exit(1)
' "${_store}"
  }

  configure_datastore_store() {
    local _store="$1"
    local _attempt _out _rc
    local _hosting_ref

    # Build an ordered list of Server refs to try.
    # Per Esri docs, configuredatastore.sh expects a GIS Server machine name
    # or URL in the format https://host:6443 (do not include /arcgis or /admin).
    local _h1 _h2
    local -a _refs
    local -a _uniq
    local _r _seen

    _h1=$(get_server_host_for_datastore 2>/dev/null) || _h1=""
    _h2=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "")

    _add_variants() {
      local h="$1"
      [[ -z "${h:-}" || "${h:-}" == "None" ]] && return 0
      # host-only
      _refs+=("${h}")
      # host:6443
      _refs+=("${h}:6443")
      # https://host:6443
      _refs+=("https://${h}:6443")
    }

    _add_variants "${_h1}"
    _add_variants "${_h2}"
    _add_variants "localhost"
    _add_variants "127.0.0.1"

    # De-duplicate while preserving order
    for _r in "${_refs[@]}"; do
      _seen=0
      for _hosting_ref in "${_uniq[@]}"; do
        [[ "${_hosting_ref}" == "${_r}" ]] && { _seen=1; break; }
      done
      (( _seen == 0 )) && _uniq+=("${_r}")
    done

    for _attempt in 1 2 3; do
      echo "Configuring ${_store} store (attempt ${_attempt}/3)..."

      # Ensure Data Store admin is up before each attempt.
      wait_for_datastore_admin 600 || restart_datastore

      local _restarted_this_attempt=0

      for _hosting_ref in "${_uniq[@]}"; do
        echo "  Trying GIS Server reference: ${_hosting_ref}"
        _rc=0
        _out=$(sudo -u "$ARCGIS_USER" ./configuredatastore.sh \
          "${_hosting_ref}" \
          "$ADMIN_USER" \
          "$ADMIN_PASS" \
          "$ESRI_BASE/arcgis/datastore/usr/arcgisdatastore" \
          --stores "${_store}" --prompt no 2>&1) || _rc=$?
        echo "${_out}"

        # Success / idempotency patterns
        (( _rc == 0 )) && return 0
        echo "${_out}" | grep -qi "already registered\|already configured\|already been configured\|already exists" && return 0

        # If Data Store returns the common null-arg error, treat it as a transient
        # admin/API readiness issue; restart Data Store once and continue.
        if echo "${_out}" | grep -qi "Method argument cannot be null"; then
          if (( _restarted_this_attempt == 0 )); then
            echo "  Detected Data Store admin error (null argument). Restarting Data Store before retry..."
            restart_datastore
            _restarted_this_attempt=1
          fi
        fi
      done

      if (( _attempt < 3 )); then
        echo "WARNING: ${_store} store configuration failed (attempt ${_attempt}). Retrying in 90s..."
        sleep 90
      fi
    done
    return 1
  }

  reregister_datastore_store() {
    # For already-configured stores, use Esri's registerdatastore.sh to refresh
    # registration with the hosting GIS Server site. This is safer than
    # re-running configuredatastore.sh (which can fail with null-argument).
    local _store="$1"
    local _h1 _h2
    local -a _hosts _urls _uniq
    local _u _seen _rc _out

    [[ -x ./registerdatastore.sh ]] || return 1

    _h1=$(get_server_host_for_datastore 2>/dev/null) || _h1=""
    _h2=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "")

    _hosts=("${_h1}" "${_h2}" "${DOMAIN}" "localhost" "127.0.0.1")
    for h in "${_hosts[@]}"; do
      [[ -z "${h:-}" || "${h:-}" == "None" ]] && continue
      # registerdatastore expects https://host:6443 (no /arcgis, no /admin)
      _urls+=("https://${h}:6443")
    done

    # De-duplicate while preserving order
    for _u in "${_urls[@]}"; do
      _seen=0
      for x in "${_uniq[@]}"; do
        [[ "${x}" == "${_u}" ]] && { _seen=1; break; }
      done
      (( _seen == 0 )) && _uniq+=("${_u}")
    done

    for _u in "${_uniq[@]}"; do
      echo "  Re-registering ${_store} store using Server URL: ${_u}"
      _rc=0
      _out=$(sudo -u "$ARCGIS_USER" ./registerdatastore.sh \
        "${_u}" \
        "$ADMIN_USER" \
        "$ADMIN_PASS" \
        --stores "${_store}" --prompt no 2>&1) || _rc=$?
      echo "${_out}"
      (( _rc == 0 )) && return 0
      echo "${_out}" | grep -qi "already registered\|already.*registered" && return 0
    done
    return 1
  }

  # IMPORTANT:
  # A Server site may have been recreated in Step 11 (config-store wipe + createsite).
  # In that case, Data Store must be re-registered with the *new* Server site.
  # describedatastore.sh output can be misleading for this purpose, so we attempt
  # registration idempotently and tolerate "already registered" output.
  DS_REL_OK=0
  DS_OBJ_OK=0
  REL_SKIPPED_CONFIGURED=0
  OBJ_SKIPPED_CONFIGURED=0

  echo "Registering relational data store with Server (idempotent)..."
  if datastore_store_already_configured relational; then
    echo "Relational data store already configured (per describedatastore), skipping configuration."
    REL_SKIPPED_CONFIGURED=1
  else
    if ! configure_datastore_store relational; then
      DS_REL_OK=1
      echo "ERROR: Relational data store registration failed after retries."
    fi
  fi
  sleep 10

  echo "Registering object store with Server (idempotent)..."
  if datastore_store_already_configured object; then
    echo "Object store already configured (per describedatastore), skipping configuration."
    OBJ_SKIPPED_CONFIGURED=1
  else
    if ! configure_datastore_store object; then
      DS_OBJ_OK=1
      echo "ERROR: Object store registration failed after retries."
    fi
  fi

  if (( DS_REL_OK != 0 || DS_OBJ_OK != 0 )); then
    if [[ -x ./describedatastore.sh ]]; then
      echo ""
      echo "--- describedatastore.sh output (for troubleshooting) ---"
      sudo -u "$ARCGIS_USER" ./describedatastore.sh 2>/dev/null || true
      echo "--- end describedatastore.sh output ---"
    fi
    echo "ERROR: Data Store configuration incomplete; aborting (hosting server promotion and reverse-proxy updates depend on a healthy relational + object store)." >&2
    exit 1
  fi

  # After Data Store registration, promote the federated Server to Hosting Server.
  # Portal validation requires a managed database (ArcGIS Data Store) registered.
  if (( DS_REL_OK == 0 && DS_OBJ_OK == 0 )); then
    PORTAL_TOKEN_HOSTING=$(generate_portal_token 2>/dev/null) || PORTAL_TOKEN_HOSTING=""
    if [[ -n "${PORTAL_TOKEN_HOSTING:-}" ]]; then
      PORTAL_ADMIN_URL="$(portal_base)/arcgis/portaladmin"
      SERVERS_JSON=$("${CURL_BASE[@]}" \
        -H "Referer: https://localhost:7443/arcgis" \
        "${PORTAL_ADMIN_URL}/federation/servers?f=json&token=$PORTAL_TOKEN_HOSTING" \
        2>/dev/null) || SERVERS_JSON=""

      FEDERATED_SERVER_ID=$(echo "$SERVERS_JSON" | python3 -c "
import sys,json
data=json.load(sys.stdin)
target='https://%s/server' % '${DOMAIN}'
for s in data.get('servers',[]):
    if s.get('url','') == target or s.get('adminUrl','') == target:
        print(s.get('id',''))
        break
" 2>/dev/null) || FEDERATED_SERVER_ID=""

      if [[ -n "${FEDERATED_SERVER_ID:-}" ]]; then
        echo "Setting federated Server as hosting server..."
        HOSTING_RESULT=$("${CURL_BASE[@]}" -X POST \
          -H "Referer: https://localhost:7443/arcgis" \
          "${PORTAL_ADMIN_URL}/federation/servers/$FEDERATED_SERVER_ID/update" \
          -d "serverRole=HOSTING_SERVER" \
          -d "token=$PORTAL_TOKEN_HOSTING" \
          -d "f=json" 2>/dev/null) || HOSTING_RESULT=""
        echo "  Hosting server result: $HOSTING_RESULT"

        if echo "${HOSTING_RESULT:-}" | grep -q '"error"'; then
          # If the role update fails and we skipped relational as "already configured",
          # prefer Esri's registerdatastore (re-register) and only fall back to
          # configuredatastore if needed.
          if (( REL_SKIPPED_CONFIGURED == 1 )); then
            if echo "${HOSTING_RESULT:-}" | grep -qi "requires the ArcGIS Server has an ArcGIS Data Store registered as a managed database"; then
              echo "WARNING: Hosting server role update failed; attempting relational store re-registration then retry..." >&2
              if reregister_datastore_store relational; then
                sleep 15
                PORTAL_TOKEN_HOSTING=$(generate_portal_token 2>/dev/null) || PORTAL_TOKEN_HOSTING=""
                if [[ -n "${PORTAL_TOKEN_HOSTING:-}" ]]; then
                  HOSTING_RESULT=$("${CURL_BASE[@]}" -X POST \
                    -H "Referer: https://localhost:7443/arcgis" \
                    "${PORTAL_ADMIN_URL}/federation/servers/$FEDERATED_SERVER_ID/update" \
                    -d "serverRole=HOSTING_SERVER" \
                    -d "token=$PORTAL_TOKEN_HOSTING" \
                    -d "f=json" 2>/dev/null) || HOSTING_RESULT=""
                  echo "  Hosting server retry result: $HOSTING_RESULT"
                fi
              fi
            fi

            if echo "${HOSTING_RESULT:-}" | grep -q '"error"'; then
              echo "WARNING: Hosting server role still failing; attempting one-time relational store reconfiguration then retry..." >&2
              if configure_datastore_store relational; then
                PORTAL_TOKEN_HOSTING=$(generate_portal_token 2>/dev/null) || PORTAL_TOKEN_HOSTING=""
                if [[ -n "${PORTAL_TOKEN_HOSTING:-}" ]]; then
                  HOSTING_RESULT=$("${CURL_BASE[@]}" -X POST \
                    -H "Referer: https://localhost:7443/arcgis" \
                    "${PORTAL_ADMIN_URL}/federation/servers/$FEDERATED_SERVER_ID/update" \
                    -d "serverRole=HOSTING_SERVER" \
                    -d "token=$PORTAL_TOKEN_HOSTING" \
                    -d "f=json" 2>/dev/null) || HOSTING_RESULT=""
                  echo "  Hosting server retry result: $HOSTING_RESULT"
                fi
              fi
            fi
          fi

          if echo "${HOSTING_RESULT:-}" | grep -q '"error"'; then
            echo "ERROR: Failed to set hosting server role. Data Store may not be registered correctly." >&2
            exit 1
          fi
        fi
      else
        echo "WARNING: Could not find federated server ID to set as hosting."
      fi

      # Post-step validation: surface federation issues immediately.
      echo "Validating federated server sites..."
      _VAL_JSON=$("${CURL_BASE[@]}" --max-time 180 \
        -H "Referer: https://localhost:7443/arcgis" \
        "${PORTAL_ADMIN_URL}/federation/servers/validate?token=$PORTAL_TOKEN_HOSTING&f=json" \
        2>/dev/null) || _VAL_JSON=""
      if echo "${_VAL_JSON:-}" | grep -qiE "decrypt token|could not decrypt|\"issuesFound\"[[:space:]]*:[[:space:]]*true|\"status\"[[:space:]]*:[[:space:]]*\"error\""; then
        echo "WARNING: Federation validation reports issues. Review Portal → Organization → Settings → Servers." >&2
        echo "  Validate result: ${_VAL_JSON}" >&2
      else
        # If validate isn't supported, it may return an error object; don't fail.
        if [[ -n "${_VAL_JSON:-}" ]]; then
          echo "  Validation result: ${_VAL_JSON}"
        fi
      fi
    else
      echo "WARNING: Could not get Portal token to set hosting server role."
    fi
  fi
else
  echo "ERROR: Data Store tools directory not found."
fi

# ==============================================================================
# Step 16: Configure Reverse Proxy Properties (post-federation)
# Must be done AFTER federation and DataStore registration so Portal and Server
# communicate using their native internal URLs during the federation handshake.
# ==============================================================================
echo ""
echo ">>> Step 16: Configuring Reverse Proxy Properties"
echo ""

# --- 16a: Portal WebContextURL + privatePortalURL ---
# These were set in Step 14 before federation. This step verifies/re-applies
# them in case Step 14 was skipped (already federated) or failed to set them.
PORTAL_TOKEN=$(generate_portal_token 2>/dev/null) || PORTAL_TOKEN=""
if [[ -n "$PORTAL_TOKEN" ]]; then
  PORTAL_INTERNAL_HOST=$(hostname -f 2>/dev/null || echo "localhost")
  PORTAL_ADMIN_URL="$(portal_base)/arcgis/portaladmin"

  # Check current properties to avoid unnecessary restart
  CURRENT_PROPS=$("${CURL_BASE[@]}" \
    -H "Referer: https://localhost:7443/arcgis" \
    "${PORTAL_ADMIN_URL}/system/properties?f=json&token=$PORTAL_TOKEN" \
    2>/dev/null) || CURRENT_PROPS=""
  CURRENT_WCU=$(echo "$CURRENT_PROPS" | python3 -c \
    "import sys,json; p=json.load(sys.stdin); print(p.get('WebContextURL',''))" 2>/dev/null) || CURRENT_WCU=""

  if [[ "$CURRENT_WCU" == "https://$DOMAIN/portal" ]]; then
    echo "  Portal WebContextURL already set to https://$DOMAIN/portal, skipping."
  else
    echo "  Setting Portal WebContextURL = https://$DOMAIN/portal"
    echo "  Setting Portal privatePortalURL = https://$PORTAL_INTERNAL_HOST:7443/arcgis"
    CTX_RESULT=$("${CURL_BASE[@]}" -X POST \
      "${PORTAL_ADMIN_URL}/system/properties/update" \
      -H "Referer: https://localhost:7443/arcgis" \
      --data-urlencode "properties={\"WebContextURL\":\"https://$DOMAIN/portal\",\"privatePortalURL\":\"https://$PORTAL_INTERNAL_HOST:7443/arcgis\"}" \
      -d "token=$PORTAL_TOKEN" \
      -d "f=json" 2>/dev/null) || CTX_RESULT=""
    echo "  Result: $CTX_RESULT"
    if echo "$CTX_RESULT" | grep -q '"error"'; then
      echo "  WARNING: Failed to set Portal properties."
    else
      echo "  Portal reverse proxy properties configured."
      echo "  Waiting for Portal to restart..."
      sleep 30
      wait_for_service "$(portal_base)/arcgis/portaladmin/healthCheck?f=json" "Portal" 300 PORTAL_HOST || true
    fi
  fi
else
  echo "WARNING: Could not get Portal token. Set WebContextURL manually."
fi

# --- 16b: Server WebContextURL ---
echo ""
echo "Setting Server WebContextURL to https://$DOMAIN/server ..."
SRV_TOK=$(generate_server_token 2>/dev/null) || SRV_TOK=""
if [[ -n "$SRV_TOK" ]]; then
  CTX_RESULT=$("${CURL_BASE[@]}" -X POST \
    "$(server_base)/arcgis/admin/system/properties/update" \
    -H "Referer: https://localhost:6443/arcgis/admin" \
    --data-urlencode "properties={\"WebContextURL\":\"https://$DOMAIN/server\"}" \
    -d "token=$SRV_TOK" -d "f=json" 2>/dev/null) || CTX_RESULT=""
  echo "  Result: $CTX_RESULT"
  if echo "$CTX_RESULT" | grep -q '"error"'; then
    echo "  WARNING: Failed to set Server WebContextURL."
  else
    echo "  Server WebContextURL configured."
  fi
else
  echo "  WARNING: Could not get Server token. Set WebContextURL manually."
fi

# --- 16c: Update federation services URL to public reverse-proxy URL ---
PORTAL_TOKEN=$(generate_portal_token 2>/dev/null) || PORTAL_TOKEN=""
if [[ -n "$PORTAL_TOKEN" ]]; then
  PORTAL_ADMIN_URL="$(portal_base)/arcgis/portaladmin"
  SERVERS_JSON=$("${CURL_BASE[@]}" \
    -H "Referer: https://localhost:7443/arcgis" \
    "${PORTAL_ADMIN_URL}/federation/servers?f=json&token=$PORTAL_TOKEN" \
    2>/dev/null) || SERVERS_JSON=""
  FED_ID=$(echo "$SERVERS_JSON" | python3 -c "
import sys,json
data=json.load(sys.stdin)
for s in data.get('servers',[]):
    print(s.get('id','')); break" 2>/dev/null) || FED_ID=""
  FED_ADMIN=$(echo "$SERVERS_JSON" | python3 -c "
import sys,json
data=json.load(sys.stdin)
for s in data.get('servers',[]):
    print(s.get('adminUrl','')); break" 2>/dev/null) || FED_ADMIN=""

  if [[ -n "$FED_ID" ]]; then
    echo ""
    echo "Updating federation services URL to https://$DOMAIN/server ..."
    UPD_RESULT=$("${CURL_BASE[@]}" -X POST \
      "${PORTAL_ADMIN_URL}/federation/servers/$FED_ID/update" \
      -H "Referer: https://localhost:7443/arcgis" \
      -d "url=https://$DOMAIN/server" \
      -d "adminUrl=$FED_ADMIN" \
      -d "token=$PORTAL_TOKEN" \
      -d "f=json" 2>/dev/null) || UPD_RESULT=""
    echo "  Result: $UPD_RESULT"
  else
    echo "WARNING: No federated server found to update URL."
  fi
else
  echo "WARNING: Could not get Portal token for federation URL update."
fi

# ==============================================================================
# Complete
# ==============================================================================
echo ""
echo "=============================================="
echo " Installation Complete!"
echo "=============================================="
echo ""
echo "Access your ArcGIS Enterprise deployment:"
echo ""
echo "  Portal Home:    https://$DOMAIN/portal/home"
echo "  Portal Admin:   https://$DOMAIN:7443/arcgis/portaladmin"
echo "  Server REST:    https://$DOMAIN/server/rest/services"
echo "  Server Admin:   https://$DOMAIN:6443/arcgis/admin"
echo ""
echo "Admin credentials:"
echo "  Username: $ADMIN_USER"
echo "  Password: (stored in .env)"
echo ""
echo "Configuration saved to: $ENV_FILE"
echo ""
