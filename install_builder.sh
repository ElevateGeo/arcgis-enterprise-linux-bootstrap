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
apt-get install -y nginx certbot python3-certbot-dns-cloudflare openjdk-11-jdk tar unzip curl jq libtcnative-1

# User
id -u "$ARCGIS_USER" &>/dev/null || useradd -m -s /bin/bash "$ARCGIS_USER"

# Limits (Esri required)
cat > /etc/security/limits.d/arcgis.conf <<EOF
$ARCGIS_USER soft nofile 65535
$ARCGIS_USER hard nofile 65535
$ARCGIS_USER soft nproc 25059
$ARCGIS_USER hard nproc 25059
EOF

grep -q "vm.max_map_count" /etc/sysctl.conf || echo "vm.max_map_count=262144" >> /etc/sysctl.conf
sysctl -p >/dev/null 2>&1 || true

# Hosts: Ensure FQDN resolves to private IP
HOSTNAME=$(hostname)
HOST_IP=$(hostname -I | awk '{print $1}')
FQDN=$(hostname -f)
[[ "$FQDN" == "$HOSTNAME" && -n "$DOMAIN" ]] && FQDN="$DOMAIN"

sed -i "/$HOSTNAME/d" /etc/hosts
sed -i "/$FQDN/d" /etc/hosts
echo "127.0.0.1 localhost" >> /etc/hosts
echo "$HOST_IP $FQDN $HOSTNAME" >> /etc/hosts

# ==============================================================================
# Step 2: Tomcat 10 & NGINX Setup
# ==============================================================================
echo ">>> Step 2: Web Server Setup (Tomcat + NGINX)"

if [[ ! -d "$TOMCAT_HOME" ]]; then
  curl -fsSL "https://archive.apache.org/dist/tomcat/tomcat-10/v10.1.34/bin/apache-tomcat-10.1.34.tar.gz" -o /tmp/tomcat.tar.gz
  mkdir -p "$TOMCAT_HOME"
  tar -xzf /tmp/tomcat.tar.gz -C "$TOMCAT_HOME" --strip-components=1
  id -u "$TOMCAT_USER" &>/dev/null || useradd -r -s /bin/false "$TOMCAT_USER"
  chown -R "$TOMCAT_USER:$TOMCAT_USER" "$TOMCAT_HOME"
  
  cat > /etc/systemd/system/tomcat10.service <<EOF
[Unit]
Description=Tomcat 10
After=network.target
[Service]
Type=forking
User=$TOMCAT_USER
Group=$TOMCAT_USER
Environment="JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))"
Environment="CATALINA_HOME=$TOMCAT_HOME"
Environment="CATALINA_PID=$TOMCAT_HOME/temp/tomcat.pid"
ExecStart=$TOMCAT_HOME/bin/startup.sh
ExecStop=$TOMCAT_HOME/bin/shutdown.sh
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now tomcat10
fi

# Configure NGINX to proxy to Tomcat (Web Adaptors)
# This is required because the Builder configures the site using these URLs.
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
    
    client_max_body_size 500M;
    proxy_read_timeout 600s;

    # Proxy to Tomcat Web Adaptors
    location /server/ {
        proxy_pass http://127.0.0.1:8080/server/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
    location /portal/ {
        proxy_pass http://127.0.0.1:8080/portal/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
    
    location / {
        return 302 /portal/home/;
    }
}
NGINX_EOF

ln -sf /etc/nginx/sites-available/arcgis /etc/nginx/sites-enabled/arcgis
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
echo "NGINX configured to proxy https://$DOMAIN -> Tomcat:8080"

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
  sudo -u "$ARCGIS_USER" "$SETUP_SCRIPT" -m silent -l yes -d "$ESRI_BASE/arcgis"
fi

echo "Checking authorization status..."
# Check for authorizeSoftware tool in standard locations
# Enterprise Builder installs server to server/ and portal to portal/
AUTH_TOOL=$(find "$ESRI_BASE/arcgis" -name "authorizeSoftware" -type f 2>/dev/null | head -1)

if [[ -z "$AUTH_TOOL" ]]; then
  echo "WARNING: authorizeSoftware not found."
  echo "Checking if Setup/install logs have errors..."
  LOG_DIR="$ESRI_BASE/arcgis/usr/logs"
  if [[ -d "$LOG_DIR" ]]; then
      ls -lt "$LOG_DIR" | head -5
  fi
  
  # Check if server directory is empty
  echo "Checking server directory content:"
  ls -la "$ESRI_BASE/arcgis/server" 2>/dev/null
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
  else
    echo "Found authorization tool at: $AUTH_TOOL"
    if ! sudo -u "$ARCGIS_USER" "$AUTH_TOOL" -s | grep -q "Congratulations"; then
        echo "Applying license to ArcGIS Server..."
        sudo -u "$ARCGIS_USER" "$AUTH_TOOL" -f "$SERVER_LIC" -e "$EMAIL"
    fi
  fi
fi

# ==============================================================================
# Step 4: Web Adaptor Deployment
# ==============================================================================
echo ">>> Step 4: Deploying Web Adaptors"
WA_WAR=$(find "$ESRI_BASE/arcgis" -name "arcgis.war" 2>/dev/null | head -1)

# Fallback: Check installer extract if installed war is missing (Web Adaptor might be separate)
if [[ -z "$WA_WAR" && -d "$EXTRACT_DIR" ]]; then
    # Web Adaptor installer is usually separate inside the Builder extract
    # Pattern: extract/WebAdaptor/Setup
    WA_SETUP=$(find "$EXTRACT_DIR" -name "Setup" | grep "WebAdaptor" | head -1)
    if [[ -n "$WA_SETUP" ]]; then
        echo "Web Adaptor WAR missing, but installer found at $WA_SETUP. Installing Web Adaptor..."
        sudo -u "$ARCGIS_USER" "$WA_SETUP" -m silent -l yes -d "$ESRI_BASE/arcgis/webadaptor"
        WA_WAR="$ESRI_BASE/arcgis/webadaptor/java/arcgis.war"
    fi
fi

if [[ -z "$WA_WAR" ]]; then
  # Try one last check
  WA_WAR=$(find "$ESRI_BASE/arcgis" -name "arcgis.war" 2>/dev/null | head -1)
fi

if [[ -z "$WA_WAR" ]]; then
  echo "ERROR: Could not find arcgis.war in $ESRI_BASE/arcgis or install it."
  echo "Installation may have failed or Web Adaptor component is missing."
  exit 1
fi

echo "Found Web Adaptor WAR: $WA_WAR"
cp "$WA_WAR" "$TOMCAT_HOME/webapps/server.war"
cp "$WA_WAR" "$TOMCAT_HOME/webapps/portal.war"
sleep 15 # Wait for Tomcat

# ==============================================================================
# Step 5: Configure Site
# ==============================================================================
echo ">>> Step 5: Configuring Enterprise Site (createsite)"

CONFIG_TOOL=$(find "$ESRI_BASE/arcgis" -name "createsite.sh" | grep "enterprise/tools" | head -1)
[[ -z "$CONFIG_TOOL" ]] && echo "ERROR: Configuration tool not found." && exit 1

# Configure using public FQDN (via NGINX proxy to Tomcat)
WA_SERVER="https://$DOMAIN/server"
WA_PORTAL="https://$DOMAIN/portal"

echo "Configuring site using public URLs:"
echo "  Portal: $WA_PORTAL"
echo "  Server: $WA_SERVER"

cat > "$ESRI_BASE/createsite.properties" <<EOF
WA_URL=$WA_PORTAL
WA_URL_SERVER=$WA_SERVER
PORTAL_ADMIN_USERNAME=$ADMIN_USER
PORTAL_ADMIN_PASSWORD=$ADMIN_PASS
PORTAL_ADMIN_FIRSTNAME=$ADMIN_FIRST
PORTAL_ADMIN_LASTNAME=$ADMIN_LAST
PORTAL_ADMIN_EMAIL=$EMAIL
PORTAL_SECURITY_QUESTION_INDEX=1
PORTAL_SECURITY_ANSWER=Blue
PORTAL_LICENSE_FILE_PATH=$PORTAL_LIC
SERVER_LICENSE_FILE_PATH=$SERVER_LIC
DATA_STORE_TYPES=relational
EOF
chown "$ARCGIS_USER" "$ESRI_BASE/createsite.properties"

echo "Running configuration tool..."
sudo -u "$ARCGIS_USER" "$CONFIG_TOOL" -f "$ESRI_BASE/createsite.properties"

echo "DONE."
