#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ------------------------------------------
# Mailbox management CLI for servers installed with
# deploy-mail-ols.sh (Postfix + Dovecot + OpenDKIM, no database)
#
# Usage:
#   sudo ./mailbox.sh add alice                 # independent mailbox (own Maildir)
#   sudo ./mailbox.sh add dave --alias-to warmup# inbound mail -> warmup@ inbox
#   sudo ./mailbox.sh add dave --alias-to warmup --same-password
#                                               # ... and reuse warmup's password
#   sudo ./mailbox.sh add alice@mail.host.tld   # full address, must match installed domain
#   sudo ./mailbox.sh alias dave warmup         # convert existing mailbox to alias
#   sudo ./mailbox.sh unalias dave              # convert back to own Maildir
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
#   /etc/postfix/virtual_aliases + .db     Per-address alias routing (alias mailboxes)
#   /var/mail/vhosts/<domain>/<local>/     Maildir storage (independent mailboxes)
#   /root/<domain>_<local>_password.txt    Generated passwords
#   main.cf virtual_alias_maps             Registered once, when the first alias
#                                         is created; existing maps are preserved
#
# Aliases are per-address only — no @domain catch-all is possible, and
# recipients not present in vmailbox/virtual_aliases keep getting
# rejected (550). Alias mailboxes keep their login (SMTP send as that
# address, IMAP login shows an empty inbox); inbound mail is delivered
# to the target mailbox.
#
# Environment overrides (for testing only):
#   VMAILBOX_FILE ALIAS_FILE PASSWD_FILE VMAIL_HOME VMAIL_USER
#   PASSWORD_DIR LOCK_FILE MAILBOX_TEST_MODE
# ------------------------------------------

if [[ $EUID -ne 0 && "${MAILBOX_TEST_MODE:-0}" != "1" ]]; then
  echo "Run as root: sudo $0 <command> [args]"
  exit 1
fi

VMAILBOX_FILE="${VMAILBOX_FILE:-/etc/postfix/vmailbox}"
ALIAS_FILE="${ALIAS_FILE:-/etc/postfix/virtual_aliases}"
PASSWD_FILE="${PASSWD_FILE:-/etc/dovecot/passwd}"
VMAIL_HOME="${VMAIL_HOME:-/var/mail/vhosts}"
VMAIL_USER="${VMAIL_USER:-vmail}"
PASSWORD_DIR="${PASSWORD_DIR:-/root}"
LOCK_FILE="${LOCK_FILE:-/var/lock/mailbox.sh.lock}"

DOMAIN=""
LOCAL_PART=""
EMAIL=""
TARGET_EMAIL=""
VMAIL_UID=5000
VMAIL_GID=5000

die() { echo "[!] $*" >&2; exit 1; }

gen_password() { openssl rand -base64 24 | tr -d '\n'; }

usage() {
  cat <<'EOF'
mailbox.sh - manage virtual mailboxes created by deploy-mail-ols.sh

Commands:
  add <local-part | user@domain> [--alias-to <target>] [--same-password]
                                   Create mailbox. Independent by default
                                   (own Maildir); --alias-to delivers inbound
                                   mail to the target mailbox instead
                                   (e.g. --alias-to warmup). --same-password
                                   (with --alias-to) reuses the target's
                                   saved password instead of a new random one
  alias <mailbox> <target>         Redirect an existing mailbox's mail to target
  unalias <mailbox>                Restore delivery to the mailbox's own Maildir
  list                             List mailboxes, delivery mode and unread count
  passwd <local-part | user@domain> Reset a mailbox password
  delete <local-part | user@domain> [--purge]
                                   Remove mailbox (--purge also deletes Maildir)

Examples:
  sudo ./mailbox.sh add alice
  sudo ./mailbox.sh add dave --alias-to warmup
  sudo ./mailbox.sh add dave --alias-to warmup --same-password
  sudo ./mailbox.sh add sales@server-1.example.net
  sudo ./mailbox.sh alias bob warmup@server-1.example.net
  sudo ./mailbox.sh unalias bob
  sudo ./mailbox.sh list
  sudo ./mailbox.sh delete bob --purge

Passwords are saved to /root/<domain>_<local-part>_password.txt (mode 600).
Alias mailboxes keep their login (send via SMTP as that address); inbound
mail arrives in the target mailbox. Never a catch-all: per-address entries
only, unknown recipients stay rejected.
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

# Sets TARGET_EMAIL from "warmup" or "warmup@<domain>"
resolve_target() {
  local input="${1:-}" dom re
  [[ -n "$input" ]] || die "missing alias target"
  input="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"
  if [[ "$input" != *"@"* ]]; then
    input="${input}@${DOMAIN}"
  fi
  dom="${input#*@}"
  [[ "$dom" == "$DOMAIN" ]] || \
    die "alias target domain '$dom' is not hosted here (installed domain: $DOMAIN)"
  re="^[a-z0-9]([a-z0-9._+-]{0,62}[a-z0-9])?@${DOMAIN//./\\.}$"
  [[ "$input" =~ $re ]] || die "invalid alias target: '$input'"
  TARGET_EMAIL="$input"
}

lookup_alias() {
  [[ -f "$ALIAS_FILE" ]] || return 0
  awk -v e="$1" '$1 == e { print $2; exit }' "$ALIAS_FILE" 2>/dev/null
}

# Uses EMAIL + TARGET_EMAIL: target must be a real mailbox, no self-alias,
# no alias chain that loops back to EMAIL
validate_alias_request() {
  [[ "$TARGET_EMAIL" != "$EMAIL" ]] || die "cannot alias ${EMAIL} to itself"
  mailbox_exists_in_vmailbox "$TARGET_EMAIL" || \
    die "alias target ${TARGET_EMAIL} does not exist (create it first)"
  local cur next hops=0
  cur="$TARGET_EMAIL"
  while :; do
    next="$(lookup_alias "$cur")"
    [[ -z "$next" ]] && return 0
    [[ "$next" != "$EMAIL" ]] || die "alias loop: ${TARGET_EMAIL} resolves back to ${EMAIL}"
    cur="$next"
    hops=$((hops + 1))
    [[ $hops -lt 10 ]] || return 0
  done
}

add_alias_entry() {
  local tmp
  touch "$ALIAS_FILE"
  tmp="$(mktemp "${ALIAS_FILE}.tmp.XXXXXX")"
  awk -v e="$EMAIL" '$1 != e' "$ALIAS_FILE" > "$tmp"
  echo "${EMAIL} ${TARGET_EMAIL}" >> "$tmp"
  cat "$tmp" > "$ALIAS_FILE"
  rm -f "$tmp"
}

remove_alias_entry() {
  local email="$1" tmp
  [[ -f "$ALIAS_FILE" ]] || return 0
  tmp="$(mktemp "${ALIAS_FILE}.tmp.XXXXXX")"
  awk -v e="$email" '$1 != e' "$ALIAS_FILE" > "$tmp"
  cat "$tmp" > "$ALIAS_FILE"
  rm -f "$tmp"
}

# Register our alias map in main.cf without clobbering existing maps
ensure_alias_map_configured() {
  local current
  current="$(postconf -h virtual_alias_maps 2>/dev/null || true)"
  case "$current" in
    *"${ALIAS_FILE}"*) return 0 ;;
  esac
  if [[ -z "${current// /}" ]]; then
    echo "[*] Registering virtual_alias_maps = hash:${ALIAS_FILE}"
    postconf -e "virtual_alias_maps = hash:${ALIAS_FILE}"
  else
    echo "[*] Appending hash:${ALIAS_FILE} to existing virtual_alias_maps"
    postconf -e "virtual_alias_maps = ${current}, hash:${ALIAS_FILE}"
  fi
}

# Print the alias target's password, reusing its saved password file.
# Fails hard if the file is missing or no longer authenticates (stale).
target_password() {
  local tlocal="${TARGET_EMAIL%%@*}"
  local tfile="${PASSWORD_DIR}/${DOMAIN}_${tlocal}_password.txt"
  [[ -f "$tfile" ]] || \
    die "no saved password for ${TARGET_EMAIL} (${tfile}); reset it first: $0 passwd ${tlocal}"
  local pass
  pass="$(head -n1 "$tfile")"
  [[ -n "$pass" ]] || die "password file for ${TARGET_EMAIL} is empty"
  doveadm auth test "$TARGET_EMAIL" "$pass" >/dev/null 2>&1 || \
    die "saved password for ${TARGET_EMAIL} no longer authenticates (stale file); reset it first: $0 passwd ${tlocal}"
  printf '%s' "$pass"
}

cmd_add() {
  local input="${1:-}" alias_arg="" same_pass="no"
  [[ -n "$input" ]] || die "missing mailbox name (see: $0 help)"
  [[ "$input" != -* ]] || die "missing mailbox name before options"
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --alias-to)
        [[ $# -ge 2 ]] || die "--alias-to needs a target mailbox"
        alias_arg="$2"; shift 2 ;;
      --same-password) same_pass="yes"; shift ;;
      *) die "unknown option: $1 (see: $0 help)" ;;
    esac
  done
  if [[ "$same_pass" == "yes" && -z "$alias_arg" ]]; then
    die "--same-password is only valid together with --alias-to"
  fi

  resolve_user "$input"
  if [[ -n "$alias_arg" ]]; then
    resolve_target "$alias_arg"
    validate_alias_request
  fi

  echo "[*] Creating mailbox: ${EMAIL}"

  local pass hash mapped
  if [[ "$same_pass" == "yes" ]]; then
    pass="$(target_password)"
    echo "[*] Reusing password of ${TARGET_EMAIL}"
  else
    pass="$(gen_password)"
  fi
  hash="$(doveadm pw -s SHA512-CRYPT -p "$pass")"

  upsert_passwd_entry "$hash"
  upsert_vmailbox_entry
  postmap "$VMAILBOX_FILE"

  if [[ -n "$alias_arg" ]]; then
    add_alias_entry
    ensure_alias_map_configured
    postmap "$ALIAS_FILE"
  else
    create_maildir
  fi

  # Verify before declaring success
  mapped="$(postmap -q "$EMAIL" "hash:${VMAILBOX_FILE}")"
  [[ "$mapped" == "${DOMAIN}/${LOCAL_PART}/" ]] || \
    die "verification failed: postmap -q ${EMAIL} returned '${mapped:-<empty>}'"
  if [[ -n "$alias_arg" ]]; then
    mapped="$(postmap -q "$EMAIL" "hash:${ALIAS_FILE}")"
    [[ "$mapped" == "$TARGET_EMAIL" ]] || \
      die "verification failed: ${EMAIL} does not resolve to ${TARGET_EMAIL}"
  fi
  doveadm auth test "$EMAIL" "$pass" >/dev/null 2>&1 || \
    die "verification failed: doveadm auth test ${EMAIL}"

  save_password "$pass"
  systemctl reload postfix 2>/dev/null || true
  systemctl reload dovecot 2>/dev/null || true

  echo "[+] Mailbox ready: ${EMAIL}"
  if [[ "$same_pass" == "yes" ]]; then
    echo "    Password: same as ${TARGET_EMAIL} (saved to: ${PASSWORD_FILE_SAVED})"
  else
    echo "    Password: ${pass}"
    echo "    Saved to: ${PASSWORD_FILE_SAVED}"
  fi
  if [[ -n "$alias_arg" ]]; then
    echo "    Delivery: mail to ${EMAIL} lands in ${TARGET_EMAIL}"
    echo "    Login still works (send as this address; IMAP inbox stays empty)"
  else
    echo "    Delivery: own mailbox"
    echo "    IMAP:     $(postconf -h myhostname 2>/dev/null || echo "$DOMAIN"):993  SMTP: :587"
  fi
  echo "    Unknown recipients are still rejected (no catch-all)."
}

cmd_list() {
  local email path localpart dom dir unread auth dtype
  printf '%-42s %-36s %-5s %s\n' "MAILBOX" "DELIVERS TO" "AUTH" "UNREAD"
  while IFS=' ' read -r email path || [[ -n "$email" ]]; do
    [[ -z "${email// /}" || "$email" == \#* ]] && continue
    localpart="${email%%@*}"
    dom="${email#*@}"
    dir="${VMAIL_HOME}/${dom}/${localpart}"

    if mailbox_exists_in_passwd "$email"; then auth="yes"; else auth="NO"; fi
    dtype="$(lookup_alias "$email")"
    if [[ -n "$dtype" ]]; then
      unread="-"
    else
      dtype="(own mailbox)"
      if [[ -d "$dir/Maildir" ]]; then
        unread="$(find "$dir/Maildir/new" -type f 2>/dev/null | wc -l | tr -d ' ')"
      else
        unread="-"
      fi
    fi

    printf '%-42s %-36s %-5s %s\n' "$email" "$dtype" "$auth" "$unread"
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

  if [[ -n "$(lookup_alias "$EMAIL")" ]]; then
    remove_alias_entry "$EMAIL"
    postmap "$ALIAS_FILE"
  fi

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

cmd_alias() {
  local user="${1:-}" tgt="${2:-}"
  [[ -n "$user" && -n "$tgt" ]] || die "usage: $0 alias <mailbox> <target-mailbox>"
  resolve_user "$user"
  mailbox_exists_in_vmailbox "$EMAIL" || mailbox_exists_in_passwd "$EMAIL" \
    || die "no such mailbox: ${EMAIL}"
  resolve_target "$tgt"
  validate_alias_request

  echo "[*] Aliasing ${EMAIL} -> ${TARGET_EMAIL}"
  add_alias_entry
  ensure_alias_map_configured
  postmap "$ALIAS_FILE"

  local mapped
  mapped="$(postmap -q "$EMAIL" "hash:${ALIAS_FILE}")"
  [[ "$mapped" == "$TARGET_EMAIL" ]] || \
    die "verification failed: ${EMAIL} does not resolve to ${TARGET_EMAIL}"

  systemctl reload postfix 2>/dev/null || true
  echo "[+] Mail to ${EMAIL} is now delivered to ${TARGET_EMAIL}"
  echo "    Existing mail stays in ${VMAIL_HOME}/${DOMAIN}/${LOCAL_PART} (untouched)"
}

cmd_unalias() {
  resolve_user "${1:-}"
  if [[ -z "$(lookup_alias "$EMAIL")" ]]; then
    echo "[*] ${EMAIL} is not aliased (already delivers to its own mailbox)"
    return 0
  fi
  echo "[*] Removing alias for ${EMAIL}"
  remove_alias_entry "$EMAIL"
  postmap "$ALIAS_FILE"
  create_maildir
  systemctl reload postfix 2>/dev/null || true
  echo "[+] Mail to ${EMAIL} now delivers to its own mailbox"
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    add) preflight; cmd_add "$@" ;;
    alias) preflight; cmd_alias "$@" ;;
    unalias) preflight; cmd_unalias "$@" ;;
    list) preflight; cmd_list "$@" ;;
    passwd) preflight; cmd_passwd "$@" ;;
    delete) preflight; cmd_delete "$@" ;;
    help|--help|-h) usage ;;
    *) usage; echo >&2; die "unknown command: $cmd" ;;
  esac
}

main "$@"
