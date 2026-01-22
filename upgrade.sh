#!/usr/bin/env bash
set -e

# ArcGIS Enterprise Upgrade Script
# This script upgrades an existing ArcGIS Enterprise deployment

ENV_FILE=".env"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

ESRI_BASE="/opt/esri"
INSTALLERS="$ESRI_BASE/installers"
ARCGIS_USER="arcgis"

echo "=============================================="
echo " ArcGIS Enterprise Upgrade"
echo "=============================================="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo)"
  exit 1
fi

# Verify arcgis user exists
if ! id "$ARCGIS_USER" &>/dev/null; then
  echo "ERROR: User '$ARCGIS_USER' not found. Is ArcGIS Enterprise installed?"
  exit 1
fi

# Check for upgrade installers
if [[ ! -d "$INSTALLERS" ]]; then
  echo "ERROR: Installers directory not found: $INSTALLERS"
  echo "Please place upgrade installers in $INSTALLERS"
  exit 1
fi

echo ""
echo ">>> Step 1: Stopping ArcGIS Services"
echo ""

# Stop services in reverse dependency order
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

echo ""
echo ">>> Step 2: Backing Up Configuration"
echo ""

BACKUP_DIR="$ESRI_BASE/backup/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

# Backup important configuration files
if [[ -d "$ESRI_BASE/arcgis/server" ]]; then
  cp -r "$ESRI_BASE/arcgis/server/framework/etc" "$BACKUP_DIR/server_etc" 2>/dev/null || true
fi

if [[ -d "$ESRI_BASE/arcgis/portal" ]]; then
  cp -r "$ESRI_BASE/arcgis/portal/framework/etc" "$BACKUP_DIR/portal_etc" 2>/dev/null || true
fi

echo "Backup saved to: $BACKUP_DIR"

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

echo ""
echo ">>> Step 4: Running Component Upgrades"
echo ""

# Upgrade ArcGIS Server
if [[ -d "$INSTALLERS/ArcGISServer" ]]; then
  echo "Upgrading ArcGIS Server..."
  cd "$INSTALLERS/ArcGISServer"
  sudo -u "$ARCGIS_USER" ./Setup -m silent -l yes
fi

# Upgrade Portal for ArcGIS
if [[ -d "$INSTALLERS/PortalForArcGIS" ]]; then
  echo "Upgrading Portal for ArcGIS..."
  cd "$INSTALLERS/PortalForArcGIS"
  sudo -u "$ARCGIS_USER" ./Setup -m silent -l yes
fi

# Upgrade ArcGIS Data Store
if [[ -d "$INSTALLERS/ArcGISDataStore" ]]; then
  echo "Upgrading ArcGIS Data Store..."
  cd "$INSTALLERS/ArcGISDataStore"
  sudo -u "$ARCGIS_USER" ./Setup -m silent -l yes
fi

# Upgrade Web Adaptor
if [[ -d "$INSTALLERS/WebAdaptor" ]]; then
  echo "Upgrading Web Adaptor..."
  cd "$INSTALLERS/WebAdaptor"
  sudo -u "$ARCGIS_USER" ./Setup -m silent -l yes
fi

echo ""
echo ">>> Step 5: Starting ArcGIS Services"
echo ""

# Start services in dependency order
echo "Starting ArcGIS Server..."
if [[ -f "$ESRI_BASE/arcgis/server/startserver.sh" ]]; then
  sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/server/startserver.sh"
fi

echo "Starting Portal for ArcGIS..."
if [[ -f "$ESRI_BASE/arcgis/portal/startportal.sh" ]]; then
  sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/portal/startportal.sh"
fi

echo "Starting ArcGIS Data Store..."
if [[ -f "$ESRI_BASE/arcgis/datastore/startdatastore.sh" ]]; then
  sudo -u "$ARCGIS_USER" "$ESRI_BASE/arcgis/datastore/startdatastore.sh"
fi

echo ""
echo ">>> Step 6: Post-Upgrade Tasks"
echo ""

# Reload NGINX to pick up any changes
systemctl reload nginx || true

echo ""
echo "=============================================="
echo " Upgrade Complete!"
echo "=============================================="
echo ""
echo "Post-upgrade steps:"
echo "  1. Verify services at https://$DOMAIN/portal"
echo "  2. Check Portal Admin: https://$DOMAIN:7443/arcgis/portaladmin"
echo "  3. Check Server Admin: https://$DOMAIN:6443/arcgis/admin"
echo "  4. Re-register Web Adaptors if needed"
echo "  5. Review backup at: $BACKUP_DIR"
echo ""
