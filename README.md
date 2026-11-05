# proxmox-windows-autounattend

Unattended installation of Windows Server on Proxmox VE: one small answer-file
ISO per VM, built from environment variables.

The repository contains these files:

| File | Purpose |
|---|---|
| `autounattend.xml` | answer file, placeholders are substituted at build time |
| `set-network.ps1` | applies the static IPv4 configuration inside the guest |
| `make-install-iso.sh` | validates the values, builds the ISO, prints the `qm create` command |
| `PROXMOX.md` | what the host needs and the one-time preparation (ISOs, image index) |

There is deliberately no profile file and no default for site-specific values.
An ISO per VM means the hostname and the network configuration are in the
medium, so a second run for another VM is one more command.

## Requirements

- Proxmox VE node with `genisoimage` and `python3` (both present on a stock node)
- A Windows Server ISO, 2019 or newer
- A virtio-win ISO (see [Driver folder](#driver-folder))
- At least 32 GB per VM; 50 GB is a sensible default

## Quick start

Build the ISO on the node:

```bash
ADMIN_PASSWORD='...' \
VM_HOSTNAME=win01 \
IP=192.0.2.10 PREFIX=24 GW=192.0.2.1 DNS1=192.0.2.53 DNS2=192.0.2.54 \
DRIVER_VERSION=2k25 IMAGE_INDEX=2 \
OUT=/var/lib/vz/template/iso/answer-win01.iso \
./make-install-iso.sh
```

Add the VM parameters and the script prints the matching `qm create` command
instead of a reminder to write it yourself:

```bash
# same variables as above, plus:
VMID=901 VMNAME=win01 STORAGE=local-lvm BRIDGE=vmbr0 \
ISO_WIN='local:iso/win-server.iso' \
ISO_VIRTIO='local:iso/virtio-win.iso' \
ISO_ANSWER='local:iso/answer-win01.iso'
```

It only prints the command. Review it, then run it or paste it into the shell.

Start the VM and watch the console: the Windows medium asks
*"Press any key to boot from CD or DVD"*. **Press a key.** Without one the
bootloader exits, the empty disk has nothing to boot, and UEFI reports
"No bootable option or device was found". This is not a configuration error.

The rest runs on its own:

1. Setup partitions, selects the image and loads the VirtIO storage driver.
2. First logon installs the VirtIO guest tools, stages `set-network.ps1` and
   reboots — the network driver only binds after that reboot.
3. Second logon applies the static IP configuration.
   Log: `C:\setup-network.log`.

Afterwards: run Windows updates, detach `ide0` (answer ISO) and `ide3`
(virtio-win), then remove the answer ISO from the ISO store.

## Parameters

See the header of `make-install-iso.sh` for the full list. Site-specific and
therefore never defaulted: addresses, hostname, password, storage, bridge.

`DRIVER_VERSION` and `IMAGE_INDEX` are the two values that depend on the
Windows version and on the media. Everything else in the answer file is
version-independent.

### Driver folder

`DRIVER_VERSION` is the version folder inside the virtio-win ISO:

| Guest | Folder |
|---|---|
| Windows Server 2016 | `2k16` |
| Windows Server 2019 | `2k19` |
| Windows Server 2022 | `2k22` |
| Windows Server 2025 | `2k25` |

The `2k25` folder exists from roughly virtio-win 0.1.27x. On 0.1.285,
VirtIO SCSI/BLK is reported to cause read errors and performance problems
with Windows Server 2025 under IO load; 0.1.271 and 0.1.302 are unaffected.

### Image index

`IMAGE_INDEX` selects the edition inside `install.wim`. The script does not
guess it: numbering differs between media, and a *name* that does not match
exactly makes Setup fall back to index 1 without an error — often the Core
edition, which some products do not support, and the failure surfaces much
later as a misleading product key message.

Read the actual numbering on the medium:

```
dism /Get-WimInfo /WimFile:X:\sources\install.wim
```

Typical Windows Server 2025 evaluation media:

| Index | Image |
|---|---|
| 1 | Windows Server 2025 Standard Evaluation (Server Core) |
| 2 | Windows Server 2025 Standard Evaluation (Desktop Experience) |
| 3 | Windows Server 2025 Datacenter Evaluation (Server Core) |
| 4 | Windows Server 2025 Datacenter Evaluation (Desktop Experience) |

### CPU type

The `qm create` output uses `x86-64-v2-AES` by default. This is required:
Windows Server 2025 needs the SSE4.2 and POPCNT instructions, which the
`kvm64` model — Proxmox' fallback when `--cpu` is omitted — does not provide.
Setup fails without them.

`host` also works and passes through everything the host has, but rules out
live migration between nodes with different CPUs.

## Activation

The answer file contains no product key. Evaluation media installs without
one; volume media gets its key from the activation tooling afterwards.

## Repository layout

The answer file assumes:

- UEFI (OVMF) — the answer file creates a GPT layout, which needs UEFI
- GPT: ESP 100 MB, MSR 16 MB, Windows on the rest
- VirtIO SCSI single for the disk, VirtIO for the network
- one network adapter: `set-network.ps1` configures the first adapter that
  reports `Up`, so it may pick the wrong one if there are two

## Pitfalls

Each of these cost a run once and is fixed in the files. They are listed so
they are not reintroduced.

### "Windows could not assign a volume label to a partition" (0x80004005)

The MSR partition had a `<Label>` in `<ModifyPartitions>`. MSR has no file
system, a volume label cannot be set, and Setup aborts while applying
`<DiskConfiguration>`. There is no `ModifyPartition` entry for the MSR
partition; the `<Order>` values of the remaining entries must be gap-free.

### APIPA address instead of the configured one

The adapter was on DHCP. `netsh interface ip set address` does not apply a
static address while DHCP is enabled and reports no error either — the log
looks successful, the adapter stays on 169.254.x.x. `set-network.ps1`
disables DHCP first, removes any existing address, then uses
`New-NetIPAddress`. Do not use `netsh`.

### FirstLogonCommands stop after the first command

`virtio-win-guest-tools.exe` reboots the machine itself. Called with
`start /wait`, the first command blocks until that reboot, and
FirstLogonCommands do not run again afterwards — the later commands never
execute. The first command therefore starts the installer asynchronously,
the second stages a RunOnce entry (which survives the reboot), and the third
waits until the installer has exited and `netkvm.inf` is in the driver store
(10 minutes at most), then forces the reboot. A fixed delay there can cut the
installer off; the guest then has no NIC driver and the adapter never appears.

### Wrong or missing network driver in the guest

The VirtIO network driver from the guest tools binds only after a reboot.
Applying the IP config in the same logon as the driver installation fails
because no adapter exists yet; hence the two-login sequence.

### "no network adapter found" on the second logon

RunOnce fires at logon, a few seconds before the freshly bound NIC shows up
in `Get-NetAdapter`. The driver is installed and fine; a single check just
comes too early. `set-network.ps1` polls for an adapter in state `Up` for up
to 120 s before it falls back to the first adapter. Re-running the script
by hand afterwards is safe.

## Security

The answer ISO contains the local Administrator password in clear text.
Detach and delete it once the installation is done. The password is also
visible in the VM configuration while the ISO is mounted, so do not reuse a
credential that matters elsewhere.
