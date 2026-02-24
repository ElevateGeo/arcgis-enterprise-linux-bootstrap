#!/usr/bin/env bash
set -euo pipefail

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

# Ensure the VM can resolve its own FQDN to localhost.
# Azure/cloud VMs often cannot hairpin through the public IP, so
# configurewebadaptor.sh (and other tools) fail to reach https://$DOMAIN.
if ! grep -q "$DOMAIN" /etc/hosts 2>/dev/null; then
  echo "Adding $DOMAIN to /etc/hosts for local resolution..."
  echo "127.0.0.1  $DOMAIN" >> /etc/hosts
fi

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
        proxy_pass https://localhost:7443/arcgis/;
        proxy_ssl_verify off;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_set_header X-Forwarded-Port  443;

        # Rewrite redirect Location headers from backend → public URL
        proxy_redirect https://localhost:7443/arcgis/ https://$host/portal/;
        proxy_redirect ~*https?://[^/]+(:7443)?/arcgis/ https://$host/portal/;
    }

    # /arcgis/ — Portal generates absolute URLs with /arcgis/ prefix in its
    # OAuth pages and static assets even when WebContextURL is set to /portal/.
    # Proxy these to Portal so sign-in assets (JS/CSS) load correctly.
    location /arcgis/ {
        proxy_pass https://localhost:7443/arcgis/;
        proxy_ssl_verify off;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_set_header X-Forwarded-Port  443;

        proxy_redirect https://localhost:7443/arcgis/ https://$host/arcgis/;
        proxy_redirect ~*https?://[^/]+(:7443)?/arcgis/ https://$host/arcgis/;
    }

    # Server — direct reverse proxy to ArcGIS Server (port 6443)
    # Rewrites /server/* → /arcgis/* on the backend
    location = /server {
        return 301 /server/;
    }
    location /server/ {
        proxy_pass https://localhost:6443/arcgis/;
        proxy_ssl_verify off;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_set_header X-Forwarded-Port  443;

        # Rewrite redirect Location headers from backend → public URL
        proxy_redirect https://localhost:6443/arcgis/ https://$host/server/;
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
    sleep 30
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

# Helper: wait until a service health-check responds
wait_for_service() {
  local url="$1"
  local name="$2"
  local max_wait="${3:-300}"  # default 5 minutes
  local elapsed=0
  echo "Waiting for $name to be ready at $url ..."
  while (( elapsed < max_wait )); do
    if curl -sk "$url" 2>/dev/null | grep -q "status.*success\|currentVersion\|html\|arcgis"; then
      echo "$name is ready."
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
    echo "  ... still waiting ($elapsed s)"
  done
  echo "WARNING: $name did not respond within ${max_wait}s"
  return 1
}

# || true prevents set -e from aborting — services may need extra time
# Use /arcgis/rest/info for Server — /admin/healthCheck requires an existing site (Step 11)
# Use /portaladmin/healthCheck for Portal — reliable JSON response
wait_for_service "https://localhost:6443/arcgis/rest/info?f=json" "ArcGIS Server" 120 || true
wait_for_service "https://localhost:7443/arcgis/portaladmin/healthCheck?f=json" "Portal for ArcGIS" 300 || true

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
SERVER_ADMIN_URL="https://localhost:6443/arcgis/admin"

# Check if site already exists
SERVER_INFO=$(curl -sk "$SERVER_ADMIN_URL/info?f=json" 2>/dev/null || echo "")
if echo "$SERVER_INFO" | grep -q "currentVersion"; then
  echo "ArcGIS Server site already exists, skipping..."
else
  if [[ -f "$CREATESITE_TOOL" ]]; then
    # Use Esri's createsite CLI tool (recommended)
    echo "Creating ArcGIS Server site using createsite.sh..."
    chmod +x "$CREATESITE_TOOL"
    sudo -u "$ARCGIS_USER" "$CREATESITE_TOOL" \
      -u "$ADMIN_USER" \
      -p "$ADMIN_PASS" \
      -d "$ESRI_BASE/arcgis/server/usr/directories" \
      -c "$ESRI_BASE/arcgis/server/usr/config-store" || true
    sleep 30
  else
    # Fallback to REST API
    echo "Creating ArcGIS Server site via REST API..."
    curl -sk -X POST "$SERVER_ADMIN_URL/createNewSite" \
      -d "username=$ADMIN_USER" \
      -d "password=$ADMIN_PASS" \
      -d "configStoreConnection={\"connectionString\":\"$ESRI_BASE/arcgis/server/usr/config-store\",\"type\":\"FILESYSTEM\"}" \
      -d "directories={\"directories\":[{\"name\":\"arcgiscache\",\"physicalPath\":\"$ESRI_BASE/arcgis/server/usr/directories/arcgiscache\",\"directoryType\":\"CACHE\"},{\"name\":\"arcgisjobs\",\"physicalPath\":\"$ESRI_BASE/arcgis/server/usr/directories/arcgisjobs\",\"directoryType\":\"JOBS\"},{\"name\":\"arcgisoutput\",\"physicalPath\":\"$ESRI_BASE/arcgis/server/usr/directories/arcgisoutput\",\"directoryType\":\"OUTPUT\"},{\"name\":\"arcgissystem\",\"physicalPath\":\"$ESRI_BASE/arcgis/server/usr/directories/arcgissystem\",\"directoryType\":\"SYSTEM\"}]}" \
      -d "f=json" || true
    sleep 30
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

PORTAL_ADMIN_URL="https://localhost:7443/arcgis/portaladmin"
PORTAL_INFO=$(curl -sk "$PORTAL_ADMIN_URL?f=json" 2>/dev/null || echo "")
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

# Import the Let's Encrypt cert into ALL Java truststores on the system.
LE_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
if [[ -f "$LE_CERT" ]]; then
  echo "Importing Let's Encrypt certificate into all Java truststores..."
  while IFS= read -r CACERTS_FILE; do
    KEYTOOL_BIN=$(dirname "$CACERTS_FILE")/../bin/keytool
    if [[ ! -x "$KEYTOOL_BIN" ]]; then
      KEYTOOL_BIN="keytool"
    fi
    if ! "$KEYTOOL_BIN" -list -keystore "$CACERTS_FILE" -storepass changeit \
        -alias "letsencrypt-$DOMAIN" > /dev/null 2>&1; then
      echo "  Importing into: $CACERTS_FILE"
      "$KEYTOOL_BIN" -importcert -trustcacerts -keystore "$CACERTS_FILE" \
        -storepass changeit -alias "letsencrypt-$DOMAIN" \
        -file "$LE_CERT" -noprompt 2>/dev/null || true
    else
      echo "  Already imported: $CACERTS_FILE"
    fi
  done < <(find /opt/esri /usr/lib/jvm /etc/ssl -name "cacerts" -type f 2>/dev/null | sort -u)
fi

# ---------------------------------------------------------------------------
# Helper: generate a Portal admin token (tries multiple approaches)
# ---------------------------------------------------------------------------
generate_portal_token() {
  local _resp _token _host

  # Portal redirects localhost → internal FQDN, and curl drops POST body on
  # redirect unless --post301/--post302 are given.  Best approach: use the
  # internal FQDN that Portal was created with to avoid redirects entirely.
  _host=$(hostname -f 2>/dev/null) || _host=""

  # Approach 1: internal FQDN + sharing/rest (avoids redirect)
  if [[ -n "$_host" ]]; then
    _resp=$(curl -sk -X POST "https://$_host:7443/arcgis/sharing/rest/generateToken" \
      -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" \
      -d "client=requestip" -d "expiration=60" -d "f=json" 2>/dev/null) || _resp=""
    _token=$(echo "$_resp" | python3 -c "import sys,json; t=json.load(sys.stdin).get('token',''); print(t if t else '')" 2>/dev/null) || _token=""
    if [[ -n "$_token" && "$_token" != "None" ]]; then echo "$_token"; return 0; fi
  fi

  # Approach 2: localhost with --post301 --post302 to preserve POST through redirect
  _resp=$(curl -sk --post301 --post302 -L -X POST \
    "https://localhost:7443/arcgis/sharing/rest/generateToken" \
    -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" \
    -d "client=requestip" -d "expiration=60" -d "f=json" 2>/dev/null) || _resp=""
  _token=$(echo "$_resp" | python3 -c "import sys,json; t=json.load(sys.stdin).get('token',''); print(t if t else '')" 2>/dev/null) || _token=""
  if [[ -n "$_token" && "$_token" != "None" ]]; then echo "$_token"; return 0; fi

  # Approach 3: portaladmin endpoint with --post301 --post302
  _resp=$(curl -sk --post301 --post302 -L -X POST \
    "https://localhost:7443/arcgis/portaladmin/generateToken" \
    -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" \
    -d "client=requestip" -d "expiration=60" -d "f=json" 2>/dev/null) || _resp=""
  _token=$(echo "$_resp" | python3 -c "import sys,json; t=json.load(sys.stdin).get('token',''); print(t if t else '')" 2>/dev/null) || _token=""
  if [[ -n "$_token" && "$_token" != "None" ]]; then echo "$_token"; return 0; fi

  # All failed — emit debug info on stderr
  echo "DEBUG: Portal generateToken last response: $_resp" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Helper: generate a Server admin token
# ---------------------------------------------------------------------------
generate_server_token() {
  local _resp _token
  _resp=$(curl -sk -X POST "https://localhost:6443/arcgis/admin/generateToken" \
    -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" \
    -d "client=requestip" -d "f=json" 2>/dev/null) || _resp=""
  _token=$(echo "$_resp" | python3 -c "import sys,json; t=json.load(sys.stdin).get('token',''); print(t if t else '')" 2>/dev/null) || _token=""
  if [[ -n "$_token" && "$_token" != "None" ]]; then echo "$_token"; return 0; fi
  echo "DEBUG: Server generateToken response: $_resp" >&2
  return 1
}

# WebContextURL and privatePortalURL are set AFTER federation (Step 16)
# to avoid a ClassCastException in Server's security config update.
# During federation, Portal and Server communicate using their native
# internal URLs without any reverse proxy involvement.
wait_for_service "https://localhost:7443/arcgis/portaladmin/healthCheck?f=json" "Portal" 300 || true
echo "Portal is healthy. Reverse proxy properties deferred to post-federation."

# ==============================================================================
# Step 14: Federate Server with Portal
# Per Esri's documented deployment order, federation MUST happen before
# DataStore registration.
# Ref: https://enterprise.arcgis.com/en/portal/12.0/administer/linux/federate-an-arcgis-server-site-with-your-portal.htm
# ==============================================================================
echo ""
echo ">>> Step 14: Federating Server with Portal"
echo ""

# Reuse generate_portal_token() defined in Step 13

# Check if already federated
PREV_TOKEN=$(generate_portal_token 2>/dev/null) || true
EXISTING_FEDERATION=""
if [[ -n "${PREV_TOKEN:-}" && "$PREV_TOKEN" != "null" ]]; then
  EXISTING_FEDERATION=$(curl -sk \
    "https://localhost:7443/arcgis/portaladmin/federation/servers?f=json&token=$PREV_TOKEN" \
    2>/dev/null || echo "")
fi

if echo "$EXISTING_FEDERATION" | grep -q '"id"'; then
  echo "Server is already federated with Portal, skipping..."
else
  TOKEN=$(generate_portal_token 2>/dev/null) || true

  if [[ -n "${TOKEN:-}" && "$TOKEN" != "null" ]]; then
    echo "Federating ArcGIS Server with Portal..."

    # ------------------------------------------------------------------
    # Pre-federation cleanup — critical for re-runs.
    # Previous runs may have set Portal WebContextURL / privatePortalURL.
    # Portal includes those properties in the security-config payload it
    # sends to Server during federation; the nested JSON value triggers a
    # ClassCastException in Server's security-config update handler.
    # ------------------------------------------------------------------

    # 1. Clear Portal system properties and wait for restart
    echo "  Clearing Portal system properties (pre-federation)..."
    CLEAR_P=$(curl -sk -X POST \
      "https://localhost:7443/arcgis/portaladmin/system/properties/update" \
      --data-urlencode 'properties={}' \
      -d "token=$TOKEN" -d "f=json" 2>/dev/null) || CLEAR_P=""
    echo "  Portal properties cleared: $CLEAR_P"
    if echo "$CLEAR_P" | grep -q '"recheckAfterSeconds"'; then
      echo "  Waiting for Portal to restart..."
      sleep 30
      wait_for_service "https://localhost:7443/arcgis/portaladmin/healthCheck?f=json" "Portal" 300 || true
    fi

    # Generate a fresh Portal token (old one may be invalid after restart)
    TOKEN=$(generate_portal_token 2>/dev/null) || TOKEN=""
    if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
      echo "ERROR: Cannot get Portal token after property reset."
      echo "  Federation must be done manually."
    else

    # 2. Restart ArcGIS Server to clear any cached JVM state from
    #    previous DataStore registration or failed federation attempts.
    echo "  Restarting ArcGIS Server before federation..."
    if [[ -f "$ESRI_BASE/arcgis/server/stopserver.sh" ]]; then
      sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/server/stopserver.sh" > /dev/null 2>&1 || true
      # Wait for the Server JVM process to actually die (up to 120s)
      echo "  Waiting for Server process to stop..."
      _stop_wait=0
      while pgrep -u "$ARCGIS_USER" -f "arcgis/server" > /dev/null 2>&1; do
        if (( _stop_wait >= 120 )); then
          echo "  Server process did not stop cleanly; force-killing..."
          pkill -9 -u "$ARCGIS_USER" -f "arcgis/server" 2>/dev/null || true
          sleep 5
          break
        fi
        sleep 5
        _stop_wait=$((_stop_wait + 5))
      done
      echo "  Server stopped. (waited ${_stop_wait}s)"
      sleep 5
    fi
    if [[ -f "$ESRI_BASE/arcgis/server/startserver.sh" ]]; then
      sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/server/startserver.sh" > /dev/null 2>&1 || true
      # /arcgis/rest/info returns currentVersion only when fully initialised
      wait_for_service "https://localhost:6443/arcgis/rest/info?f=json" "Server" 300 || true
    fi

    # 3. Discover Server's machine name (matches its SSL certificate)
    SERVER_TOKEN_FED=$(generate_server_token 2>/dev/null) || SERVER_TOKEN_FED=""
    SERVER_MACHINE=""
    if [[ -n "$SERVER_TOKEN_FED" ]]; then
      SERVER_MACHINE=$(curl -sk \
        "https://localhost:6443/arcgis/admin/machines?f=json&token=$SERVER_TOKEN_FED" \
        2>/dev/null | python3 -c "
import sys,json
data=json.load(sys.stdin)
for m in data.get('machines',[]):
    print(m.get('machineName','')); break" 2>/dev/null) || SERVER_MACHINE=""
    fi
    if [[ -z "$SERVER_MACHINE" ]]; then
      SERVER_MACHINE=$(hostname -f 2>/dev/null || echo "localhost")
    fi

    # 4. Clear Server system properties
    if [[ -n "$SERVER_TOKEN_FED" ]]; then
      echo "  Clearing Server system properties..."
      curl -sk -X POST "https://localhost:6443/arcgis/admin/system/properties/update" \
        --data-urlencode 'properties={}' \
        -d "token=$SERVER_TOKEN_FED" -d "f=json" > /dev/null 2>&1 || true
    fi

    # 5. Unregister DataStore items from Server's config store.
    #    DataStore registration persists in Server's on-disk config store and
    #    survives JVM restarts. The complex JSON descriptors in those items
    #    may cause a ClassCastException in the federation security handler.
    #    DataStore will auto-reconnect after federation completes.
    if [[ -n "$SERVER_TOKEN_FED" ]]; then
      echo "  Unregistering DataStore items from Server config store..."
      DS_ITEMS=$(curl -sk \
        "https://localhost:6443/arcgis/admin/data/items?f=json&token=$SERVER_TOKEN_FED" \
        2>/dev/null) || DS_ITEMS=""
      # Store paths in a variable to avoid pipe + set -euo pipefail interaction
      DS_PATHS=$(echo "$DS_ITEMS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for item in data.get('items', data.get('rootItems', [])):
        p = item.get('path', item.get('id', ''))
        if p:
            print(p)
except Exception:
    pass
" 2>/dev/null) || DS_PATHS=""
      if [[ -n "$DS_PATHS" ]]; then
        while IFS= read -r item_path; do
          [[ -z "$item_path" ]] && continue
          echo "    Unregistering: $item_path"
          curl -sk -X POST "https://localhost:6443/arcgis/admin/data/unregisterItem" \
            --data-urlencode "itempath=$item_path" \
            -d "token=$SERVER_TOKEN_FED" -d "f=json" 2>/dev/null \
            | python3 -c "import sys,json; r=json.load(sys.stdin); print('    -> ' + r.get('status', str(r)))" 2>/dev/null || true
        done <<< "$DS_PATHS"
      else
        echo "  No DataStore items registered (or could not retrieve list)."
      fi
    fi

    # 6. Generate Portal admin token via portaladmin/generateToken
    #    (matches what the Portal Admin UI uses — different from sharing/rest token)
    PORTAL_FQDN=$(hostname -f 2>/dev/null || echo "localhost")
    FED_TOKEN=$(curl -sk -X POST \
      "https://$PORTAL_FQDN:7443/arcgis/portaladmin/generateToken" \
      -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" \
      -d "client=requestip" -d "expiration=60" -d "f=json" 2>/dev/null \
      | python3 -c "import sys,json; t=json.load(sys.stdin).get('token',''); print(t)" 2>/dev/null) || FED_TOKEN=""
    if [[ -z "$FED_TOKEN" || "$FED_TOKEN" == "None" ]]; then
      echo "  portaladmin/generateToken failed, falling back to sharing token..."
      FED_TOKEN="$TOKEN"
    else
      echo "  Portal admin token (portaladmin endpoint) acquired."
    fi

    # 7. Federate using INTERNAL URLs.
    #    We update the services URL to the public reverse-proxy URL after
    #    federation succeeds (Step 16).
    echo "  Services URL (internal): https://$SERVER_MACHINE:6443/arcgis"
    echo "  Admin URL:               https://$SERVER_MACHINE:6443/arcgis"

    FEDERATE_RESULT=$(curl -sk -X POST \
      "https://localhost:7443/arcgis/portaladmin/federation/servers/federate" \
      -d "url=https://$SERVER_MACHINE:6443/arcgis" \
      -d "adminUrl=https://$SERVER_MACHINE:6443/arcgis" \
      -d "username=$ADMIN_USER" \
      -d "password=$ADMIN_PASS" \
      -d "token=$FED_TOKEN" \
      -d "f=json" 2>/dev/null) || true
    echo "Federation result: $FEDERATE_RESULT"

    if echo "$FEDERATE_RESULT" | grep -q '"error"'; then
      echo "ERROR: Federation failed. See output above."
      echo "You can federate manually via Portal Admin."
      # Print recent Server logs to help diagnose
      SERVER_LOG_DIR="$ESRI_BASE/arcgis/server/usr/logs/$SERVER_MACHINE/server"
      if [[ -d "$SERVER_LOG_DIR" ]]; then
        echo ""
        echo "  --- Recent ArcGIS Server log entries ---"
        ls -t "$SERVER_LOG_DIR"/*.log 2>/dev/null | head -1 | xargs -r tail -100 2>/dev/null \
          | grep -i "error\|exception\|federation\|security" | tail -30 || true
        echo "  --- End Server log ---"
      fi
    else
      echo "  Federation successful."
      sleep 10

      # Set as hosting server
      echo "Setting Server as hosting server..."
      SERVERS=$(curl -sk \
        "https://localhost:7443/arcgis/portaladmin/federation/servers?f=json&token=$FED_TOKEN" \
        2>/dev/null) || true
      FEDERATED_SERVER_ID=$(echo "$SERVERS" | python3 -c "import sys,json; s=json.load(sys.stdin).get('servers',[]); print(s[0]['id'] if s else '')" 2>/dev/null) || FEDERATED_SERVER_ID=""

      if [[ -n "$FEDERATED_SERVER_ID" ]]; then
        HOSTING_RESULT=$(curl -sk -X POST \
          "https://localhost:7443/arcgis/portaladmin/federation/servers/$FEDERATED_SERVER_ID/update" \
          -d "serverRole=HOSTING_SERVER" \
          -d "token=$FED_TOKEN" \
          -d "f=json" 2>/dev/null) || true
        echo "Hosting server result: $HOSTING_RESULT"
      else
        echo "WARNING: Could not find federated server to set as hosting."
      fi
    fi

    fi  # end of post-restart token check

  else
    echo "WARNING: Could not get Portal token. Federation may need to be done manually."
    echo "See: https://enterprise.arcgis.com/en/portal/12.0/administer/linux/federate-an-arcgis-server-site-with-your-portal.htm"
  fi
fi

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

  # Check if relational data store is already registered
  DS_STATUS=$(sudo -u "$ARCGIS_USER" ./describedatastore.sh 2>/dev/null || echo "")
  if echo "$DS_STATUS" | grep -qi "relational"; then
    echo "Relational data store already registered, skipping..."
  else
    echo "Registering relational data store with Server..."
    sudo -u "$ARCGIS_USER" ./configuredatastore.sh \
      "https://localhost:6443/arcgis/admin" \
      "$ADMIN_USER" \
      "$ADMIN_PASS" \
      "$ESRI_BASE/arcgis/datastore/usr/arcgisdatastore" \
      --stores relational 2>&1 || {
        echo "ERROR: Relational data store registration failed."
      }
    sleep 10
  fi

  # Object store is required for the base deployment in 12.0
  if echo "$DS_STATUS" | grep -qi "object"; then
    echo "Object store already registered, skipping..."
  else
    echo "Registering object store with Server..."
    sudo -u "$ARCGIS_USER" ./configuredatastore.sh \
      "https://localhost:6443/arcgis/admin" \
      "$ADMIN_USER" \
      "$ADMIN_PASS" \
      "$ESRI_BASE/arcgis/datastore/usr/arcgisdatastore" \
      --stores object 2>&1 || {
        echo "ERROR: Object store registration failed."
      }
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
PORTAL_TOKEN=$(generate_portal_token 2>/dev/null) || PORTAL_TOKEN=""
if [[ -n "$PORTAL_TOKEN" ]]; then
  echo "Portal admin token acquired."

  # Discover Portal's internal FQDN for privatePortalURL
  PORTAL_INTERNAL_HOST=$(hostname -f 2>/dev/null || echo "localhost")

  echo "Setting Portal WebContextURL to https://$DOMAIN/portal ..."
  echo "Setting Portal privatePortalURL to https://$PORTAL_INTERNAL_HOST:7443/arcgis ..."
  CTX_RESULT=$(curl -sk -X POST \
    "https://localhost:7443/arcgis/portaladmin/system/properties/update" \
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
    wait_for_service "https://localhost:7443/arcgis/portaladmin/healthCheck?f=json" "Portal" 300 || true
  fi
else
  echo "WARNING: Could not get Portal token. Set WebContextURL manually."
fi

# --- 16b: Server WebContextURL ---
echo ""
echo "Setting Server WebContextURL to https://$DOMAIN/server ..."
SRV_TOK=$(generate_server_token 2>/dev/null) || SRV_TOK=""
if [[ -n "$SRV_TOK" ]]; then
  CTX_RESULT=$(curl -sk -X POST \
    "https://localhost:6443/arcgis/admin/system/properties/update" \
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
  SERVERS_JSON=$(curl -sk \
    "https://localhost:7443/arcgis/portaladmin/federation/servers?f=json&token=$PORTAL_TOKEN" \
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
    UPD_RESULT=$(curl -sk -X POST \
      "https://localhost:7443/arcgis/portaladmin/federation/servers/$FED_ID/update" \
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
