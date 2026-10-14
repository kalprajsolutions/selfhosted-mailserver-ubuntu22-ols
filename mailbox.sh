#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ------------------------------------------
# Mailbox management CLI for servers installed with
# deploy-mail-ols.sh (Postfix + Dovecot + OpenDKIM, no database)
#
# Usage:
#   sudo ./mailbox.sh add alice                 # alice@<installed-domain>
#   sudo ./mailbox.sh add alice@mail.host.tld   # full address, must match installed domain
#   sudo ./mailbox.sh list
#   sudo ./mailbox.sh passwd alice              # new random password
#   sudo ./mailbox.sh delete alice [--purge]    # --purge also removes the Maildir
#
# The mail domain is detected from `postconf virtual_mailbox_domains`,
# NOT from an argument — deploy-mail-ols.sh uses its install argument as
# the mail domain (installed as mail.example.com -> addresses are
# @mail.example.com), so we never guess.
#
# What this script touches (and nothing else):
#   /etc/dovecot/passwd                    Dovecot auth entries
#   /etc/postfix/vmailbox + .db            Postfix recipient validation
#   /var/mail/vhosts/<domain>/<local>/     Maildir storage
#   /root/<domain>_<local>_password.txt    Generated passwords
#
# It never edits main.cf / dovecot.conf and never adds a catch-all:
# recipients not present in vmailbox keep getting rejected (550).
#
# Environment overrides (for testing only):
#   VMAILBOX_FILE PASSWD_FILE VMAIL_HOME VMAIL_USER
#   PASSWORD_DIR LOCK_FILE MAILBOX_TEST_MODE
# ------------------------------------------

if [[ $EUID -ne 0 && "${MAILBOX_TEST_MODE:-0}" != "1" ]]; then
  echo "Run as root: sudo $0 <command> [args]"
  exit 1
fi

VMAILBOX_FILE="${VMAILBOX_FILE:-/etc/postfix/vmailbox}"
PASSWD_FILE="${PASSWD_FILE:-/etc/dovecot/passwd}"
VMAIL_HOME="${VMAIL_HOME:-/var/mail/vhosts}"
VMAIL_USER="${VMAIL_USER:-vmail}"
PASSWORD_DIR="${PASSWORD_DIR:-/root}"
LOCK_FILE="${LOCK_FILE:-/var/lock/mailbox.sh.lock}"

DOMAIN=""
LOCAL_PART=""
EMAIL=""
VMAIL_UID=5000
VMAIL_GID=5000

die() { echo "[!] $*" >&2; exit 1; }

gen_password() { openssl rand -base64 24 | tr -d '\n'; }

usage() {
  cat <<'EOF'
mailbox.sh - manage virtual mailboxes created by deploy-mail-ols.sh

Commands:
  add <local-part | user@domain>   Create mailbox (random password generated)
  list                             List all mailboxes with auth/maildir status
  passwd <local-part | user@domain> Reset a mailbox password
  delete <local-part | user@domain> [--purge]
                                   Remove mailbox (--purge also deletes Maildir)

Examples:
  sudo ./mailbox.sh add alice
  sudo ./mailbox.sh add sales@server-1.example.net
  sudo ./mailbox.sh list
  sudo ./mailbox.sh delete bob --purge

Passwords are saved to /root/<domain>_<local-part>_password.txt (mode 600).
EOF
}

preflight() {
  local cmd
  for cmd in postconf postmap doveadm openssl; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd (run on a server installed by deploy-mail-ols.sh)"
  done
  [[ -f "$VMAILBOX_FILE" ]] || die "$VMAILBOX_FILE not found - is this a deploy-mail-ols.sh server?"

  local domains
  domains="$(postconf -h virtual_mailbox_domains 2>/dev/null | xargs || true)"
  [[ -n "$domains" ]] || die "virtual_mailbox_domains is empty - not a deploy-mail-ols.sh server?"
  [[ "$domains" != *" "* ]] || die "multiple virtual domains not supported (found: $domains)"
  DOMAIN="$domains"

  if getent passwd "$VMAIL_USER" >/dev/null 2>&1; then
    VMAIL_UID="$(getent passwd "$VMAIL_USER" | cut -d: -f3)"
    VMAIL_GID="$(getent passwd "$VMAIL_USER" | cut -d: -f4)"
  fi

  # Serialize mutations of passwd/vmailbox against concurrent runs
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "another mailbox.sh instance is running ($LOCK_FILE)"
  fi
}

# Sets LOCAL_PART and EMAIL from "alice" or "alice@<domain>"
resolve_user() {
  local input="${1:-}" dom
  [[ -n "$input" ]] || die "missing mailbox name (see: $0 help)"
  input="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"

  if [[ "$input" == *"@"* ]]; then
    LOCAL_PART="${input%%@*}"
    dom="${input#*@}"
    [[ "$dom" == "$DOMAIN" ]] || \
      die "'$dom' is not hosted on this server (installed domain: $DOMAIN). deploy-mail-ols.sh uses its install argument as the mail domain - installed as mail.example.com means addresses are @mail.example.com"
  else
    LOCAL_PART="$input"
  fi

  [[ "$LOCAL_PART" =~ ^[a-z0-9]([a-z0-9._+-]{0,62}[a-z0-9])?$ ]] || \
    die "invalid local part: '$LOCAL_PART' (allowed: a-z 0-9 . _ + -)"
  EMAIL="${LOCAL_PART}@${DOMAIN}"
}

password_file_path() { printf '%s/%s_%s_password.txt' "$PASSWORD_DIR" "$DOMAIN" "$LOCAL_PART"; }

upsert_passwd_entry() {
  local hash="$1" tmp
  touch "$PASSWD_FILE"
  tmp="$(mktemp "${PASSWD_FILE}.tmp.XXXXXX")"
  awk -F: -v u="$EMAIL" '$1 != u' "$PASSWD_FILE" > "$tmp"
  printf '%s:%s:%s:%s::%s/%s/%s::\n' \
    "$EMAIL" "$hash" "$VMAIL_UID" "$VMAIL_GID" "$VMAIL_HOME" "$DOMAIN" "$LOCAL_PART" >> "$tmp"
  cat "$tmp" > "$PASSWD_FILE"
  rm -f "$tmp"
  chmod 640 "$PASSWD_FILE"
  chown root:dovecot "$PASSWD_FILE" 2>/dev/null || true
}

upsert_vmailbox_entry() {
  local tmp
  tmp="$(mktemp "${VMAILBOX_FILE}.tmp.XXXXXX")"
  awk -v e="$EMAIL" '$1 != e' "$VMAILBOX_FILE" > "$tmp"
  echo "${EMAIL} ${DOMAIN}/${LOCAL_PART}/" >> "$tmp"
  cat "$tmp" > "$VMAILBOX_FILE"
  rm -f "$tmp"
}

create_maildir() {
  local root f
  root="${VMAIL_HOME}/${DOMAIN}/${LOCAL_PART}"
  mkdir -p "$root/Maildir"/{cur,new,tmp}
  for f in Drafts Sent Trash Junk; do
    mkdir -p "$root/Maildir/.$f"/{cur,new,tmp}
  done
  chown -R "${VMAIL_UID}:${VMAIL_GID}" "$root" || die "chown failed for $root"
  find "$root" -type d -exec chmod 700 {} +
}

save_password() {
  local pass="$1" file
  file="$(password_file_path)"
  printf '%s\n' "$pass" > "$file"
  chmod 600 "$file"
  PASSWORD_FILE_SAVED="$file"
}

mailbox_exists_in_vmailbox() {
  awk -v e="$1" '$1 == e { found = 1 } END { exit !found }' "$VMAILBOX_FILE"
}

mailbox_exists_in_passwd() {
  awk -F: -v u="$1" '$1 == u { found = 1 } END { exit !found }' "$PASSWD_FILE" 2>/dev/null
}

cmd_add() {
  resolve_user "${1:-}"
  local pass hash mapped
  echo "[*] Creating mailbox: ${EMAIL}"

  pass="$(gen_password)"
  hash="$(doveadm pw -s SHA512-CRYPT -p "$pass")"

  upsert_passwd_entry "$hash"
  upsert_vmailbox_entry
  create_maildir
  postmap "$VMAILBOX_FILE"

  # Verify before declaring success
  mapped="$(postmap -q "$EMAIL" "hash:${VMAILBOX_FILE}")"
  [[ "$mapped" == "${DOMAIN}/${LOCAL_PART}/" ]] || \
    die "verification failed: postmap -q ${EMAIL} returned '${mapped:-<empty>}'"
  doveadm auth test "$EMAIL" "$pass" >/dev/null 2>&1 || \
    die "verification failed: doveadm auth test ${EMAIL}"

  save_password "$pass"
  systemctl reload postfix 2>/dev/null || true
  systemctl reload dovecot 2>/dev/null || true

  echo "[+] Mailbox ready: ${EMAIL}"
  echo "    Password: ${pass}"
  echo "    Saved to: ${PASSWORD_FILE_SAVED}"
  echo "    IMAP:     $(postconf -h myhostname 2>/dev/null || echo "$DOMAIN"):993  SMTP: :587"
  echo "    Unknown recipients are still rejected (no catch-all)."
}

cmd_list() {
  local email path localpart dom dir unread auth maildir
  printf '%-42s %-5s %-8s %s\n' "MAILBOX" "AUTH" "MAILDIR" "UNREAD"
  while IFS=' ' read -r email path || [[ -n "$email" ]]; do
    [[ -z "${email// /}" || "$email" == \#* ]] && continue
    localpart="${email%%@*}"
    dom="${email#*@}"
    dir="${VMAIL_HOME}/${dom}/${localpart}"

    if mailbox_exists_in_passwd "$email"; then auth="yes"; else auth="NO"; fi
    if [[ -d "$dir/Maildir" ]]; then
      maildir="ok"
      unread="$(find "$dir/Maildir/new" -type f 2>/dev/null | wc -l | tr -d ' ')"
    else
      maildir="MISSING"
      unread="-"
    fi

    printf '%-42s %-5s %-8s %s\n' "$email" "$auth" "$maildir" "$unread"
  done < <(sort "$VMAILBOX_FILE")
}

cmd_passwd() {
  resolve_user "${1:-}"
  mailbox_exists_in_passwd "$EMAIL" || die "no auth entry for ${EMAIL} (add it first)"
  echo "[*] Resetting password for: ${EMAIL}"

  local pass hash
  pass="$(gen_password)"
  hash="$(doveadm pw -s SHA512-CRYPT -p "$pass")"

  upsert_passwd_entry "$hash"
  doveadm auth test "$EMAIL" "$pass" >/dev/null 2>&1 || \
    die "verification failed: doveadm auth test ${EMAIL}"
  save_password "$pass"

  echo "[+] Password reset for: ${EMAIL}"
  echo "    Password: ${pass}"
  echo "    Saved to: ${PASSWORD_FILE_SAVED}"
}

cmd_delete() {
  local purge="no"
  local input="${1:-}"
  [[ -n "$input" ]] || die "missing mailbox name (see: $0 help)"
  shift || true
  local a
  for a in "$@"; do
    case "$a" in
      --purge) purge="yes" ;;
      *) die "unknown option: $a" ;;
    esac
  done

  resolve_user "$input"

  # Refuse to "delete" an address this server knows nothing about (typo guard);
  # allow --purge cleanup when only the Maildir is left over.
  if ! mailbox_exists_in_vmailbox "$EMAIL" \
     && ! mailbox_exists_in_passwd "$EMAIL" \
     && [[ ! -d "${VMAIL_HOME}/${DOMAIN}/${LOCAL_PART}" ]]; then
    die "no such mailbox: ${EMAIL}"
  fi

  echo "[*] Deleting mailbox: ${EMAIL}"

  local tmp
  tmp="$(mktemp "${PASSWD_FILE}.tmp.XXXXXX")"
  awk -F: -v u="$EMAIL" '$1 != u' "$PASSWD_FILE" > "$tmp"
  cat "$tmp" > "$PASSWD_FILE"
  rm -f "$tmp"

  tmp="$(mktemp "${VMAILBOX_FILE}.tmp.XXXXXX")"
  awk -v e="$EMAIL" '$1 != e' "$VMAILBOX_FILE" > "$tmp"
  cat "$tmp" > "$VMAILBOX_FILE"
  rm -f "$tmp"
  postmap "$VMAILBOX_FILE"

  rm -f "$(password_file_path)"
  systemctl reload postfix 2>/dev/null || true

  local root="${VMAIL_HOME}/${DOMAIN}/${LOCAL_PART}"
  if [[ "$purge" == "yes" ]]; then
    [[ "$root" == "${VMAIL_HOME}/${DOMAIN}/"* && "$root" != "${VMAIL_HOME}/${DOMAIN}/" ]] || \
      die "refusing to purge unexpected path: $root"
    rm -rf "$root"
    echo "[+] Deleted ${EMAIL} (auth, maps and Maildir removed)"
  else
    echo "[+] Deleted ${EMAIL} (auth and maps removed; Maildir kept at $root)"
  fi
  echo "    Inbound mail to this address is now rejected (550)."
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    add) preflight; cmd_add "$@" ;;
    list) preflight; cmd_list "$@" ;;
    passwd) preflight; cmd_passwd "$@" ;;
    delete) preflight; cmd_delete "$@" ;;
    help|--help|-h) usage ;;
    *) usage; echo >&2; die "unknown command: $cmd" ;;
  esac
}

main "$@"
