#!/usr/bin/env bash
set -euo pipefail

# AirPrint bridge for an HP LaserJet P1005 on a Raspberry Pi Zero 2 W(H).
#
# - the P1005 is a USB-only, host-based (ZjStream/GDI) printer, so all
#   rendering happens on the Pi via foo2zjs/foo2xqx
# - the printer has no persistent firmware: a blob must be uploaded after every
#   power-on. The firmware file is non-free and is fetched once with
#   `getweb P1005` (or supplied via P1005_FIRMWARE); this script installs a
#   udev rule that uploads it whenever the printer appears on USB.
#
# The Pi reaches the LAN over an Ethernet HAT and the printer over USB. The
# fixed IP is expected to be set as a DHCP reservation on the router, so nothing
# about the IP is configured here (see prepare-host.sh for hostname/Ethernet).

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root: sudo bash $0"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

ADMIN_USER="${SUDO_USER:-}"
QUEUE_NAME="${QUEUE_NAME:-HP-LaserJet-P1005}"
PRINTER_NAME="${PRINTER_NAME:-HP LaserJet P1005}"
PRINTER_LOCATION="${PRINTER_LOCATION:-}"
PRINTER_URI="${PRINTER_URI:-auto}"
PRINTER_MODEL="${PRINTER_MODEL:-auto}"
PRINTER_PPD="${PRINTER_PPD:-auto}"
# 1200x600dpi is the PPD default but makes the Pi Zero rasterize for minutes.
DEFAULT_RESOLUTION="${DEFAULT_RESOLUTION:-600x600dpi}"
DEFAULT_DENSITY="${DEFAULT_DENSITY:-Density5}"
DEFAULT_PAGE_SIZE="${DEFAULT_PAGE_SIZE:-A4}"
DEFAULT_DUPLEX="${DEFAULT_DUPLEX:-None}"
DISABLE_DUPLEX_ADVERTISEMENT="${DISABLE_DUPLEX_ADVERTISEMENT:-1}"
ALLOW_ACTIVE_JOBS="${ALLOW_ACTIVE_JOBS:-0}"
# Optional override: local path or URL to a ready-made sihpP1005.dl firmware
# blob. When empty the script tries `getweb P1005`.
P1005_FIRMWARE="${P1005_FIRMWARE:-}"
FIRMWARE_DEST="/lib/firmware/hp/sihpP1005.dl"
# The stock udev rule from printer-driver-foo2zjs runs a loader (hpljP1005) that
# is missing on Ubuntu 22.04 armhf, so the firmware never loads on power-on. We
# install our own loader + rule instead.
FIRMWARE_LOADER="/usr/local/bin/p1005-loadfw.sh"
FIRMWARE_UDEV_RULE="/etc/udev/rules.d/99-p1005-firmware.rules"
# The Pi Zero is slow at TLS; a storm of iOS ipps retries can wedge cupsd so it
# accepts connections but never answers. A timer restarts it when that happens.
WATCHDOG_SCRIPT="/usr/local/bin/cups-watchdog.sh"
WATCHDOG_UNIT="/etc/systemd/system/cups-watchdog"
# The P1005 is unidirectional over USB. Without a quirk the CUPS usb backend
# waits ~7s (WAIT_EOF_DELAY) for a back-channel it never sends, stalling every
# job and prolonging the iOS print spinner. VID:PID from `lsusb` (03f0:3d17).
USB_QUIRK_FILE="/usr/share/cups/usb/hp-laserjet-p1005.quirks"
CUPS_DROPIN_DIR="/etc/cups/cupsd.conf.d"
CUPS_DROPIN_FILE="${CUPS_DROPIN_DIR}/10-airprint-server.conf"
# When the Pi is multi-homed (e.g. Ethernet HAT + Wi-Fi on the same subnet),
# Avahi otherwise advertises the printer on every interface, producing duplicate
# Bonjour records that make iOS AirPrint drop the selection, and it can rename
# the host to "<name>-2" on a self-collision. Restrict advertising to one
# interface to fix both. Leave empty to advertise on all interfaces.
AVAHI_INTERFACE="${AVAHI_INTERFACE:-}"
AVAHI_CONF="/etc/avahi/avahi-daemon.conf"

log() {
  echo
  echo "==> $1"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

run_step() {
  local description="$1"
  shift

  log "${description}"
  "$@"
}

maybe_prompt_location() {
  if [[ -n "${PRINTER_LOCATION}" ]]; then
    return
  fi

  if [[ -t 0 ]]; then
    read -r -p "Printer room/location: " PRINTER_LOCATION || true
  fi
}

ensure_admin_user() {
  if [[ -n "${ADMIN_USER}" ]] && id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    usermod -aG lpadmin "${ADMIN_USER}"
    echo "Added ${ADMIN_USER} to lpadmin"
  else
    echo "Skipping lpadmin user assignment; SUDO_USER is not set to a real account"
  fi
}

ensure_no_active_jobs() {
  local active_jobs=""

  active_jobs="$(lpstat -o "${QUEUE_NAME}" 2>/dev/null || true)"
  if [[ -z "${active_jobs}" || "${ALLOW_ACTIVE_JOBS}" == "1" ]]; then
    return
  fi

  echo "Active jobs exist for ${QUEUE_NAME}; refusing to reconfigure CUPS while printing." >&2
  echo "${active_jobs}" >&2
  echo "Wait for them to finish, cancel them, or rerun with ALLOW_ACTIVE_JOBS=1." >&2
  exit 1
}

install_base_packages() {
  apt-get update
  apt-get install -y --no-install-recommends \
    cups \
    cups-filters \
    avahi-daemon \
    avahi-utils \
    printer-driver-foo2zjs \
    foomatic-db-compressed-ppds \
    usb.ids \
    curl
}

# foo2zjs ships getweb but does not always put it on PATH.
find_getweb() {
  if command -v getweb >/dev/null 2>&1; then
    command -v getweb
    return
  fi

  local candidate
  for candidate in /usr/share/foo2zjs/getweb /usr/bin/getweb /usr/lib/foo2zjs/getweb; do
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return
    fi
  done
}

install_firmware() {
  if [[ -s "${FIRMWARE_DEST}" ]]; then
    echo "Firmware already present: ${FIRMWARE_DEST}"
    return
  fi

  mkdir -p "$(dirname "${FIRMWARE_DEST}")"

  # 1. Explicit override (local file or URL).
  if [[ -n "${P1005_FIRMWARE}" ]]; then
    if [[ "${P1005_FIRMWARE}" =~ ^https?:// ]]; then
      curl --fail --location --retry 5 --retry-delay 2 \
        "${P1005_FIRMWARE}" -o "${FIRMWARE_DEST}"
    elif [[ -f "${P1005_FIRMWARE}" ]]; then
      install -m 0644 "${P1005_FIRMWARE}" "${FIRMWARE_DEST}"
    else
      echo "P1005_FIRMWARE not found: ${P1005_FIRMWARE}" >&2
      exit 1
    fi
    echo "Installed firmware from P1005_FIRMWARE to ${FIRMWARE_DEST}"
    return
  fi

  # 2. getweb from the foo2zjs package. It downloads + converts the blob and,
  #    on Debian/Ubuntu, drops it into /lib/firmware/hp/. We run it from a temp
  #    dir and then make sure the .dl ended up at FIRMWARE_DEST.
  local getweb tmp_dir found
  getweb="$(find_getweb || true)"
  if [[ -z "${getweb}" ]]; then
    echo "getweb not found; cannot fetch firmware automatically." >&2
    firmware_help
    return
  fi

  tmp_dir="$(mktemp -d)"
  echo "Fetching P1005 firmware with ${getweb} (needs internet)..."
  if ! ( cd "${tmp_dir}" && "${getweb}" P1005 ); then
    echo "getweb P1005 failed (foo2zjs.com may be unreachable)." >&2
    rm -rf "${tmp_dir}"
    firmware_help
    return
  fi

  if [[ ! -s "${FIRMWARE_DEST}" ]]; then
    found="$(find "${tmp_dir}" /usr/share/foo2zjs -name 'sihpP1005.dl' -type f 2>/dev/null | head -n 1 || true)"
    if [[ -n "${found}" ]]; then
      install -m 0644 "${found}" "${FIRMWARE_DEST}"
    fi
  fi

  rm -rf "${tmp_dir}"

  if [[ -s "${FIRMWARE_DEST}" ]]; then
    echo "Installed firmware to ${FIRMWARE_DEST}"
  else
    echo "Firmware was not installed." >&2
    firmware_help
  fi
}

firmware_help() {
  cat >&2 <<EOF
The P1005 needs its firmware uploaded after every power-on. Without
${FIRMWARE_DEST} the printer will accept jobs but print nothing.

Fix it by either:
  - placing a sihpP1005.dl blob and rerunning with:
      sudo P1005_FIRMWARE=/path/to/sihpP1005.dl ./install-airprint-p1005.sh
  - or fetching it manually on the Pi:
      cd /tmp && /usr/share/foo2zjs/getweb P1005
      sudo cp sihpP1005.dl ${FIRMWARE_DEST}
EOF
}

install_firmware_autoloader() {
  cat > "${FIRMWARE_LOADER}" <<EOF
#!/usr/bin/env bash
# Uploads the HP LaserJet P1005 firmware. Called from udev on every USB add.
# Without firmware the printer re-enumerates every few seconds and CUPS reports
# "Printer not connected; will retry".
FIRMWARE="${FIRMWARE_DEST}"

if [[ ! -s "\${FIRMWARE}" ]]; then
  logger -t p1005-loadfw "firmware \${FIRMWARE} is missing"
  exit 1
fi

# The device node flickers while the printer waits for firmware; catch it.
for _ in \$(seq 1 20); do
  for dev in /dev/usb/lp0 /dev/usblp0; do
    if [[ -c "\${dev}" ]] && cat "\${FIRMWARE}" > "\${dev}" 2>/dev/null; then
      logger -t p1005-loadfw "firmware uploaded to \${dev}"
      exit 0
    fi
  done
  sleep 0.5
done

logger -t p1005-loadfw "printer device node did not appear; firmware not uploaded"
exit 1
EOF
  chmod 0755 "${FIRMWARE_LOADER}"

  # systemd-run detaches the loader so udev is not blocked while it waits.
  cat > "${FIRMWARE_UDEV_RULE}" <<EOF
# HP LaserJet P1005: upload firmware on every power-on / USB plug.
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="03f0", ATTR{idProduct}=="3d17", RUN+="/bin/systemd-run --no-block ${FIRMWARE_LOADER}"
EOF

  udevadm control --reload-rules
  echo "Installed ${FIRMWARE_LOADER} and ${FIRMWARE_UDEV_RULE}"
  echo "Loader logs: journalctl -t p1005-loadfw"
}

install_cups_watchdog() {
  cat > "${WATCHDOG_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
# Restarts cupsd when it accepts connections but stops answering HTTP.
for attempt in 1 2; do
  if curl -fsS -o /dev/null --max-time 10 http://127.0.0.1:631/; then
    exit 0
  fi
  [[ "${attempt}" -eq 1 ]] && sleep 5
done

logger -t cups-watchdog "cupsd is not answering on :631; restarting cups"
systemctl restart cups
EOF
  chmod 0755 "${WATCHDOG_SCRIPT}"

  cat > "${WATCHDOG_UNIT}.service" <<EOF
[Unit]
Description=Restart CUPS if it stops answering

[Service]
Type=oneshot
ExecStart=${WATCHDOG_SCRIPT}
EOF

  cat > "${WATCHDOG_UNIT}.timer" <<'EOF'
[Unit]
Description=Check CUPS health every minute

[Timer]
OnBootSec=60
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now cups-watchdog.timer
  echo "Enabled cups-watchdog.timer (logs: journalctl -t cups-watchdog)"
}

# Push the firmware to the printer right now if it is connected. The udev rule
# above does this on every power-on; this just avoids a power-cycle for the
# first job.
load_firmware_now() {
  if [[ ! -s "${FIRMWARE_DEST}" ]]; then
    return
  fi

  local usb_backend="/usr/lib/cups/backend/usb"
  local printer_uri=""

  if [[ ! -x "${usb_backend}" ]]; then
    echo "CUPS USB backend not found; firmware will load via udev when the printer is connected/powered on."
    return
  fi

  # Use the same libusb path as foo2zjs' udev helper. Direct writes to
  # /dev/usb/lp0 can fail with EIO while the P1005 is waiting for firmware.
  printer_uri="$(
    "${usb_backend}" 2>/dev/null \
      | awk 'tolower($0) ~ /hp.*laserjet.*p1005/ && $0 !~ /FWVER/ { print $2; exit }'
  )"

  if [[ -z "${printer_uri}" ]]; then
    echo "No firmware upload needed, or the P1005 is not connected yet."
    return
  fi

  echo "Uploading firmware to ${printer_uri}"
  if timeout 90 env DEVICE_URI="${printer_uri}" \
    "${usb_backend}" 1 root firmware 1 "" "${FIRMWARE_DEST}"; then
    echo "Firmware upload completed"
    return
  fi

  echo "Firmware upload did not complete; power-cycle the printer and check journalctl for hpljP1005 logs."
}

configure_usb_quirk() {
  # Separate file (not the package-managed org.cups.usb-quirks) so CUPS updates
  # don't overwrite it; the usb backend reads every file in this directory.
  if [[ ! -d "$(dirname "${USB_QUIRK_FILE}")" ]]; then
    echo "CUPS usb quirks dir missing; skipping unidir quirk"
    return
  fi

  cat > "${USB_QUIRK_FILE}" <<'EOF'
# HP LaserJet P1005 (03f0:3d17) — host-based, unidirectional over USB.
# Without this the CUPS usb backend waits ~7s (WAIT_EOF_DELAY) for a
# back-channel the printer never sends, stalling every job / the iOS spinner.
0x03f0 0x3d17 unidir
EOF
  echo "Wrote USB unidir quirk: ${USB_QUIRK_FILE}"
}

configure_cups() {
  mkdir -p "${CUPS_DROPIN_DIR}"

  cat > "${CUPS_DROPIN_FILE}" <<'EOF'
# LAN-facing CUPS settings for AirPrint on a Raspberry Pi.
Port 631
Browsing Yes
BrowseLocalProtocols dnssd
DefaultShared Yes
WebInterface Yes

<Location />
  Order allow,deny
  Allow @LOCAL
</Location>

<Location /admin>
  Order allow,deny
  Allow @LOCAL
</Location>

<Location /admin/conf>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow @LOCAL
</Location>
EOF

  cupsctl --remote-admin --remote-any --share-printers >/dev/null
}

suggest_lan_interface() {
  local iface_path

  for iface_path in /sys/class/net/enx* /sys/class/net/eth*; do
    if [[ -e "${iface_path}" ]]; then
      basename "${iface_path}"
      return
    fi
  done
}

configure_avahi() {
  if [[ -z "${AVAHI_INTERFACE}" ]]; then
    local suggested_interface=""

    suggested_interface="$(suggest_lan_interface || true)"
    echo "AVAHI_INTERFACE not set; Avahi advertises on all interfaces."
    echo "On a multi-homed Pi (Ethernet HAT + Wi-Fi) this can make iOS AirPrint"
    echo "drop the printer. To pin it to the wired NIC, rerun with e.g.:"
    if [[ -n "${suggested_interface}" ]]; then
      echo "  sudo AVAHI_INTERFACE=${suggested_interface} ./install-airprint-p1005.sh"
    else
      echo "  sudo AVAHI_INTERFACE=<wired-interface> ./install-airprint-p1005.sh"
    fi
    return
  fi

  if [[ ! -e "/sys/class/net/${AVAHI_INTERFACE}" ]]; then
    echo "AVAHI_INTERFACE=${AVAHI_INTERFACE} does not exist; skipping Avahi restriction" >&2
    return
  fi

  if [[ ! -f "${AVAHI_CONF}" ]]; then
    echo "${AVAHI_CONF} not found; skipping Avahi restriction" >&2
    return
  fi

  cp -n "${AVAHI_CONF}" "${AVAHI_CONF}.bak" || true

  if grep -qE '^[#[:space:]]*allow-interfaces=' "${AVAHI_CONF}"; then
    sed -i "s|^[#[:space:]]*allow-interfaces=.*|allow-interfaces=${AVAHI_INTERFACE}|" "${AVAHI_CONF}"
  else
    sed -i "/^\[server\]/a allow-interfaces=${AVAHI_INTERFACE}" "${AVAHI_CONF}"
  fi

  # IPv6 + IPv4 dual advertising is another source of iOS selection flapping.
  sed -i 's|^[#[:space:]]*use-ipv6=.*|use-ipv6=no|' "${AVAHI_CONF}"

  echo "Restricted Avahi to ${AVAHI_INTERFACE} (IPv4 only)"
}

is_ufw_active() {
  ufw status 2>/dev/null | head -n 1 | grep -q "Status: active"
}

ensure_ufw_rule() {
  local rule="$1"
  local comment="$2"

  if ufw status numbered 2>/dev/null | grep -Fq "${rule}"; then
    echo "ufw rule already exists: ${rule}"
    return
  fi

  ufw allow "${rule}" comment "${comment}"
}

configure_firewall() {
  if ! command -v ufw >/dev/null 2>&1; then
    echo "ufw is not installed; skipping firewall rules"
    return
  fi

  if ! is_ufw_active; then
    echo "ufw is installed but inactive; not changing firewall state"
    return
  fi

  ensure_ufw_rule "631/tcp" "CUPS IPP / AirPrint"
  ensure_ufw_rule "5353/udp" "mDNS / Bonjour"
}

restart_services() {
  systemctl enable cups avahi-daemon
  if systemctl is-active --quiet cups; then
    systemctl reload-or-restart cups
  else
    systemctl start cups
  fi

  # A reload does not re-read allow-interfaces/use-ipv6; restart instead.
  systemctl restart avahi-daemon
}

find_printer_model() {
  if [[ "${PRINTER_MODEL}" != "auto" ]]; then
    echo "${PRINTER_MODEL}"
    return
  fi

  # Prefer the foo2xqx entry for the P1005.
  lpinfo -m 2>/dev/null | awk 'tolower($0) ~ /p1005/ && tolower($0) ~ /foo2xqx/ { print $1; exit }'
}

find_printer_ppd() {
  if [[ "${PRINTER_PPD}" != "auto" ]]; then
    echo "${PRINTER_PPD}"
    return
  fi

  find /opt /usr/share/ppd /usr/share/cups/model \
    -type f \
    \( -iname '*p1005*.ppd' -o -iname '*p1005*.ppd.gz' \) \
    2>/dev/null | head -n 1
}

find_usb_uri() {
  lpinfo -v 2>/dev/null \
    | awk '/usb:\/\// && (/HP/ || /Hewlett/ || /LaserJet/ || /P1005/) { print $2; exit }'
}

find_existing_queue_by_uri() {
  local target_uri="$1"

  lpstat -v 2>/dev/null | awk -v target="${target_uri}" '
    $0 ~ /^device for / {
      queue=$3
      sub(/:$/, "", queue)
      uri=$4
      if (uri == target) {
        print queue
        exit
      }
    }
  '
}

delete_conflicting_queue() {
  local target_uri="$1"
  local existing_uri=""

  if ! lpstat -p "${QUEUE_NAME}" >/dev/null 2>&1; then
    return
  fi

  existing_uri="$(lpstat -v "${QUEUE_NAME}" 2>/dev/null | awk '{print $4}')"
  if [[ "${existing_uri}" == "${target_uri}" ]]; then
    echo "Printer queue ${QUEUE_NAME} already points to ${target_uri}"
    return
  fi

  echo "Printer queue ${QUEUE_NAME} exists but points to ${existing_uri}"
  echo "Recreating it for ${target_uri}"
  cancel -a "${QUEUE_NAME}" >/dev/null 2>&1 || true
  lpadmin -x "${QUEUE_NAME}"
}

reuse_existing_queue_name() {
  local target_uri="$1"
  local existing_queue=""

  existing_queue="$(find_existing_queue_by_uri "${target_uri}" || true)"
  if [[ -z "${existing_queue}" || "${existing_queue}" == "${QUEUE_NAME}" ]]; then
    return
  fi

  echo "A queue for ${target_uri} already exists: ${existing_queue}"
  echo "Reusing it by renaming to ${QUEUE_NAME}"
  cancel -a "${existing_queue}" >/dev/null 2>&1 || true
  lpadmin -x "${existing_queue}"
}

configure_printer_queue() {
  local printer_uri=""
  local printer_model=""
  local printer_ppd=""

  maybe_prompt_location
  printer_uri="$(detect_target_uri)"
  printer_model="$(find_printer_model || true)"
  printer_ppd="$(find_printer_ppd || true)"

  if [[ -z "${printer_uri}" ]]; then
    echo "Could not find the P1005 over USB."
    echo "Make sure it is connected and powered on, then check:"
    echo "  lpinfo -v | grep -i usb"
    echo "Or pass it explicitly:"
    echo "  sudo PRINTER_URI='usb://HP/LaserJet%20P1005' ./install-airprint-p1005.sh"
    return
  fi

  if [[ -z "${printer_model}" && -z "${printer_ppd}" ]]; then
    echo "The foo2zjs P1005 driver/PPD was not detected."
    echo "Confirm printer-driver-foo2zjs is installed, then check:"
    echo "  lpinfo -m | grep -i p1005"
    return
  fi

  reuse_existing_queue_name "${printer_uri}"
  delete_conflicting_queue "${printer_uri}"

  if [[ -n "${printer_model}" ]]; then
    lpadmin \
      -p "${QUEUE_NAME}" \
      -E \
      -v "${printer_uri}" \
      -m "${printer_model}" \
      -D "${PRINTER_NAME}" \
      -L "${PRINTER_LOCATION}" \
      -o "Resolution=${DEFAULT_RESOLUTION}" \
      -o "Density=${DEFAULT_DENSITY}" \
      -o "PageSize=${DEFAULT_PAGE_SIZE}" \
      -o "Duplex=${DEFAULT_DUPLEX}" \
      -o sides=one-sided \
      -o printer-is-shared=true
  else
    lpadmin \
      -p "${QUEUE_NAME}" \
      -E \
      -v "${printer_uri}" \
      -P "${printer_ppd}" \
      -D "${PRINTER_NAME}" \
      -L "${PRINTER_LOCATION}" \
      -o "Resolution=${DEFAULT_RESOLUTION}" \
      -o "Density=${DEFAULT_DENSITY}" \
      -o "PageSize=${DEFAULT_PAGE_SIZE}" \
      -o "Duplex=${DEFAULT_DUPLEX}" \
      -o sides=one-sided \
      -o printer-is-shared=true
  fi

  cupsenable "${QUEUE_NAME}"
  cupsaccept "${QUEUE_NAME}"
  lpadmin -d "${QUEUE_NAME}"

  echo "Configured and shared printer queue: ${QUEUE_NAME}"
  echo "Display name: ${PRINTER_NAME}"
  if [[ -n "${PRINTER_LOCATION}" ]]; then
    echo "Location: ${PRINTER_LOCATION}"
  fi
  echo "Default resolution: ${DEFAULT_RESOLUTION}"
  echo "Default density: ${DEFAULT_DENSITY}"
  echo "Default page size: ${DEFAULT_PAGE_SIZE}"
  echo "Default duplex: ${DEFAULT_DUPLEX}"
  echo "Device URI: ${printer_uri}"
}

disable_duplex_advertisement() {
  if [[ "${DISABLE_DUPLEX_ADVERTISEMENT}" != "1" ]]; then
    echo "Leaving PPD duplex choices advertised"
    return
  fi

  local ppd="/etc/cups/ppd/${QUEUE_NAME}.ppd"
  local tmp=""
  local mode=""
  local owner=""
  local group=""

  if [[ ! -f "${ppd}" ]]; then
    echo "PPD not found yet; skipping duplex advertisement removal: ${ppd}"
    return
  fi

  if ! grep -q '^\*OpenUI \*Duplex/' "${ppd}"; then
    echo "Duplex choices are already absent from ${ppd}"
    return
  fi

  cp -n "${ppd}" "${ppd}.with-duplex.bak" || true

  tmp="$(mktemp)"
  awk '
    /^\*OpenUI \*Duplex\// { skip=1; next }
    skip && /^\*CloseUI: \*Duplex/ { skip=0; next }
    !skip { print }
  ' "${ppd}" > "${tmp}"

  mode="$(stat -c %a "${ppd}")"
  owner="$(stat -c %u "${ppd}")"
  group="$(stat -c %g "${ppd}")"
  install -o "${owner}" -g "${group}" -m "${mode}" "${tmp}" "${ppd}"
  rm -f "${tmp}"

  systemctl reload-or-restart cups
  echo "Removed P1005 Duplex choices from ${ppd}; backup: ${ppd}.with-duplex.bak"
}

detect_target_uri() {
  if [[ "${PRINTER_URI}" != "auto" ]]; then
    echo "${PRINTER_URI}"
    return
  fi

  find_usb_uri || true
}

verify_state() {
  local status=0

  if ! systemctl is-enabled cups >/dev/null 2>&1; then
    echo "Verification failed: cups is not enabled"
    status=1
  fi

  if ! systemctl is-enabled avahi-daemon >/dev/null 2>&1; then
    echo "Verification failed: avahi-daemon is not enabled"
    status=1
  fi

  if ! systemctl is-active --quiet cups; then
    echo "Verification failed: cups is not active"
    status=1
  fi

  if ! systemctl is-active --quiet avahi-daemon; then
    echo "Verification failed: avahi-daemon is not active"
    status=1
  fi

  if [[ ! -f "${CUPS_DROPIN_FILE}" ]]; then
    echo "Verification failed: ${CUPS_DROPIN_FILE} is missing"
    status=1
  fi

  if [[ -s "${FIRMWARE_DEST}" ]]; then
    echo "Verification: firmware present at ${FIRMWARE_DEST}"
  else
    echo "Verification warning: firmware ${FIRMWARE_DEST} is missing; printing will not work until it is fetched"
  fi

  if ! cupsctl 2>/dev/null | grep -q "_share_printers=1"; then
    echo "Verification warning: CUPS does not report share_printers=1 yet"
  fi

  if lpstat -p "${QUEUE_NAME}" >/dev/null 2>&1; then
    echo "Verification: printer queue ${QUEUE_NAME} exists"
  else
    echo "Verification: printer queue ${QUEUE_NAME} does not exist yet"
    echo "This is acceptable if the printer is not connected yet"
  fi

  return "${status}"
}

print_summary() {
  cat <<EOF

Done.

AirPrint services:
- CUPS: enabled
- Avahi: enabled

Printer:
- Queue name: ${QUEUE_NAME}
- Display name: ${PRINTER_NAME}
- Location: ${PRINTER_LOCATION:-<not set>}
- Connection: USB (host-based, foo2zjs/foo2xqx)
- Default resolution: ${DEFAULT_RESOLUTION}
- Default density: ${DEFAULT_DENSITY}
- Default page size: ${DEFAULT_PAGE_SIZE}
- Default duplex: ${DEFAULT_DUPLEX}
- Duplex advertisement: $( [[ "${DISABLE_DUPLEX_ADVERTISEMENT}" == "1" ]] && echo "disabled" || echo "left as PPD" )
- Firmware: ${FIRMWARE_DEST} $( [[ -s "${FIRMWARE_DEST}" ]] && echo "(present)" || echo "(MISSING)" )
- Firmware autoloader: ${FIRMWARE_UDEV_RULE}

Network:
- The Pi reaches the LAN over its Ethernet HAT.
- Fix the IP as a DHCP reservation on the router.
- CUPS UI: http://$(hostname).local:631/  (or http://$(hostname -I 2>/dev/null | awk '{print $1}'):631/ )

Useful checks:
- Printers: lpstat -t
- USB devices: lpinfo -v | grep -i usb
- P1005 driver: lpinfo -m | grep -i p1005
- AirPrint advertisement: avahi-browse -rt _ipp._tcp
- Test print: lp -d ${QUEUE_NAME} /usr/share/cups/data/testprint

If a job is "completed" but nothing prints, the firmware was not uploaded.
Re-fetch it: cd /tmp && /usr/share/foo2zjs/getweb P1005 && sudo cp sihpP1005.dl ${FIRMWARE_DEST}
EOF
}

require_cmd systemctl

run_step "Installing AirPrint + foo2zjs packages" install_base_packages

require_cmd lpinfo
require_cmd lpadmin
require_cmd lpstat

run_step "Adding admin user to lpadmin" ensure_admin_user
run_step "Checking for active print jobs" ensure_no_active_jobs
run_step "Fetching P1005 firmware blob" install_firmware
run_step "Installing the firmware autoloader (udev)" install_firmware_autoloader
run_step "Writing USB unidir quirk (avoids 7s back-channel stall)" configure_usb_quirk
run_step "Configuring CUPS" configure_cups
run_step "Restricting Avahi to one interface (multi-homed Pi)" configure_avahi
run_step "Opening firewall ports" configure_firewall
run_step "Enabling and restarting services" restart_services
run_step "Uploading firmware to the printer if connected" load_firmware_now
run_step "Creating or updating the printer queue" configure_printer_queue
run_step "Disabling P1005 duplex advertisement" disable_duplex_advertisement
run_step "Installing the CUPS watchdog" install_cups_watchdog

# verify_state is informational: never let a failed/transient check abort the run
# before the summary is printed (the queue is already created by this point).
log "Verifying resulting state"
verify_state || echo "(verification reported issues above; review them, the setup may still be usable)"

print_summary
