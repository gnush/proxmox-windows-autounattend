#!/usr/bin/env bash
#
# Builds the answer-file ISO for an unattended Windows Server installation
# on Proxmox VE and, if VMID is given, prints the matching "qm create".
#
# Run on a Proxmox VE node; genisoimage and python3 are assumed present.
# Writes one ISO to OUT and nothing else: no VM is created, no command run.
#
#   ADMIN_PASSWORD='...' VM_HOSTNAME=win01 IP=192.0.2.10 PREFIX=24 \
#   GW=192.0.2.1 DNS1=192.0.2.53 DNS2=192.0.2.54 \
#   DRIVER_VERSION=2k25 IMAGE_INDEX=2 OUT=/path/answer.iso \
#   ./make-install-iso.sh
#
# There is no built-in profile: every value is required, because a default
# that fits one environment is wrong in the next one.
#
# Required:
#   ADMIN_PASSWORD   password of the local Administrator
#   VM_HOSTNAME      computer name, max 15 chars, A-Z a-z 0-9 and '-'
#   IP               static IPv4 address
#   PREFIX           prefix length, 1-32
#   GW               default gateway
#   DNS1, DNS2       DNS servers
#   DRIVER_VERSION   version folder on the virtio-win ISO: 2k16 2k19 2k22 2k25
#   IMAGE_INDEX      image index inside install.wim, see README
#   OUT              path of the ISO to write
#
# Optional:
#   TIMEZONE         Windows time zone id (UTC)
#   ENABLE_PING      1 enables inbound ICMPv4 from the VM's own subnet;
#                    any other value leaves it off
#   ENABLE_RDP       1 enables Remote Desktop (NLA) from the VM's own
#                    subnet; any other value leaves it off
#
# Required only when VMID is set (otherwise the qm command is omitted):
#   VMID             numeric VM id
#   VMNAME           name shown in the Proxmox UI
#   STORAGE          storage id for disk and EFI vars, e.g. local-lvm
#   BRIDGE           network bridge, e.g. vmbr0
#   ISO_WIN          Windows ISO as Proxmox sees it, e.g. local:iso/win.iso
#   ISO_VIRTIO       virtio-win ISO as Proxmox sees it
#   ISO_ANSWER       the ISO built here, e.g. local:iso/answer.iso
#
# Optional with VMID:
#   POOL, TAGS, VLAN, VM_OSTYPE (win11), CPU (x86-64-v2-AES),
#   CORES (2), MEMORY (8192), DISK (50)
#
set -euo pipefail

TIMEZONE="${TIMEZONE:-UTC}"
ENABLE_PING="${ENABLE_PING:-0}"
ENABLE_RDP="${ENABLE_RDP:-0}"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for v in ADMIN_PASSWORD VM_HOSTNAME IP PREFIX GW DNS1 DNS2 DRIVER_VERSION IMAGE_INDEX OUT; do
  if [ -z "${!v:-}" ]; then
    echo "ERROR: $v is not set. See the header of this script." >&2
    exit 1
  fi
done

for bin in genisoimage python3; do
  command -v "$bin" >/dev/null || { echo "ERROR: $bin not found" >&2; exit 1; }
done

# The same checks run again in python; failing here gives a clearer message
# than the parser error from the substitution step.
#
# VM_HOSTNAME, not HOSTNAME: bash sets HOSTNAME itself, so a missing value
# would silently become the node's hostname instead of an error. Same for
# VM_OSTYPE vs. bash's OSTYPE.
case "$VM_HOSTNAME" in
  *[!A-Za-z0-9-]*) echo "ERROR: VM_HOSTNAME allows only A-Z a-z 0-9 and '-' ($VM_HOSTNAME)" >&2; exit 1 ;;
esac
if [ "${#VM_HOSTNAME}" -gt 15 ]; then
  echo "ERROR: VM_HOSTNAME is ${#VM_HOSTNAME} chars, max is 15" >&2
  exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# ---------------------------------------------------------------------------
# Substitute placeholders.
#
# python3 str.replace instead of sed: in a sed replacement '&' means "the
# matched text", so a password containing & < or > would expand to nonsense
# after XML escaping. str.replace is literal.
#
# Values go in through the environment, not as arguments, so the password
# does not show up in the process list.
# ---------------------------------------------------------------------------
SRC_DIR="$SRC_DIR" WORKDIR="$workdir" \
ADMIN_PASSWORD="$ADMIN_PASSWORD" VM_HOSTNAME="$VM_HOSTNAME" \
IP="$IP" PREFIX="$PREFIX" GW="$GW" DNS1="$DNS1" DNS2="$DNS2" \
DRIVER_VERSION="$DRIVER_VERSION" IMAGE_INDEX="$IMAGE_INDEX" TIMEZONE="$TIMEZONE" \
ENABLE_PING="$ENABLE_PING" ENABLE_RDP="$ENABLE_RDP" \
python3 <<'PY'
import ipaddress, os, sys
import xml.sax.saxutils as sx
from xml.dom import minidom

src  = os.environ['SRC_DIR']
work = os.environ['WORKDIR']
env  = os.environ

def fail(msg):
    print(f'ERROR: {msg}', file=sys.stderr)
    sys.exit(1)

def xesc(s):
    return sx.escape(s, {'"': '&quot;', "'": '&apos;'})

# --- validate -------------------------------------------------------------
for key in ('IP', 'GW', 'DNS1', 'DNS2'):
    try:
        addr = ipaddress.IPv4Address(env[key])
    except ValueError:
        fail(f'{key} is not a valid IPv4 address ({env[key]})')
    if addr.is_loopback or addr.is_unspecified or addr.is_multicast:
        fail(f'{key} must be a unicast host address ({env[key]})')

if not env['PREFIX'].isdigit() or not 1 <= int(env['PREFIX']) <= 32:
    fail(f"PREFIX must be 1-32 ({env['PREFIX']})")

if not env['IMAGE_INDEX'].isdigit() or int(env['IMAGE_INDEX']) < 1:
    fail(f"IMAGE_INDEX must be a positive integer ({env['IMAGE_INDEX']})")

# Ends up in a path on the virtio-win ISO; keep it to that shape.
if not env['DRIVER_VERSION'].replace('.', '').isalnum():
    fail(f"DRIVER_VERSION must be alphanumeric ({env['DRIVER_VERSION']})")

net = {
    '@@IP@@':     env['IP'],
    '@@PREFIX@@': env['PREFIX'],
    '@@GW@@':     env['GW'],
    '@@DNS1@@':   env['DNS1'],
    '@@DNS2@@':   env['DNS2'],
}

# The rule targets the VM's own subnet, never the whole internet side.
subnet = str(ipaddress.IPv4Network(f"{env['IP']}/{env['PREFIX']}", strict=False))

ping_values = {'@@SUBNET@@': subnet}

# cmd /c for replaces %i in a FirstLogonCommands line.
def runonce(key, fname):
    return ('        ' + '<SynchronousCommand wcm:action="add">'
            '<Order>2</Order>'
            f'<Description>Stage {fname}</Description>'
            f'<CommandLine>cmd /c for %i in (D E F G H) do if exist %i:\\{fname} '
            f'(copy /Y %i:\\{fname} C:\\setup\\{fname} '
            f'&amp; reg add "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\RunOnce" '
            f'/v {key} /t REG_SZ /d "powershell -NoProfile -ExecutionPolicy Bypass '
            f'-File C:\\setup\\{fname}" /f)</CommandLine>'
            '</SynchronousCommand>')

ping_command = ''
if env['ENABLE_PING'] == '1':
    ping_command = runonce('EnablePing', 'enable-ping.ps1')

rdp_command = ''
if env['ENABLE_RDP'] == '1':
    rdp_command = runonce('EnableRdp', 'enable-rdp.ps1')

xml_values = {
    **net,
    '@@PING_COMMAND@@':   ping_command.rstrip(),
    '@@RDP_COMMAND@@':    rdp_command.rstrip(),
    '@@HOSTNAME@@':       xesc(env['VM_HOSTNAME']),
    '@@ADMIN_PASSWORD@@': xesc(env['ADMIN_PASSWORD']),
    '@@DRIVER_VERSION@@': env['DRIVER_VERSION'],
    '@@IMAGE_INDEX@@':    env['IMAGE_INDEX'],
    '@@TIMEZONE@@':       xesc(env['TIMEZONE']),
}

def render(name, values, crlf):
    with open(os.path.join(src, name), encoding='utf-8') as f:
        text = f.read()
    for k, v in values.items():
        text = text.replace(k, v)
    left = [k for k in values if k in text]
    if left:
        fail(f'unreplaced placeholders in {name}: {", ".join(left)}')
    out = os.path.join(work, name)
    with open(out, 'w', encoding='utf-8', newline='\r\n' if crlf else '\n') as f:
        f.write(text)
    return text

# autounattend.xml: XML-escaped, must stay well-formed afterwards
xml = render('autounattend.xml', xml_values, crlf=False)
try:
    minidom.parseString(xml)
except Exception as e:
    fail(f'autounattend.xml is not well-formed after substitution: {e}')

# set-network.ps1: plain values, CRLF for Windows PowerShell
render('set-network.ps1', net, crlf=True)

if env['ENABLE_PING'] == '1':
    render('enable-ping.ps1', ping_values, crlf=True)

if env['ENABLE_RDP'] == '1':
    render('enable-rdp.ps1', ping_values, crlf=True)

print('Substitution OK: XML well-formed, no placeholders left.')
PY

genisoimage -quiet -J -R -V ANSWERFILE -o "$OUT" "$workdir"

echo "ISO written: $OUT"
echo "  hostname:  $VM_HOSTNAME"
echo "  network:   $IP/$PREFIX gw $GW dns $DNS1,$DNS2"
echo "  driver:    vioscsi/$DRIVER_VERSION/amd64"
echo "  image:     index $IMAGE_INDEX"
echo "  contents:  autounattend.xml, set-network.ps1$( [ "$ENABLE_PING" = 1 ] && echo ', enable-ping.ps1')$( [ "$ENABLE_RDP" = 1 ] && echo ', enable-rdp.ps1')"
echo
echo "The ISO contains the Administrator password in clear text. Detach it"
echo "from the VM and remove it from the ISO store once installed."
ls -l "$OUT"

# ---------------------------------------------------------------------------
# Print the qm create command when the parameters for one are present.
# ---------------------------------------------------------------------------
if [ -z "${VMID:-}" ]; then
  exit 0
fi

for v in VMNAME STORAGE BRIDGE ISO_WIN ISO_VIRTIO ISO_ANSWER; do
  if [ -z "${!v:-}" ]; then
    echo >&2
    echo "ERROR: VMID is set, so $v is required as well." >&2
    exit 1
  fi
done

VM_OSTYPE="${VM_OSTYPE:-win11}"
CPU="${CPU:-x86-64-v2-AES}"
CORES="${CORES:-2}"
MEMORY="${MEMORY:-8192}"
DISK="${DISK:-50}"

net0="virtio,bridge=$BRIDGE"
[ -n "${VLAN:-}" ] && net0="$net0,tag=$VLAN"

lines=(
  "qm create $VMID"
  "  --name $VMNAME"
  "  --ostype $VM_OSTYPE"
  "  --machine q35"
  "  --bios ovmf"
  "  --efidisk0 $STORAGE:0,efitype=4m,pre-enrolled-keys=1"
  "  --agent 1"
  "  --scsihw virtio-scsi-single"
  "  --cpu $CPU"
  "  --cores $CORES --sockets 1 --memory $MEMORY"
  "  --scsi0 $STORAGE:$DISK,iothread=1,cache=writeback,discard=on"
  "  --ide2 $ISO_WIN,media=cdrom"
  "  --ide3 $ISO_VIRTIO,media=cdrom"
  "  --ide0 $ISO_ANSWER,media=cdrom"
  "  --net0 $net0"
  "  --boot order='ide2;scsi0'"
)
[ -n "${POOL:-}" ] && lines+=("  --pool $POOL")
[ -n "${TAGS:-}" ] && lines+=("  --tags $TAGS")

echo
echo "# Review before running. Answers are not checked against this VM."
if [ "$CPU" = "x86-64-v2-AES" ]; then
  echo "# Windows Server 2025 needs SSE4.2 and POPCNT; the kvm64 default lacks them."
fi
printf '%s \\\n' "${lines[@]:0:${#lines[@]}-1}"
printf '%s\n' "${lines[${#lines[@]}-1]}"
echo
echo "# After installation: detach ide0 and ide3, then remove the answer ISO."
