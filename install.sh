#!/usr/bin/env bash
set -e

# ArcGIS Enterprise Linux Bootstrap - Full Automated Install
# This script performs a complete single-machine deployment

ENV_FILE=".env"

echo "=============================================="
echo " ArcGIS Enterprise Linux Bootstrap"
echo "=============================================="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo)"
  exit 1
fi

# Load existing .env if present
if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
  echo "Loaded configuration from $ENV_FILE"
fi

prompt_if_empty() {
  local var_name="$1"
  local prompt_text="$2"
  local secret="$3"
  local default="$4"
  local value="${!var_name}"

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
    echo "$var_name=$value" >> "$ENV_FILE"
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
prompt_if_empty ADMIN_SECURITY_QUESTION "Security question" "" "What is your favorite color?"
prompt_if_empty ADMIN_SECURITY_ANSWER "Security answer" "" "Blue"

# License files
prompt_if_empty PORTAL_LICENSE_FILE "Portal license file path" "" "/opt/esri/licenses/portal.prvc"
prompt_if_empty SERVER_LICENSE_FILE "Server license file path" "" "/opt/esri/licenses/server.prvc"

# Paths
ESRI_BASE="/opt/esri"
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

# Verify license files exist
if [[ ! -f "$PORTAL_LICENSE_FILE" ]]; then
  echo "WARNING: Portal license file not found: $PORTAL_LICENSE_FILE"
  echo "You will need to authorize Portal manually after install."
fi
if [[ ! -f "$SERVER_LICENSE_FILE" ]]; then
  echo "WARNING: Server license file not found: $SERVER_LICENSE_FILE"
  echo "You will need to authorize Server manually after install."
fi

# Verify installers exist
if [[ ! -d "$INSTALLERS" ]]; then
  echo "ERROR: Installers directory not found: $INSTALLERS"
  echo "Please download ArcGIS installers from My Esri and place them in $INSTALLERS"
  exit 1
fi

echo ""
echo ">>> Step 1: Installing System Dependencies"
echo ""

apt update
apt install -y nginx certbot python3-certbot-dns-cloudflare openjdk-11-jdk tar unzip tomcat9 curl jq

# Configure Tomcat
systemctl enable tomcat9

echo ""
echo ">>> Step 2: Configuring SSL Certificates"
echo ""

mkdir -p /root/.secrets/certbot
cat > /root/.secrets/certbot/cloudflare.ini <<EOF
dns_cloudflare_api_token = $CF_API_TOKEN
EOF
chmod 600 /root/.secrets/certbot/cloudflare.ini

# Only request cert if not already present
if [[ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
  certbot certonly --dns-cloudflare \
    --dns-cloudflare-credentials /root/.secrets/certbot/cloudflare.ini \
    -d "$DOMAIN" --agree-tos -m "$EMAIL" --non-interactive
else
  echo "SSL certificate already exists, skipping..."
fi

echo ""
echo ">>> Step 3: Configuring NGINX Reverse Proxy"
echo ""

cat > /etc/nginx/sites-available/arcgis <<EOF
server {
  listen 80;
  server_name $DOMAIN;
  return 301 https://\$host\$request_uri;
}

server {
  listen 443 ssl;
  server_name $DOMAIN;
  
  ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers HIGH:!aNULL:!MD5;
  
  client_max_body_size 100M;
  proxy_connect_timeout 600;
  proxy_send_timeout 600;
  proxy_read_timeout 600;
  
  # Portal Web Adaptor
  location /portal {
    proxy_pass http://localhost:8080/portal;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
  }
  
  # Server Web Adaptor
  location /server {
    proxy_pass http://localhost:8080/server;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
  }
  
  # Default
  location / {
    proxy_pass http://localhost:8080;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto https;
  }
}
EOF

ln -sf /etc/nginx/sites-available/arcgis /etc/nginx/sites-enabled/arcgis
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

echo ""
echo ">>> Step 4: Creating ArcGIS User"
echo ""

id "$ARCGIS_USER" &>/dev/null || useradd -m "$ARCGIS_USER"
mkdir -p "$ESRI_BASE"
mkdir -p "$ESRI_BASE/licenses"
chown -R "$ARCGIS_USER:$ARCGIS_USER" "$ESRI_BASE"

# Set system limits for arcgis user
cat > /etc/security/limits.d/arcgis.conf <<EOF
$ARCGIS_USER soft nofile 65535
$ARCGIS_USER hard nofile 65535
$ARCGIS_USER soft nproc 25059
$ARCGIS_USER hard nproc 25059
EOF

echo ""
echo ">>> Step 5: Extracting Installers"
echo ""

cd "$INSTALLERS"
for f in *.tar.gz; do
  if [[ -f "$f" ]]; then
    echo "Extracting $f..."
    tar -xzf "$f"
  fi
done

echo ""
echo ">>> Step 6: Installing ArcGIS Server"
echo ""

if [[ -d "$INSTALLERS/ArcGISServer" ]]; then
  if [[ ! -d "$ESRI_BASE/arcgis/server" ]]; then
    cd "$INSTALLERS/ArcGISServer"
    sudo -u "$ARCGIS_USER" ./Setup -m silent -l yes -d "$ESRI_BASE"
  else
    echo "ArcGIS Server already installed, skipping..."
  fi
fi

echo ""
echo ">>> Step 7: Installing Portal for ArcGIS"
echo ""

if [[ -d "$INSTALLERS/PortalForArcGIS" ]]; then
  if [[ ! -d "$ESRI_BASE/arcgis/portal" ]]; then
    cd "$INSTALLERS/PortalForArcGIS"
    sudo -u "$ARCGIS_USER" ./Setup -m silent -l yes -d "$ESRI_BASE"
  else
    echo "Portal for ArcGIS already installed, skipping..."
  fi
fi

echo ""
echo ">>> Step 8: Installing ArcGIS Data Store"
echo ""

if [[ -d "$INSTALLERS/ArcGISDataStore" ]]; then
  if [[ ! -d "$ESRI_BASE/arcgis/datastore" ]]; then
    cd "$INSTALLERS/ArcGISDataStore"
    sudo -u "$ARCGIS_USER" ./Setup -m silent -l yes -d "$ESRI_BASE"
  else
    echo "ArcGIS Data Store already installed, skipping..."
  fi
fi

echo ""
echo ">>> Step 9: Installing Web Adaptor"
echo ""

if [[ -d "$INSTALLERS/WebAdaptor" ]]; then
  if [[ ! -d "$ESRI_BASE/webadaptor" ]]; then
    cd "$INSTALLERS/WebAdaptor"
    sudo -u "$ARCGIS_USER" ./Setup -m silent -l yes -d "$ESRI_BASE"
  else
    echo "Web Adaptor already installed, skipping..."
  fi
fi

# Deploy Web Adaptor WARs to Tomcat
echo "Deploying Web Adaptor WARs to Tomcat..."
if [[ -f "$ESRI_BASE/webadaptor/java/arcgis.war" ]]; then
  cp "$ESRI_BASE/webadaptor/java/arcgis.war" /var/lib/tomcat9/webapps/portal.war
  cp "$ESRI_BASE/webadaptor/java/arcgis.war" /var/lib/tomcat9/webapps/server.war
  chown tomcat:tomcat /var/lib/tomcat9/webapps/*.war
  systemctl restart tomcat9
  sleep 10
fi

echo ""
echo ">>> Step 10: Starting ArcGIS Services"
echo ""

# Start ArcGIS Server
if [[ -f "$ESRI_BASE/arcgis/server/startserver.sh" ]]; then
  echo "Starting ArcGIS Server..."
  sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/server/startserver.sh"
  sleep 30
fi

# Start Portal
if [[ -f "$ESRI_BASE/arcgis/portal/startportal.sh" ]]; then
  echo "Starting Portal for ArcGIS..."
  sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/portal/startportal.sh"
  sleep 60
fi

# Start Data Store
if [[ -f "$ESRI_BASE/arcgis/datastore/startdatastore.sh" ]]; then
  echo "Starting ArcGIS Data Store..."
  sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/datastore/startdatastore.sh"
  sleep 30
fi

# Wait for services to be ready
wait_for_service() {
  local url="$1"
  local name="$2"
  local max_attempts=30
  local attempt=1
  
  echo "Waiting for $name to be ready..."
  while [[ $attempt -le $max_attempts ]]; do
    if curl -sk "$url" > /dev/null 2>&1; then
      echo "$name is ready!"
      return 0
    fi
    echo "  Attempt $attempt/$max_attempts - waiting..."
    sleep 10
    ((attempt++))
  done
  echo "WARNING: $name did not respond in time"
  return 1
}

wait_for_service "https://localhost:6443/arcgis/rest/info" "ArcGIS Server"
wait_for_service "https://localhost:7443/arcgis/home" "Portal for ArcGIS"

echo ""
echo ">>> Step 11: Creating ArcGIS Server Site"
echo ""

# Create Server site if not already created
SERVER_ADMIN_URL="https://localhost:6443/arcgis/admin"
if curl -sk "$SERVER_ADMIN_URL/info" | grep -q "error"; then
  echo "Creating ArcGIS Server site..."
  curl -sk -X POST "$SERVER_ADMIN_URL/createNewSite" \
    -d "username=$ADMIN_USER" \
    -d "password=$ADMIN_PASS" \
    -d "configStoreConnection={\"connectionString\":\"$ESRI_BASE/arcgis/server/usr/config-store\",\"type\":\"FILESYSTEM\"}" \
    -d "directories={\"directories\":[{\"name\":\"arcgiscache\",\"physicalPath\":\"$ESRI_BASE/arcgis/server/usr/directories/arcgiscache\",\"directoryType\":\"CACHE\"},{\"name\":\"arcgisjobs\",\"physicalPath\":\"$ESRI_BASE/arcgis/server/usr/directories/arcgisjobs\",\"directoryType\":\"JOBS\"},{\"name\":\"arcgisoutput\",\"physicalPath\":\"$ESRI_BASE/arcgis/server/usr/directories/arcgisoutput\",\"directoryType\":\"OUTPUT\"},{\"name\":\"arcgissystem\",\"physicalPath\":\"$ESRI_BASE/arcgis/server/usr/directories/arcgissystem\",\"directoryType\":\"SYSTEM\"}]}" \
    -d "f=json"
  sleep 30
else
  echo "ArcGIS Server site already exists, skipping..."
fi

echo ""
echo ">>> Step 12: Creating Portal Administrator"
echo ""

# Create Portal if not already created
PORTAL_ADMIN_URL="https://localhost:7443/arcgis/portaladmin"
if curl -sk "$PORTAL_ADMIN_URL/info" | grep -q "error\|not yet configured"; then
  echo "Creating Portal site..."
  cd "$ESRI_BASE/arcgis/portal/tools/createportal"
  sudo -u "$ARCGIS_USER" ./createportal.sh \
    -fn "$ADMIN_FIRST_NAME" \
    -ln "$ADMIN_LAST_NAME" \
    -u "$ADMIN_USER" \
    -p "$ADMIN_PASS" \
    -e "$EMAIL" \
    -qi "$ADMIN_SECURITY_QUESTION" \
    -qa "$ADMIN_SECURITY_ANSWER" \
    -d "$ESRI_BASE/arcgis/portal/usr/arcgisportal"
  sleep 60
else
  echo "Portal already configured, skipping..."
fi

echo ""
echo ">>> Step 13: Authorizing Software"
echo ""

# Authorize Portal
if [[ -f "$PORTAL_LICENSE_FILE" ]]; then
  echo "Authorizing Portal for ArcGIS..."
  cd "$ESRI_BASE/arcgis/portal/tools/authorizeSoftware"
  sudo -u "$ARCGIS_USER" ./authorizeSoftware -f "$PORTAL_LICENSE_FILE" || true
fi

# Authorize Server
if [[ -f "$SERVER_LICENSE_FILE" ]]; then
  echo "Authorizing ArcGIS Server..."
  cd "$ESRI_BASE/arcgis/server/tools/authorizeSoftware"
  sudo -u "$ARCGIS_USER" ./authorizeSoftware -f "$SERVER_LICENSE_FILE" || true
fi

echo ""
echo ">>> Step 14: Configuring Web Adaptors"
echo ""

WA_TOOLS="$ESRI_BASE/webadaptor/java/tools"

# Wait for Tomcat to deploy WARs
sleep 20

# Configure Web Adaptor for Portal
if [[ -d "$WA_TOOLS" ]]; then
  echo "Configuring Web Adaptor for Portal..."
  cd "$WA_TOOLS"
  sudo -u "$ARCGIS_USER" ./configurewebadaptor.sh \
    -m portal \
    -w "https://$DOMAIN/portal/webadaptor" \
    -g "https://localhost:7443" \
    -u "$ADMIN_USER" \
    -p "$ADMIN_PASS" || true
  
  sleep 10
  
  echo "Configuring Web Adaptor for Server..."
  sudo -u "$ARCGIS_USER" ./configurewebadaptor.sh \
    -m server \
    -w "https://$DOMAIN/server/webadaptor" \
    -g "https://localhost:6443" \
    -u "$ADMIN_USER" \
    -p "$ADMIN_PASS" \
    -a true || true
fi

echo ""
echo ">>> Step 15: Configuring Data Store"
echo ""

if [[ -d "$ESRI_BASE/arcgis/datastore/tools" ]]; then
  echo "Registering relational data store with Server..."
  cd "$ESRI_BASE/arcgis/datastore/tools"
  sudo -u "$ARCGIS_USER" ./configuredatastore.sh \
    "https://localhost:6443/arcgis/admin" \
    "$ADMIN_USER" \
    "$ADMIN_PASS" \
    "$ESRI_BASE/arcgis/datastore/usr/arcgisdatastore" \
    --stores relational || true
fi

echo ""
echo ">>> Step 16: Federating Server with Portal"
echo ""

# Get Portal token
get_portal_token() {
  curl -sk -X POST "https://localhost:7443/arcgis/sharing/rest/generateToken" \
    -d "username=$ADMIN_USER" \
    -d "password=$ADMIN_PASS" \
    -d "client=referer" \
    -d "referer=https://$DOMAIN" \
    -d "f=json" | jq -r '.token'
}

TOKEN=$(get_portal_token)

if [[ -n "$TOKEN" && "$TOKEN" != "null" ]]; then
  echo "Federating ArcGIS Server with Portal..."
  
  # Get server admin token
  SERVER_TOKEN=$(curl -sk -X POST "https://localhost:6443/arcgis/admin/generateToken" \
    -d "username=$ADMIN_USER" \
    -d "password=$ADMIN_PASS" \
    -d "client=referer" \
    -d "referer=https://$DOMAIN" \
    -d "f=json" | jq -r '.token')
  
  # Get server ID
  SERVER_ID=$(curl -sk "https://localhost:6443/arcgis/admin/info?f=json&token=$SERVER_TOKEN" | jq -r '.id // empty')
  
  # Federate server
  curl -sk -X POST "https://localhost:7443/arcgis/portaladmin/federation/servers/federate" \
    -d "url=https://$DOMAIN/server" \
    -d "adminUrl=https://localhost:6443/arcgis" \
    -d "username=$ADMIN_USER" \
    -d "password=$ADMIN_PASS" \
    -d "token=$TOKEN" \
    -d "f=json" || true
  
  sleep 10
  
  # Set as hosting server
  echo "Setting Server as hosting server..."
  SERVERS=$(curl -sk "https://localhost:7443/arcgis/portaladmin/federation/servers?f=json&token=$TOKEN")
  FEDERATED_SERVER_ID=$(echo "$SERVERS" | jq -r '.servers[0].id // empty')
  
  if [[ -n "$FEDERATED_SERVER_ID" ]]; then
    curl -sk -X POST "https://localhost:7443/arcgis/portaladmin/federation/servers/$FEDERATED_SERVER_ID/update" \
      -d "serverRole=HOSTING_SERVER" \
      -d "token=$TOKEN" \
      -d "f=json" || true
  fi
else
  echo "WARNING: Could not get Portal token. Federation may need to be done manually."
fi

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
