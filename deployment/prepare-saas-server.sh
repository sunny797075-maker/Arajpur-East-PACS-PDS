#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! swapon --show=NAME --noheadings | grep -q .; then
  fallocate -l 1G /pds-swap
  chmod 600 /pds-swap
  mkswap /pds-swap >/dev/null
  swapon /pds-swap
  printf '/pds-swap none swap sw 0 0\n' >> /etc/fstab
fi
apt-get update -qq
apt-get install -y -qq postgresql python3-venv ca-certificates curl xz-utils
install -d /opt/pds /etc/pds
if ! test -x /opt/pds/node/bin/node; then
  version=$(curl -fsSL https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt | awk '/linux-x64.tar.xz$/ {print $2;exit}')
  test -n "$version"
  curl -fsSL "https://nodejs.org/dist/latest-v22.x/$version" -o "/tmp/$version"
  curl -fsSL https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt | grep " $version$" > /tmp/pds-node.sha256
  (cd /tmp && sha256sum -c pds-node.sha256)
  install -d /opt/pds/node
  tar -xJf "/tmp/$version" --strip-components=1 -C /opt/pds/node
fi
python3 -m venv /opt/pds/certbot
/opt/pds/certbot/bin/pip install --quiet 'certbot>=5.4,<6'
/opt/pds/certbot/bin/certbot --version
/opt/pds/node/bin/node --version
id pds-api >/dev/null 2>&1 || useradd --system --home /opt/pds/api --shell /usr/sbin/nologin pds-api
printf 'Server prerequisites ready\n'
