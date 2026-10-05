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

For GitHub Actions, store a base64 encoded kubeconfig as the repository secret:

```text
SERVERKING_KUBECONFIG_B64
```

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
  -> create my-project-root from source.disk.name
  -> wait VMDisk Ready
  -> create VMInstance
  -> linux.efi / u1.small
  -> inject SSH key + cloud-init hostname
  -> expose requested TCP ports
  -> wait VM Ready
  -> print matching Service / address
```

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

## Next milestone

The first end-to-end acceptance test is:

1. Build the 10 GiB qcow2 in GitHub Actions.
2. Publish it as a release asset.
3. Import it as `nixos-26-05-v1`.
4. Clone it into a test root VMDisk.
5. Create a test VMInstance.
6. Wait for Ready.
7. Verify external IP and SSH.
8. Confirm a larger clone expands the root filesystem automatically.
