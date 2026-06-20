# Cloudflare Email Worker — inbound mail bridge

Pulls inbound mail into the homelab despite the ISP blocking inbound port 25.
Cloudflare is the MX (via Email Routing); this Worker reads each message and
POSTs it to the `mail-injector` service, which relays it into Stalwart.

## Deploy

Requires the `wrangler` CLI and a Cloudflare account with the zones added.

```bash
cd cf-email-worker

# 1. Set the shared secret (must match MAILIN_SHARED_SECRET in the homelab .env)
npm exec wrangler secret put MAILIN_SHARED_SECRET

# 2. Publish the worker
npm exec wrangler deploy
```

## Wire up Email Routing (per inbound domain)

In the Cloudflare dashboard, for each inbound domain:

1. **Email → Email Routing → Enable**, accept the MX/SPF records Cloudflare adds.
2. **Routing rules → Catch-all address → Action: Send to a Worker →**
   `homelab-mail-inbound`.

After this, mail to any address at those domains flows:
`sender → Cloudflare MX → this Worker → https://mail.<domain>/_inject → Stalwart`.

## Notes

- On any failure reaching the injector (or a non-2xx response) the Worker calls
  `message.setReject(...)`, so the sending MTA retries — mail is never silently
  dropped.
- Keep the handler minimal (stream body straight through) to stay within the
  Workers Free CPU limit (10 ms/invocation). Move to Workers Paid ($5/mo) only if
  large attachments start exceeding it.
- `MAILIN_URL` points at one injector (`mail.<your-domain>/_inject`) for all inbound
  domains — the injector relays by envelope recipient and Stalwart handles each
  domain.
