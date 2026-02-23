# ArcGIS Enterprise 12.0 Linux Bootstrap

One-command bootstrap for a **single-machine ArcGIS Enterprise 12.0 deployment on Linux**
with **automatic HTTPS certificates via Cloudflare DNS**.

This repository is designed for:
- ArcGIS **Developer Bundle** (dev/test, non-production)
- Azure, AWS, or on‑prem Linux VMs
- Lowest-cost, repeatable deployments

> **Reference:** [Tutorial: Set up a base ArcGIS Enterprise deployment](https://enterprise.arcgis.com/en/get-started/12.0/linux/tutorial-creating-your-first-web-gis-configuration.htm)

---

## What This Sets Up

- Ubuntu 22.04 LTS
- ArcGIS Enterprise 12.0 (single machine):
  - Portal for ArcGIS
  - ArcGIS GIS Server
  - ArcGIS Data Store (relational + object)
  - Web Adaptor (Java / Tomcat 9)
- NGINX reverse proxy with WebSocket support
- Automatic HTTPS (Let's Encrypt via Cloudflare DNS)
- `.env`‑based configuration (no secrets in scripts)

---

## What This Is *Not*

- ❌ Production‑ready
- ❌ High‑availability
- ❌ Docker / Kubernetes (not supported by Esri)

---

## Prerequisites

1. **Linux VM**
   - Ubuntu 22.04 LTS (22.04.5 or later)
   - 4 vCPU / 16 GB RAM minimum ([system requirements](https://enterprise.arcgis.com/en/system-requirements/12.0/linux/arcgis-enterprise-overall-system-requirements.htm))
   - 20 GB+ free disk space

2. **ArcGIS Installers (Linux)**
   Download from [My Esri](https://my.esri.com/) and place in:

   ```
   /opt/esri/installers
   ```

   Required files:
   - `ArcGIS_Server_Linux_*.tar.gz`
   - `Portal_for_ArcGIS_Linux_*.tar.gz`
   - `ArcGIS_DataStore_Linux_*.tar.gz`
   - `Web_Adaptor_Java_Linux_*.tar.gz`

   Optional:
   - `Portal_for_ArcGIS_Web_Styles_Linux_*.tar.gz` (3D symbols for Scene Viewer — not required)

3. **ArcGIS License Files**
   Download from [My Esri](https://my.esri.com/) and place in:

   ```
   /opt/esri/licenses
   ```

   Required files:
   - `ArcGIS_Enterprise_Portal_*.json` — Portal authorization file (JSON format, contains user types and apps)
   - `*.prvc` — ArcGIS Server provisioning file (e.g., `ArcGISGISServerAdvanced_DeveloperArcGISServer_*.prvc`)

   > **Note:** Portal 12.0 uses a `.json` license file (not `.prvc`). Server still uses `.prvc`.
   > The script auto-detects any matching files in `/opt/esri/licenses/`.

4. **Cloudflare**
   - Domain managed by Cloudflare
   - API Token with:
     - Zone → DNS → Edit
     - Zone → Read

---

## Configuration

Create a `.env` file (or the script will prompt for values and save them):

```env
# Domain and SSL
DOMAIN='gis.example.com'
EMAIL='admin@example.com'
CF_API_TOKEN='your_cloudflare_api_token'

# Admin credentials (used for Portal and Server)
ADMIN_USER='siteadmin'
ADMIN_PASS='YourSecurePassword123!'
ADMIN_FIRST_NAME='Site'
ADMIN_LAST_NAME='Admin'
ADMIN_SECURITY_QUESTION='What is your favorite color?'
ADMIN_SECURITY_ANSWER='Blue'

# License files (auto-detected from /opt/esri/licenses if not specified)
# Portal: JSON file from My Esri (user types and apps)
# Server: .prvc provisioning file
PORTAL_LICENSE_FILE='/opt/esri/licenses/ArcGIS_Enterprise_Portal.json'
SERVER_LICENSE_FILE='/opt/esri/licenses/server.prvc'
```

If any value is missing, the script will prompt you and save it automatically.

---

## Usage

### Fresh Install

```bash
sudo chmod +x install.sh
sudo ./install.sh
```

The script is safe to re-run (idempotent — all steps check for prior completion).

### Upgrade Existing Installation

1. Place new version installers in `/opt/esri/installers`
2. Run the upgrade script:

```bash
sudo chmod +x upgrade.sh
sudo ./upgrade.sh
```

The upgrade script will:
- Stop all ArcGIS services (reverse dependency order)
- Backup configuration
- Verify system tuning (ulimits, sysctl)
- Upgrade each component in Esri's documented order
- Re-authorize ArcGIS Server (via `-a` flag)
- Restart services (dependency order)
- Re-import Portal JSON license file
- Re-configure Web Adaptors
- Reload NGINX

---

## Access After Install

| Service | URL |
|---------|-----|
| Portal Home | `https://YOUR_DOMAIN/portal/home` |
| Portal Admin | `https://YOUR_DOMAIN:7443/arcgis/portaladmin` |
| Server REST | `https://YOUR_DOMAIN/server/rest/services` |
| Server Admin | `https://YOUR_DOMAIN:6443/arcgis/admin` |

---

## Automated Installation Steps

The `install.sh` script follows [Esri's documented deployment order](https://enterprise.arcgis.com/en/get-started/12.0/linux/tutorial-creating-your-first-web-gis-configuration.htm):

| Step | Action | Esri Reference |
|------|--------|----------------|
| 1 | Install system dependencies (NGINX, Tomcat 9, OpenJDK 11, Certbot) | |
| 2 | Configure SSL certificates via Cloudflare DNS | |
| 3 | Configure NGINX reverse proxy (with WebSocket support) | |
| 4 | Create `arcgis` user, set ulimits and sysctl kernel parameters | [Server system requirements](https://enterprise.arcgis.com/en/server/12.0/install/linux/arcgis-server-system-requirements.htm) |
| 5 | Extract installer tar.gz archives | |
| 6 | Install **and authorize** ArcGIS Server (via `-a` flag during install) | [Install ArcGIS Server silently](https://enterprise.arcgis.com/en/server/12.0/install/linux/silently-install-arcgis-server.htm) |
| 7 | Install Portal for ArcGIS (+ Web Styles if present) | [Install Portal for ArcGIS](https://enterprise.arcgis.com/en/portal/12.0/install/linux/install-portal-for-arcgis.htm) |
| 8 | Install ArcGIS Data Store | [Install ArcGIS Data Store](https://enterprise.arcgis.com/en/data-store/12.0/install/linux/install-arcgis-data-store.htm) |
| 9 | Install Web Adaptor + deploy WARs to Tomcat | [Install Web Adaptor (Java)](https://enterprise.arcgis.com/en/web-adaptor/12.0/install/java-linux/install-arcgis-web-adaptor-java-linux.htm) |
| 10 | Start all ArcGIS services | |
| 11 | Create ArcGIS Server site (via `createsite.sh`) | [Create a site](https://enterprise.arcgis.com/en/server/12.0/deploy/linux/creating-a-new-site.htm) |
| 12 | Create Portal with JSON license file (via `-lf` flag) | [Create a single machine portal](https://enterprise.arcgis.com/en/portal/12.0/install/linux/create-a-single-machine-portal.htm) |
| 13 | Configure Web Adaptors for Portal and Server | [Configure Web Adaptor](https://enterprise.arcgis.com/en/web-adaptor/12.0/install/java-linux/configure-arcgis-web-adaptor-portal.htm) |
| 14 | Register relational **and** object data stores | [Base deployment requirements](https://enterprise.arcgis.com/en/get-started/12.0/linux/base-arcgis-enterprise-deployment.htm) |
| 15 | Federate Server with Portal, set as hosting server | [Federate a server](https://enterprise.arcgis.com/en/portal/12.0/administer/linux/federate-an-arcgis-server-site-with-your-portal.htm) |

### Key Esri Compliance Notes

- **Server authorization** is done during install (Step 6) using the `-a` flag, which is the [recommended silent install method](https://enterprise.arcgis.com/en/server/12.0/install/linux/silently-install-arcgis-server.htm). This avoids the standalone `authorizeSoftware` tool which requires `-e EMAIL` for `.prvc` files.
- **Portal license** (JSON) is imported during portal creation (Step 12) using the `-lf` flag, per [Esri's portal creation docs](https://enterprise.arcgis.com/en/portal/12.0/install/linux/create-a-single-machine-portal.htm).
- **Object store** is registered in addition to relational (Step 14), as [required by base deployment in 12.0](https://enterprise.arcgis.com/en/get-started/12.0/linux/base-arcgis-enterprise-deployment.htm).
- **Kernel parameters** (`vm.max_map_count=262144`, `vm.swappiness=1`) are set per [Portal](https://enterprise.arcgis.com/en/portal/12.0/install/linux/system-requirements-portal.htm) and [Data Store](https://enterprise.arcgis.com/en/data-store/12.0/install/linux/data-store-system-requirements.htm) system requirements.

### Manual Steps (Only if automation fails)

<details>
<summary>Click to expand manual steps</summary>

#### Authorize ArcGIS Server (standalone)

If Server was installed without the `-a` flag, authorize manually.
The `-e` flag (email) is **required** when using a `.prvc` file with the standalone tool:

```bash
cd /opt/esri/arcgis/server/tools/authorizeSoftware
sudo -u arcgis ./authorizeSoftware -f /opt/esri/licenses/YOUR_SERVER_LICENSE.prvc -e admin@example.com
```

#### Create Initial Portal Administrator

```bash
cd /opt/esri/arcgis/portal/tools/createportal
sudo -u arcgis ./createportal.sh \
  -fn "Admin" \
  -ln "User" \
  -u siteadmin \
  -p "YourSecurePassword123!" \
  -e admin@example.com \
  -qi "What is your favorite color?" \
  -qa "Blue" \
  -d /opt/esri/arcgis/portal/usr/arcgisportal \
  -lf /opt/esri/licenses/ArcGIS_Enterprise_Portal_120_551327_20260122.json
```

#### Create ArcGIS Server Site

```bash
cd /opt/esri/arcgis/server/tools/createsite
sudo -u arcgis ./createsite.sh \
  -u siteadmin \
  -p "YourSecurePassword123!" \
  -d /opt/esri/arcgis/server/usr/directories \
  -c /opt/esri/arcgis/server/usr/config-store
```

#### Configure Web Adaptor for Portal

```bash
cd /opt/esri/webadaptor/java/tools
sudo -u arcgis ./configurewebadaptor.sh \
  -m portal \
  -w https://YOUR_DOMAIN/portal/webadaptor \
  -g https://localhost:7443 \
  -u siteadmin \
  -p "YourSecurePassword123!"
```

#### Configure Web Adaptor for Server

```bash
cd /opt/esri/webadaptor/java/tools
sudo -u arcgis ./configurewebadaptor.sh \
  -m server \
  -w https://YOUR_DOMAIN/server/webadaptor \
  -g https://localhost:6443 \
  -u siteadmin \
  -p "YourSecurePassword123!" \
  -a true
```

#### Register Data Stores

```bash
cd /opt/esri/arcgis/datastore/tools

# Relational data store
sudo -u arcgis ./configuredatastore.sh \
  https://localhost:6443/arcgis/admin \
  siteadmin \
  "YourSecurePassword123!" \
  /opt/esri/arcgis/datastore/usr/arcgisdatastore \
  --stores relational

# Object store (required for 12.0 base deployment)
sudo -u arcgis ./configuredatastore.sh \
  https://localhost:6443/arcgis/admin \
  siteadmin \
  "YourSecurePassword123!" \
  /opt/esri/arcgis/datastore/usr/arcgisdatastore \
  --stores object
```

#### Federate Server with Portal

1. Log in to Portal: `https://YOUR_DOMAIN/portal/home`
2. Go to **Organization** → **Settings** → **Servers**
3. Click **Add Server** and enter:
   - **Server URL**: `https://YOUR_DOMAIN/server`
   - **Admin URL**: `https://YOUR_DOMAIN:6443/arcgis`
   - **Username**: `siteadmin`
   - **Password**: Your server admin password
4. Set as **Hosting Server**

</details>

### Verify Installation

| Check | URL |
|-------|-----|
| Portal Home | `https://YOUR_DOMAIN/portal/home` |
| Portal Health | `https://YOUR_DOMAIN:7443/arcgis/portaladmin/healthCheck` |
| Server Services | `https://YOUR_DOMAIN/server/rest/services` |
| Server Health | `https://YOUR_DOMAIN:6443/arcgis/admin/healthCheck` |

---

## Auto‑Renew Certificates

Certbot renews automatically via system timers.
NGINX reloads safely on renewal.

---

## Why Linux + VM?

ArcGIS Enterprise is:
- Stateful
- Host‑bound
- Not container‑friendly

Linux VMs provide the best stability, cost, and automation balance.

---

## License

This repository contains **no Esri software**.
You must comply with [Esri licensing terms](https://www.esri.com/legal/licensing-translations).

MIT License for scripts and documentation.
