#!/bin/bash
# =============================================================================
# Pre-Installation Validation Script
# =============================================================================
# Run this before install.sh to verify everything is ready
# Usage: ./preflight.sh
# =============================================================================

# Don't use set -e here - we want to continue checking even if some checks fail
set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ERRORS=0
WARNINGS=0

check_pass() { echo -e "  ${GREEN}✓${NC} $1"; }
check_fail() { echo -e "  ${RED}✗${NC} $1"; ((ERRORS++)); }
check_warn() { echo -e "  ${YELLOW}!${NC} $1"; ((WARNINGS++)); }

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         ArcGIS Enterprise Pre-Installation Check             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# -----------------------------------------------------------------------------
echo "Checking System Requirements..."
# -----------------------------------------------------------------------------

# Check if root or sudo available
if [[ $EUID -eq 0 ]] || sudo -n true 2>/dev/null; then
    check_pass "Root/sudo access available"
else
    check_fail "Root/sudo access required"
fi

# Check OS
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    if [[ "$ID" == "ubuntu" ]]; then
        check_pass "Operating system: Ubuntu $VERSION_ID"
    else
        check_warn "OS is $ID - script tested on Ubuntu"
    fi
else
    check_warn "Could not determine OS"
fi

# Check memory
MEM_GB=$(free -g | awk '/^Mem:/{print $2}' || echo "0")
if [[ -z "$MEM_GB" ]] || [[ ! "$MEM_GB" =~ ^[0-9]+$ ]]; then
    check_warn "Could not determine memory"
elif [[ $MEM_GB -ge 16 ]]; then
    check_pass "Memory: ${MEM_GB}GB (≥16GB required)"
elif [[ $MEM_GB -ge 8 ]]; then
    check_warn "Memory: ${MEM_GB}GB (16GB recommended, may work with 8GB)"
else
    check_fail "Memory: ${MEM_GB}GB (minimum 16GB required)"
fi

# Check disk space
DISK_GB=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G' || echo "0")
if [[ -z "$DISK_GB" ]] || [[ ! "$DISK_GB" =~ ^[0-9]+$ ]]; then
    check_warn "Could not determine free disk space"
elif [[ $DISK_GB -ge 100 ]]; then
    check_pass "Free disk space: ${DISK_GB}GB (≥100GB recommended)"
elif [[ $DISK_GB -ge 50 ]]; then
    check_warn "Free disk space: ${DISK_GB}GB (100GB recommended)"
else
    check_fail "Free disk space: ${DISK_GB}GB (need at least 50GB)"
fi

echo ""

# -----------------------------------------------------------------------------
echo "Checking Configuration..."
# -----------------------------------------------------------------------------

# Check .env file
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    check_pass ".env file exists"
    
    # Load and validate
    set -a
    source "${SCRIPT_DIR}/.env"
    set +a
    
    # Auto-detect FQDN if not set
    if [[ -z "${ARCGIS_FQDN:-}" ]]; then
        ARCGIS_FQDN=$(hostname -f 2>/dev/null)
        if [[ -n "$ARCGIS_FQDN" ]]; then
            if [[ "$ARCGIS_FQDN" =~ \.(internal|local|cloudapp|compute|amazonaws|googleusercontent)\. ]]; then
                check_warn "ARCGIS_FQDN auto-detected: ${ARCGIS_FQDN} (looks like internal hostname)"
            else
                check_pass "ARCGIS_FQDN auto-detected: ${ARCGIS_FQDN}"
            fi
        else
            check_fail "ARCGIS_FQDN not set and could not auto-detect"
        fi
    else
        check_pass "ARCGIS_FQDN: ${ARCGIS_FQDN}"
    fi
    
    # Check required variables
    [[ -n "${ARCGIS_ADMIN_USER:-}" ]] && check_pass "ARCGIS_ADMIN_USER: ${ARCGIS_ADMIN_USER}" || check_fail "ARCGIS_ADMIN_USER not set"
    [[ -n "${ARCGIS_ADMIN_PASSWORD:-}" ]] && check_pass "ARCGIS_ADMIN_PASSWORD: (set)" || check_fail "ARCGIS_ADMIN_PASSWORD not set"
    [[ -n "${ARCGIS_ADMIN_EMAIL:-}" ]] && check_pass "ARCGIS_ADMIN_EMAIL: ${ARCGIS_ADMIN_EMAIL}" || check_fail "ARCGIS_ADMIN_EMAIL not set"
    [[ -n "${LETSENCRYPT_EMAIL:-}" ]] && check_pass "LETSENCRYPT_EMAIL: ${LETSENCRYPT_EMAIL}" || check_fail "LETSENCRYPT_EMAIL not set"
    [[ -n "${ARCGIS_RUN_AS_USER:-}" ]] && check_pass "ARCGIS_RUN_AS_USER: ${ARCGIS_RUN_AS_USER}" || check_fail "ARCGIS_RUN_AS_USER not set"
    
    # Check portal admin profile fields (used in properties file)
    [[ -n "${ARCGIS_ADMIN_FIRSTNAME:-}" ]] && check_pass "ARCGIS_ADMIN_FIRSTNAME: ${ARCGIS_ADMIN_FIRSTNAME}" || check_fail "ARCGIS_ADMIN_FIRSTNAME not set"
    [[ -n "${ARCGIS_ADMIN_LASTNAME:-}" ]] && check_pass "ARCGIS_ADMIN_LASTNAME: ${ARCGIS_ADMIN_LASTNAME}" || check_fail "ARCGIS_ADMIN_LASTNAME not set"
    
    # Check security question index (must be 1-14 per Esri docs)
    if [[ -n "${ARCGIS_ADMIN_SECURITY_QUESTION_INDEX:-}" ]]; then
        if [[ "$ARCGIS_ADMIN_SECURITY_QUESTION_INDEX" =~ ^[0-9]+$ ]] && \
           [[ "$ARCGIS_ADMIN_SECURITY_QUESTION_INDEX" -ge 1 ]] && \
           [[ "$ARCGIS_ADMIN_SECURITY_QUESTION_INDEX" -le 14 ]]; then
            check_pass "ARCGIS_ADMIN_SECURITY_QUESTION_INDEX: ${ARCGIS_ADMIN_SECURITY_QUESTION_INDEX}"
        else
            check_fail "ARCGIS_ADMIN_SECURITY_QUESTION_INDEX must be 1-14 (got: ${ARCGIS_ADMIN_SECURITY_QUESTION_INDEX})"
        fi
    else
        check_fail "ARCGIS_ADMIN_SECURITY_QUESTION_INDEX not set (must be 1-14)"
    fi
    [[ -n "${ARCGIS_ADMIN_SECURITY_ANSWER:-}" ]] && check_pass "ARCGIS_ADMIN_SECURITY_ANSWER: (set)" || check_fail "ARCGIS_ADMIN_SECURITY_ANSWER not set"
    
    # Check password strength
    if [[ -n "${ARCGIS_ADMIN_PASSWORD:-}" ]]; then
        if [[ "$ARCGIS_ADMIN_PASSWORD" == *"CHANGE_ME"* ]]; then
            check_fail "Password still contains placeholder 'CHANGE_ME'"
        elif [[ ${#ARCGIS_ADMIN_PASSWORD} -ge 8 ]]; then
            check_pass "Password length: ≥8 characters"
        else
            check_fail "Password too short (minimum 8 characters)"
        fi
    fi
    
    # Check for placeholder email values
    if [[ "${ARCGIS_ADMIN_EMAIL:-}" == "admin@example.com" ]]; then
        check_warn "ARCGIS_ADMIN_EMAIL is still example.com (update to real email)"
    fi
    if [[ "${LETSENCRYPT_EMAIL:-}" == "admin@example.com" ]]; then
        check_warn "LETSENCRYPT_EMAIL is still example.com (update to real email)"
    fi
else
    check_fail ".env file not found - copy from .env.example"
fi

echo ""

# -----------------------------------------------------------------------------
echo "Checking License Files..."
# -----------------------------------------------------------------------------

LICENSE_DIR="${ARCGIS_LICENSE_DIR:-/opt/esri/licenses}"
INSTALLER_DIR="${ARCGIS_INSTALLER_DIR:-/opt/esri/installers}"

# Auto-discover or use configured Server license
if [[ -z "${ARCGIS_SERVER_LICENSE:-}" ]]; then
    ARCGIS_SERVER_LICENSE=$(find "$LICENSE_DIR" -maxdepth 1 -name "*.prvc" -type f 2>/dev/null | head -1)
fi
if [[ -n "$ARCGIS_SERVER_LICENSE" ]] && [[ -f "$ARCGIS_SERVER_LICENSE" ]]; then
    check_pass "Server license: $ARCGIS_SERVER_LICENSE"
elif [[ -n "$ARCGIS_SERVER_LICENSE" ]]; then
    check_fail "Server license not found: $ARCGIS_SERVER_LICENSE"
else
    check_fail "No .prvc file found in $LICENSE_DIR"
fi

# Auto-discover or use configured Portal license
if [[ -z "${ARCGIS_PORTAL_LICENSE:-}" ]]; then
    ARCGIS_PORTAL_LICENSE=$(find "$LICENSE_DIR" -maxdepth 1 -name "*Portal*.json" -type f 2>/dev/null | head -1)
fi
if [[ -n "$ARCGIS_PORTAL_LICENSE" ]] && [[ -f "$ARCGIS_PORTAL_LICENSE" ]]; then
    check_pass "Portal license: $ARCGIS_PORTAL_LICENSE"
elif [[ -n "$ARCGIS_PORTAL_LICENSE" ]]; then
    check_fail "Portal license not found: $ARCGIS_PORTAL_LICENSE"
else
    check_fail "No *Portal*.json file found in $LICENSE_DIR"
fi

echo ""

# -----------------------------------------------------------------------------
echo "Checking Installer..."
# -----------------------------------------------------------------------------

# Auto-discover or use configured installer
if [[ -z "${ARCGIS_INSTALLER_TAR:-}" ]]; then
    ARCGIS_INSTALLER_TAR=$(find "$INSTALLER_DIR" -maxdepth 1 -name "ArcGIS_Enterprise_Builder_Linux*.tar.gz" -type f 2>/dev/null | head -1)
fi
if [[ -n "$ARCGIS_INSTALLER_TAR" ]] && [[ -f "$ARCGIS_INSTALLER_TAR" ]]; then
    SIZE=$(du -h "$ARCGIS_INSTALLER_TAR" | cut -f1)
    check_pass "Installer: $ARCGIS_INSTALLER_TAR ($SIZE)"
elif [[ -n "$ARCGIS_INSTALLER_TAR" ]]; then
    check_fail "Installer not found: $ARCGIS_INSTALLER_TAR"
else
    check_fail "No ArcGIS_Enterprise_Builder_Linux*.tar.gz found in $INSTALLER_DIR"
fi

echo ""

# -----------------------------------------------------------------------------
echo "Checking Network..."
# -----------------------------------------------------------------------------

# Check DNS resolution (external)
if [[ -n "${ARCGIS_FQDN:-}" ]]; then
    RESOLVED_IP=$(dig +short "$ARCGIS_FQDN" 2>/dev/null | head -1)
    if [[ -n "$RESOLVED_IP" ]]; then
        check_pass "External DNS resolves: ${ARCGIS_FQDN} → ${RESOLVED_IP}"
    else
        check_fail "DNS does not resolve: ${ARCGIS_FQDN}"
    fi
    
    # Check hosts file for local resolution (important for ArcGIS internal communication)
    if grep -q "^127\.0\.0\.1.*${ARCGIS_FQDN}" /etc/hosts 2>/dev/null; then
        check_pass "Hosts file: ${ARCGIS_FQDN} → 127.0.0.1 (local)"
    else
        check_warn "Hosts file missing local entry for ${ARCGIS_FQDN} (will be added during install)"
    fi
fi

# Check SSL challenge method
echo ""
echo "SSL Certificate Method:"
if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    check_pass "Using Cloudflare DNS challenge (CLOUDFLARE_API_TOKEN detected)"
    # Verify token looks valid (basic format check)
    if [[ ${#CLOUDFLARE_API_TOKEN} -lt 20 ]]; then
        check_warn "CLOUDFLARE_API_TOKEN seems too short"
    fi
else
    check_pass "Using HTTP-01 challenge (standalone mode)"
    # Check port 80 (needed for HTTP-01)
    if ! ss -tlnp | grep -q ':80 '; then
        check_pass "Port 80 is available"
    else
        check_warn "Port 80 is in use (may need to stop existing web server)"
    fi
fi

# Check external connectivity
if curl -s --connect-timeout 5 https://acme-v02.api.letsencrypt.org/directory > /dev/null 2>&1; then
    check_pass "Can reach Let's Encrypt API"
else
    check_warn "Cannot reach Let's Encrypt API"
fi

echo ""

# -----------------------------------------------------------------------------
echo "Checking Ports..."
# -----------------------------------------------------------------------------

ports_to_check=(443 6443 7443)
if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    ports_to_check=(80 443 6443 7443)
fi
for port in "${ports_to_check[@]}"; do
    if command -v nc &> /dev/null; then
        if timeout 2 nc -z localhost "$port" 2>/dev/null; then
            check_warn "Port $port is already in use"
        else
            check_pass "Port $port is available"
        fi
    else
        if ss -tlnp | grep -q ":${port} "; then
            check_warn "Port $port is already in use"
        else
            check_pass "Port $port is available"
        fi
    fi
done

echo ""

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════════════"
if [[ $ERRORS -eq 0 ]] && [[ $WARNINGS -eq 0 ]]; then
    echo -e "${GREEN}All checks passed! Ready to install.${NC}"
    echo ""
    echo "Run: sudo ./install.sh"
elif [[ $ERRORS -eq 0 ]]; then
    echo -e "${YELLOW}${WARNINGS} warning(s), but can proceed with installation.${NC}"
    echo ""
    echo "Run: sudo ./install.sh"
else
    echo -e "${RED}${ERRORS} error(s) found. Please fix before installing.${NC}"
    if [[ $WARNINGS -gt 0 ]]; then
        echo -e "${YELLOW}Also ${WARNINGS} warning(s).${NC}"
    fi
fi
echo "═══════════════════════════════════════════════════════════════"
echo ""

exit $ERRORS
