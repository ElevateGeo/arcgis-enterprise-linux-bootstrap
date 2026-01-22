# ArcGIS Enterprise Linux Bootstrap

One-command bootstrap for a **single-machine ArcGIS Enterprise deployment on Linux**
with **automatic HTTPS certificates via Cloudflare DNS**.

This repository is designed for:
- ArcGIS **Developer Bundle** (dev/test, non-production)
- Azure, AWS, or on‑prem Linux VMs
- Lowest-cost, repeatable deployments

---

## ✨ What This Sets Up

- Ubuntu 22.04 LTS
- ArcGIS Enterprise (single machine):
  - Portal for ArcGIS
  - ArcGIS GIS Server
  - ArcGIS Data Store (relational only)
  - Web Adaptor (Java)
- NGINX reverse proxy
- Automatic HTTPS (Let’s Encrypt via Cloudflare DNS)
- `.env`‑based configuration (no secrets in scripts)

---

## 🚫 What This Is *Not*

- ❌ Production‑ready
- ❌ High‑availability
- ❌ Docker / Kubernetes (not supported by Esri)

---

## 📦 Prerequisites

1. **Linux VM**
   - Ubuntu 22.04 LTS
   - 4 vCPU / 16 GB RAM recommended (B4ms equivalent)

2. **ArcGIS Installers (Linux)**
   Download from My Esri and place in:

   ```
   /opt/esri/installers
   ```

   Required files:
   - ArcGIS_Server_Linux_*.tar.gz
   - Portal_for_ArcGIS_Linux_*.tar.gz
   - ArcGIS_DataStore_Linux_*.tar.gz
   - Web_Adaptor_Java_Linux_*.tar.gz

3. **Cloudflare**
   - Domain managed by Cloudflare
   - API Token with:
     - Zone → DNS → Edit
     - Zone → Read

---

## ⚙️ Configuration

Create a `.env` file (or the script will prompt for values and save them):

```env
# Domain and SSL
DOMAIN=gis.example.com
EMAIL=admin@example.com
CF_API_TOKEN=your_cloudflare_api_token

# Admin credentials (used for Portal and Server)
ADMIN_USER=siteadmin
ADMIN_PASS=YourSecurePassword123!
ADMIN_FIRST_NAME=Site
ADMIN_LAST_NAME=Admin
ADMIN_SECURITY_QUESTION=What is your favorite color?
ADMIN_SECURITY_ANSWER=Blue

# License files
PORTAL_LICENSE_FILE=/opt/esri/licenses/portal.prvc
SERVER_LICENSE_FILE=/opt/esri/licenses/server.prvc
```

If any value is missing, the script will prompt you and save it automatically.

---

## 🚀 Usage

### Fresh Install

```bash
sudo chmod +x install.sh
sudo ./install.sh
```

The script is safe to re-run.

### Upgrade Existing Installation

1. Place new version installers in `/opt/esri/installers`
2. Run the upgrade script:

```bash
sudo chmod +x upgrade.sh
sudo ./upgrade.sh
```

The upgrade script will:
- Stop all ArcGIS services
- Backup configuration
- Run component upgrades
- Restart services

---

## 🔐 Access After Install

- Portal: https://YOUR_DOMAIN/portal
- Server: https://YOUR_DOMAIN/server
- Portal Admin: https://YOUR_DOMAIN:7443/arcgis/portaladmin
- Server Admin: https://YOUR_DOMAIN:6443/arcgis/admin

---

## 🧭 Automated Installation Steps

The `install.sh` script performs all of the following automatically:

1. ✅ Install system dependencies (NGINX, Tomcat, Java, Certbot)
2. ✅ Configure SSL certificates via Cloudflare DNS
3. ✅ Configure NGINX reverse proxy
4. ✅ Create `arcgis` system user with proper limits
5. ✅ Install ArcGIS Server
6. ✅ Install Portal for ArcGIS
7. ✅ Install ArcGIS Data Store
8. ✅ Install and deploy Web Adaptors
9. ✅ Create ArcGIS Server site
10. ✅ Create Portal administrator account
11. ✅ Authorize Portal and Server (if license files provided)
12. ✅ Configure Web Adaptors for Portal and Server
13. ✅ Register relational Data Store
14. ✅ Federate Server with Portal
15. ✅ Set Server as hosting server

### Manual Steps (Only if automation fails)

<details>
<summary>Click to expand manual steps</summary>

#### Create Initial Portal Administrator

```bash
cd /opt/esri/arcgis/portal/tools/createportal
sudo -u arcgis ./createportal.sh \
  -fn "Admin" \
  -ln "User" \
  -u portaladmin \
  -p "YourSecurePassword123!" \
  -e admin@example.com \
  -qi "What is your favorite color?" \
  -qa "Blue"
```

#### Authorize Portal for ArcGIS

```bash
cd /opt/esri/arcgis/portal/tools/authorizeSoftware
sudo -u arcgis ./authorizeSoftware -f /opt/esri/licenses/portal.prvc
```

#### Authorize ArcGIS Server

```bash
cd /opt/esri/arcgis/server/tools/authorizeSoftware
sudo -u arcgis ./authorizeSoftware -f /opt/esri/licenses/server.prvc
```

#### Configure Web Adaptor for Portal

```bash
cd /opt/esri/webadaptor/java/tools
sudo -u arcgis ./configurewebadaptor.sh \
  -m portal \
  -w https://YOUR_DOMAIN/portal/webadaptor \
  -g https://YOUR_DOMAIN:7443 \
  -u portaladmin \
  -p "YourSecurePassword123!"
```

#### Configure Web Adaptor for Server

```bash
cd /opt/esri/webadaptor/java/tools
sudo -u arcgis ./configurewebadaptor.sh \
  -m server \
  -w https://YOUR_DOMAIN/server/webadaptor \
  -g https://YOUR_DOMAIN:6443 \
  -u siteadmin \
  -p "YourSecurePassword123!" \
  -a true
```

#### Register Relational Data Store

```bash
cd /opt/esri/arcgis/datastore/tools
sudo -u arcgis ./configuredatastore.sh \
  https://YOUR_DOMAIN:6443/arcgis/admin \
  siteadmin \
  "YourSecurePassword123!" \
  /opt/esri/arcgis/datastore/data \
  --stores relational
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

- Portal Home: `https://YOUR_DOMAIN/portal/home`
- Portal Health Check: `https://YOUR_DOMAIN:7443/arcgis/portaladmin/healthCheck`
- Server Services: `https://YOUR_DOMAIN/server/rest/services`
- Server Health Check: `https://YOUR_DOMAIN:6443/arcgis/admin/healthCheck`

---

## 🔄 Auto‑Renew Certificates

Certbot renews automatically via system timers.
NGINX reloads safely on renewal.

---

## 🧠 Why Linux + VM?

ArcGIS Enterprise is:
- Stateful
- Host‑bound
- Not container‑friendly

Linux VMs provide the best stability, cost, and automation balance.

---

## 📄 License

This repository contains **no Esri software**.
You must comply with Esri licensing terms.

MIT License for scripts and documentation.
