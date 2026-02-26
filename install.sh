#!/usr/bin/env bash
set -euo pipefail

# Curl defaults can prefer IPv6 for localhost (::1). ArcGIS Server on some
# installs listens only on IPv4, which makes curl appear to "return nothing".
# Use IPv4 + timeouts for reliability in health checks and admin calls.
CURL_BASE=(curl -4 -skS --connect-timeout 5 --max-time 30)

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
ESRI_BASE="/opt/esri"
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

  # If already mapped correctly, do nothing.
  if grep -Eq "^${_ip}[[:space:]]+${_fqdn}([[:space:]]|$)" /etc/hosts 2>/dev/null || \
     grep -Eq "^${_ip}[[:space:]]+${_host}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
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
$ARCGIS_USER soft nofile 65535
$ARCGIS_USER hard nofile 65535
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

# wait_for_service URL NAME [MAX_SECONDS]
wait_for_service() {
  local url="$1"
  local name="$2"
  local max_wait="${3:-300}"  # default 5 minutes
  local elapsed=0
  echo "Waiting for $name to be ready at $url ..."
  while (( elapsed < max_wait )); do
    if "${CURL_BASE[@]}" "$url" 2>/dev/null | grep -q "status.*success\|currentVersion\|html\|arcgis"; then
      echo "$name is ready."
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
    (( elapsed % 30 == 0 )) && echo "  ... still waiting ($elapsed s)"
  done
  echo "WARNING: $name did not respond within ${max_wait}s"
  return 1
}

# Server needs up to 8 min on first start (site creation / fresh install).
# If the process is alive but port 6443 is not responding (broken init state
# from a prior failed run), force a stop/start cycle before giving up.
wait_for_server() {
  # Fast path: already responding
  if "${CURL_BASE[@]}" \
      "https://127.0.0.1:6443/arcgis/rest/info?f=json" 2>/dev/null \
      | grep -q "currentVersion"; then
    echo "ArcGIS Server is ready."
    return 0
  fi

  # Wait up to 4 min for a clean start
  wait_for_service "https://127.0.0.1:6443/arcgis/rest/info?f=json" "ArcGIS Server" 240 && return 0

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
  wait_for_service "https://127.0.0.1:6443/arcgis/rest/info?f=json" "ArcGIS Server" 300
}

# ---------------------------------------------------------------------------
# Helper: generate a Portal admin token
# ---------------------------------------------------------------------------
generate_portal_token() {
  local _resp _token

  # Try portaladmin/generateToken first (admin-scoped), then sharing/rest as fallback.
  # Use client=referer for robustness against IP changes/NAT loopbacks.
  local _ep
  for _ep in \
    "https://127.0.0.1:7443/arcgis/portaladmin/generateToken" \
    "https://127.0.0.1:7443/arcgis/sharing/rest/generateToken"; do
    _resp=$("${CURL_BASE[@]}" --post301 --post302 -L -X POST "$_ep" \
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
    if [[ -n "$_token" && "$_token" != "None" ]]; then echo "$_token"; return 0; fi
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
  _resp=$("${CURL_BASE[@]}" -X POST "https://127.0.0.1:6443/arcgis/admin/generateToken" \
    -H "Referer: https://localhost:6443/arcgis/admin" \
    -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" \
    -d "client=referer" -d "referer=https://localhost:6443/arcgis/admin" \
    -d "expiration=60" \
    -d "f=json" 2>/dev/null) || _resp=""
  _token=$(echo "$_resp" | python3 -c "import sys,json; t=json.load(sys.stdin).get('token',''); print(t if t else '')" 2>/dev/null) || _token=""
  if [[ -n "$_token" && "$_token" != "None" ]]; then echo "$_token"; return 0; fi
  echo "DEBUG: Server generateToken response: $_resp" >&2
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
wait_for_service "https://127.0.0.1:7443/arcgis/portaladmin/healthCheck?f=json" "Portal for ArcGIS" 300 || true

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
SERVER_ADMIN_URL="https://127.0.0.1:6443/arcgis/admin"

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
  echo "$_info" | grep -q '"currentVersion"' || return 1

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
  _rest=$("${CURL_BASE[@]}" "https://127.0.0.1:6443/arcgis/rest/info?f=json" 2>/dev/null) || _rest=""
  echo "$_rest" | grep -q '"currentVersion"' && return 0

  # Admin endpoint may require a token and respond with 499 if missing;
  # that still indicates the admin endpoint is alive and the site exists.
  _info=$("${CURL_BASE[@]}" -H "Referer: https://localhost:6443/arcgis/admin" \
    "$SERVER_ADMIN_URL/info?f=json" 2>/dev/null) || _info=""
  echo "$_info" | grep -q '"currentVersion"' && return 0
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
    "https://127.0.0.1:6443/arcgis/admin/generateToken" \
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

# Determine Server state and act accordingly:
#   Healthy  = /admin/info + token generation both succeed  → skip
#   Degraded = /admin/info succeeds but token fails          → wipe + recreate
#   Down     = /admin/info fails (no site or admin unreachable) → create (or wipe+create)
if server_admin_is_healthy; then
  echo "ArcGIS Server site exists and admin is healthy, skipping..."
else
  # If the site exists but admin isn't fully healthy yet, prefer waiting over wiping.
  # Wiping a partially-initialized but valid site causes long loops and can break
  # downstream Data Store registration.
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
      echo "  ERROR: Server admin did not become healthy within 900s." >&2
      server_admin_diagnose
      exit 1
    fi
  else
  # If the admin is not 100% healthy, we assume the site is broken or non-existent.
  # We FORCE a wipe of the config-store to ensure a clean slate for createsite.sh.
  # Previous attempts to detect "if site exists but broken" were flaky.
  echo "  Server admin is not fully healthy (missing token or config) — wiping config-store to force fresh creation."
  SERVER_SITE_RECREATED=1
  wipe_server_config_store "$SERVER_CS" "$SERVER_DIRS"

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
  # On a no-site instance, REST endpoints may not respond yet; createsite.sh
  # has its own internal checks.
  sleep 20

  # Now create (or recreate) the site.
  # IMPORTANT: use "|| _cs_rc=$?" not "|| true" so we capture the real exit
  # code without triggering set -e (which would kill the script).
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
    echo "  ... still waiting for Server admin (${_elapsed}s)"
  done
  if ! server_admin_is_healthy; then
    echo "  ERROR: Server admin did not become healthy within 900s. Check Server logs." >&2
    server_admin_diagnose
    echo "  Aborting next steps because the Server site is not usable (Data Store + federation will fail)." >&2
    exit 1
  fi
  fi  # server_site_exists
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

PORTAL_ADMIN_URL="https://127.0.0.1:7443/arcgis/portaladmin"
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

wait_for_service "https://127.0.0.1:7443/arcgis/portaladmin/healthCheck?f=json" "Portal" 300 || true

# Check if already federated — idempotency gate
PREV_TOKEN=$(generate_portal_token 2>/dev/null) || PREV_TOKEN=""
EXISTING_FEDERATION=""
if [[ -n "${PREV_TOKEN:-}" ]]; then
  EXISTING_FEDERATION=$("${CURL_BASE[@]}" \
    -H "Referer: https://localhost:7443/arcgis" \
    "https://127.0.0.1:7443/arcgis/portaladmin/federation/servers?f=json&token=$PREV_TOKEN" \
    2>/dev/null) || EXISTING_FEDERATION=""
fi

HAS_FEDERATION=0
if echo "$EXISTING_FEDERATION" | python3 -c \
    "import sys,json; s=json.load(sys.stdin).get('servers',[]); exit(0 if s else 1)" 2>/dev/null; then
  HAS_FEDERATION=1
fi

if (( HAS_FEDERATION == 1 && SERVER_SITE_RECREATED == 0 )); then
  echo "Server is already federated with Portal, skipping..."
else
  if (( HAS_FEDERATION == 1 && SERVER_SITE_RECREATED == 1 )); then
    echo "Server was recreated in Step 11 — existing federation is stale. Unfederating then re-federating..."
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
          "https://127.0.0.1:7443/arcgis/portaladmin/federation/servers/$sid/unfederate" \
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
      "https://127.0.0.1:7443/arcgis/portaladmin/federation/servers/federate" \
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

  # IMPORTANT:
  # A Server site may have been recreated in Step 11 (config-store wipe + createsite).
  # In that case, Data Store must be re-registered with the *new* Server site.
  # describedatastore.sh output can be misleading for this purpose, so we attempt
  # registration idempotently and tolerate "already registered" output.
  DS_REL_OK=0
  DS_OBJ_OK=0

  echo "Registering relational data store with Server (idempotent)..."
  DS_REL_OUT=$(sudo -u "$ARCGIS_USER" ./configuredatastore.sh \
    "https://127.0.0.1:6443/arcgis/admin" \
    "$ADMIN_USER" \
    "$ADMIN_PASS" \
    "$ESRI_BASE/arcgis/datastore/usr/arcgisdatastore" \
    --stores relational 2>&1) || DS_REL_OK=$?
  echo "$DS_REL_OUT"
  if (( DS_REL_OK != 0 )) && ! echo "$DS_REL_OUT" | grep -qi "already registered"; then
    echo "ERROR: Relational data store registration failed."
  else
    DS_REL_OK=0
  fi
  sleep 10

  echo "Registering object store with Server (idempotent)..."
  DS_OBJ_OUT=$(sudo -u "$ARCGIS_USER" ./configuredatastore.sh \
    "https://127.0.0.1:6443/arcgis/admin" \
    "$ADMIN_USER" \
    "$ADMIN_PASS" \
    "$ESRI_BASE/arcgis/datastore/usr/arcgisdatastore" \
    --stores object 2>&1) || DS_OBJ_OK=$?
  echo "$DS_OBJ_OUT"
  if (( DS_OBJ_OK != 0 )) && ! echo "$DS_OBJ_OUT" | grep -qi "already registered"; then
    echo "ERROR: Object store registration failed."
  else
    DS_OBJ_OK=0
  fi

  # After Data Store registration, promote the federated Server to Hosting Server.
  # Portal validation requires a managed database (ArcGIS Data Store) registered.
  if (( DS_REL_OK == 0 && DS_OBJ_OK == 0 )); then
    PORTAL_TOKEN_HOSTING=$(generate_portal_token 2>/dev/null) || PORTAL_TOKEN_HOSTING=""
    if [[ -n "${PORTAL_TOKEN_HOSTING:-}" ]]; then
      SERVERS_JSON=$("${CURL_BASE[@]}" \
        -H "Referer: https://localhost:7443/arcgis" \
        "https://127.0.0.1:7443/arcgis/portaladmin/federation/servers?f=json&token=$PORTAL_TOKEN_HOSTING" \
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
          "https://127.0.0.1:7443/arcgis/portaladmin/federation/servers/$FEDERATED_SERVER_ID/update" \
          -d "serverRole=HOSTING_SERVER" \
          -d "token=$PORTAL_TOKEN_HOSTING" \
          -d "f=json" 2>/dev/null) || HOSTING_RESULT=""
        echo "  Hosting server result: $HOSTING_RESULT"
      else
        echo "WARNING: Could not find federated server ID to set as hosting."
      fi
    else
      echo "WARNING: Could not get Portal token to set hosting server role."
    fi
  else
    echo "WARNING: Skipping hosting server promotion due to Data Store registration errors."
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

  # Check current properties to avoid unnecessary restart
  CURRENT_PROPS=$("${CURL_BASE[@]}" \
    -H "Referer: https://localhost:7443/arcgis" \
    "https://127.0.0.1:7443/arcgis/portaladmin/system/properties?f=json&token=$PORTAL_TOKEN" \
    2>/dev/null) || CURRENT_PROPS=""
  CURRENT_WCU=$(echo "$CURRENT_PROPS" | python3 -c \
    "import sys,json; p=json.load(sys.stdin); print(p.get('WebContextURL',''))" 2>/dev/null) || CURRENT_WCU=""

  if [[ "$CURRENT_WCU" == "https://$DOMAIN/portal" ]]; then
    echo "  Portal WebContextURL already set to https://$DOMAIN/portal, skipping."
  else
    echo "  Setting Portal WebContextURL = https://$DOMAIN/portal"
    echo "  Setting Portal privatePortalURL = https://$PORTAL_INTERNAL_HOST:7443/arcgis"
    CTX_RESULT=$("${CURL_BASE[@]}" -X POST \
      "https://127.0.0.1:7443/arcgis/portaladmin/system/properties/update" \
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
      wait_for_service "https://127.0.0.1:7443/arcgis/portaladmin/healthCheck?f=json" "Portal" 300 || true
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
    "https://127.0.0.1:6443/arcgis/admin/system/properties/update" \
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
  SERVERS_JSON=$("${CURL_BASE[@]}" \
    -H "Referer: https://localhost:7443/arcgis" \
    "https://127.0.0.1:7443/arcgis/portaladmin/federation/servers?f=json&token=$PORTAL_TOKEN" \
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
      "https://127.0.0.1:7443/arcgis/portaladmin/federation/servers/$FED_ID/update" \
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
