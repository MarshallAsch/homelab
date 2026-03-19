# SMTP Relay Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a centralized `boky/postfix` SMTP relay to the Docker Compose homelab, replacing per-service Brevo credentials with network-level isolation.

**Architecture:** A new `smtp-relay` service on `smtp_internal` + `egress` networks relays all outbound mail through Brevo. 9 services join `smtp_internal` and point their SMTP config at the relay hostname. No internal auth — access controlled by Docker network isolation.

**Tech Stack:** Docker Compose, boky/postfix, Postfix

**Spec:** `docs/superpowers/specs/2026-03-19-smtp-relay-design.md`

---

### Task 1: Add smtp_internal network

**Files:**
- Modify: `compose.yaml:1135-1156` (networks section)

- [ ] **Step 1: Add the network definition**

Add `smtp_internal` to the networks section, after `unifi`:

```yaml
  smtp_internal:
    internal: true
```

Insert between line 1155 (`internal: true` under `unifi`) and line 1156 (`egress: {}`).

- [ ] **Step 2: Validate compose file**

Run: `docker compose config --quiet`
Expected: No output (valid config)

- [ ] **Step 3: Commit**

```bash
git add compose.yaml
git commit -m "feat: add smtp_internal network for centralized mail relay"
```

---

### Task 2: Add smtp-relay service

**Files:**
- Modify: `compose.yaml` (add new service after the `ddclient` service, before the Support Services section)

- [ ] **Step 1: Add the smtp-relay service definition**

Add this service block. Place it in the Core Services area (after `ddclient`, around line 544, before the `######################################################` Support Services comment):

```yaml
  smtp-relay:
    image: boky/postfix
    networks:
      - smtp_internal
      - egress
    environment:
      - RELAYHOST=[${SMTP_HOST}]:${SMTP_PORT}
      - RELAYHOST_USERNAME=${SMTP_USER}
      - RELAYHOST_PASSWORD=${SMTP_PASS}
      - ALLOWED_SENDER_DOMAINS=marshallasch.ca road2ir.org dive-tec.ca pigilab.com
    restart: unless-stopped
```

- [ ] **Step 2: Validate compose file**

Run: `docker compose config --quiet`
Expected: No output (valid config)

- [ ] **Step 3: Commit**

```bash
git add compose.yaml
git commit -m "feat: add smtp-relay service using boky/postfix for centralized outbound mail"
```

---

### Task 3: Reconfigure authelia to use the relay

**Files:**
- Modify: `compose.yaml:483-507` (authelia service)
- Modify: `compose.yaml:1118-1128` (secrets section)

- [ ] **Step 1: Update authelia environment and networks**

In the `authelia` service (line 483):

1. Add `smtp_internal` to the networks list (after `authelia_internal`):
```yaml
    networks:
      - plex_internal
      - egress
      - authelia_internal
      - smtp_internal
```

2. Replace SMTP env vars (lines 491-492, 494):
```yaml
      AUTHELIA_NOTIFIER_SMTP_USERNAME: ""
      AUTHELIA_NOTIFIER_SMTP_ADDRESS: "smtp://smtp-relay:587"
```
Remove the line: `AUTHELIA_NOTIFIER_SMTP_PASSWORD_FILE: '/run/secrets/smtp_password'`

3. Remove `smtp_password` from the secrets list (line 503):
```yaml
    secrets:
      - ldap_admin_password
      - oidc_hmac
      - session_secret
      - reset_secret
```

- [ ] **Step 2: Remove the smtp_password secret definition**

Remove lines 1121-1122 from the top-level `secrets:` section:
```yaml
  smtp_password:
    environment: "SMTP_PASS"
```

- [ ] **Step 3: Validate compose file**

Run: `docker compose config --quiet`
Expected: No output (valid config)

- [ ] **Step 4: Commit**

```bash
git add compose.yaml
git commit -m "feat: point authelia SMTP at internal relay, remove smtp_password secret"
```

---

### Task 4: Reconfigure ldap-user-manager to use the relay

**Files:**
- Modify: `compose.yaml:446-481` (ldap-user-manager service)

- [ ] **Step 1: Update networks and SMTP env vars**

1. Add `smtp_internal` to the networks list:
```yaml
    networks:
      - authelia_internal
      - plex_internal
      - smtp_internal
```

2. Replace SMTP env vars (lines 469-473):
```yaml
      SMTP_HOSTNAME: smtp-relay
      SMTP_HOST_PORT: "587"
      SMTP_USERNAME: ""
      SMTP_PASSWORD: ""
      SMTP_USE_TLS: "FALSE"
```

- [ ] **Step 2: Validate compose file**

Run: `docker compose config --quiet`
Expected: No output (valid config)

- [ ] **Step 3: Commit**

```bash
git add compose.yaml
git commit -m "feat: point ldap-user-manager SMTP at internal relay"
```

---

### Task 5: Reconfigure gitea to use the relay

**Files:**
- Modify: `compose.yaml:737-772` (gitea service)

- [ ] **Step 1: Update networks and mailer env vars**

1. Add `smtp_internal` to the networks list:
```yaml
    networks:
      gitea_internal: {}
      authelia_internal: {}
      smtp_internal: {}
      lab_net:
        ipv4_address: ${SUBNET}.208
```

2. Replace mailer env vars (lines 760-764):
```yaml
      - GITEA__mailer__PROTOCOL=smtp
      - GITEA__mailer__SMTP_ADDR=smtp-relay
      - GITEA__mailer__SMTP_PORT=587
      - GITEA__mailer__USER=
      - GITEA__mailer__PASSWD=
```

- [ ] **Step 2: Validate compose file**

Run: `docker compose config --quiet`
Expected: No output (valid config)

- [ ] **Step 3: Commit**

```bash
git add compose.yaml
git commit -m "feat: point gitea mailer at internal relay"
```

---

### Task 6: Add smtp_internal network to nextcloud

**Files:**
- Modify: `compose.yaml:627-643` (nextcloud service)

- [ ] **Step 1: Add smtp_internal to networks**

```yaml
    networks:
      - internal
      - ingress
      - egress
      - authelia_internal
      - smtp_internal
```

Note: Nextcloud SMTP is configured via admin UI, not env vars. The network addition allows it to reach the relay. After deploying, configure SMTP in the Nextcloud admin UI:
- Mail server: `smtp-relay`
- Port: `587`
- Authentication: None
- Encryption: None

- [ ] **Step 2: Validate compose file**

Run: `docker compose config --quiet`
Expected: No output (valid config)

- [ ] **Step 3: Commit**

```bash
git add compose.yaml
git commit -m "feat: add smtp_internal network to nextcloud for relay access"
```

---

### Task 7: Add smtp_internal network to immich_server

**Files:**
- Modify: `compose.yaml:662-684` (immich_server service)

- [ ] **Step 1: Add smtp_internal to networks**

```yaml
    networks:
      - immich_internal
      - egress
      - smtp_internal
```

Note: Immich SMTP is configured via admin UI (Administration > Notifications). After deploying, set:
- SMTP host: `smtp-relay`
- Port: `587`
- Authentication: disabled
- TLS: disabled

- [ ] **Step 2: Validate compose file**

Run: `docker compose config --quiet`
Expected: No output (valid config)

- [ ] **Step 3: Commit**

```bash
git add compose.yaml
git commit -m "feat: add smtp_internal network to immich_server for relay access"
```

---

### Task 8: Reconfigure lubelogger to use the relay

**Files:**
- Modify: `compose.yaml:645-660` (lubelogger service)

- [ ] **Step 1: Add smtp_internal network and mail config env vars**

1. Add `smtp_internal` to the networks list:
```yaml
    networks:
      - plex_internal
      - internal
      - smtp_internal
```

2. Add mail config env vars to the environment list (after `- TZ`):
```yaml
      - MailConfig__EmailServer=smtp-relay
      - MailConfig__Port=587
      - MailConfig__Username=
      - MailConfig__Password=
      - MailConfig__EnableSsl=false
```

- [ ] **Step 2: Validate compose file**

Run: `docker compose config --quiet`
Expected: No output (valid config)

- [ ] **Step 3: Commit**

```bash
git add compose.yaml
git commit -m "feat: configure lubelogger SMTP to use internal relay"
```

---

### Task 9: Reconfigure solidinvoice to use the relay

**Files:**
- Modify: `compose.yaml:774-785` (solidinvoice service)

- [ ] **Step 1: Add smtp_internal network and MAILER_DSN env var**

1. Replace the networks list:
```yaml
    networks:
      - ingress
      - smtp_internal
```

Note: `egress` is removed — solidinvoice only needed it for SMTP, which now goes through the relay.

2. Add `MAILER_DSN` to the environment list:
```yaml
    environment:
      - PUID
      - PGID
      - TZ
      - MAILER_DSN=smtp://smtp-relay:587
```

- [ ] **Step 2: Validate compose file**

Run: `docker compose config --quiet`
Expected: No output (valid config)

- [ ] **Step 3: Commit**

```bash
git add compose.yaml
git commit -m "feat: configure solidinvoice SMTP to use internal relay"
```

---

### Task 10: Add smtp_internal network to fill-station and dive-tec

**Files:**
- Modify: `compose.yaml:866-887` (fill-station service)
- Modify: `compose.yaml:888-911` (dive-tec service)

- [ ] **Step 1: Add smtp_internal to fill-station networks**

```yaml
    networks:
      - ingress
      - internal
      - egress
      - smtp_internal
```

- [ ] **Step 2: Add smtp_internal to dive-tec networks**

```yaml
    networks:
      - ingress
      - internal
      - egress
      - smtp_internal
```

Note: Neither service has SMTP env vars yet. The network is added now so they're ready when email support is configured in those apps.

- [ ] **Step 3: Validate compose file**

Run: `docker compose config --quiet`
Expected: No output (valid config)

- [ ] **Step 4: Commit**

```bash
git add compose.yaml
git commit -m "feat: add smtp_internal network to fill-station and dive-tec for future email support"
```

---

### Task 11: Final validation

**Files:**
- Read: `compose.yaml` (full file)

- [ ] **Step 1: Validate full compose file**

Run: `docker compose config --quiet`
Expected: No output (valid config)

- [ ] **Step 2: Verify smtp-relay service exists and has correct config**

Run: `docker compose config --format json | jq '.services["smtp-relay"]'`
Expected: Service definition with `boky/postfix` image, `smtp_internal` and `egress` networks, and the RELAYHOST/RELAYHOST_USERNAME/RELAYHOST_PASSWORD/ALLOWED_SENDER_DOMAINS env vars.

- [ ] **Step 3: Verify all 9 services are on smtp_internal**

Run: `docker compose config --format json | jq '[.services | to_entries[] | select(.value.networks | keys | any(. == "smtp_internal")) | .key] | sort'`
Expected: `["authelia", "dive-tec", "fill-station", "gitea", "immich_server", "ldap-user-manager", "lubelogger", "nextcloud", "smtp-relay", "solidinvoice"]` (10 services including the relay itself)

- [ ] **Step 4: Verify no service references SMTP_HOST/SMTP_USER/SMTP_PASS directly (except smtp-relay)**

Run: `docker compose config --format json | jq '[.services | to_entries[] | select(.key != "smtp-relay") | select(.value.environment // {} | to_entries | any(.value | tostring | test("SMTP_HOST|SMTP_USER|SMTP_PASS|SMTP_PORT"))) | .key]'`
Expected: Empty array `[]` — no service other than smtp-relay should reference external Brevo credentials.

- [ ] **Step 5: Verify smtp_password secret is removed**

Run: `docker compose config --format json | jq '.secrets.smtp_password // "removed"'`
Expected: `"removed"`

- [ ] **Step 6: Commit (if any fixups were needed)**

```bash
git add compose.yaml
git commit -m "fix: address any issues found during final validation"
```
