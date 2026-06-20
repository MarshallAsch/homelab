/**
 * Cloudflare Email Worker — homelab inbound mail bridge.
 *
 * Bound to a catch-all Email Routing rule for the inbound domains.
 * Reads each raw message and POSTs it to the
 * internal mail-injector over HTTPS, which relays it into Stalwart. This is the
 * only path inbound mail can take, because the ISP blocks inbound port 25.
 *
 * Config:
 *   env.MAILIN_URL            (var)    full URL of the injector endpoint
 *   env.MAILIN_SHARED_SECRET  (secret) must match the injector + .env
 */
export default {
  async email(message, env, ctx) {
    const raw = await new Response(message.raw).arrayBuffer();

    let resp;
    try {
      resp = await fetch(env.MAILIN_URL, {
        method: "POST",
        headers: {
          "Content-Type": "message/rfc822",
          "X-Auth-Token": env.MAILIN_SHARED_SECRET,
          "X-Env-From": message.from,
          "X-Env-To": message.to,
        },
        body: raw,
      });
    } catch (err) {
      // Reject so the sending MTA retries instead of silently losing the mail.
      message.setReject("temporary failure reaching mail server");
      return;
    }

    if (!resp.ok) {
      message.setReject(`mail server returned ${resp.status}`);
    }
  },
};
