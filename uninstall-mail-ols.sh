#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ------------------------------------------
# Uninstall Postfix + Dovecot + OpenDKIM mail stack
# Ubuntu 22.04
# OpenLiteSpeed safe (does not touch OLS)
#
# Usage:
#   sudo bash uninstall-mail-ols.sh domain.com
#
# Optional FULL wipe (dangerous):
#   sudo WIPE_ALL=1 bash uninstall-mail-ols.sh domain.com
#
# What it removes:
# - Postfix/Dovecot/OpenDKIM packages + configs (purge)
# - vmail mailboxes for DOMAIN (or all if WIPE_ALL=1)
# - OpenDKIM keys for DOMAIN (or all if WIPE_ALL=1)
# - Let's Encrypt certificate for DOMAIN
# - Cert renewal hook that reloads postfix/dovecot
#
# What it DOES NOT remove:
# - OpenLiteSpeed
# - UFW rules / hardening script changes
# - Fail2ban global config (only packages if you choose)
# ------------------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0 <domain>"
  exit 1
fi

DOMAIN="${1:-}"
if [[ -z "$DOMAIN" ]]; then
  echo "Usage: sudo bash $0 <domain>"
  exit 1
fi

MAIL_HOST="${DOMAIN}"
VMAIL_HOME="/var/mail/vhosts"
PASSWD_FILE="/etc/dovecot/passwd"
WIPE_ALL="${WIPE_ALL:-0}"

echo "========================================"
echo " Uninstall mail stack for: ${DOMAIN}"
echo " Mail host: ${MAIL_HOST}"
echo " WIPE_ALL:  ${WIPE_ALL}"
echo "========================================"
echo

stop_services() {
  echo "[*] Stopping services (if running)..."
  systemctl stop postfix 2>/dev/null || true
  systemctl stop dovecot 2>/dev/null || true
  systemctl stop opendkim 2>/dev/null || true
}

remove_domain_data() {
  echo "[*] Removing domain mailbox + DKIM keys for: ${DOMAIN}"

  # Remove mailbox data
  if [[ -d "${VMAIL_HOME}/${DOMAIN}" ]]; then
    rm -rf "${VMAIL_HOME:?}/${DOMAIN}"
    echo "    ✔ Removed mailbox directory: ${VMAIL_HOME}/${DOMAIN}"
  else
    echo "    - No mailbox directory found for ${DOMAIN}"
  fi

  # Remove DKIM keys
  if [[ -d "/etc/opendkim/keys/${DOMAIN}" ]]; then
    rm -rf "/etc/opendkim/keys/${DOMAIN}"
    echo "    ✔ Removed DKIM keys: /etc/opendkim/keys/${DOMAIN}"
  else
    echo "    - No DKIM keys directory found for ${DOMAIN}"
  fi

  # Remove any password file created by installer
  if [[ -f "/root/${DOMAIN}_warmup_password.txt" ]]; then
    rm -f "/root/${DOMAIN}_warmup_password.txt"
    echo "    ✔ Removed password file: /root/${DOMAIN}_warmup_password.txt"
  fi

  # Clean dovecot passwd entry lines for this domain
  if [[ -f "${PASSWD_FILE}" ]]; then
    cp -a "${PASSWD_FILE}" "${PASSWD_FILE}.bak.$(date +%s)" || true
    # Remove any user ending with @DOMAIN
    grep -v "@${DOMAIN}:" "${PASSWD_FILE}" > "${PASSWD_FILE}.tmp" || true
    mv "${PASSWD_FILE}.tmp" "${PASSWD_FILE}"
    echo "    ✔ Cleaned Dovecot passwd entries for @${DOMAIN}"
  fi

  # Clean postfix vmailbox map entries for this domain
  if [[ -f "/etc/postfix/vmailbox" ]]; then
    cp -a "/etc/postfix/vmailbox" "/etc/postfix/vmailbox.bak.$(date +%s)" || true
    grep -v "@${DOMAIN}[[:space:]]" /etc/postfix/vmailbox > /etc/postfix/vmailbox.tmp || true
    mv /etc/postfix/vmailbox.tmp /etc/postfix/vmailbox
    postmap /etc/postfix/vmailbox 2>/dev/null || true
    echo "    ✔ Cleaned Postfix vmailbox entries for @${DOMAIN}"
  fi
}

wipe_all_mail_data() {
  echo "[!] WIPE_ALL=1 enabled. Removing ALL mail data on this VPS..."
  echo "[!] This deletes: ${VMAIL_HOME}, /etc/opendkim/keys, and passwd files."

  rm -rf "${VMAIL_HOME:?}" || true
  rm -rf "/etc/opendkim/keys" || true

  if [[ -f "${PASSWD_FILE}" ]]; then
    rm -f "${PASSWD_FILE}" || true
  fi

  echo "    ✔ All mail data removed"
}

remove_cert() {
  echo "[*] Removing Let's Encrypt cert for: ${MAIL_HOST}"

  if certbot certificates 2>/dev/null | grep -q "Certificate Name: ${MAIL_HOST}"; then
    certbot delete --non-interactive --cert-name "${MAIL_HOST}" || true
    echo "    ✔ Certificate deleted for ${MAIL_HOST}"
  else
    echo "    - No cert found for ${MAIL_HOST}"
  fi
}

remove_cert_hook() {
  echo "[*] Removing cert renewal hook (reload-mail.sh)..."
  if [[ -f "/etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh" ]]; then
    rm -f "/etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh"
    echo "    ✔ Removed renewal hook"
  else
    echo "    - No renewal hook found"
  fi
}

purge_packages() {
  echo "[*] Purging Postfix + Dovecot + OpenDKIM packages..."
  export DEBIAN_FRONTEND=noninteractive

  # Purge packages
  apt-get purge -y postfix\* dovecot\* opendkim\* || true
  apt-get autoremove -y || true

  # Remove leftover configs
  rm -rf /etc/postfix /etc/dovecot /etc/opendkim /opendkim || true
  rm -rf /var/spool/postfix || true

  echo "    ✔ Packages purged + configs removed"

  rm -rf /var/lib/dovecot || true
  rm -rf /etc/dovecot/ || true
}

cleanup_hostname_note() {
  echo
  echo "[*] Note:"
  echo "    Hostname was set to ${MAIL_HOST} by installer."
  echo "    If this VPS should use another hostname, change it manually:"
  echo "      hostnamectl set-hostname YOUR_HOSTNAME"
  echo
}

main() {
  stop_services

  if [[ "${WIPE_ALL}" == "1" ]]; then
    wipe_all_mail_data
  else
    remove_domain_data
  fi

  purge_packages
  cleanup_hostname_note

  echo "✅ Uninstall complete."
}

main
