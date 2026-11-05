# Proxmox host: prerequisites and preparation

What the node needs before a VM can be built with this repository, and what
to prepare once.

## Host requirements

| Item | Requirement | Why |
|---|---|---|
| Proxmox VE | 8.x or 9.x | `virtio-scsi-single`, `efidisk0` with `efitype=4m` |
| Tools on the node | `genisoimage`, `python3` | `make-install-iso.sh` needs both; a stock node has them |
| CPU | SSE4.2 and POPCNT on the host | Windows Server 2025 requires these instructions; a host without them cannot run the guest at all |
| Storage | one storage for VM disks and one for ISOs | the ISO store must be `iso` content type |
| RAM | 8 GB per VM (2 GB is the Windows minimum, 8 GB is what most roles want) | |
| Disk | 50 GB per VM | Windows Server 2025 needs 32 GB minimum |

The `qm create` command printed by the script uses:

| Option | Value | Rationale |
|---|---|---|
| `--bios ovmf` with `--efidisk0` | Secure Boot pre-enrolled | the answer file writes a GPT layout, which needs UEFI |
| `--scsihw virtio-scsi-single` | one queue per disk, `iothread=1` | the VirtIO SCSI driver loaded in WinPE is the one this controller needs; with a different controller the disk stays invisible |
| `--net0 virtio` | VirtIO NIC | the driver comes from the guest tools, which is why the network is configured on the second logon |
| `--agent 1` | QEMU guest agent | installed by the guest tools, gives Proxmox a clean shutdown |

Check that the ISO store accepts images:

```bash
pvesm status --content iso
```

## Preparation, once per host

### 1. Windows Server ISO

Get an ISO from one of:

- **Evaluation** — Microsoft Evaluation Center, Windows Server 2025. Free,
  runs 180 days without a product key. Appropriate for testing the build.
- **Volume license** — your Microsoft licensing channel. No key is needed at
  installation time; activation happens afterwards.

Upload it to the ISO store, either through the web UI
(node → local → ISO Images → Upload) or directly:

```bash
# on the node; /var/lib/vz/template/iso is the default store path
scp win-server-2025.iso root@pve:/var/lib/vz/template/iso/
```

The name as Proxmox sees it is `<storage>:iso/<file>`, e.g.
`local:iso/win-server-2025.iso`.

### 2. VirtIO driver ISO

Windows has no drivers for VirtIO devices. Without them the installer cannot
see the disk and the guest has no network. Download `virtio-win.iso` from the
Fedora project:

- stable build: <https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso>
- specific versions: <https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/>
- release notes and known issues: <https://pve.proxmox.com/wiki/Windows_VirtIO_Drivers#virtio-win_Releases>

Upload it the same way. The file carries a version folder per Windows release
(`2k19`, `2k22`, `2k25`); `make-install-iso.sh` takes that folder as
`DRIVER_VERSION`, see the README.

### 3. Note the image index of your Windows ISO

`IMAGE_INDEX` selects the edition. Read it from the medium rather than
assuming it — numbering differs between Microsoft media:

```
# in WinPE or any Windows machine, X: is the mounted ISO
dism /Get-WimInfo /WimFile:X:\sources\install.wim
```

Pick the *Desktop Experience* entry. Server Core is a separate image and is
not supported by every product that runs on Windows Server.

### 4. Check free VM IDs

```bash
qm list
```

The `qm create` command printed by the script does not check its VM ID.

## Building the answer ISO

The script runs on the node and writes one file. It creates no VM:

```bash
ADMIN_PASSWORD='...' \
VM_HOSTNAME=win01 \
IP=192.0.2.10 PREFIX=24 GW=192.0.2.1 DNS1=192.0.2.53 DNS2=192.0.2.54 \
DRIVER_VERSION=2k25 IMAGE_INDEX=2 \
OUT=/var/lib/vz/template/iso/answer-win01.iso \
./make-install-iso.sh
```

The ISO is about 700 KB. It contains `autounattend.xml` and
`set-network.ps1`, with the values already substituted.

## Creating and starting the VM

With the VM variables set, the script prints the `qm create` command instead
of a reminder. Review it, then run it.

Three CD-ROMs are attached:

| Device | Medium |
|---|---|
| `ide0` | the answer ISO built here |
| `ide2` | the Windows ISO |
| `ide3` | the virtio-win ISO |

Boot order is `ide2;scsi0`: Setup starts from the Windows medium and
continues from the disk after the reboot.

Start the VM and open the console. **Press a key when the medium asks
"Press any key to boot from CD or DVD"** — otherwise the empty disk is
booted and UEFI reports "No bootable option or device was found". This
looks like a failure and is not one.

Expect two reboots. The installation is done when the desktop shows up and
`C:\setup-network.log` reports the configured addresses.

## After the installation

```bash
# detach the answer ISO and the virtio ISO, keep the Windows ISO detached too
qm set 901 --delete ide0
qm set 901 --delete ide3
qm set 901 --delete ide2
```

Then:

- run Windows updates
- install activation, if the media is volume licensed
- remove the answer ISO from the ISO store: it contains the Administrator
  password in clear text

## Troubleshooting

The console is the only feedback during Setup; `C:\setup-network.log` and
`C:\Windows\Panther\unattendgc\setupact.log` are the places to look
afterwards. The known pitfalls — MSR volume label, APIPA address,
FirstLogonCommands stopping early — are documented in the README.

If Setup stops at "Select the operating system you want to install", the
`IMAGE_INDEX` does not exist on this medium; the file has the list.
