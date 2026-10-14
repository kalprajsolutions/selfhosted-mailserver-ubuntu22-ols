# One-Click Mail Server Setup (Postfix + Dovecot + OpenDKIM) for Ubuntu 22.04

Quickly deploy a production-ready mail server on **Ubuntu 22.04** using:

- ✅ Postfix (SMTP + Submission 587 + SMTPS 465)
- ✅ Dovecot (IMAP 993 + LMTP)
- ✅ OpenDKIM (DKIM signing)
- ✅ TLS (Let’s Encrypt via webroot OR existing certificates)
- ✅ Virtual mailbox support (no MySQL / no PostfixAdmin)

This repo is built for fast server provisioning and is ideal for:
- Warmup inboxes (e.g. `warmup@yourdomain.com`)
- Transactional sender setup (basic)
- Lightweight self-hosted mail deployments

---

## Features

✅ **IMAP + SMTP working with Thunderbird / Outlook / mobile clients**  
✅ **Secure TLS configuration** (IMAPS + STARTTLS submission)  
✅ **DKIM signing** using OpenDKIM  
✅ **No database required** (uses a local Dovecot passwd-file)  
✅ **Compatible with OpenLiteSpeed** (certbot `--webroot`)  
✅ Folder structure created automatically:
- Inbox
- Sent
- Drafts
- Junk
- Trash

---

## Requirements

- Ubuntu **22.04**
- A domain/subdomain pointing to your VPS (A record)
- Ports open on server/network:
  - `25` (SMTP server-to-server)
  - `587` (SMTP submission - recommended)
  - `465` (SMTPS - optional)
  - `993` (IMAPS)
  - `80` (only needed for Let’s Encrypt webroot challenge)

> ⚠️ Many VPS providers block outbound port **25** by default.  
> Sending to Gmail/Outlook may require opening port 25 or using an SMTP relay.

---

## DNS Records You Must Set

### A Record
Point your domain/subdomain to your VPS IP:
```

mail.example.com  ->  <YOUR_SERVER_IP>

```

### MX Record
```

example.com MX 10 mail.example.com

```

### SPF (TXT)
```

example.com TXT "v=spf1 a mx ip4:<YOUR_SERVER_IP> ~all"

```

### DKIM (TXT)
After installation, the script prints the DKIM record like:
```

s1._domainkey.example.com TXT "v=DKIM1; k=rsa; p=...."

```

### DMARC (TXT)
```

_dmarc.example.com TXT "v=DMARC1; p=none; rua=mailto:dmarc@example.com; fo=1; adkim=s; aspf=s"

````

✅ Recommended:
- Set **PTR / rDNS** of your server IP to your mail hostname (`mail.example.com`)
- Ensure `hostname -f` matches your mail hostname

---

## Installation (One Command)

### 1) Download + run script
```bash
curl -fsSL https://raw.githubusercontent.com/kalprajsolutions/selfhosted-mailserver-ubuntu22-ols/main/deploy-mail-ols.sh | sudo bash -s mail.example.com
````

Example:

```bash
curl -fsSL https://raw.githubusercontent.com/kalprajsolutions/selfhosted-mailserver-ubuntu22-ols/main/deploy-mail-ols.sh | sudo bash -s server-123.kalprajsolutions.net
```

---

## TLS Options (SSL Certificate)

### ✅ Option A: Use Let’s Encrypt (recommended)

The script will automatically try certbot `--webroot`.

Make sure your domain is loading in browser:

```
http://mail.example.com/
```

If you use OpenLiteSpeed, set webroot before running:

```bash
export WEBROOT=/usr/local/lsws/Example/html
```

Then run the installer.

---

### ✅ Option B: Use existing certificates

You can pass your existing cert and key:

```bash
export SSL_CERT=/path/to/fullchain.pem
export SSL_KEY=/path/to/privkey.pem

sudo bash deploy-mail-ols.sh mail.example.com
```

---

## Default Mailbox Created

The script creates:

* **Email:** `warmup@YOUR_DOMAIN`
* **Password:** saved to:

  ```
  /root/YOUR_DOMAIN_warmup_password.txt
  ```

Mailbox path:

```
/var/mail/vhosts/<domain>/warmup/Maildir/
```

---

## Managing Additional Mailboxes (mailbox.sh)

After installation, create as many extra mailboxes as you need with `mailbox.sh`. It uses the same file layout as the installer (`/etc/dovecot/passwd`, `/etc/postfix/vmailbox`, `/var/mail/vhosts/`) and never adds a catch-all — unknown recipients keep getting rejected.

```bash
sudo ./mailbox.sh add alice              # INDEPENDENT mailbox (own Maildir)
sudo ./mailbox.sh add dave --alias-to warmup   # ALIAS: mail lands in warmup@ inbox
sudo ./mailbox.sh add sales@server-1.example.net   # must match installed domain
sudo ./mailbox.sh alias bob warmup       # convert existing mailbox to alias
sudo ./mailbox.sh unalias bob            # convert back to own Maildir
sudo ./mailbox.sh list
sudo ./mailbox.sh passwd alice           # new random password
sudo ./mailbox.sh delete bob             # removes login + mail routing
sudo ./mailbox.sh delete bob --purge     # also deletes the Maildir
```

Two delivery modes:

* **Independent (default):** a real mailbox like `warmup@` — own login, own Maildir receiving its own mail, DKIM-signed automatically.
* **Alias (`--alias-to warmup` or the `alias` command):** keeps its own login (can send via SMTP as that address), but inbound mail is delivered to the target mailbox. Useful for send-only identities whose replies should collect in a central inbox. The IMAP inbox of an alias user stays empty. Aliases are per-address entries in `virtual_alias_maps` — never an `@domain` catch-all.

### One-liner usage (no download, same as the installer)

Run any command directly from this repo on a server:

```bash
curl -fsSL https://raw.githubusercontent.com/kalprajsolutions/selfhosted-mailserver-ubuntu22-ols/main/mailbox.sh | sudo bash -s add alice
```

All commands work the same way:

```bash
MBX=https://raw.githubusercontent.com/kalprajsolutions/selfhosted-mailserver-ubuntu22-ols/main/mailbox.sh

curl -fsSL "$MBX" | sudo bash -s add dave --alias-to warmup
curl -fsSL "$MBX" | sudo bash -s alias bob warmup
curl -fsSL "$MBX" | sudo bash -s unalias bob
curl -fsSL "$MBX" | sudo bash -s list
curl -fsSL "$MBX" | sudo bash -s passwd alice
curl -fsSL "$MBX" | sudo bash -s delete bob --purge
```

Across a fleet (`servers.txt` with one `root@IP` per line):

```bash
while IFS= read -r srv; do
  ssh -n "$srv" "curl -fsSL $MBX | bash -s add dave --alias-to warmup"
done < servers.txt
```

Notes:

* The mail domain is **auto-detected** from `postconf virtual_mailbox_domains`. Since `deploy-mail-ols.sh` uses its install argument as the mail domain, a server installed as `mail.example.com` hosts `@mail.example.com` addresses — the script refuses any other domain instead of misconfiguring the server.
* Passwords are generated (24+ chars) and saved to `/root/<domain>_<local-part>_password.txt` (mode 600), same convention as the installer.
* `main.cf` is touched only to register `virtual_alias_maps` when you create the first alias, and any existing alias maps are preserved (ours is appended).
* Alias targets must already exist (no accepted-then-bounced mail), self-aliases and alias loops are rejected, and every change is verified (`postmap -q` + `doveadm auth test`) before success is reported.
* On a fleet, run it remotely: `scp mailbox.sh root@<server>:/root/ && ssh root@<server> '/root/mailbox.sh add dave --alias-to warmup'`

---

## Mail Client Settings (Thunderbird / Outlook)

### Incoming Mail (IMAP)

* Host: `mail.example.com`
* Port: `993`
* Security: `SSL/TLS`
* Username: `warmup@mail.example.com`
* Password: from `/root/<domain>_warmup_password.txt`

### Outgoing Mail (SMTP)

✅ Recommended:

* Host: `mail.example.com`
* Port: `587`
* Security: `STARTTLS`
* Authentication: `Normal Password`
* Username: `warmup@mail.example.com`

Optional:

* Port: `465`
* Security: `SSL/TLS`

---

## Verify Your Mail Server

### Check listening ports

```bash
sudo ss -lntp | egrep ':25|:587|:465|:993'
```

### Test IMAPS

```bash
openssl s_client -connect mail.example.com:993 -servername mail.example.com -brief
```

### Test SMTP STARTTLS (587)

```bash
openssl s_client -starttls smtp -connect mail.example.com:587 -servername mail.example.com -brief
```

### Send a test mail (swaks)

```bash
sudo apt install -y swaks

swaks --to warmup@mail.example.com \
  --from warmup@mail.example.com \
  --server mail.example.com \
  --port 587 \
  --auth LOGIN \
  --auth-user warmup@mail.example.com \
  --auth-password "$(cat /root/mail.example.com_warmup_password.txt)" \
  --tls
```

---

## Folder Copying Issue (Sent Folder Stuck)

If your mail client gets stuck on:
**"Copying message to Sent folder…"**

Make sure Maildir special folders exist:

* `.Sent/cur,new,tmp`
* `.Drafts/cur,new,tmp`
* `.Trash/cur,new,tmp`
* `.Junk/cur,new,tmp`

This repo includes auto folder creation by default.

---

## Security Notes

This script is designed to be **secure by default**, but for real-world deliverability you should also configure:

* Reverse DNS (PTR)
* Proper HELO hostname
* Rate limiting
* Fail2ban (optional)
* Spam filtering (Rspamd / SpamAssassin) (not included)

---

## Troubleshooting

### Check logs

```bash
sudo journalctl -u dovecot -n 100 --no-pager
sudo journalctl -u postfix -n 100 --no-pager
sudo journalctl -u opendkim -n 100 --no-pager
sudo tail -n 100 /var/log/mail.log
```

### Common issues

✅ IMAP connects but login fails
→ Ensure Dovecot `auth_username_format = %u` matches `user@domain` in passwd-file.

✅ SMTP works but can’t deliver to Gmail
→ Outbound port 25 blocked OR missing SPF/DKIM/DMARC/PTR.

---

## Roadmap

* [x] Multi-mailbox support (`mailbox.sh`)
* [ ] Optional Fail2ban integration
* [ ] Optional Rspamd installation
* [ ] Debian 12 support
* [ ] Docker version

---

## License

MIT

---

## Author

Kalpraj Solutions
kalprajsolutions.com

Built for fast VPS deployments and warmup mailbox provisioning.
