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

Create a `.env` file:

```env
DOMAIN=gis.example.com
EMAIL=admin@example.com
CF_API_TOKEN=your_cloudflare_api_token
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

- Portal: https://<domain>/portal
- Server: https://<domain>/server
- Portal Admin: https://<domain>:7443/arcgis/portaladmin
- Server Admin: https://<domain>:6443/arcgis/admin

---

## 🧭 Manual Post‑Install Steps (Required)

1. License **Portal** and **Server**
2. Configure Web Adaptors (`/portal`, `/server`)
3. Register **Relational Data Store**
4. Create initial Portal admin user

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
