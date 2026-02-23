#!/usr/bin/env bash
set -euo pipefail

# ArcGIS Enterprise 12.x Upgrade Script
# Upgrades an existing single-machine ArcGIS Enterprise deployment.
#
# Esri's documented upgrade order:
#   1. Stop services (reverse dependency order)
#   2. Upgrade ArcGIS Server  → re-authorize
#   3. Upgrade Portal for ArcGIS → re-import license (JSON)
#   4. Upgrade ArcGIS Data Store
#   5. Upgrade Web Adaptor
#   6. Start services (dependency order)
#   7. Post-upgrade validation
#
# Ref: https://enterprise.arcgis.com/en/get-started/12.0/linux/base-arcgis-enterprise-deployment.htm

ENV_FILE=".env"

echo "=============================================="
echo " ArcGIS Enterprise Upgrade"
echo "=============================================="

# ---------- Root check ----------
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo)"
  exit 1
fi

# ---------- Load .env ----------
if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
  echo "Loaded configuration from $ENV_FILE"
else
  echo "WARNING: No .env file found. Some post-upgrade steps may be skipped."
fi

# ---------- Paths ----------
ESRI_BASE="/opt/esri"
INSTALLERS="$ESRI_BASE/installers"
ARCGIS_USER="arcgis"

# ---------- Verify prerequisites ----------
if ! id "$ARCGIS_USER" &>/dev/null; then
  echo "ERROR: User '$ARCGIS_USER' not found. Is ArcGIS Enterprise installed?"
  exit 1
fi

if [[ ! -d "$INSTALLERS" ]]; then
  echo "ERROR: Installers directory not found: $INSTALLERS"
  echo "Please place upgrade installers in $INSTALLERS"
  exit 1
fi

# ---------- Auto-detect license files ----------
# Portal 12.0+ uses a JSON file (downloaded from My Esri)
PORTAL_LICENSE_FILE="${PORTAL_LICENSE_FILE:-}"
if [[ -z "$PORTAL_LICENSE_FILE" || ! -f "$PORTAL_LICENSE_FILE" ]]; then
  FOUND_PORTAL_LIC=$(find "$ESRI_BASE/licenses" -name "ArcGIS_Enterprise_Portal*.json" 2>/dev/null | head -1)
  if [[ -n "${FOUND_PORTAL_LIC:-}" ]]; then
    PORTAL_LICENSE_FILE="$FOUND_PORTAL_LIC"
    echo "Found Portal license: $PORTAL_LICENSE_FILE"
  fi
fi

# Server uses .prvc provisioning file
SERVER_LICENSE_FILE="${SERVER_LICENSE_FILE:-}"
if [[ -z "$SERVER_LICENSE_FILE" || ! -f "$SERVER_LICENSE_FILE" ]]; then
  FOUND_SERVER_LIC=$(find "$ESRI_BASE/licenses" -name "*.prvc" 2>/dev/null | head -1)
  if [[ -n "${FOUND_SERVER_LIC:-}" ]]; then
    SERVER_LICENSE_FILE="$FOUND_SERVER_LIC"
    echo "Found Server license: $SERVER_LICENSE_FILE"
  fi
fi

# ---------- wait_for_service helper ----------
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
  echo "WARNING: $name did not respond within $(( max_attempts * 10 )) seconds"
  return 1
}

echo ""
echo "Configuration:"
echo "  Portal License: ${PORTAL_LICENSE_FILE:-not found}"
echo "  Server License: ${SERVER_LICENSE_FILE:-not found}"
echo ""

# ==============================================================================
# Step 1: Stop Services (reverse dependency order)
# ==============================================================================
echo ""
echo ">>> Step 1: Stopping ArcGIS Services"
echo ""

echo "Stopping ArcGIS Data Store..."
if [[ -f "$ESRI_BASE/arcgis/datastore/stopdatastore.sh" ]]; then
  sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/datastore/stopdatastore.sh" || true
fi

echo "Stopping Portal for ArcGIS..."
if [[ -f "$ESRI_BASE/arcgis/portal/stopportal.sh" ]]; then
  sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/portal/stopportal.sh" || true
fi

echo "Stopping ArcGIS Server..."
if [[ -f "$ESRI_BASE/arcgis/server/stopserver.sh" ]]; then
  sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/server/stopserver.sh" || true
fi

# ==============================================================================
# Step 2: Backup Configuration
# ==============================================================================
echo ""
echo ">>> Step 2: Backing Up Configuration"
echo ""

BACKUP_DIR="$ESRI_BASE/backup/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

if [[ -d "$ESRI_BASE/arcgis/server/framework/etc" ]]; then
  cp -r "$ESRI_BASE/arcgis/server/framework/etc" "$BACKUP_DIR/server_etc" 2>/dev/null || true
fi

if [[ -d "$ESRI_BASE/arcgis/portal/framework/etc" ]]; then
  cp -r "$ESRI_BASE/arcgis/portal/framework/etc" "$BACKUP_DIR/portal_etc" 2>/dev/null || true
fi

echo "Backup saved to: $BACKUP_DIR"

# ==============================================================================
# Step 3: Extract Upgrade Installers
# ==============================================================================
echo ""
echo ">>> Step 3: Extracting Upgrade Installers"
echo ""

cd "$INSTALLERS"
for f in *.tar.gz; do
  if [[ -f "$f" ]]; then
    echo "Extracting $f..."
    tar -xzf "$f"
  fi
done
chown -R "$ARCGIS_USER:$ARCGIS_USER" "$INSTALLERS"

# ==============================================================================
# Step 4: Verify System Tuning
# Ensure kernel parameters and limits are set (may have been lost after reboot).
# ==============================================================================
echo ""
echo ">>> Step 4: Verifying System Tuning"
echo ""

# Ensure ulimits are set
if [[ ! -f /etc/security/limits.d/arcgis.conf ]]; then
  cat > /etc/security/limits.d/arcgis.conf <<EOF
$ARCGIS_USER soft nofile 65535
$ARCGIS_USER hard nofile 65535
$ARCGIS_USER soft nproc  25059
$ARCGIS_USER hard nproc  25059
EOF
  echo "Created ulimits config."
fi

# Ensure sysctl parameters are set
if [[ ! -f /etc/sysctl.d/99-arcgis.conf ]]; then
  cat > /etc/sysctl.d/99-arcgis.conf <<EOF
vm.max_map_count = 262144
vm.swappiness = 1
EOF
  sysctl --system > /dev/null 2>&1
  echo "Created sysctl config."
else
  echo "System tuning already configured."
fi

# ==============================================================================
# Step 5: Upgrade ArcGIS Server
# Per Esri docs: Run the new version's Setup -m silent -l yes.
# Re-authorize after upgrade with the -a flag.
# Ref: https://enterprise.arcgis.com/en/server/12.0/install/linux/silently-install-arcgis-server.htm
# ==============================================================================
echo ""
echo ">>> Step 5: Upgrading ArcGIS Server"
echo ""

SERVER_SETUP=$(find "$INSTALLERS" -maxdepth 2 -name "Setup" -path "*Server*" -type f 2>/dev/null | head -1)
if [[ -n "${SERVER_SETUP:-}" ]]; then
  SERVER_DIR=$(dirname "$SERVER_SETUP")
  echo "Found Server installer: $SERVER_DIR"
  cd "$SERVER_DIR"

  # Authorize during upgrade with -a flag (same as fresh install)
  if [[ -f "${SERVER_LICENSE_FILE:-}" ]]; then
    echo "Upgrading and re-authorizing ArcGIS Server..."
    sudo -u "$ARCGIS_USER" ./Setup -m silent -l yes -a "$SERVER_LICENSE_FILE"
  else
    echo "Upgrading ArcGIS Server (no license file — authorize manually later)..."
    sudo -u "$ARCGIS_USER" ./Setup -m silent -l yes
  fi
else
  echo "WARNING: ArcGIS Server installer not found in $INSTALLERS"
fi

# ==============================================================================
# Step 6: Upgrade Portal for ArcGIS
# Ref: https://enterprise.arcgis.com/en/portal/12.0/install/linux/install-portal-for-arcgis.htm
# ==============================================================================
echo ""
echo ">>> Step 6: Upgrading Portal for ArcGIS"
echo ""

PORTAL_SETUP=$(find "$INSTALLERS" -maxdepth 2 -name "Setup" -path "*Portal*" -type f 2>/dev/null | head -1)
if [[ -n "${PORTAL_SETUP:-}" ]]; then
  PORTAL_DIR=$(dirname "$PORTAL_SETUP")
  echo "Found Portal installer: $PORTAL_DIR"
  cd "$PORTAL_DIR"
  sudo -u "$ARCGIS_USER" ./Setup -m silent -l yes
else
  echo "WARNING: Portal for ArcGIS installer not found in $INSTALLERS"
fi

# Upgrade Portal Web Styles (companion to Portal)
WS_SETUP=$(find "$INSTALLERS" -maxdepth 2 -name "Setup" -path "*Web_Styles*" -o -name "Setup" -path "*WebStyles*" 2>/dev/null | head -1)
if [[ -n "${WS_SETUP:-}" ]]; then
  WS_DIR=$(dirname "$WS_SETUP")
  echo "Upgrading Portal Web Styles from: $WS_DIR"
  cd "$WS_DIR"
  sudo -u "$ARCGIS_USER" ./Setup -m silent -l yes
else
  echo "Portal Web Styles installer not found — skipping."
fi

# ==============================================================================
# Step 7: Upgrade ArcGIS Data Store
# Ref: https://enterprise.arcgis.com/en/data-store/12.0/install/linux/install-arcgis-data-store.htm
# ==============================================================================
echo ""
echo ">>> Step 7: Upgrading ArcGIS Data Store"
echo ""

DS_SETUP=$(find "$INSTALLERS" -maxdepth 2 -name "Setup" -path "*DataStore*" -type f 2>/dev/null | head -1)
if [[ -n "${DS_SETUP:-}" ]]; then
  DS_DIR=$(dirname "$DS_SETUP")
  echo "Found Data Store installer: $DS_DIR"
  cd "$DS_DIR"
  sudo -u "$ARCGIS_USER" ./Setup -m silent -l yes
else
  echo "WARNING: ArcGIS Data Store installer not found in $INSTALLERS"
fi

# ==============================================================================
# Step 8: Upgrade Web Adaptor
# Ref: https://enterprise.arcgis.com/en/web-adaptor/12.0/install/java-linux/install-arcgis-web-adaptor-java-linux.htm
# ==============================================================================
echo ""
echo ">>> Step 8: Upgrading Web Adaptor"
echo ""

WA_SETUP=$(find "$INSTALLERS" -maxdepth 2 -name "Setup" -path "*WebAdaptor*" -type f 2>/dev/null | head -1)
if [[ -n "${WA_SETUP:-}" ]]; then
  WA_DIR=$(dirname "$WA_SETUP")
  echo "Found Web Adaptor installer: $WA_DIR"
  cd "$WA_DIR"
  sudo -u "$ARCGIS_USER" ./Setup -m silent -l yes

  # Re-deploy WARs to Tomcat
  echo "Re-deploying Web Adaptor WARs to Tomcat..."
  if [[ -f "$ESRI_BASE/webadaptor/java/arcgis.war" ]]; then
    cp "$ESRI_BASE/webadaptor/java/arcgis.war" /var/lib/tomcat9/webapps/portal.war
    cp "$ESRI_BASE/webadaptor/java/arcgis.war" /var/lib/tomcat9/webapps/server.war
    chown tomcat:tomcat /var/lib/tomcat9/webapps/portal.war
    chown tomcat:tomcat /var/lib/tomcat9/webapps/server.war
    systemctl restart tomcat9
    sleep 10
  fi
else
  echo "WARNING: Web Adaptor installer not found in $INSTALLERS"
fi

# ==============================================================================
# Step 9: Start Services (dependency order)
# ==============================================================================
echo ""
echo ">>> Step 9: Starting ArcGIS Services"
echo ""

echo "Starting ArcGIS Server..."
if [[ -f "$ESRI_BASE/arcgis/server/startserver.sh" ]]; then
  sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/server/startserver.sh" || true
  sleep 30
fi

echo "Starting Portal for ArcGIS..."
if [[ -f "$ESRI_BASE/arcgis/portal/startportal.sh" ]]; then
  sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/portal/startportal.sh" || true
  sleep 60
fi

echo "Starting ArcGIS Data Store..."
if [[ -f "$ESRI_BASE/arcgis/datastore/startdatastore.sh" ]]; then
  sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/datastore/startdatastore.sh" || true
  sleep 30
fi

# || true prevents set -euo pipefail from aborting if services need extra time
wait_for_service "https://localhost:6443/arcgis/rest/info" "ArcGIS Server" || true
wait_for_service "https://localhost:7443/arcgis/home" "Portal for ArcGIS" || true

# ==============================================================================
# Step 10: Post-Upgrade - Re-import Portal License (if available)
# Per Esri docs: After upgrading Portal, you may need to re-import the JSON
# license file to enable new user types or apps added in the new version.
# Ref: https://enterprise.arcgis.com/en/portal/12.0/install/linux/create-a-single-machine-portal.htm
# ==============================================================================
echo ""
echo ">>> Step 10: Post-Upgrade Tasks"
echo ""

if [[ -n "${PORTAL_LICENSE_FILE:-}" && -f "${PORTAL_LICENSE_FILE:-}" ]]; then
  echo "Re-importing Portal license file: $PORTAL_LICENSE_FILE"

  if [[ -n "${ADMIN_USER:-}" && -n "${ADMIN_PASS:-}" ]]; then
    # Get portal token
    TOKEN=$(curl -sk -X POST "https://localhost:7443/arcgis/sharing/rest/generateToken" \
      -d "username=$ADMIN_USER" \
      -d "password=$ADMIN_PASS" \
      -d "client=referer" \
      -d "referer=https://${DOMAIN:-localhost}" \
      -d "f=json" 2>/dev/null | jq -r '.token // empty') || true

    if [[ -n "${TOKEN:-}" ]]; then
      curl -sk -X POST "https://localhost:7443/arcgis/portaladmin/license/importEntitlements" \
        -F "file=@$PORTAL_LICENSE_FILE" \
        -F "token=$TOKEN" \
        -F "f=json" || true
      echo "Portal license re-imported."
    else
      echo "WARNING: Could not get Portal token. Re-import license manually."
    fi
  else
    echo "WARNING: Admin credentials not in .env. Re-import license manually."
  fi
else
  echo "No Portal license file found — skip license re-import."
fi

# Re-configure Web Adaptors after upgrade (required by Esri)
WA_TOOLS="$ESRI_BASE/webadaptor/java/tools"
if [[ -d "$WA_TOOLS" && -n "${ADMIN_USER:-}" && -n "${ADMIN_PASS:-}" && -n "${DOMAIN:-}" ]]; then
  sleep 20  # Allow Tomcat to finish deploying WARs

  echo "Re-configuring Web Adaptor for Portal..."
  cd "$WA_TOOLS"
  sudo -u "$ARCGIS_USER" ./configurewebadaptor.sh \
    -m portal \
    -w "https://$DOMAIN/portal/webadaptor" \
    -g "https://localhost:7443" \
    -u "$ADMIN_USER" \
    -p "$ADMIN_PASS" || true

  sleep 10

  echo "Re-configuring Web Adaptor for Server..."
  sudo -u "$ARCGIS_USER" ./configurewebadaptor.sh \
    -m server \
    -w "https://$DOMAIN/server/webadaptor" \
    -g "https://localhost:6443" \
    -u "$ADMIN_USER" \
    -p "$ADMIN_PASS" \
    -a true || true
else
  echo "Web Adaptor re-configuration skipped (missing credentials or domain)."
  echo "Re-configure manually after upgrade if needed."
fi

# Reload NGINX
systemctl reload nginx || true

# ==============================================================================
# Complete
# ==============================================================================
echo ""
echo "=============================================="
echo " Upgrade Complete!"
echo "=============================================="
echo ""
echo "Post-upgrade verification:"
echo "  1. Portal Home:  https://${DOMAIN:-<your-domain>}/portal/home"
echo "  2. Portal Admin: https://${DOMAIN:-<your-domain>}:7443/arcgis/portaladmin"
echo "  3. Server Admin: https://${DOMAIN:-<your-domain>}:6443/arcgis/admin"
echo "  4. Server REST:  https://${DOMAIN:-<your-domain>}/server/rest/services"
echo ""
echo "Backup saved to: $BACKUP_DIR"
echo ""
echo "If you encounter issues:"
echo "  - Check logs: $ESRI_BASE/arcgis/server/usr/logs"
echo "  - Check logs: $ESRI_BASE/arcgis/portal/usr/arcgisportal/logs"
echo "  - Re-authorize Server: authorizeSoftware -f <license.prvc> -e <email>"
echo "  - Re-import Portal license via Portal Admin > License"
echo ""
