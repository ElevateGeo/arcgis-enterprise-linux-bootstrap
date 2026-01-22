#!/usr/bin/env bash
set -e

ENV_FILE=".env"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

prompt_if_empty() {
  local var_name="$1"
  local prompt_text="$2"
  local secret="$3"
  local value="${!var_name}"

  if [[ -z "$value" ]]; then
    if [[ "$secret" == "secret" ]]; then
      read -rsp "$prompt_text: " value
      echo
    else
      read -rp "$prompt_text: " value
    fi

    [[ -z "$value" ]] && echo "ERROR: $var_name cannot be empty" && exit 1
    export "$var_name=$value"
    echo "$var_name=$value" >> "$ENV_FILE"
  fi
}

prompt_if_empty DOMAIN "Domain (gis.example.com)"
prompt_if_empty EMAIL "Let's Encrypt email"
prompt_if_empty CF_API_TOKEN "Cloudflare API Token" secret

ESRI_BASE="/opt/esri"
INSTALLERS="$ESRI_BASE/installers"

apt update
apt install -y nginx certbot python3-certbot-dns-cloudflare openjdk-11-jdk tar unzip

mkdir -p /root/.secrets/certbot
cat > /root/.secrets/certbot/cloudflare.ini <<EOF
dns_cloudflare_api_token = $CF_API_TOKEN
EOF
chmod 600 /root/.secrets/certbot/cloudflare.ini

certbot certonly --dns-cloudflare   --dns-cloudflare-credentials /root/.secrets/certbot/cloudflare.ini   -d "$DOMAIN" --agree-tos -m "$EMAIL" --non-interactive

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
  location / {
    proxy_pass http://localhost:8080;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto https;
  }
}
EOF

ln -sf /etc/nginx/sites-available/arcgis /etc/nginx/sites-enabled/arcgis
rm -f /etc/nginx/sites-enabled/default
systemctl reload nginx

id arcgis &>/dev/null || useradd -m arcgis
mkdir -p "$ESRI_BASE"
chown -R arcgis:arcgis "$ESRI_BASE"

cd "$INSTALLERS"
for f in *.tar.gz; do tar -xzf "$f"; done

echo "Install complete. License Portal and Server to continue."
