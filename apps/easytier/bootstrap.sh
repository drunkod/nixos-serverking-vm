#!/usr/bin/env bash
set -euo pipefail

VM_NAME="__VM_NAME__"
INFRA_REF="__INFRA_REF__"

NETWORK_NAME="serverking-u665"
VIRTUAL_IPV4="10.144.144.1/24"
LISTEN_PORT="11010"

STATE_DIR="/var/lib/easytier-bootstrap"
ET_STATE_DIR="/var/lib/easytier"
HOST_CONFIG_DIR="/root/server-config"
SECRET_FILE="$ET_STATE_DIR/network-secret"
ENV_FILE="$ET_STATE_DIR/network.env"
CLIENT_INFO_FILE="/root/easytier-client-info"
STATUS_FILE="$STATE_DIR/bootstrap-status"
LOG_FILE="/var/log/easytier-bootstrap.log"

mkdir -p "$STATE_DIR" "$ET_STATE_DIR" "$HOST_CONFIG_DIR" /run/easytier-bootstrap
chmod 700 "$STATE_DIR" "$ET_STATE_DIR"

exec >>"$LOG_FILE" 2>&1
echo "[$(date -u +%FT%TZ)] starting EasyTier bootstrap for $VM_NAME"

if ! mkdir /run/easytier-bootstrap/lock 2>/dev/null; then
  echo "another bootstrap process is already running"
  exit 0
fi
trap 'rmdir /run/easytier-bootstrap/lock 2>/dev/null || true' EXIT

if [ -s "$STATUS_FILE" ] && grep -q '^ready$' "$STATUS_FILE"; then
  echo "bootstrap already completed"
  exit 0
fi

if [ ! -s "$SECRET_FILE" ]; then
  umask 077
  {
    tr -d '-' < /proc/sys/kernel/random/uuid
    tr -d '-' < /proc/sys/kernel/random/uuid
  } | tr -d '\n' > "$SECRET_FILE"
fi
chmod 600 "$SECRET_FILE"
NETWORK_SECRET="$(cat "$SECRET_FILE")"

cat > "$ENV_FILE" <<EOF
ET_NETWORK_SECRET=$NETWORK_SECRET
EOF
chmod 600 "$ENV_FILE"

cat > "$HOST_CONFIG_DIR/flake.nix" <<EOF
{
  description = "$VM_NAME ServerKing EasyTier host configuration";

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
  networking.firewall.allowedTCPPorts = [ $LISTEN_PORT ];

  services.easytier = {
    enable = true;

    instances.default = {
      settings = {
        instance_name = "$VM_NAME";
        hostname = "$VM_NAME";
        network_name = "$NETWORK_NAME";
        ipv4 = "$VIRTUAL_IPV4";
        listeners = [
          "tcp://0.0.0.0:$LISTEN_PORT"
        ];
        peers = [ ];
      };

      extraSettings = {
        rpc_portal = "127.0.0.1:15888";

        flags = {
          enable_encryption = true;
          encryption_algorithm = "aes-gcm";
          enable_ipv6 = false;
          enable_exit_node = true;
          private_mode = true;
          multi_thread = true;
        };
      };
    };
  };

  # Keep the mesh secret out of the Nix store. EasyTier maps this
  # environment variable to --network-secret.
  systemd.services.easytier-default.serviceConfig.EnvironmentFile = [
    "$ENV_FILE"
  ];
}
EOF

cd "$HOST_CONFIG_DIR"
nix flake lock
nixos-rebuild switch --flake ".#$VM_NAME"

for _ in $(seq 1 90); do
  if systemctl is-active --quiet easytier-default.service; then
    break
  fi
  sleep 2
done

systemctl is-enabled --quiet easytier-default.service
systemctl is-active --quiet easytier-default.service

if ! ss -ltn | grep -Eq "LISTEN.+:$LISTEN_PORT([[:space:]]|$)"; then
  echo "EasyTier TCP/$LISTEN_PORT listener is not active" >&2
  systemctl status easytier-default.service --no-pager >&2 || true
  exit 1
fi

for _ in $(seq 1 30); do
  if easytier-cli node >/tmp/easytier-node.txt 2>/dev/null; then
    break
  fi
  sleep 2
done

if ! easytier-cli node >/tmp/easytier-node.txt 2>/dev/null; then
  echo "easytier-cli could not reach local RPC portal" >&2
  exit 1
fi

if ! ip -4 addr show | grep -q '10\.144\.144\.1/24'; then
  echo "EasyTier virtual IPv4 address 10.144.144.1/24 is missing" >&2
  ip -4 addr show >&2
  exit 1
fi

cat > "$CLIENT_INFO_FILE" <<EOF
network_name=$NETWORK_NAME
network_secret=$NETWORK_SECRET
server_virtual_ip=10.144.144.1
peer_port=$LISTEN_PORT
exit_node=10.144.144.1
transport=tcp
EOF
chmod 600 "$CLIENT_INFO_FILE"

cat > "$STATE_DIR/deployment-info" <<EOF
infra_ref=$INFRA_REF
vm_name=$VM_NAME
network_name=$NETWORK_NAME
server_virtual_ip=10.144.144.1
listen_port=$LISTEN_PORT
exit_node=enabled
encryption=aes-gcm
private_mode=enabled
ipv6=disabled
deployed_at=$(date -u +%FT%TZ)
EOF
chmod 600 "$STATE_DIR/deployment-info"

printf 'ready\n' > "$STATUS_FILE"
chmod 600 "$STATUS_FILE"

echo "[$(date -u +%FT%TZ)] EasyTier bootstrap completed successfully"
easytier-cli node || true
