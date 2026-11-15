#!/usr/bin/env bash
set -Eeuo pipefail

repo='jackh0006/XHTTP-WEB-Setup'
asset_url="https://github.com/${repo}/releases/latest/download/xhttp-web-setup.sh"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

curl --fail --location --proto '=https' --tlsv1.2 "$asset_url" --output "$tmp"
chmod 700 "$tmp"
sudo bash "$tmp"
