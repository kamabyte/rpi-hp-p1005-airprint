#!/usr/bin/env bash
set -euo pipefail

# Prepares a freshly flashed Raspberry Pi (Ubuntu Server 22.04) before the
# AirPrint install:
#
# 1. sets a unique hostname and makes it survive reboots. Ubuntu's cloud-init
#    ships with preserve_hostname: false and resets the name on every boot. Two
#    AirPrint Pis that share a hostname fight over <name>.local, and iOS then
#    routes jobs to the wrong printer.
# 2. brings up a USB Ethernet HAT (enx<mac>). cloud-init's netplan only knows
#    about eth0, so the HAT stays DOWN. Ethernet gets route-metric 100 and is
#    preferred; Wi-Fi stays up as a fallback for SSH.
#
# Run it BEFORE install-airprint-p1005.sh: CUPS generates its TLS certificate
# for the current hostname, and a cert for the wrong name breaks AirPrint
# over ipps on macOS.

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root: sudo bash $0"
  exit 1
fi

NEW_HOSTNAME="${NEW_HOSTNAME:-printserver-hp}"
# Interface name of the Ethernet HAT. "auto" picks the first enx*/eth* device.
# Set to "none" to leave networking untouched.
ETH_INTERFACE="${ETH_INTERFACE:-auto}"
NETPLAN_FILE="/etc/netplan/99-ethernet.yaml"
CLOUD_INIT_HOSTNAME_FILE="/etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg"

log() {
  echo
  echo "==> $1"
}

preserve_hostname() {
  if [[ ! -d /etc/cloud/cloud.cfg.d ]]; then
    echo "cloud-init is not installed; nothing to pin"
    return
  fi

  cat > "${CLOUD_INIT_HOSTNAME_FILE}" <<'EOF'
# Keep the hostname set via hostnamectl; do not let cloud-init reset it on boot.
preserve_hostname: true
EOF
  echo "Wrote ${CLOUD_INIT_HOSTNAME_FILE}"
}

set_hostname() {
  local old_hostname=""

  old_hostname="$(hostname)"
  if [[ "${old_hostname}" == "${NEW_HOSTNAME}" ]]; then
    echo "Hostname is already ${NEW_HOSTNAME}"
    return
  fi

  hostnamectl set-hostname "${NEW_HOSTNAME}"

  if grep -q '^127\.0\.1\.1' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${NEW_HOSTNAME}/" /etc/hosts
  else
    printf '127.0.1.1\t%s\n' "${NEW_HOSTNAME}" >> /etc/hosts
  fi

  echo "Hostname: ${old_hostname} -> ${NEW_HOSTNAME}"

  # CUPS keeps a self-signed cert per hostname. A stale one makes macOS refuse
  # the printer over ipps, so drop it and let cupsd generate a new one.
  if [[ -d /etc/cups/ssl ]]; then
    rm -f "/etc/cups/ssl/${old_hostname}.crt" "/etc/cups/ssl/${old_hostname}.key"
  fi
  if systemctl is-active --quiet cups 2>/dev/null; then
    systemctl restart cups
  fi
  if systemctl is-active --quiet avahi-daemon 2>/dev/null; then
    systemctl restart avahi-daemon
  fi
}

detect_eth_interface() {
  local iface_path

  for iface_path in /sys/class/net/enx* /sys/class/net/eth*; do
    if [[ -e "${iface_path}" ]]; then
      basename "${iface_path}"
      return
    fi
  done
}

configure_ethernet() {
  local iface="${ETH_INTERFACE}"

  if [[ "${iface}" == "none" ]]; then
    echo "ETH_INTERFACE=none; leaving networking untouched"
    return
  fi

  if ! command -v netplan >/dev/null 2>&1; then
    echo "netplan not found; configure the Ethernet interface manually"
    return
  fi

  if [[ "${iface}" == "auto" ]]; then
    iface="$(detect_eth_interface || true)"
  fi

  if [[ -z "${iface}" || ! -e "/sys/class/net/${iface}" ]]; then
    echo "No Ethernet interface found (looked for enx*/eth*); skipping netplan"
    return
  fi

  cat > "${NETPLAN_FILE}" <<EOF
# Ethernet HAT: preferred uplink. Fix the IP with a DHCP reservation on the
# router for this interface's MAC address (not the Wi-Fi one).
network:
  version: 2
  ethernets:
    ${iface}:
      dhcp4: true
      optional: true
      dhcp4-overrides:
        route-metric: 100
EOF
  chmod 600 "${NETPLAN_FILE}"

  netplan generate
  netplan apply

  echo "Configured ${iface} via ${NETPLAN_FILE}"
  echo "MAC address for the DHCP reservation: $(cat "/sys/class/net/${iface}/address")"
}

log "Pinning the hostname against cloud-init"
preserve_hostname
log "Setting the hostname"
set_hostname
log "Configuring the Ethernet HAT"
configure_ethernet

cat <<EOF

Done. Hostname: $(hostname), mDNS name: $(hostname).local

Next:
  sudo AVAHI_INTERFACE=<ethernet-interface> ./install-airprint-p1005.sh
EOF
