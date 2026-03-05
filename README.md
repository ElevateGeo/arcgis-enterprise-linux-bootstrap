<p align="center">
  <img src="https://www.esri.com/content/dam/esrisites/en-us/common/icons/product-logos/ArcGIS-Enterprise.png" alt="ArcGIS Enterprise" width="80"/>
</p>

<h1 align="center">ArcGIS Enterprise Linux Bootstrap</h1>

<p align="center">
  <strong>One command. Full deployment. Zero hassle.</strong>
</p>

<p align="center">
  <a href="#-quick-start"><img src="https://img.shields.io/badge/Quick_Start-blue?style=for-the-badge" alt="Quick Start"/></a>
  <a href="#-features"><img src="https://img.shields.io/badge/Features-green?style=for-the-badge" alt="Features"/></a>
  <a href="#-troubleshooting"><img src="https://img.shields.io/badge/Troubleshooting-orange?style=for-the-badge" alt="Troubleshooting"/></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/ArcGIS_Enterprise-12.x-0079C1?style=flat-square&logo=esri" alt="ArcGIS Enterprise 12"/>
  <img src="https://img.shields.io/badge/Ubuntu-24.x-E95420?style=flat-square&logo=ubuntu&logoColor=white" alt="Ubuntu 24"/>
  <img src="https://img.shields.io/badge/Let's_Encrypt-SSL-003A70?style=flat-square&logo=letsencrypt" alt="Let's Encrypt"/>
  <img src="https://img.shields.io/badge/License-MIT-yellow?style=flat-square" alt="License"/>
</p>

---

Single-command installation of ArcGIS Enterprise on Linux following Esri's recommendations for single-machine deployments. Includes automatic SSL certificate provisioning and renewal via Let's Encrypt.

<br/>

## ✨ Features

| Feature | Description |
|:-------:|-------------|
| 🚀 | **One Command Install** — Run `sudo ./install.sh` and walk away |
| 🔍 | **Auto-Discovery** — Automatically finds FQDN, license files, and installer |
| �🔐 | **Let's Encrypt SSL** — Automatic certificate provisioning and renewal |
| 🔒 | **Git-Safe Configuration** — Sensitive values in `.env` (gitignored) |
| 📋 | **Esri Best Practices** — Follows single-machine deployment guidelines |
| 🔄 | **Auto-Renewal Hooks** — Certificates automatically updated in ArcGIS when renewed |
| ✅ | **Pre-flight Checks** — Validate your setup before installation |

<br/>

## 📋 Prerequisites

<details>
<summary><strong>🖥️ VM Requirements</strong></summary>

<br/>

| Requirement | Specification |
|:------------|:--------------|
| **OS** | Ubuntu 24.x |
| **RAM** | Minimum 16GB *(32GB recommended)* |
| **Storage** | Minimum 100GB |
| **CPU** | 8+ cores recommended |
| **Ports** | 80, 443, 6443, 7443 open |

</details>

<details>
<summary><strong>📄 Required Files on VM</strong></summary>

<br/>

**License Files:**
- ArcGIS Server license (`.prvc` or `.json`)
- Portal for ArcGIS license (`.json`)

**Installer:**
- ArcGIS Enterprise Builder for Linux tarball

</details>

<details>
<summary><strong>🌐 DNS & Hostname Configuration</strong></summary>

<br/>

**External DNS**: Ensure your domain points to the VM's public IP *(required for Let's Encrypt)*:
```
gis.example.com  →  <your-public-ip>
```

**Hosts File**: The install script automatically adds a local hosts entry so ArcGIS components can communicate internally without hairpin NAT:
```
127.0.0.1  gis.example.com
```

> 💡 If your VM's `hostname -f` already returns your public domain (e.g., `gis.example.com`), everything is auto-configured.

</details>

<br/>

## 🚀 Quick Start

### Step 1️⃣ — Clone Repository

```bash
git clone https://github.com/ElevateGeo/arcgis-enterprise-linux-bootstrap.git ~/arcgis-enterprise-linux-bootstrap
cd ~/arcgis-enterprise-linux-bootstrap
```

### Step 2️⃣ — Upload Licenses & Installer

```bash
# Create directories
sudo mkdir -p /opt/esri/licenses
sudo mkdir -p /opt/esri/installers

# Upload your files (example using scp from local machine)
scp ArcGIS_Enterprise_Builder_Linux_*.tar.gz user@vm:/opt/esri/installers/
scp *.prvc *.json user@vm:/opt/esri/licenses/
```

### Step 3️⃣ — Configure

```bash
cp .env.example .env
nano .env
```

<details>
<summary>📝 <strong>Example Configuration</strong></summary>

```bash
# Admin Credentials (USE STRONG PASSWORD!)
ARCGIS_ADMIN_USER=admin
ARCGIS_ADMIN_PASSWORD=YourStr0ng!Password
ARCGIS_ADMIN_EMAIL=admin@yourdomain.com
ARCGIS_ADMIN_FIRSTNAME=Admin
ARCGIS_ADMIN_LASTNAME=User
ARCGIS_ADMIN_SECURITY_QUESTION=What is your favorite color?
ARCGIS_ADMIN_SECURITY_ANSWER=YourSecretAnswer

# OS User (will be created if doesn't exist, no password needed)
ARCGIS_RUN_AS_USER=arcgis

# Let's Encrypt
LETSENCRYPT_EMAIL=admin@yourdomain.com

# Cloudflare DNS Challenge (OPTIONAL - for DNS-01 validation)
# CLOUDFLARE_API_TOKEN=your_cloudflare_api_token_here

# Everything else is AUTO-DISCOVERED:
#   - FQDN: from hostname -f (override: ARCGIS_FQDN=gis.example.com)
#   - Server license: *.prvc in /opt/esri/licenses/
#   - Portal license: *Portal*.json in /opt/esri/licenses/
#   - Installer: ArcGIS_Enterprise_Builder_Linux*.tar.gz in /opt/esri/installers/
```

</details>

### Step 4️⃣ — Install 🎉

```bash
# Make scripts executable
chmod +x install.sh preflight.sh scripts/*.sh

# (Optional) Validate setup first
./preflight.sh

# Run the installer (takes 30-60 minutes)
sudo ./install.sh
```

> 💡 **Tip:** Grab a coffee ☕ — the installation takes 30-60 minutes.

<br/>

## 📦 What Gets Installed

The installer deploys a **complete ArcGIS Enterprise base deployment**:

```
┌─────────────────────────────────────────────────────────────┐
│                    ArcGIS Enterprise                         │
├─────────────────┬─────────────────┬─────────────────────────┤
│  Portal for     │  ArcGIS Server  │  ArcGIS Data Store      │
│  ArcGIS         │                 │  (Relational + Tile)    │
├─────────────────┴─────────────────┴─────────────────────────┤
│              Web Adaptor (Tomcat)                           │
├─────────────────────────────────────────────────────────────┤
│              Let's Encrypt SSL Certificate                  │
└─────────────────────────────────────────────────────────────┘
```

### 🌐 Access Points After Installation

| Service | URL |
|:--------|:----|
| 🏠 **Portal Home** | `https://<your-fqdn>/portal/home` |
| ⚙️ **Portal Admin** | `https://<your-fqdn>:7443/arcgis/portaladmin` |
| 🗺️ **Server REST** | `https://<your-fqdn>/server/rest/services` |
| 🔧 **Server Admin** | `https://<your-fqdn>:6443/arcgis/admin` |

<br/>

## 🔐 SSL Certificate Management

### How It Works

```
 +------------+     +------------+     +------------+     +------------+
 |  Certbot   | --> |  PKCS12    | --> | Import to  | --> |  ArcGIS    |
 |  Obtains   |     |  Convert   |     | Portal &   |     |  Ready!    |
 |  Cert      |     |            |     | Server     |     |            |
 +------------+     +------------+     +------------+     +------------+
       |                                                        |
       +----------------- Auto-Renewal (every 60 days) ---------+
```

1. **Initial Setup** — Installer obtains Let's Encrypt certificate via certbot
2. **PKCS12 Conversion** — Certificate converted to PKCS12 format for ArcGIS
3. **Import** — Certificate imported into both Portal and Server
4. **Auto-Renewal** — Certbot timer automatically renews certificates
5. **Renewal Hook** — On renewal, script reimports the certificate into ArcGIS

### Challenge Methods

| Method | When Used | Requirements |
|:-------|:----------|:-------------|
| **HTTP-01** | Default | Port 80 open, DNS pointing to VM |
| **DNS-01 (Cloudflare)** | When `CLOUDFLARE_API_TOKEN` is set | Cloudflare API token |

<details>
<summary>☁️ <strong>Using Cloudflare DNS Challenge</strong></summary>

<br/>

If your domain is managed by Cloudflare, you can use DNS validation instead of HTTP:

**Benefits:**
- No need for port 80 to be open
- Works before the VM is publicly accessible
- Supports wildcard certificates

**Setup:**
1. Go to [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens)
2. Create a token with **Zone:DNS:Edit** permission for your domain
3. Add to `.env`:
   ```bash
   CLOUDFLARE_API_TOKEN=your_token_here
   ```

The script auto-detects the token and uses DNS challenge.

</details>

<details>
<summary>🔧 <strong>Manual Certificate Operations</strong></summary>

```bash
# Force certificate renewal
sudo certbot renew --force-renewal

# Manually run the ArcGIS import hook
sudo /opt/esri/scripts/ssl-renewal-hook.sh

# Check certificate status
sudo certbot certificates

# View renewal hook log
sudo cat /var/log/arcgis-ssl-renewal.log
```

</details>

<details>
<summary>🧪 <strong>Testing with Staging Certificates</strong></summary>

To avoid Let's Encrypt rate limits during testing:

```bash
# In .env
LETSENCRYPT_STAGING=true
```

> ⚠️ **Note:** Staging certificates are not trusted by browsers.

</details>

<br/>

## 🔧 Post-Installation

### Verify Installation

```bash
sudo ./install.sh --verify
```

<details>
<summary>🎛️ <strong>Service Management</strong></summary>

```bash
# As the arcgis user
sudo -u arcgis /opt/esri/arcgis/portal/tools/startportal.sh
sudo -u arcgis /opt/esri/arcgis/portal/tools/stopportal.sh

sudo -u arcgis /opt/esri/arcgis/server/tools/startserver.sh
sudo -u arcgis /opt/esri/arcgis/server/tools/stopserver.sh
```

</details>

<details>
<summary>❤️ <strong>Health Checks</strong></summary>

```bash
# Portal health
curl -sk "https://localhost:7443/arcgis/portaladmin/healthCheck?f=json"

# Server health  
curl -sk "https://localhost:6443/arcgis/admin/healthCheck?f=json"
```

</details>

<br/>

## 📁 Directory Structure

<details>
<summary><strong>View Installation Layout</strong></summary>

```
/opt/esri/
├── 📂 arcgis/              # ArcGIS Enterprise installation
│   ├── 📂 portal/          # Portal for ArcGIS
│   ├── 📂 server/          # ArcGIS Server
│   ├── 📂 datastore/       # ArcGIS Data Store
│   └── 📂 webadaptor/      # Web Adaptor
├── 📂 data/
│   ├── 📂 config-store/    # Server configuration store
│   ├── 📂 server-dirs/     # Server directories
│   └── 📂 portal-content/  # Portal content
├── 📂 licenses/            # License files
├── 📂 installers/          # Installation media
├── 📂 ssl/                 # SSL certificates (PKCS12)
├── 📂 scripts/             # Utility scripts
└── 📂 builder/             # Enterprise Builder (temporary)
```

</details>

<br/>

## 🔥 Troubleshooting

<details>
<summary>❌ <strong>Installation Fails</strong></summary>

1. Check the log file: `cat install.log`
2. Verify license files are valid and not expired
3. Ensure DNS is properly configured
4. Verify ports 80/443 are accessible from the internet

</details>

<details>
<summary>🔐 <strong>SSL Certificate Issues</strong></summary>

```bash
# Check certbot status
sudo certbot certificates

# Test renewal
sudo certbot renew --dry-run

# Check for errors
sudo journalctl -u certbot.timer
```

</details>

<details>
<summary>⚠️ <strong>ArcGIS Services Won't Start</strong></summary>

```bash
# Check logs
sudo tail -f /opt/esri/arcgis/portal/logs/*.log
sudo tail -f /opt/esri/arcgis/server/logs/*.log

# Check system limits
ulimit -a
cat /etc/security/limits.d/99-arcgis.conf
```

</details>

<details>
<summary>🔌 <strong>Port Already in Use</strong></summary>

If port 80 is in use (blocking Let's Encrypt):

```bash
# Find what's using port 80
sudo lsof -i :80

# Stop the service temporarily
sudo systemctl stop nginx  # or apache2
```

</details>

<br/>

## 🛡️ Security Notes

> ⚠️ **Important Security Practices**

| Practice | Description |
|:---------|:------------|
| 🚫 | **Never commit** the `.env` file to version control |
| 🔑 | **Use strong passwords** — minimum 8 chars, mixed case, numbers, special chars |
| 🔒 | **Restrict admin ports** (6443, 7443) to trusted IPs via Azure NSG |
| 📦 | **Regular updates** — Keep the OS and ArcGIS patched |

<br/>

## 📚 File Reference

| File | Purpose |
|:-----|:--------|
| 📜 `install.sh` | Main installation script |
| 📜 `preflight.sh` | Pre-installation validation |
| 📄 `.env.example` | Configuration template *(copy to .env)* |
| 🔒 `.env` | Your configuration *(gitignored)* |
| 📜 `scripts/ssl-renewal-hook.sh` | Let's Encrypt renewal hook |
| 📄 `templates/enterprise-builder.properties.template` | Properties file template |

<br/>

## 📖 Resources

<p align="center">
  <a href="https://enterprise.arcgis.com/en/documentation/"><img src="https://img.shields.io/badge/Esri-ArcGIS_Enterprise_Docs-0079C1?style=for-the-badge&logo=esri" alt="ArcGIS Enterprise Documentation"/></a>
  <a href="https://enterprise.arcgis.com/en/enterprise/latest/install/linux/arcgis-enterprise-builder.htm"><img src="https://img.shields.io/badge/Esri-Enterprise_Builder_Guide-0079C1?style=for-the-badge&logo=esri" alt="Enterprise Builder Guide"/></a>
  <a href="https://letsencrypt.org/docs/"><img src="https://img.shields.io/badge/Let's_Encrypt-Documentation-003A70?style=for-the-badge&logo=letsencrypt" alt="Let's Encrypt Documentation"/></a>
</p>

---

<p align="center">
  <sub>This bootstrap script is provided as-is. ArcGIS Enterprise requires valid Esri licenses.</sub>
</p>

<p align="center">
  Made with ☕ for the GIS community
</p>
