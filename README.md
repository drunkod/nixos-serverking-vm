# nixos-serverking-vm

Reproducible NixOS image and provisioning template for ServerKing/Cozystack.

## Goal

Turn one NixOS flake into a reusable provisioning flow:

```text
Nix flake
  -> 10 GiB EFI qcow2 golden image
  -> versioned GitHub Release
  -> Cozystack base VMDisk
  -> per-project VMDisk clone
  -> VMInstance
  -> cloud-init hostname / SSH key
  -> external Service / IP
```

The existing `nixos-anywhere` flow remains available for manual recovery/reinstall, but normal VM creation should use the golden-image clone path.

## Repository layout

```text
.
├── common.nix                       # shared NixOS guest/network/SSH defaults
├── configuration.nix                # existing installed-machine config
├── disko.nix                        # destructive reinstall layout for nixos-anywhere
├── image.nix                        # generic 10 GiB EFI qcow2 golden image
├── flake.nix
├── cozystack/
│   ├── vmdisk-clone.example.yaml
│   └── vminstance.example.yaml
├── scripts/
│   ├── serverking-auth-check
│   ├── import-base-disk
│   └── provision-vm
└── .github/workflows/
    ├── build-image.yml
    ├── publish-base-disk.yml
    └── provision.yml
```

## Design sources

This implementation uses ideas verified against:

- NixOS `make-disk-image.nix`: native qcow2/EFI image construction.
- `n-at-han-k/nixos-kubevirt-vm`: KubeVirt-oriented qcow2 build, `boot.growPartition`, and root `autoResize`.
- Cozystack's live `ApplicationDefinition` schema on ServerKing: `VMDisk.source.disk`, `VMInstance`, `linux.efi`, external ports, SSH keys and cloud-init fields.
- `cozystack/terraform-provider-cozystack`: official resource model for VMDisk/VMInstance and the pattern of waiting for VM readiness.
- ContainerCraft KMI: test/validate an image before promotion.

The repository intentionally uses direct Kubernetes/Cozystack CRs for the first MVP. OpenTofu/Terraform can be introduced after the API lifecycle is proven end-to-end.

## Golden image

`image.nix` creates:

- x86_64 NixOS 26.05
- 10 GiB virtual disk
- GPT + EFI System Partition
- ext4 root
- QEMU guest profile
- DHCP with systemd-networkd
- OpenSSH
- cloud-init
- serial console
- automatic root partition/filesystem growth

Build on an x86_64 Linux runner:

```sh
nix build .#serverking-image
```

The qcow2 is expected under the build result and is validated with `qemu-img check` in CI.

## ServerKing API credential

The ServerKing dashboard exposes a tenant kubeconfig. Never commit it to this repository.

For local use:

```sh
export KUBECONFIG="$HOME/.config/serverking/kubeconfig"
export SERVERKING_NAMESPACE=tenant-u665
./scripts/serverking-auth-check
```

For GitHub Actions, use the tenant service-account credential:

```text
SERVERKING_TOKEN
SERVERKING_CA_B64
```

The workflows construct an ephemeral kubeconfig on the runner. This avoids interactive Keycloak/OIDC login in CI.

Optional repository variables:

```text
SERVERKING_NAMESPACE=tenant-u665
SERVERKING_STORAGE_CLASS=replicated2
SERVERKING_SSH_PUBLIC_KEY=ssh-ed25519 ...
```

## Import a versioned base disk

After publishing a qcow2 at a public URL:

```sh
./scripts/import-base-disk \
  nixos-26-05-v1 \
  https://github.com/OWNER/REPO/releases/download/image-v26.05-1/nixos-serverking.qcow2 \
  10Gi
```

The script refuses to overwrite an existing VMDisk with a different source, size, or storage class.

## Provision a VM

```sh
EXTERNAL_PORTS=22,80,443 \
./scripts/provision-vm my-project u1.small 30Gi nixos-26-05-v1
```

Provisioning flow:

```text
verify base VMDisk
  -> choose disk source
       -> HTTP import when the golden VMDisk has an HTTP source
       -> VMDisk clone when explicitly requested/appropriate
  -> create my-project-root
  -> create VMInstance
  -> linux.efi / requested instance type
  -> inject SSH key + cloud-init
  -> expose requested TCP ports
  -> wait for the underlying KubeVirt VM Ready/Running
  -> print matching Service / address
```

`DISK_SOURCE_MODE=auto` is the safe default. ServerKing's `WaitForFirstConsumer` storage can leave a golden VMDisk application object `Ready` before its backing PVC is materialized; in that case CDI clone can fail with `source/target size info missing`. If the golden disk came from HTTP, auto mode reuses that image URL for the new root disk instead.

The script is retry-safe for matching resources and fails if an object with the same name has a conflicting root disk/spec.

## GitHub Actions

### Build NixOS golden image

Run **Build NixOS golden image** manually or push a tag such as:

```text
image-v26.05-1
```

Tag builds create a GitHub Release containing `nixos-serverking.qcow2`.

### Import ServerKing base disk

Run **Import ServerKing base disk** with:

- VMDisk name
- public qcow2 URL
- base disk size

### Provision ServerKing VM

Run **Provision ServerKing VM** with:

- VM name
- base disk
- instance type
- root disk size
- exposed TCP ports


### Provision V2Ray + WARP in one workflow

Run **Provision V2Ray WARP VM**. The workflow pins the application to:

```text
https://github.com/drunkod/nix-v2ray-warp
commit 84953e1c8c15ea550cb51d161cfca7f9ec96ef3b
```

The VM receives a first-boot bootstrap through `VMInstance.spec.cloudInit`. It clones the pinned app, generates a unique VMess UUID only inside the guest, creates persistent WARP state, installs the Nix-built stack, creates a declarative NixOS systemd service, opens TCP/8080, runs `nixos-rebuild switch`, and verifies `warp=on`.

No VMess UUID is stored in GitHub Actions, repository variables, or cloud-init.

On the VM:

```text
/root/render-v2ray-client <PUBLIC_IP_OR_HOSTNAME>
/var/lib/nix-v2ray-warp/vmess-uuid
/var/lib/nix-v2ray-warp/wgcf-account.toml
/var/lib/nix-v2ray-warp/wireproxy.conf
```

The public ServerKing Service exposes TCP 22 and 8080. Ports 40000 and 10808 remain loopback-only inside the guest.

## Manual reinstall / recovery

The original Disko + nixos-anywhere path is retained:

```sh
nix run github:nix-community/nixos-anywhere -- \
  --flake github:drunkod/nixos-serverking-vm#nixos-minimal \
  -i ~/.ssh/id_ed25519_nixos_minimal \
  --ssh-option 'ProxyCommand=nc %h %p' \
  --target-host nixos-minimal
```

This path destroys and recreates `/dev/vda` and should not be the normal provisioning mechanism.

## Verified deployment

The first real application VM has been validated end-to-end:

```text
VM:            v2ray-warp-01
instance type: u1.small
root disk:     20 GiB
external:      22/tcp, 8080/tcp
application:   nix-v2ray-warp
WARP:          warp=on
reboot test:   passed
```

The 10 GiB golden image expands its root partition/filesystem to the requested 20 GiB guest disk. The application service is declarative and returns automatically after reboot.
