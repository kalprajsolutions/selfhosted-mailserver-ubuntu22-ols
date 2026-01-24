#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ------------------------------------------
# Postfix + Dovecot + OpenDKIM (No MySQL)
# Ubuntu 22.04
# OpenLiteSpeed compatible TLS using existing certs or certbot --webroot
#
# Usage:
#   sudo bash deploy-mail-ols.sh subdomain.example.com
#
# Uses EXACT provided domain for EVERYTHING:
#   Hostname: DOMAIN
#   Email: warmup@DOMAIN
#
# Environment Variables (optional):
#   WEBROOT    - Path to webroot for ACME challenges (default: /usr/local/lsws/Example/html)
#   SSL_CERT   - Path to existing SSL certificate (fullchain)
#   SSL_KEY    - Path to existing SSL private key
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

# EXACT domain is used as mail host
MAIL_HOST="${DOMAIN}"

MAILBOX_LOCAL="warmup"
MAIL_USER="${MAILBOX_LOCAL}@${DOMAIN}"

VMAIL_USER="vmail"
VMAIL_UID=5000
VMAIL_GID=5000
VMAIL_HOME="/var/mail/vhosts"

PASSWD_FILE="/etc/dovecot/passwd"
DKIM_SELECTOR="s1"

# OpenLiteSpeed webroot (common defaults)
# If you run multiple vhosts, set this to the active docroot serving DOMAIN.
WEBROOT="${WEBROOT:-/usr/local/lsws/Example/html}"

# SSL Certificate paths (can be overridden via environment)
SSL_CERT="${SSL_CERT:-}"
SSL_KEY="${SSL_KEY:-}"

# Detect public IPv4
SERVER_IP="$(curl -4 -s https://api.ipify.org || true)"

gen_password() {
  openssl rand -base64 24 | tr -d '\n'
}

ensure_hostname() {
  echo "[*] Setting hostname to: ${MAIL_HOST}"

  # Basic validation (must contain at least one dot)
  if [[ "${MAIL_HOST}" != *.* ]]; then
    echo "[!] Invalid domain/hostname: ${MAIL_HOST}"
    echo "    Example: mail.example.com"
    exit 1
  fi

  hostnamectl set-hostname "${MAIL_HOST}"

  # Remove any existing 127.0.1.1 line
  sed -i '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts

  # Ensure file ends with exactly ONE newline before appending
  tail -c1 /etc/hosts | read -r _ || echo >> /etc/hosts
  tail -c1 /etc/hosts | read -r _ || echo >> /etc/hosts

  # Append new entry on its own line
  echo "127.0.1.1 ${MAIL_HOST} ${MAIL_HOST%%.*}" >> /etc/hosts
}

install_packages() {
  echo "[*] Installing packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y

  apt-get install -y \
    postfix postfix-pcre \
    dovecot-core dovecot-imapd dovecot-lmtpd \
    opendkim opendkim-tools \
    certbot \
    ca-certificates \
    curl \
    openssl
}

create_vmail_user() {
  echo "[*] Creating vmail user/group..."
  if ! getent group "${VMAIL_USER}" >/dev/null; then
    groupadd -g "${VMAIL_GID}" "${VMAIL_USER}"
  fi
  if ! id -u "${VMAIL_USER}" >/dev/null 2>&1; then
    useradd -g "${VMAIL_USER}" -u "${VMAIL_UID}" -d "${VMAIL_HOME}" -m -s /usr/sbin/nologin "${VMAIL_USER}"
  fi

  mkdir -p "${VMAIL_HOME}/${DOMAIN}"
  chown -R "${VMAIL_USER}:${VMAIL_USER}" "${VMAIL_HOME}"

  mkdir -p "${VMAIL_HOME}/${DOMAIN}/${MAILBOX_LOCAL}/Maildir/{cur,new,tmp}"
  chown -R "${VMAIL_USER}:${VMAIL_USER}" "${VMAIL_HOME}/${DOMAIN}/${MAILBOX_LOCAL}"
}

create_warmup_user() {
  echo "[*] Creating system user 'warmup' and adding to /etc/aliases..."
  if ! id -u warmup >/dev/null 2>&1; then
    useradd -m -s /bin/bash warmup
  fi

  # Add to /etc/aliases if not already present
  if ! grep -q "^warmup:" /etc/aliases; then
    echo "warmup: ${MAIL_USER}" >> /etc/aliases
  fi

  # Rebuild aliases database
  newaliases
}

update_openssl_config() {
  echo "[*] Updating /etc/ssl/openssl.cnf to comment [openssl_init] providers..."
  if [[ -f /etc/ssl/openssl.cnf ]]; then
    sed -i '/^\[openssl_init\]/,/^\[/ { s/^providers/#providers/; }' /etc/ssl/openssl.cnf
  fi
}

configure_ufw() {
  echo "[*] Configuring UFW to allow mail server ports..."
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 25/tcp comment 'SMTP'
    ufw allow 587/tcp comment 'SMTP Submission'
    ufw allow 465/tcp comment 'SMTPS'
    ufw allow 143/tcp comment 'IMAP'
    ufw allow 993/tcp comment 'IMAPS'
    echo "[+] UFW rules added for mail ports"

    ufw reload
  else
    echo "[!] UFW not found, skipping firewall configuration"
  fi
}

ensure_webroot() {
  echo "[*] Checking webroot: ${WEBROOT}"
  if [[ ! -d "${WEBROOT}" ]]; then
    echo "[!] WEBROOT does not exist: ${WEBROOT}"
    echo "    Fix: export WEBROOT=/path/to/your/domain/docroot"
    exit 1
  fi

  mkdir -p "${WEBROOT}/.well-known/acme-challenge"
  echo "ok" > "${WEBROOT}/.well-known/acme-challenge/ping.txt"
}

# Check for existing SSL certificates (OpenLiteSpeed or Let's Encrypt)
find_existing_ssl_certs() {
  echo "[*] Checking for existing SSL certificates..."
  
  # If user provided SSL paths via environment, use those
  if [[ -n "${SSL_CERT}" ]] && [[ -n "${SSL_KEY}" ]]; then
    if [[ -f "${SSL_CERT}" ]] && [[ -f "${SSL_KEY}" ]]; then
      echo "[+] Using user-provided SSL certificates:"
      echo "    Cert: ${SSL_CERT}"
      echo "    Key:  ${SSL_KEY}"
      return 0
    else
      echo "[!] User-provided SSL paths not found, will search for existing certs..."
    fi
  fi
  
  # Check for existing Let's Encrypt certificate for this domain
  local LE_CERT="/etc/letsencrypt/live/${MAIL_HOST}/fullchain.pem"
  local LE_KEY="/etc/letsencrypt/live/${MAIL_HOST}/privkey.pem"
  
  if [[ -f "${LE_CERT}" ]] && [[ -f "${LE_KEY}" ]]; then
    echo "[+] Found existing Let's Encrypt certificate for ${MAIL_HOST}"
    SSL_CERT="${LE_CERT}"
    SSL_KEY="${LE_KEY}"
    return 0
  fi
  
  # Check common OpenLiteSpeed certificate locations
  local OLS_PATHS=(
    "/usr/local/lsws/conf/cert/${DOMAIN}"
    "/usr/local/lsws/conf/${DOMAIN}"
    "/usr/local/lsws/ssl/${DOMAIN}"
    "/etc/letsencrypt/live/${DOMAIN}"
  )
  
  for OLS_PATH in "${OLS_PATHS[@]}"; do
    # Check for fullchain.pem / privkey.pem (Let's Encrypt style)
    if [[ -f "${OLS_PATH}/fullchain.pem" ]] && [[ -f "${OLS_PATH}/privkey.pem" ]]; then
      echo "[+] Found SSL certificates at: ${OLS_PATH}"
      SSL_CERT="${OLS_PATH}/fullchain.pem"
      SSL_KEY="${OLS_PATH}/privkey.pem"
      return 0
    fi
    
    # Check for cert.pem / key.pem
    if [[ -f "${OLS_PATH}/cert.pem" ]] && [[ -f "${OLS_PATH}/key.pem" ]]; then
      echo "[+] Found SSL certificates at: ${OLS_PATH}"
      SSL_CERT="${OLS_PATH}/cert.pem"
      SSL_KEY="${OLS_PATH}/key.pem"
      return 0
    fi
    
    # Check for .crt / .key files
    if [[ -f "${OLS_PATH}/${DOMAIN}.crt" ]] && [[ -f "${OLS_PATH}/${DOMAIN}.key" ]]; then
      echo "[+] Found SSL certificates at: ${OLS_PATH}"
      SSL_CERT="${OLS_PATH}/${DOMAIN}.crt"
      SSL_KEY="${OLS_PATH}/${DOMAIN}.key"
      return 0
    fi
  done
  
  # Check default OLS example cert location (for testing)
  if [[ -f "/usr/local/lsws/admin/conf/webadmin.crt" ]] && [[ -f "/usr/local/lsws/admin/conf/webadmin.key" ]]; then
    echo "[!] Only found OLS admin certificate - not suitable for mail"
  fi
  
  echo "[-] No existing SSL certificates found for ${MAIL_HOST}"
  return 1
}

setup_tls_cert_webroot() {
  echo "[*] Setting up TLS certificates..."
  
  # First, try to find existing certificates
  if find_existing_ssl_certs; then
    echo "[+] Using existing SSL certificates"
    return 0
  fi
  
  echo "[*] No existing certificates found, requesting new certificate via certbot..."
  ensure_webroot

  certbot certonly --webroot --non-interactive --agree-tos \
    -m "postmaster@${DOMAIN}" \
    -w "${WEBROOT}" \
    -d "${MAIL_HOST}" || {
      echo "[!] Certbot failed."
      echo "    Confirm these:"
      echo "    1) A record of ${MAIL_HOST} -> ${SERVER_IP}"
      echo "    2) OpenLiteSpeed is serving ${WEBROOT} for ${MAIL_HOST}"
      echo "    3) http://${MAIL_HOST}/.well-known/acme-challenge/ping.txt loads in browser"
      exit 1
    }
  
  # Set the certificate paths after successful certbot
  SSL_CERT="/etc/letsencrypt/live/${MAIL_HOST}/fullchain.pem"
  SSL_KEY="/etc/letsencrypt/live/${MAIL_HOST}/privkey.pem"
}

setup_postfix() {
  echo "[*] Configuring Postfix..."

  postconf -e "myhostname = ${MAIL_HOST}"
  postconf -e "mydomain = ${DOMAIN}"
  postconf -e "myorigin = \$mydomain"
  postconf -e "inet_interfaces = all"
  postconf -e "inet_protocols = ipv4"
  
  # CRITICAL FIX: Domain must NOT be in mydestination when using virtual_mailbox_domains
  # Otherwise mail delivery will fail with "User unknown in local recipient table"
  postconf -e "mydestination = localhost"
  
  postconf -e "relayhost ="
  postconf -e "mynetworks = 127.0.0.0/8"
  postconf -e "message_size_limit = 31457280"
  postconf -e "append_dot_mydomain = no"
  postconf -e "compatibility_level = 2"

  # Virtual mailbox domain = EXACT DOMAIN
  postconf -e "virtual_mailbox_domains = ${DOMAIN}"
  postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"
  postconf -e "virtual_mailbox_base = ${VMAIL_HOME}"
  postconf -e "virtual_mailbox_maps = hash:/etc/postfix/vmailbox"
  postconf -e "virtual_uid_maps = static:${VMAIL_UID}"
  postconf -e "virtual_gid_maps = static:${VMAIL_GID}"

  # TLS Configuration with modern security settings
  postconf -e "smtpd_tls_cert_file=${SSL_CERT}"
  postconf -e "smtpd_tls_key_file=${SSL_KEY}"
  postconf -e "smtpd_tls_security_level=may"
  postconf -e "smtpd_tls_auth_only=yes"
  postconf -e "smtpd_tls_loglevel=1"
  postconf -e "smtpd_sasl_authenticated_header=yes"
  postconf -e "smtp_tls_security_level=may"
  postconf -e "smtpd_tls_received_header=yes"
  postconf -e "smtpd_tls_session_cache_database=btree:\${data_directory}/smtpd_scache"
  postconf -e "smtp_tls_session_cache_database=btree:\${data_directory}/smtp_scache"
  
  # TLS Protocol restrictions (disable old insecure protocols)
  postconf -e "smtpd_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1"
  postconf -e "smtp_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1"
  postconf -e "smtpd_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1"
  postconf -e "smtp_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1"
  postconf -e "smtpd_tls_ciphers = high"
  postconf -e "smtpd_tls_mandatory_ciphers = high"
  postconf -e "tls_preempt_cipherlist = yes"
  
  # Ensure mydestination is set to localhost to avoid conflicts with virtual_mailbox_domains
  postconf -e "mydestination = localhost"

  # Auth via Dovecot
  postconf -e "smtpd_sasl_type=dovecot"
  postconf -e "smtpd_sasl_path=private/auth"
  postconf -e "smtpd_sasl_auth_enable=yes"
  postconf -e "smtpd_sasl_security_options=noanonymous"
  postconf -e "broken_sasl_auth_clients=yes"
  postconf -e "mailbox_transport=lmtp:unix:private/dovecot-lmtp"

  # No open relay
  postconf -e "smtpd_recipient_restrictions=permit_sasl_authenticated,permit_mynetworks,reject_unauth_destination"
  postconf -e "smtpd_relay_restrictions=permit_sasl_authenticated,permit_mynetworks,reject_unauth_destination"

  # DKIM milter - socket inside Postfix chroot for compatibility
  postconf -e "milter_default_action=accept"
  postconf -e "milter_protocol=6"
  postconf -e "smtpd_milters=unix:/var/spool/postfix/opendkim/opendkim.sock"
  postconf -e "non_smtpd_milters=unix:/var/spool/postfix/opendkim/opendkim.sock"

  # Enable submission ports
  if ! grep -q "^submission" /etc/postfix/master.cf; then
    cat >> /etc/postfix/master.cf <<'EOF'

submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_tls_auth_only=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_recipient_restrictions=permit_mynetworks,permit_sasl_authenticated,reject
  -o smtpd_sasl_type=dovecot
  -o smtpd_sasl_path=private/auth
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING

smtps     inet  n       -       y       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_tls_auth_only=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
EOF
  fi
  
  # Ensure services are enabled and started
  systemctl enable postfix
  systemctl enable dovecot
  systemctl enable opendkim

  # mailbox map
  echo "${MAIL_USER} ${DOMAIN}/${MAILBOX_LOCAL}/" > /etc/postfix/vmailbox
  postmap /etc/postfix/vmailbox

  systemctl enable postfix
}

setup_dovecot() {
  echo "[*] Configuring Dovecot..."

  mkdir -p "${VMAIL_HOME}/${DOMAIN}/${MAILBOX_LOCAL}"
  chown -R "${VMAIL_USER}:${VMAIL_USER}" "${VMAIL_HOME}/${DOMAIN}"

  # CRITICAL FIX: 'imaps' is NOT a valid protocol name in Dovecot
  # Dovecot uses 'imap' and configures SSL separately
  cat > /etc/dovecot/dovecot.conf <<EOF
protocols = imap lmtp
listen = *
!include conf.d/*.conf
EOF

  cat > /etc/dovecot/conf.d/10-mail.conf <<EOF
mail_location = maildir:${VMAIL_HOME}/%d/%n
namespace inbox {
  inbox = yes
}
EOF

  cat > /etc/dovecot/conf.d/10-auth.conf <<'EOF'
disable_plaintext_auth = yes
auth_username_format = %u
auth_mechanisms = plain login
!include auth-passwdfile.conf.ext
EOF

  cat > /etc/dovecot/conf.d/auth-passwdfile.conf.ext <<EOF
passdb {
  driver = passwd-file
  args = scheme=SHA512-CRYPT username_format=%u ${PASSWD_FILE}
}
userdb {
  driver = static
  args = uid=${VMAIL_UID} gid=${VMAIL_GID} home=${VMAIL_HOME}/%d/%n
}
EOF

  # SSL Configuration with proper security settings
  cat > /etc/dovecot/conf.d/10-ssl.conf <<EOF
ssl = required
ssl_min_protocol = TLSv1.2
ssl_prefer_server_ciphers = yes
ssl_cert = <${SSL_CERT}
ssl_key = <${SSL_KEY}
EOF
  
  # Ensure mail_location is set to maildir:${VMAIL_HOME}/%d/%n
  cat > /etc/dovecot/conf.d/10-mail.conf <<EOF
mail_location = maildir:${VMAIL_HOME}/%d/%n/Maildir
namespace inbox {
  inbox = yes
}
EOF

  # CRITICAL FIX: Add proper imap-login service configuration for SSL/TLS
  # This enables IMAPS on port 993 and IMAP with STARTTLS on port 143
  cat > /etc/dovecot/conf.d/10-master.conf <<'EOF'
# IMAP login service - handles both IMAP (143) and IMAPS (993)
service imap-login {
  inet_listener imap {
    port = 143
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
}

# IMAP service (post-login)
service imap {
  # Most of the memory goes to mmap()ing files. You may need to increase this
  # limit if you have huge mailboxes.
}

# LMTP service for mail delivery from Postfix
service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}

# Authentication service for Postfix SASL
service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
EOF

  cat > /etc/dovecot/conf.d/15-mailboxes.conf <<'EOF'
namespace inbox {
  inbox = yes

  mailbox Drafts {
    special_use = \Drafts
    auto = subscribe
  }

  mailbox Junk {
    special_use = \Junk
    auto = subscribe
  }

  mailbox Sent {
    special_use = \Sent
    auto = subscribe
  }

  mailbox Trash {
    special_use = \Trash
    auto = subscribe
  }
}
EOF

  # restart dovecot
  systemctl enable dovecot
}

add_mail_user() {
  echo "[*] Creating mailbox: ${MAIL_USER}"

  local PASS HASH
  PASS="$(gen_password)"
  HASH="$(doveadm pw -s SHA512-CRYPT -p "${PASS}")"

  touch "${PASSWD_FILE}"
  chmod 640 "${PASSWD_FILE}"
  chown root:dovecot "${PASSWD_FILE}" 2>/dev/null || true

  # Replace if exists
  grep -v "^${MAIL_USER}:" "${PASSWD_FILE}" > "${PASSWD_FILE}.tmp" || true
  mv "${PASSWD_FILE}.tmp" "${PASSWD_FILE}"

  echo "${MAIL_USER}:${HASH}:${VMAIL_UID}:${VMAIL_GID}::${VMAIL_HOME}/${DOMAIN}/${MAILBOX_LOCAL}::" >> "${PASSWD_FILE}"

  mkdir -p "${VMAIL_HOME}/${DOMAIN}/${MAILBOX_LOCAL}"/{.Drafts,.Sent,.Trash,.Junk}
  chown -R "${VMAIL_USER}:${VMAIL_USER}" "${VMAIL_HOME}/${DOMAIN}/${MAILBOX_LOCAL}"

  echo "${PASS}" > "/root/${DOMAIN}_${MAILBOX_LOCAL}_password.txt"
  chmod 600 "/root/${DOMAIN}_${MAILBOX_LOCAL}_password.txt"
}

fix_opendkim_runtime() {
  echo "[*] Fixing OpenDKIM runtime permissions..."

  # Create runtime directory for PID
  install -d -o opendkim -g opendkim -m 0755 /run/opendkim
  
  # CRITICAL FIX: Create socket directory inside Postfix chroot
  # This allows Postfix to access the OpenDKIM socket
  install -d -o opendkim -g postfix -m 0750 /var/spool/postfix/opendkim
  
  # Add postfix user to opendkim group for socket access
  usermod -aG opendkim postfix 2>/dev/null || true

  # Ensure PIDFile is correct (Ubuntu expects this)
  if [[ -f /etc/default/opendkim ]]; then
    sed -i 's|^PIDFile=.*|PIDFile=/run/opendkim/opendkim.pid|' /etc/default/opendkim || true
    # Also ensure socket path is set correctly
    sed -i 's|^SOCKET=.*|SOCKET="local:/var/spool/postfix/opendkim/opendkim.sock"|' /etc/default/opendkim || true
  fi

  # Persist runtime dir after reboot
  cat >/etc/tmpfiles.d/opendkim.conf <<'EOF'
d /run/opendkim 0755 opendkim opendkim -
d /var/spool/postfix/opendkim 0750 opendkim postfix -
EOF

  systemd-tmpfiles --create || true
}

setup_opendkim() {
  echo "[*] Configuring OpenDKIM..."

  mkdir -p /etc/opendkim/keys/"${DOMAIN}"
  
  # Create socket directory inside Postfix chroot
  mkdir -p /var/spool/postfix/opendkim
  chown opendkim:postfix /var/spool/postfix/opendkim
  chmod 0750 /var/spool/postfix/opendkim

  chown -R opendkim:opendkim /etc/opendkim

  # CRITICAL FIX: Socket path must be accessible from Postfix chroot
  cat > /etc/opendkim.conf <<EOF
Syslog                  yes
UMask                   002
Canonicalization        relaxed/simple
Mode                    sv
SubDomains              no
AutoRestart             yes
AutoRestartRate         10/1h
OversignHeaders         From
KeyTable                /etc/opendkim/key.table
SigningTable            refile:/etc/opendkim/signing.table
ExternalIgnoreList      /etc/opendkim/trusted.hosts
InternalHosts           /etc/opendkim/trusted.hosts
Socket                  local:/var/spool/postfix/opendkim/opendkim.sock
PidFile                 /run/opendkim/opendkim.pid
EOF
  
  # Ensure runtime permissions for OpenDKIM are correctly set
  install -d -o opendkim -g opendkim -m 0755 /run/opendkim
  install -d -o opendkim -g postfix -m 0750 /var/spool/postfix/opendkim
  usermod -aG opendkim postfix 2>/dev/null || true

  cat > /etc/opendkim/trusted.hosts <<EOF
127.0.0.1
localhost
${DOMAIN}
EOF

  cat > /etc/opendkim/signing.table <<EOF
*@${DOMAIN} ${DKIM_SELECTOR}._domainkey.${DOMAIN}
EOF

  cat > /etc/opendkim/key.table <<EOF
${DKIM_SELECTOR}._domainkey.${DOMAIN} ${DOMAIN}:${DKIM_SELECTOR}:/etc/opendkim/keys/${DOMAIN}/${DKIM_SELECTOR}.private
EOF

  if [[ ! -f "/etc/opendkim/keys/${DOMAIN}/${DKIM_SELECTOR}.private" ]]; then
    opendkim-genkey -b 2048 -d "${DOMAIN}" -s "${DKIM_SELECTOR}" -D "/etc/opendkim/keys/${DOMAIN}"
    chown opendkim:opendkim "/etc/opendkim/keys/${DOMAIN}/${DKIM_SELECTOR}.private"
    chmod 600 "/etc/opendkim/keys/${DOMAIN}/${DKIM_SELECTOR}.private"
  fi

  systemctl enable opendkim
}

fix_opendkim_systemd_pid_issue() {
  echo "[*] Applying OpenDKIM systemd override (no PID file mode)..."

  mkdir -p /etc/systemd/system/opendkim.service.d

  cat >/etc/systemd/system/opendkim.service.d/override.conf <<'EOF'
[Service]
Type=simple
PIDFile=
ExecStart=
ExecStart=/usr/sbin/opendkim -f
EOF

  systemctl daemon-reload
}

enable_cert_renew_hook() {
  echo "[*] Setting up cert renewal hook..."
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy

  cat > /etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh <<'EOF'
#!/usr/bin/env bash
# Reload mail services after certificate renewal
systemctl reload postfix || true
systemctl reload dovecot || true
# OpenDKIM doesn't use TLS certs, but restart for good measure
systemctl restart opendkim || true
EOF
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh
}

restart_services() {
  echo "[*] Restarting services..."
  
  # Ensure socket directory permissions are correct before starting
  chown opendkim:postfix /var/spool/postfix/opendkim 2>/dev/null || true
  chmod 0750 /var/spool/postfix/opendkim 2>/dev/null || true
  
  systemctl restart opendkim
  sleep 2  # Give OpenDKIM time to create socket
  
  # Verify OpenDKIM socket exists
  if [[ ! -S /var/spool/postfix/opendkim/opendkim.sock ]]; then
    echo "[!] Warning: OpenDKIM socket not found. Checking status..."
    systemctl status opendkim --no-pager || true
  fi

  # Add dovecot to mail group
  adduser dovecot mail
  
  # Restart mail services
  systemctl restart postfix
  systemctl restart dovecot
  
  # Verify services are running
  echo "[*] Verifying services..."
  local ALL_OK=true
  
  if systemctl is-active --quiet postfix; then
    echo "    ✅ Postfix is running"
  else
    echo "    ❌ Postfix failed to start"
    ALL_OK=false
  fi
  
  if systemctl is-active --quiet dovecot; then
    echo "    ✅ Dovecot is running"
  else
    echo "    ❌ Dovecot failed to start"
    ALL_OK=false
  fi
  
  if systemctl is-active --quiet opendkim; then
    echo "    ✅ OpenDKIM is running"
  else
    echo "    ❌ OpenDKIM failed to start"
    ALL_OK=false
  fi
  
  if [[ "${ALL_OK}" != "true" ]]; then
    echo ""
    echo "[!] Some services failed to start. Check logs with:"
    echo "    journalctl -u postfix -n 50"
    echo "    journalctl -u dovecot -n 50"
    echo "    journalctl -u opendkim -n 50"
  fi
}

verify_ports() {
  echo "[*] Verifying listening ports..."
  
  # Check if common ports are listening
  local PORTS_CHECK=("25" "587" "465" "143" "993")
  
  for PORT in "${PORTS_CHECK[@]}"; do
    if ss -tlnp | grep -q ":${PORT} "; then
      echo "    ✅ Port ${PORT} is listening"
    else
      echo "    ⚠️  Port ${PORT} is NOT listening"
    fi
  done
}

print_dns_records() {
  MAIL_PASSWORD=$(cat "/root/${DOMAIN}_${MAILBOX_LOCAL}_password.txt")
  echo
  echo "=============================="
  echo "✅ MAIL READY: ${DOMAIN}"
  echo "Host: ${MAIL_HOST}"
  echo "IP:   ${SERVER_IP}"
  echo "=============================="
  echo

  echo "Mailbox created:"
  echo "  Email: ${MAIL_USER}"
  echo "  Password file: /root/${DOMAIN}_${MAILBOX_LOCAL}_password.txt"
  echo

  echo "SMTP (Outgoing Mail):"
  echo "  Host: ${MAIL_HOST}"
  echo "  Port: 587 (STARTTLS) - Recommended"
  echo "  Port: 465 (SSL/TLS)"
  echo "  Port: 25 (Plain - for server-to-server)"
  echo "  Username: ${MAIL_USER}"
  echo "  Password: ${MAIL_PASSWORD}"
  echo "  Authentication: Required"
  echo "  Encryption: TLS/SSL"
  echo

  echo "IMAP (Incoming Mail):"
  echo "  Host: ${MAIL_HOST}"
  echo "  Port: 993 (SSL/TLS) - Recommended"
  echo "  Port: 143 (STARTTLS)"
  echo "  Username: ${MAIL_USER}"
  echo "  Password: ${MAIL_PASSWORD}"
  echo "  Authentication: Required"
  echo "  Encryption: TLS/SSL"
  echo

  echo "SSL Certificate:"
  echo "  Cert: ${SSL_CERT}"
  echo "  Key:  ${SSL_KEY}"
  echo

  echo "---- DNS RECORDS ----"
  echo "A:"
  echo "  ${DOMAIN} -> ${SERVER_IP}"
  echo
  echo "MX:"
  echo "  ${DOMAIN} -> ${DOMAIN} (priority 10)"
  echo
  echo "SPF (TXT):"
  echo "  ${DOMAIN} TXT \"v=spf1 a mx ip4:${SERVER_IP} ~all\""
  echo
  echo "DMARC (TXT):"
  echo "  _dmarc.${DOMAIN} TXT \"v=DMARC1; p=none; rua=mailto:dmarc@${DOMAIN}; fo=1; adkim=s; aspf=s\""
  echo
  echo "DKIM (TXT):"
  local DKIM_TXT

  DKIM_TXT=$(
    tr -d '\n' < "/etc/opendkim/keys/${DOMAIN}/${DKIM_SELECTOR}.txt" |
    sed -e 's/.*(//' -e 's/).*//' -e 's/"//g'
  )

  echo "  ${DKIM_SELECTOR}._domainkey.${DOMAIN} TXT \"${DKIM_TXT}\""
  echo
  echo "Deliverability MUST:"
  echo "  ✅ Set PTR/rDNS of ${SERVER_IP} to ${DOMAIN}"
  echo "----------------------------------"
  echo
  echo "Testing Commands:"
  echo "  # Test SMTP connection:"
  echo "  openssl s_client -connect ${MAIL_HOST}:587 -starttls smtp"
  echo
  echo "  # Test IMAP connection:"
  echo "  openssl s_client -connect ${MAIL_HOST}:993"
  echo
  echo "  # Test sending email:"
  echo "  echo 'Test' | mail -s 'Test Subject' your-email@example.com"
  echo
}

main() {
  ensure_hostname
  install_packages
  update_openssl_config
  create_vmail_user
  create_warmup_user
  setup_tls_cert_webroot
  setup_postfix
  setup_dovecot
  add_mail_user
  setup_opendkim
  fix_opendkim_runtime
  fix_opendkim_systemd_pid_issue
  enable_cert_renew_hook
  configure_ufw
  restart_services
  verify_ports
  print_dns_records
}

main
