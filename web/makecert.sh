#!/usr/bin/env bash
# Self-signed certificate for web/serve.py's LAN server (this machine's name and first address),
# valid 1 year, in build/web-cert/ (not in the repo: it holds the private key)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
d="$root/build/web-cert"
mkdir -p "$d"
ip="$(hostname -I | awk '{print $1}')"
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout "$d/key.pem" -out "$d/cert.pem" -subj "/CN=$(hostname)" \
  -addext "subjectAltName=IP:$ip,IP:127.0.0.1,DNS:$(hostname),DNS:localhost" 2> /dev/null
chmod 600 "$d/key.pem"
echo "build/web-cert: certificate for $(hostname) / $ip"
