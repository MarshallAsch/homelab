# Email Audit Archive & Outbound MTA

End-to-end design and runbook for archiving every outbound email through
Postal and (eventually) routing all outbound mail through Postal → SES.

## Goals

1. **Audit** — every email sent by any service is persisted with full body,
   headers, and delivery status in a searchable store (Postal's message DB).
2. **Outbound** — mail still leaves the network via SES (outbound port 25 is
   blocked by the ISP, so we need a smart host).
3. **Inbound** — receive mail for our domains. Phase 3, blocked on a separate
   workstream (Cloudflare Email Workers).

## Architecture

### Phase 1 (current branch) — BCC archive

```
   ┌──────────┐                                             ┌─────┐
   │ apps     │──► smtp-relay ────────► RELAYHOST ────────► │ SES │──► 🌍
   │ (×10)    │       │                                     └─────┘
   └──────────┘       │ Postfix always_bcc
                      ▼
                  audit@audit.marshallasch.ca
                      │ transport_map override
                      ▼
                  postal_smtp ──► message_db (audit copy, searchable)
                              ──► postal web UI @ mail.marshallasch.ca
```

Each email gets two queue entries: the original out to SES, and a BCC into
Postal. They're independent — if SES rejects the original, the BCC is still
stored.

### Phase 2 — Postal becomes the MTA

```
   ┌──────────┐                       ┌────────────────┐    ┌─────┐
   │ apps     │──► smtp-relay ──────► │ postal_smtp    │    │ SES │
   │ (×10)    │  (forwarding shim)    │     │          │    └──▲──┘
   └──────────┘                       │     ▼          │       │
                                      │ postal_worker ─┼───────┘
                                      │     │          │
                                      │     ▼          │
                                      │ message_db ◄───┼── audit copy
                                      └────────────────┘    (native, no BCC)
```

Phase 2 keeps `smtp-relay` as a thin shim so we don't have to reconfigure
every app at once. It changes `RELAYHOST` from SES → Postal; Postal forwards
to SES via the `smtp_relays` config in `postal.yml` and archives natively.
The Phase 1 BCC trick is dropped.

### Phase 2.5 (optional) — apps talk to Postal directly

Once Phase 2 is stable, apps get repointed from `smtp-relay` to
`postal_smtp` one at a time, and `smtp-relay` is retired. Tracked per-app
in the table below.

## Prerequisites

- `.env` populated. Keys used:
  - `DOMAIN`, `SUBNET`
  - `SMTP_SES_HOST`, `SMTP_SES_PORT`, `SMTP_SES_USER`, `SMTP_SES_PASS`
  - `POSTAL_USER`, `POSTAL_DB`, `POSTAL_DB_PASSWORD`, `POSTAL_OIDC_SECRET`
- DNS A record for `mail.${DOMAIN}` → reverse proxy. The cert is already
  issued (`mail` is in SWAG's `SUBDOMAINS` list).

---

## Phase 0 — Wipe existing Postal state

Postal currently has no production data.

```bash
docker compose down postal postal_worker postal_smtp postal_db
sudo rm -rf ${CONFIG_VOLUMES}/postal
```

(`${CONFIG_VOLUMES}` defaults to `./volumes` if unset.)

---

## Phase 1 — BCC audit copy via `smtp-relay`

**Already applied on this branch.** Files changed:

| Path | Purpose |
|---|---|
| `smtp-relay/transport` | Postfix transport map: `audit.marshallasch.ca` → `postal_smtp:25` |
| `compose.yaml` (`smtp-relay`) | Adds `POSTFIX_always_bcc=audit@audit.marshallasch.ca`, `POSTFIX_transport_maps=texthash:/etc/postfix/transport`, bind-mounts the transport file |
| `compose.yaml` (`postal_smtp`) | Joins `smtp_internal` so the relay can reach it |

### 1.1 Bring up the Postal database

```bash
docker compose up -d postal_db
```

### 1.2 Bootstrap Postal (one-time, generates signing key + default config)

```bash
docker compose run --rm postal postal bootstrap mail.${DOMAIN} /config
```

This writes `${CONFIG_VOLUMES}/postal/app/postal.yml` (a default config) and
`signing.key` (RSA key for DKIM, sensitive — back this up).

### 1.3 Hand-edit `postal.yml`

Bootstrap's defaults assume Postal connects to `127.0.0.1:3306` with root
credentials. Update `${CONFIG_VOLUMES}/postal/app/postal.yml` so DB
connections target our container:

```yaml
main_db:
  host: postal_db
  port: 3306
  username: postal             # match ${POSTAL_USER} in .env
  database: postal             # match ${POSTAL_DB} in .env
  # password comes from MAIN_DB_PASSWORD env var (already set in compose)

message_db:
  host: postal_db
  port: 3306
  username: postal
  prefix: postal
  # password comes from MESSAGE_DB_PASSWORD env var
```

You can leave the rest of the bootstrap defaults alone for Phase 1 — Postal
won't be sending anything outbound yet, so the `dns.*` and `smtp_relays`
sections don't matter.

### 1.4 Grant message-DB privileges to the Postal user

Postal creates a new MariaDB database per mail server
(`postal-server-1`, …). The default user only owns `${POSTAL_DB}`, so we
need to broaden it once:

```bash
docker compose exec postal_db mariadb -uroot \
  -e "GRANT ALL PRIVILEGES ON \`postal-server-%\`.* TO '${POSTAL_USER}'@'%'; FLUSH PRIVILEGES;"
```

(`linuxserver/mariadb` starts without a root password by default; if you've
set one, append `-p<password>`.)

### 1.5 Initialize schema and create admin

```bash
docker compose run --rm postal postal initialize
docker compose run --rm postal postal make-user
```

`make-user` prompts for email/name/password — that's your Postal admin
login.

### 1.6 Add a SWAG proxy conf for the web UI

In `${CONFIG_VOLUMES}/swag/nginx/proxy-confs/mail.subdomain.conf`:

```nginx
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name mail.*;
    include /config/nginx/ssl.conf;

    location / {
        include /config/nginx/proxy.conf;
        include /config/nginx/resolver.conf;
        set $upstream_app postal;
        set $upstream_port 5000;
        set $upstream_proto http;
        proxy_pass $upstream_proto://$upstream_app:$upstream_port;
    }
}
```

SWAG is already on the `internal` network, so it can reach `postal:5000`.
Reload it (`docker compose restart swag`).

### 1.7 Bring up the rest

```bash
docker compose up -d postal postal_worker postal_smtp smtp-relay
```

### 1.8 Configure the archive server in the Postal UI

Log in at `https://mail.${DOMAIN}` and:

1. **Organization** → name `homelab`.
2. **Mail server** → name `archive`, mode **Development**.
3. **Retention** → tune to your audit needs (start with 365 days).
4. **Domains → Add domain** → `audit.marshallasch.ca`. Skip DNS
   verification — it's purely internal.
5. **Routes → New** →
   - Pattern: `audit@audit.marshallasch.ca`
   - Endpoint: **Hold** (store, do not forward).

### 1.9 Verify Phase 1

```bash
docker compose exec smtp-relay sh -c '
  printf "From: test@marshallasch.ca\nTo: marshallasch@gmail.com\nSubject: phase 1 test\n\nbody\n" \
    | sendmail -f test@marshallasch.ca marshallasch@gmail.com
'
```

Within seconds, the BCC copy should appear under the `archive` server's
**Messages** tab, and the original should land in your Gmail inbox via SES.

---

## Phase 2 — Route all outbound through Postal (Postal → SES)

Goal: stop the BCC trick and make Postal the single outbound MTA. Apps keep
submitting to `smtp-relay`, but `smtp-relay` now forwards to Postal instead
of SES. Postal forwards to SES via the `smtp_relays:` block in
`postal.yml`.

### 2.1 Create the production mail server

In Postal UI:

1. **Mail server** → name `outbound`, mode **Live**.
2. **Retention** → 365 days (or your policy).
3. **Domains → Add domain** for every sending domain (see "Sending domains"
   below). Postal shows SPF/DKIM records to add per domain — without these,
   downstream filters (Gmail, etc.) will mark mail as spam.
4. **Credentials → New SMTP credential** → name `smtp-relay-upstream`.
   Save the username/password — they go in `.env` in step 2.3.

**Sending domains** (from `ALLOWED_SENDER_DOMAINS` on the relay):
- `marshallasch.ca`
- `road2ir.org`
- `dive-tec.ca`
- `s-sdiving.com`
- `s-sdiving.ca`

### 2.2 Add the SES smart host to `postal.yml`

Append to `${CONFIG_VOLUMES}/postal/app/postal.yml`:

```yaml
smtp_relays:
  - host: ${SMTP_SES_HOST}      # actual value, no $ substitution at this layer
    port: 587
    ssl_mode: StartTLS
    username: ${SMTP_SES_USER}
    password: ${SMTP_SES_PASS}
```

Yes — paste the literal values here, not `${...}`. Postal does not perform
env substitution on `postal.yml`. The values are also in `.env` for
`smtp-relay`'s old config; they can be copied straight across.

Restart the worker so it picks up the new config:

```bash
docker compose restart postal_worker
```

### 2.3 Point `smtp-relay` at Postal

Edit `compose.yaml`'s `smtp-relay` block:

```diff
     environment:
-      - RELAYHOST=${SMTP_SES_HOST}:${SMTP_SES_PORT}
-      - RELAYHOST_USERNAME=${SMTP_SES_USER}
-      - RELAYHOST_PASSWORD=${SMTP_SES_PASS}
+      - RELAYHOST=[postal_smtp]:25
+      - RELAYHOST_USERNAME=${POSTAL_SMTP_USER}
+      - RELAYHOST_PASSWORD=${POSTAL_SMTP_PASS}
       - ALLOWED_SENDER_DOMAINS=marshallasch.ca road2ir.org dive-tec.ca s-sdiving.com s-sdiving.ca
-      - POSTFIX_always_bcc=audit@audit.marshallasch.ca
-      - POSTFIX_transport_maps=texthash:/etc/postfix/transport
-    volumes:
-      - ./smtp-relay/transport:/etc/postfix/transport:ro
     restart: unless-stopped
```

Add to `.env` (and `env.template`):

```
# Postal SMTP submission credential (used by smtp-relay's RELAYHOST)
POSTAL_SMTP_USER=
POSTAL_SMTP_PASS=
```

Delete `smtp-relay/transport` (no longer used).

In the Postal UI, delete the `archive` mail server and its `Hold` route —
the `outbound` server archives natively, so the BCC pipeline is redundant.

### 2.4 Restart and verify

```bash
docker compose up -d smtp-relay
docker compose exec smtp-relay sh -c '
  printf "From: test@marshallasch.ca\nTo: marshallasch@gmail.com\nSubject: phase 2 test\n\nbody\n" \
    | sendmail -f test@marshallasch.ca marshallasch@gmail.com
'
```

Message should appear under `outbound` → **Messages** with **Sent** status
once SES accepts it. The detail page shows the SES response code and any
bounce/complaint events.

---

## Phase 2.5 (optional) — Migrate apps directly to `postal_smtp`

`smtp-relay` is now just a forwarder. To retire it, point each service
directly at `postal_smtp:25` using a Postal SMTP credential. Recommended:
**create one credential per app** so you can revoke individually and see
per-app usage in Postal's UI.

For each app: change SMTP host/port and add credentials, then `docker
compose up -d <service>` and send a test from the app.

### Per-app manual config table

All apps currently target `smtp-relay:587` with empty credentials. To
migrate, set host → `postal_smtp`, port → `25` (or `587` if you prefer
submission), and add the credentials from a Postal credential.

| App | Compose lines | Env vars to change | Notes |
|---|---|---|---|
| **Luminary** (LDAP UI) | `compose.yaml:497-510` | `SMTP_HOSTNAME`, `SMTP_HOST_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_USE_TLS` | Sends from `no-reply@marshallasch.ca`. Set `SMTP_USE_TLS=TRUE` if using port 587. |
| **Authelia** | `compose.yaml:522-523` | `AUTHELIA_NOTIFIER_SMTP_ADDRESS`, `AUTHELIA_NOTIFIER_SMTP_USERNAME`, `AUTHELIA_NOTIFIER_SMTP_PASSWORD` | Uses URI form: `smtp://postal_smtp:25`. Password file pattern is preferred — add an Authelia `_FILE` env + Docker secret instead of inline. |
| **backup-manager** | `compose.yaml:603-609` | `SMTP_RELAY_HOST`, plus add `SMTP_USER`, `SMTP_PASS` if not already supported (check `backup-manager/` script) | Check whether the script accepts credentials at all; may need a code change. |
| **Mealie** | `compose.yaml:735-738` | `SMTP_HOST`, `SMTP_PORT`, `SMTP_AUTH_STRATEGY`, `SMTP_USER`, `SMTP_PASSWORD` | Change `SMTP_AUTH_STRATEGY=NONE` → `SMTP_AUTH_STRATEGY=PLAIN` (or `LOGIN`) and add credentials. |
| **LubeLogger** | `compose.yaml:774-777` | `MailConfig__EmailServer`, `MailConfig__Port`, `MailConfig__Username`, `MailConfig__Password`, `MailConfig__EnableSsl` | `EnableSsl=true` if using 587. |
| **Gitea** | `compose.yaml:909-914` | `GITEA__mailer__SMTP_ADDR`, `GITEA__mailer__SMTP_PORT`, `GITEA__mailer__USER`, `GITEA__mailer__PASSWD` | Sends from `code@marshallasch.ca` (line 911). |
| **Solidinvoice** | `compose.yaml:954` | `MAILER_DSN` | URI form: `smtp://user:pass@postal_smtp:25`. Symfony-style DSN. |
| **Fills station** (dive) | `compose.yaml:1078-1080` | `SMTP__HOST`, plus add `SMTP__PORT`, `SMTP__USER`, `SMTP__PASS` (check app's env contract) | Currently only `SMTP__HOST` is set — the app may already pull port/credentials from elsewhere; verify before migrating. |
| **Dive-tec website** | `compose.yaml:1106-1110` | `SMTP_HOST`, plus add `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS` | `SMTP_TLS_REJECT_UNAUTHORIZED=false` is currently set — fine for internal cert, but verify with Postal's StartTLS handshake. |
| **Inventory** (road2ir) | `compose.yaml:1141-1142` | `SMTP_HOST`, plus add `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS` | Sends from `inventory@marshallasch.ca` — must be in the `outbound` server's allowed domains in Postal. Domain is `marshallasch.ca`, already added. |

### Additional manual steps

- **Add new env vars to `.env` and `env.template`**: per-app SMTP user/pass
  variables (e.g. `MEALIE_SMTP_USER`, `MEALIE_SMTP_PASS`, …). Keep one
  credential per app for revocability.
- **Retire `smtp-relay`** once all apps are migrated:
  - Remove the `smtp-relay` service block from `compose.yaml`.
  - Remove `smtp_internal` from any service that no longer needs it
    (most don't, but keep it on `postal_smtp` so apps can still talk to
    it on that network).
  - Remove the `smtp-relay/` directory.
  - Remove `SMTP_SES_*` from `.env` and `env.template` (Postal carries
    these now via `postal.yml`).

### Apps that send via `SMTP_FROM` not in compose

A few apps (Mealie, Firefly III when enabled, etc.) store SMTP config in
their own DB instead of (or in addition to) env vars. After flipping the
env vars, log into each app and verify the in-app mail-test feature works.
Apps to double-check this way:

- Mealie → Settings → Email
- Firefly III → System → Configuration (if mail features enabled)
- Authelia uses env-only config; no in-app override.
- Gitea → Site Administration → Configuration → Mailer (env wins, but UI
  shows current values for verification).

---

## Phase 3 — Inbound via Cloudflare Email Workers (separate task)

Constraint: ISP blocks inbound port 25, so we can't accept public SMTP.
Cloudflare Email Routing handles MX duty, and a Worker ships received
messages into Postal.

Two candidate approaches; both need investigation before implementing:

### Option A — Worker → Postal HTTP API

CF Email Worker calls Postal's HTTP submission API (`/api/v1/send/raw`).
That API is outbound-oriented, so we'd need an incoming route in Postal
that catches the recipient and treats it as inbound. Needs a test to
confirm Postal stores it as "received" vs. "sent".

### Option B — Worker → submission on a non-standard port

Expose `postal_smtp` publicly on a non-blocked port (e.g. 2525). Workers
can `forward()` to an email address but cannot speak arbitrary SMTP — so
this requires a small relay in between. More moving parts.

### Deferred decisions

- Which domains accept inbound (`marshallasch.ca`, others?).
- Whether Postal stores inbound permanently or just forwards to a mailbox.
- DNS: CF MX records replace any existing MX for those domains.

---

## Operations

### Where things live

| Thing | Path |
|---|---|
| Postal config | `${CONFIG_VOLUMES}/postal/app/postal.yml` (runtime, hand-edited) |
| Postal DKIM signing key | `${CONFIG_VOLUMES}/postal/app/signing.key` (sensitive — back up) |
| Postal main DB | `${CONFIG_VOLUMES}/postal/db` (MariaDB) |
| Postal message DBs | Same MariaDB instance, schemas `postal-server-N` |
| smtp-relay transport file | `smtp-relay/transport` (Phase 1 only; deleted in Phase 2) |

### Adjusting retention

Postal UI → mail server → **Advanced → Retention**. Tune per server: short
for transactional, long for audit. Message DB grows ~linearly with
retention × throughput.

### Backups

`postal_db` is in scope of `backup-manager` (see
`docs/superpowers/specs/2026-03-21-volume-backup-design.md`). Per-server
message schemas (`postal-server-N`) are in the same instance and get picked
up by `--all-databases`. **Back up `signing.key` separately** — losing it
breaks DKIM continuity for any domain you've published the public key for.

### Common failure modes

| Symptom | Likely cause |
|---|---|
| Postal UI shows messages stuck in "queueing" | `smtp_relays` credentials wrong, or SES sandbox limits |
| Messages reach Postal but never SES | Check `postal_worker` logs; usually `smtp_relays` connection refused or TLS mismatch |
| `smtp-relay` queues with no movement | `postal_smtp` unreachable on `smtp_internal`; verify network membership |
| MariaDB error `Access denied … 'postal-server-1'` | Step 1.4 GRANT not applied |
| BCC arrives, original doesn't | Phase 1 transport map override is too greedy — confirm `transport` file only covers `audit.marshallasch.ca`, not parent domain |
| Mail marked as spam by recipients | Missing SPF/DKIM records on sending domains (Phase 2.1 step 3) |
