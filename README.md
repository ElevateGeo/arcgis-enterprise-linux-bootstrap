<p align="center">
  <img src="https://www.esri.com/content/dam/esrisites/en-us/common/icons/product-logos/ArcGIS-Enterprise.png" alt="ArcGIS Enterprise" width="80" />
</p>

<h1 align="center">🌍 ArcGIS Enterprise 12.0 Linux Bootstrap</h1>

<p align="center">
  <strong>One-command bootstrap for a single-machine ArcGIS Enterprise 12.0 deployment on Linux</strong><br/>
  with automatic HTTPS certificates via Cloudflare DNS
</p>

<p align="center">
  <a href="https://enterprise.arcgis.com/en/get-started/12.0/linux/tutorial-creating-your-first-web-gis-configuration.htm">📖 Esri Tutorial</a> ·
  <a href="#-quick-start">🚀 Quick Start</a> ·
  <a href="#-prerequisites">📋 Prerequisites</a> ·
  <a href="#-configuration">⚙️ Configuration</a>
</p>

---

## ✨ What This Sets Up

| Component | Details |
|-----------|---------|
| 🐧 **OS** | Ubuntu 22.04 LTS or 24.04 LTS |
| 🌐 **Portal for ArcGIS** | Web GIS hub |
| 🖥️ **ArcGIS GIS Server** | Map/feature services |
| 💾 **ArcGIS Data Store** | Relational + object stores |
| 🔌 **Web Adaptor** | Java / Tomcat 10.1 (auto-installed; required for 12.x Web Adaptor WAR) |
| 🔒 **HTTPS** | Let's Encrypt via Cloudflare DNS |
| ⚡ **NGINX** | Reverse proxy with WebSocket support |
| 📄 **Config** | `.env`-based (no secrets in scripts) |

### 🎯 Designed For

- ☁️ Azure, AWS, or on-prem Linux VMs
- 🧑‍💻 Any ArcGIS Enterprise license (Developer, Standard, Advanced)
- 💰 Lowest-cost, repeatable deployments

### 🚫 What This Is *Not*

- ❌ Production-ready
- ❌ High-availability
- ❌ Docker (not supported by Esri)

---

## 📋 Prerequisites

### 1. 🐧 Linux VM

- Ubuntu 22.04 LTS or 24.04 LTS
- 4 vCPU / 16 GB RAM minimum ([system requirements](https://enterprise.arcgis.com/en/system-requirements/12.0/linux/arcgis-enterprise-overall-system-requirements.htm))
- 💿 **100 GB+ free disk** (Portal extraction alone requires ~15 GB; full deployment needs 50+ GB)

### 2. 📦 ArcGIS Installers

Download from [My Esri](https://my.esri.com/) and place in `/opt/esri/installers`:

| File | Required |
|------|----------|
| `ArcGIS_Server_Linux_*.tar.gz` | ✅ Yes |
| `Portal_for_ArcGIS_Linux_*.tar.gz` | ✅ Yes |
| `ArcGIS_DataStore_Linux_*.tar.gz` | ✅ Yes |
| `Web_Adaptor_Java_Linux_*.tar.gz` | ✅ Yes |
| `Portal_for_ArcGIS_Web_Styles_Linux_*.tar.gz` | ⬜ Optional (3D symbols for Scene Viewer) |

### 3. 🔑 License Files

Download from [My Esri](https://my.esri.com/) and place in `/opt/esri/licenses`:

| File | Format | Notes |
|------|--------|-------|
| `ArcGIS_Enterprise_Portal_*.json` | JSON | Portal user types & apps |
| `*.prvc` (e.g., `ArcGISGISServerAdvanced_*.prvc`) | PRVC | Server provisioning file |

> 💡 **Tip:** Portal 12.0 uses `.json` (not `.prvc`). Server still uses `.prvc`.
> The script **auto-detects** matching files in `/opt/esri/licenses/`.

### 4. ☁️ Cloudflare

- Domain managed by Cloudflare
- API Token with permissions:
  - `Zone → DNS → Edit`
  - `Zone → Zone → Read`

---

## ⚙️ Configuration

Create a `.env` file (or the script will prompt and save automatically):

```env
# 🌐 Domain and SSL
DOMAIN='gis.example.com'
EMAIL='admin@example.com'
CF_API_TOKEN='your_cloudflare_api_token'

# 👤 Admin credentials (used for Portal and Server)
ADMIN_USER='siteadmin'
ADMIN_PASS='YourSecurePassword123!'
ADMIN_FIRST_NAME='Site'
ADMIN_LAST_NAME='Admin'
# Security question index (1-14):
#   1  What city were you born in?
#   2  What was your high school mascot?
#   3  What is your mother's maiden name?
#   4  What was the make of your first car?
#   5  What high school did you go to?
#   6  What is the last name of your best friend?
#   7  What is the middle name of your youngest sibling?
#   8  What is the name of the street on which you grew up?
#   9  What is the name of your favorite fictional character?
#  10  What is the name of your favorite pet?
#  11  What is the name of your favorite restaurant?
#  12  What is the title of your favorite book?
#  13  What is your dream job?
#  14  Where did you go on your honeymoon?
ADMIN_SECURITY_QUESTION='1'
ADMIN_SECURITY_ANSWER='Springfield'

# 🔑 License files (auto-detected if not specified)
PORTAL_LICENSE_FILE='/opt/esri/licenses/ArcGIS_Enterprise_Portal.json'
SERVER_LICENSE_FILE='/opt/esri/licenses/server.prvc'
```

> 💡 If any value is missing, the script will prompt you interactively and save it to `.env`.

---

## 🚀 Quick Start

### Option A: Download from GitHub (recommended)

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/ElevateGeo/arcgis-enterprise-linux-bootstrap/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

> ⚠️ The script reads `.env` from the **current directory**. Run it from the same folder as your `.env` file. Do not pipe via `curl | bash` — interactive prompts won't work.

### Option B: Clone the repo

```bash
git clone https://github.com/ElevateGeo/arcgis-enterprise-linux-bootstrap.git
cd arcgis-enterprise-linux-bootstrap
sudo chmod +x install.sh
sudo ./install.sh
```

> 🔄 The script is **idempotent** — safe to re-run. All steps check for prior completion.

### 🧨 Wipe and Reinstall (destructive)

If you’re stuck in a bad state and want a clean reinstall, you can wipe existing ArcGIS Enterprise components first:

```bash
sudo ./install.sh --wipe
```

For non-interactive automation (no prompt), add `--yes`:

```bash
sudo ./install.sh --wipe --yes
```

> ⚠️ **Destructive:** `--wipe` deletes the existing deployment under `/opt/esri/arcgis` (Portal/Server/Data Store/Web Adaptor install dirs) and removes Tomcat Web Adaptor deployments. This will remove your existing configuration/content unless you’ve backed it up.

### ⬆️ Upgrade Existing Installation

1. Place new version installers in `/opt/esri/installers`
2. Download and run:

```bash
curl -fsSL -o upgrade.sh https://raw.githubusercontent.com/ElevateGeo/arcgis-enterprise-linux-bootstrap/main/upgrade.sh
chmod +x upgrade.sh
sudo ./upgrade.sh
```

<details>
<summary>📄 What the upgrade does</summary>

- 🛑 Stop all ArcGIS services (reverse dependency order)
- 💾 Backup configuration
- 🔧 Verify system tuning (ulimits, sysctl)
- 📦 Upgrade each component in Esri's documented order
- 🔑 Re-authorize ArcGIS Server (via `-a` flag)
- ▶️ Restart services (dependency order)
- 📄 Re-import Portal JSON license
- 🔌 Re-configure Web Adaptors
- 🔄 Reload NGINX

</details>

---

## 🌐 Access After Install

| Service | URL |
|---------|-----|
| 🏠 Portal Home | `https://YOUR_DOMAIN/portal/home` |
| 🔧 Portal Admin | `https://YOUR_DOMAIN:7443/arcgis/portaladmin` |
| 🗺️ Server REST | `https://YOUR_DOMAIN/server/rest/services` |
| ⚙️ Server Admin | `https://YOUR_DOMAIN:6443/arcgis/admin` |

---

## 📝 Installation Steps

The `install.sh` script follows [Esri's documented deployment order](https://enterprise.arcgis.com/en/get-started/12.0/linux/tutorial-creating-your-first-web-gis-configuration.htm):

| Step | Action | Reference |
|:----:|--------|:---------:|
| 1️⃣ | Install system dependencies (NGINX, Tomcat, OpenJDK 11, Certbot) | |
| 2️⃣ | Configure SSL certificates via Cloudflare DNS | |
| 3️⃣ | Configure NGINX reverse proxy (WebSocket support) | |
| 4️⃣ | Create `arcgis` user, set ulimits & sysctl | [📖](https://enterprise.arcgis.com/en/server/12.0/install/linux/arcgis-server-system-requirements.htm) |
| 5️⃣ | Extract installer archives | |
| 6️⃣ | Install & authorize ArcGIS Server (`-a` flag) | [📖](https://enterprise.arcgis.com/en/server/12.0/install/linux/silently-install-arcgis-server.htm) |
| 7️⃣ | Install Portal for ArcGIS (+ Web Styles if present) | [📖](https://enterprise.arcgis.com/en/portal/12.0/install/linux/install-portal-for-arcgis.htm) |
| 8️⃣ | Install ArcGIS Data Store | [📖](https://enterprise.arcgis.com/en/data-store/12.0/install/linux/install-arcgis-data-store.htm) |
| 9️⃣ | Install Web Adaptor + deploy WARs to Tomcat | [📖](https://enterprise.arcgis.com/en/web-adaptor/12.0/install/java-linux/install-arcgis-web-adaptor-java-linux.htm) |
| 🔟 | Start all ArcGIS services | |
| 1️⃣1️⃣ | Create Server site (`createsite.sh`) | [📖](https://enterprise.arcgis.com/en/server/12.0/deploy/linux/creating-a-new-site.htm) |
| 1️⃣2️⃣ | Create Portal with JSON license (`-lf` flag) | [📖](https://enterprise.arcgis.com/en/portal/12.0/install/linux/create-a-single-machine-portal.htm) |
| 1️⃣3️⃣ | Configure Web Adaptors | [📖](https://enterprise.arcgis.com/en/web-adaptor/12.0/install/java-linux/configure-arcgis-web-adaptor-portal.htm) |
| 1️⃣4️⃣ | Federate Server with Portal | [📖](https://enterprise.arcgis.com/en/portal/12.0/administer/linux/federate-an-arcgis-server-site-with-your-portal.htm) |
| 1️⃣5️⃣ | Register/configure relational & object data stores | [📖](https://enterprise.arcgis.com/en/get-started/12.0/linux/base-arcgis-enterprise-deployment.htm) |

---

## 🔐 Key Esri Compliance Notes

| Topic | Details |
|-------|---------|
| 🔑 **Server auth** | Done during install (Step 6) via `-a` flag — avoids standalone `authorizeSoftware` which needs `-e EMAIL` for `.prvc` |
| 📄 **Portal license** | JSON imported during creation (Step 12) via `-lf` flag |
| 💾 **Object store** | Registered alongside relational (Step 14) — [required in 12.0](https://enterprise.arcgis.com/en/get-started/12.0/linux/base-arcgis-enterprise-deployment.htm) |
| ⚙️ **Kernel params** | `vm.max_map_count=262144`, `vm.swappiness=1` per Esri system requirements |

---

## 🛠️ Manual Steps (if automation fails)

<details>
<summary>🔧 Click to expand manual steps</summary>

#### 🔑 Authorize ArcGIS Server (standalone)

```bash
cd /opt/esri/arcgis/server/tools/authorizeSoftware
sudo -u arcgis ./authorizeSoftware -f /opt/esri/licenses/YOUR_SERVER_LICENSE.prvc -e admin@example.com
```

#### 🏗️ Create Initial Portal Administrator

```bash
cd /opt/esri/arcgis/portal/tools/createportal
sudo -u arcgis ./createportal.sh \
  -fn "Admin" -ln "User" \
  -u siteadmin -p "YourSecurePassword123!" \
  -e admin@example.com \
  -qi 1 -qa "Springfield" \
  -d /opt/esri/arcgis/portal/usr/arcgisportal \
  -lf /opt/esri/licenses/ArcGIS_Enterprise_Portal_120_551327_20260122.json
```

#### 🖥️ Create ArcGIS Server Site

```bash
cd /opt/esri/arcgis/server/tools/createsite
sudo -u arcgis ./createsite.sh \
  -u siteadmin -p "YourSecurePassword123!" \
  -d /opt/esri/arcgis/server/usr/directories \
  -c /opt/esri/arcgis/server/usr/config-store
```

#### 🔌 Configure Web Adaptors

```bash
# Find the tools directory (versioned path)
WA_TOOLS=$(find /opt/esri -path "*/webadaptor*/java/tools" -type d | head -1)
cd "$WA_TOOLS"

# Portal
sudo -u arcgis ./configurewebadaptor.sh \
  -m portal -w https://YOUR_DOMAIN/portal/webadaptor \
  -g https://localhost:7443 -u siteadmin -p "YourSecurePassword123!"

# Server
sudo -u arcgis ./configurewebadaptor.sh \
  -m server -w https://YOUR_DOMAIN/server/webadaptor \
  -g https://localhost:6443 -u siteadmin -p "YourSecurePassword123!" -a true
```

#### 💾 Register Data Stores

```bash
cd /opt/esri/arcgis/datastore/tools

# Relational
sudo -u arcgis ./configuredatastore.sh \
  https://localhost:6443/arcgis/admin siteadmin "YourSecurePassword123!" \
  /opt/esri/arcgis/datastore/usr/arcgisdatastore --stores relational

# Object (required for 12.0)
sudo -u arcgis ./configuredatastore.sh \
  https://localhost:6443/arcgis/admin siteadmin "YourSecurePassword123!" \
  /opt/esri/arcgis/datastore/usr/arcgisdatastore --stores object
```

#### 🔗 Federate Server with Portal

1. Log in to Portal: `https://YOUR_DOMAIN/portal/home`
2. Go to **Organization** → **Settings** → **Servers**
3. Click **Add Server**:
   - **Server URL**: `https://YOUR_DOMAIN/server`
   - **Admin URL**: `https://YOUR_DOMAIN:6443/arcgis`
4. Set as **Hosting Server**

</details>

---

## ✅ Verify Installation

| Check | URL | Expected |
|-------|-----|----------|
| 🏠 Portal Home | `https://YOUR_DOMAIN/portal/home` | Sign-in page |
| 💚 Portal Health | `https://YOUR_DOMAIN:7443/arcgis/portaladmin/healthCheck` | `{"status":"success"}` |
| 🗺️ Server Services | `https://YOUR_DOMAIN/server/rest/services` | Services directory |
| 💚 Server Health | `https://YOUR_DOMAIN:6443/arcgis/admin/healthCheck` | `{"status":"success"}` |

---

## 🔄 Auto-Renew Certificates

Certbot renews automatically via system timers. NGINX reloads safely on renewal. No action needed.

---

## 💡 Why Linux + VM?

ArcGIS Enterprise is **stateful**, **host-bound**, and **not container-friendly**.
Linux VMs provide the best stability, cost, and automation balance.

---

## 📄 License

This repository contains **no Esri software**.
You must comply with [Esri licensing terms](https://www.esri.com/legal/licensing-translations).

MIT License for scripts and documentation.

---

<p align="center">
  Made with ❤️ by <a href="https://github.com/ElevateGeo">ElevateGeo</a>
</p>
