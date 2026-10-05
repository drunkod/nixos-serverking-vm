#!/usr/bin/env bash
set -euo pipefail

APP_NAME="nix-v2ray-warp"
APP_REPO="https://github.com/drunkod/nix-v2ray-warp.git"
APP_REF="__V2RAY_WARP_REF__"
INFRA_REF="__INFRA_REF__"
VM_NAME="__VM_NAME__"

REPO_DIR="/opt/nix-v2ray-warp"
STATE_DIR="/var/lib/nix-v2ray-warp"
HOST_CONFIG_DIR="/root/server-config"
PROFILE="/nix/var/nix/profiles/nix-v2ray-warp"
UUID_FILE="$STATE_DIR/vmess-uuid"
LOG_FILE="/var/log/nix-v2ray-warp-bootstrap.log"
STATUS_FILE="$STATE_DIR/bootstrap-status"

mkdir -p "$STATE_DIR" /opt "$HOST_CONFIG_DIR" /run/nix-v2ray-warp-bootstrap
chmod 700 "$STATE_DIR"

exec >>"$LOG_FILE" 2>&1
echo "[$(date -u +%FT%TZ)] starting $APP_NAME bootstrap for $VM_NAME"

if ! mkdir /run/nix-v2ray-warp-bootstrap/lock 2>/dev/null; then
  echo "another bootstrap process is already running"
  exit 0
fi
trap 'rmdir /run/nix-v2ray-warp-bootstrap/lock 2>/dev/null || true' EXIT

if [ -s "$STATUS_FILE" ] && grep -q '^ready$' "$STATUS_FILE"; then
  echo "bootstrap already completed"
  exit 0
fi

rm -rf "$REPO_DIR.new"
mkdir -p "$REPO_DIR.new"
cd "$REPO_DIR.new"
nix shell nixpkgs#git -c git init -q
nix shell nixpkgs#git -c git remote add origin "$APP_REPO"
nix shell nixpkgs#git -c git fetch --depth 1 origin "$APP_REF"
nix shell nixpkgs#git -c git checkout -q --detach FETCH_HEAD
cd /
rm -rf "$REPO_DIR.old"
if [ -d "$REPO_DIR" ]; then
  mv "$REPO_DIR" "$REPO_DIR.old"
fi
mv "$REPO_DIR.new" "$REPO_DIR"
rm -rf "$REPO_DIR.old"

if [ ! -s "$UUID_FILE" ]; then
  cat /proc/sys/kernel/random/uuid > "$UUID_FILE"
  chmod 600 "$UUID_FILE"
fi
VMESS_UUID="$(tr -d '\r\n' < "$UUID_FILE")"

cd "$REPO_DIR"

patch_server() {
  local file="$1"
  local tmp
  tmp="$(mktemp)"
  # shellcheck disable=SC2016
  nix shell nixpkgs#jq -c jq --arg id "$VMESS_UUID" '
    (.inbounds[] | select(.protocol == "vmess") | .settings.clients) =
      [{"id": $id, "alterId": 0, "security": "auto"}]
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

patch_client() {
  local file="$1"
  local tmp
  tmp="$(mktemp)"
  # shellcheck disable=SC2016
  nix shell nixpkgs#jq -c jq --arg id "$VMESS_UUID" '
    (.outbounds[] | select(.protocol == "vmess") | .settings.vnext[0].users[0].id) = $id
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

patch_server v2ray-server-config-warp.json
patch_server v2ray-server-config.json
patch_client v2ray-client-config.json

nix flake check --no-build

WARP_DIR="$STATE_DIR" nix run .#warp-setup

STACK_PATH="$(nix build .#v2ray-stack --no-link --print-out-paths)"
nix-env -p "$PROFILE" -i "$STACK_PATH"

install -m 600 v2ray-client-config.json /root/v2ray-client-template.json
cat > /root/render-v2ray-client <<'RENDER'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo "Usage: render-v2ray-client <public-ip-or-hostname>" >&2
  exit 2
fi
address="$1"
sed "s/YOUR_SERVER_IP_OR_HOSTNAME/$address/g" /root/v2ray-client-template.json
RENDER
chmod 700 /root/render-v2ray-client

cat > "$HOST_CONFIG_DIR/flake.nix" <<EOF
{
  description = "$VM_NAME ServerKing host configuration";

  inputs = {
    infra.url = "github:drunkod/nixos-serverking-vm/$INFRA_REF";
    nixpkgs.follows = "infra/nixpkgs";
  };

  outputs = { self, nixpkgs, infra, ... }: {
    nixosConfigurations.$VM_NAME = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        "\${infra}/image.nix"
        ./service.nix
      ];
    };
  };
}
EOF

cat > "$HOST_CONFIG_DIR/service.nix" <<EOF
{ lib, ... }:
{
  networking.hostName = lib.mkForce "$VM_NAME";
  networking.firewall.allowedTCPPorts = [ 8080 ];

  systemd.services.nix-v2ray-warp = {
    description = "V2Ray server, local client and Cloudflare WARP proxy";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    environment.WARP_DIR = "$STATE_DIR";

    serviceConfig = {
      Type = "simple";
      WorkingDirectory = "$STATE_DIR";
      ExecStart = "$PROFILE/bin/run-v2ray-stack";
      Restart = "always";
      RestartSec = 5;
      KillMode = "control-group";
      TimeoutStopSec = 20;
      UMask = "0077";
      LimitNOFILE = 65536;
    };
  };
}
EOF

cd "$HOST_CONFIG_DIR"
nix flake lock
systemctl stop nix-v2ray-warp.service 2>/dev/null || true
nixos-rebuild switch --flake ".#$VM_NAME"

for _ in $(seq 1 60); do
  if systemctl is-active --quiet nix-v2ray-warp.service; then
    break
  fi
  sleep 2
done
systemctl is-enabled --quiet nix-v2ray-warp.service
systemctl is-active --quiet nix-v2ray-warp.service

# Resolve exactly one curl executable from the Nix shell. The curl derivation
# has multiple outputs, so nix build --print-out-paths is not safe here.
# shellcheck disable=SC2016
CURL_BIN="$(nix shell nixpkgs#curl -c sh -c 'command -v curl')"
TRACE=""
WARP_READY=false
for _ in $(seq 1 60); do
  TRACE="$("$CURL_BIN" --fail --silent --show-error --max-time 10 --socks5-hostname 127.0.0.1:10808 https://cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
  if printf '%s\n' "$TRACE" | grep -q '^warp=on$'; then
    WARP_READY=true
    break
  fi
  sleep 2
done

if [[ "$WARP_READY" != true ]]; then
  echo "WARP verification failed; stopping application service." >&2
  systemctl stop nix-v2ray-warp.service || true
  exit 1
fi

cat > "$STATE_DIR/deployment-info" <<EOF
repository=$APP_REPO
application_ref=$APP_REF
infra_ref=$INFRA_REF
vm_name=$VM_NAME
deployed_at=$(date -u +%FT%TZ)
warp=on
EOF
chmod 600 "$STATE_DIR/deployment-info"

printf 'ready\n' > "$STATUS_FILE"
chmod 600 "$STATUS_FILE"

echo "[$(date -u +%FT%TZ)] bootstrap completed successfully; warp=on"
