# SMTP Relay Service Design

## Problem

9 services in the homelab need outbound email capability (7 active, 2 not yet configured). Currently, each service that sends mail is configured with external Brevo SMTP credentials directly. This creates credential sprawl — every service holds the same external secret, and rotating credentials means updating multiple places.

## Solution

Add a centralized SMTP relay service (`boky/postfix`) that acts as the single outbound mail gateway. Internal services connect to the relay without authentication — access is controlled by the `smtp_internal` Docker network (internal-only, no external access). Only the relay holds external Brevo credentials.

## Architecture

```
[gitea, nextcloud, authelia, ldap-user-manager, dive-tec, fill-station, immich_server, lubelogger, solidinvoice]
    → smtp-relay (port 587, no auth, smtp_internal network)
    → smtp-relay.brevo.com:587 (external, STARTTLS, egress network)
```

**Access control**: The `smtp_internal` network is Docker-internal-only. Only services explicitly attached to it can reach the relay. No authentication is needed because no untrusted container can join the network.

## Service Definition

**Image**: `boky/postfix`

**Networks**:
- `smtp_internal` (internal-only) — receives mail from other services
- `egress` — outbound connectivity to Brevo

**No exposed ports** — only reachable via Docker DNS on `smtp_internal`.

**No volumes** — stateless relay. Postfix's built-in mail queue handles transient outbound failures.

**Restart policy**: `unless-stopped`

### Environment Variables

The relay consumes these `boky/postfix` env vars:

| Variable | Purpose | Value |
|----------|---------|-------|
| `RELAYHOST` | Brevo relay host with port | `[${SMTP_HOST}]:${SMTP_PORT}` |
| `RELAYHOST_USERNAME` | Brevo SMTP username | `${SMTP_USER}` |
| `RELAYHOST_PASSWORD` | Brevo SMTP password | `${SMTP_PASS}` |
| `ALLOWED_SENDER_DOMAINS` | Domains permitted to send | `marshallasch.ca road2ir.org dive-tec.ca pigilab.com` |

### env.template Changes

No new env vars needed. The `RELAY_SMTP_USER` / `RELAY_SMTP_PASS` variables from the earlier design are removed since there is no internal auth.

Existing `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS` remain — they are the external Brevo credentials consumed only by the relay.

## Network

New network `smtp_internal` added to the `networks:` section:

```yaml
smtp_internal:
  internal: true
```

## TLS Strategy

- **Internal (services → relay)**: Plain SMTP on port 587, no TLS. The `smtp_internal` network is Docker-internal-only, so traffic never leaves the host.
- **External (relay → Brevo)**: STARTTLS on port 587, handled by Postfix automatically when relaying to `smtp-relay.brevo.com`.

Services that currently set `SMTP_USE_TLS=TRUE` or `smtp+starttls` will switch to plain SMTP since they now talk to the local relay.

## Per-Service Changes

Each mail-sending service is reconfigured to point at `smtp-relay` on port 587 with no authentication. Add `smtp_internal` to each service's network list.

### authelia
- `AUTHELIA_NOTIFIER_SMTP_ADDRESS`: `smtp://smtp-relay:587` (was `smtp://${SMTP_HOST}:${SMTP_PORT}`)
- `AUTHELIA_NOTIFIER_SMTP_USERNAME`: remove or set empty
- Remove `AUTHELIA_NOTIFIER_SMTP_PASSWORD_FILE` reference
- Remove `smtp_password` from the service's `secrets` list
- The `smtp://` scheme (not `submissions://`) is intentional — no STARTTLS for internal connections
- Add `smtp_internal` network

### ldap-user-manager
- `SMTP_HOSTNAME`: `smtp-relay` (was `${SMTP_HOST}`)
- `SMTP_HOST_PORT`: `587` (was `${SMTP_PORT}`)
- `SMTP_USERNAME`: remove or set empty
- `SMTP_PASSWORD`: remove or set empty
- `SMTP_USE_TLS`: `FALSE` (was `TRUE`)
- Add `smtp_internal` network

### gitea
- `GITEA__mailer__PROTOCOL`: `smtp` (was `smtp+starttls`)
- `GITEA__mailer__SMTP_ADDR`: `smtp-relay` (was `${SMTP_HOST}`)
- `GITEA__mailer__SMTP_PORT`: `587` (was `${SMTP_PORT}`)
- `GITEA__mailer__USER`: remove or set empty
- `GITEA__mailer__PASSWD`: remove or set empty
- Add `smtp_internal` network

### nextcloud
- Nextcloud SMTP is configured via admin UI or `config.php`. Set:
  - Mail server: `smtp-relay`
  - Port: `587`
  - Authentication: `None` (no username/password)
  - Encryption: `None`
- Add `smtp_internal` network to the `nextcloud` service in compose

### immich_server
- Immich SMTP is configured via admin UI (Administration → Notifications). Set:
  - SMTP host: `smtp-relay`
  - Port: `587`
  - Authentication: disabled
  - TLS: disabled
- Add `smtp_internal` network to the `immich_server` service in compose
- `immich_ml` does not need SMTP — no changes

### dive-tec
- Not yet configured for email. When adding SMTP support, use:
  - Host: `smtp-relay`, Port: `587`, No auth, No TLS
- Add `smtp_internal` network now so it's ready

### fill-station
- Not yet configured for email. When adding SMTP support, use:
  - Host: `smtp-relay`, Port: `587`, No auth, No TLS
- Add `smtp_internal` network now so it's ready

### lubelogger
- Lubelogger uses `MailConfig__` prefixed env vars:
  - `MailConfig__EmailServer`: `smtp-relay`
  - `MailConfig__Port`: `587`
  - `MailConfig__Username`: (empty string)
  - `MailConfig__Password`: (empty string)
  - `MailConfig__EnableSsl`: `false`
- Add `smtp_internal` network

### solidinvoice
- SolidInvoice 2.x uses Symfony Mailer with `MAILER_DSN`:
  - `MAILER_DSN`: `smtp://smtp-relay:587`
- This env var needs to be added to the solidinvoice service definition in compose (not currently present)
- Add `smtp_internal` network

## Docker Secret Update

The `smtp_password` secret (compose line 1121-1122) is no longer needed by any service — Authelia no longer uses a password file for SMTP auth. The secret can be removed from the `secrets:` section and from Authelia's `secrets` list.

The `SMTP_PASS` env var remains — it's consumed directly by the relay service for Brevo outbound auth.

## Services NOT Changed

- **wrapped (wrapperr)**: Does not send email. No changes needed.
- **firefly**: Does not send email in this deployment. No changes needed.
- **Postal**: Unrelated full mail server (runs by default, no profile). No changes needed.
- **DIUN**: Uses Discord webhooks, not email. No changes needed.

## Failure Modes

- **Relay down**: Services fail to send mail until the relay restarts. Acceptable for homelab.
- **Brevo outage**: Postfix queues mail internally and retries automatically.
- **Misconfigured service**: Service can't reach relay. Check it's on `smtp_internal` network.
