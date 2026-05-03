# Error decoder — what each message means and what NOT to do

Read this when an error message doesn't match the canonical fix in `SKILL.md`. Each entry says what the error actually means, what people commonly try (and why it doesn't work), and what the right move is.

---

## `origin not allowed (open the Control UI from the gateway host or allow it in gateway.controlUi.allowedOrigins)`

**Meaning:** the WebSocket upgrade request's `Origin` header doesn't match any entry in `gateway.controlUi.allowedOrigins`.

**Common dead-end:** setting `OPENCLAW_GATEWAY_CONTROLUI_ALLOWEDORIGINS` (or any other `OPENCLAW_GATEWAY_*` env var) in the panel. The gateway init does not read these for origin allowlisting.

**Right move:** add the public domain (with scheme) to the JSON config file at `/home/node/.openclaw/openclaw.json`, key `gateway.controlUi.allowedOrigins`. Restart the gateway. Use `openclaw config set gateway.controlUi.allowedOrigins '["https://your-host"]'` or `openclaw config patch --stdin` to make sure it goes through schema validation.

---

## `device pairing required (requestId: <uuid>)`

**Meaning:** the gateway has a `device-pair` plugin that requires every WS client to be approved before it can talk to the gateway. New origins (any time you open the dashboard from a fresh browser) trigger a new pairing request.

**Common dead-end #1:** `openclaw pair approve <id>`. The CLI tells you `pair is a runtime slash command`. Wrong syntax.

**Common dead-end #2:** `openclaw devices approve <id>`. The right syntax — but it requires the CLI itself to be paired first, and a fresh deployment has no paired CLI. Chicken and egg.

**Common dead-end #3:** `openclaw devices approve <id> --url ws://localhost:18789 --token <T>`. The CLI connects, opens a WS, but the gateway closes it because the CLI's role hasn't been approved either. Same loop, one level deeper.

**Right move:** skip pairing entirely. Switch the gateway to `auth.mode: trusted-proxy`. When trusted-proxy auth passes (request comes from a trusted IP), device pairing is bypassed for Control UI WebSocket access. This is the documented escape from the loop.

---

## `unauthorized: gateway token missing`

**Meaning:** the dashboard is connecting via WS but isn't sending a token, OR the token it's sending doesn't match `gateway.auth.token`.

**Common dead-end:** setting `gateway.remote.token` to match `gateway.auth.token`. The contenedor logs explain why this doesn't help: `"gateway.remote.token" is for remote CLI calls; it does not enable local gateway auth.` It's the credential the CLI uses *outbound* when connecting to a remote gateway, not the credential the dashboard uses.

**Right move:** drop token auth entirely if you're going trusted-proxy. If you really want token auth, the dashboard's "paste your token" UI sends the token correctly — but without device pairing, the connection still fails because the role isn't approved. Trusted-proxy is the cleaner path.

---

## `missing scope: operator.admin`

**Meaning:** the connection authenticated, but the role's scope set doesn't include `operator.admin`, which is needed for the admin operations the dashboard tries to perform on first connect.

**Common dead-end:** `openclaw config set gateway.auth.scopes '["operator.admin", …]'`. Returns a Zod validation error: `Unrecognized key: 'scopes'`. The schema doesn't have a per-token scopes field.

**Why it happens:** OpenClaw has a "localhost trust assumption" — only connections from `127.0.0.1` automatically receive operator scopes. Token-mode connections from any non-loopback source get a default scope set that excludes admin operations.

**Right move:** trusted-proxy auth grants the full operator scope set when the source IP is in `trustedProxies`. This is the only way to get admin from outside loopback without manual pairing.

---

## `Refusing to bind gateway to lan without auth.`

**Meaning:** the gateway will not expose itself to anything other than loopback when `auth.mode` is `none` (or unset). It refuses to start.

**Common dead-end:** trying to run with `auth.mode: none` "just to test" the rest of the stack. It won't bind, the contenedor restart-loops, Traefik shows "Service is not reachable". You learn nothing.

**Right move:** set `auth.mode` to `trusted-proxy` (preferred for reverse-proxy setups) or `token` (with a token configured). Don't try to disable auth. The accompanying log line `Set OPENCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_PASSWORD, or pass --token/--password to start with auth.` is OpenClaw telling you what it's actually willing to accept.

---

## `Proxy headers detected from untrusted address. Connection will not be treated as local.`

**Meaning:** the request reached the gateway through what looks like a proxy (`X-Forwarded-*` headers present), but the immediate peer's IP is not in `gateway.trustedProxies`. The gateway will refuse to honour the forwarded identity.

**Common dead-end:** `trustedProxies: ["0.0.0.0/0"]`. The gateway treats this as a misconfiguration (it would defeat the trust model entirely) and silently ignores it, so requests still fail as untrusted. There's no error about the bad CIDR — the misconfig is just unused.

**Right move:** put real, narrow CIDR ranges in `trustedProxies`. For Easypanel's default setup, `["10.11.0.0/16", "10.0.0.0/8"]` covers the overlay networks Traefik runs in. Verify with `docker network inspect easypanel` from SSH.

---

## `gateway auth mode is trusted-proxy, but a shared token is also configured; remove gateway.auth.token / OPENCLAW_GATEWAY_TOKEN because trusted-proxy and token auth are mutually exclusive`

**Meaning:** exactly what it says. Trusted-proxy and token auth are mutually exclusive; you can't have both partially configured.

**Common dead-end:** removing only `gateway.auth.token` from the JSON config but leaving `OPENCLAW_GATEWAY_TOKEN` set in the Easypanel env vars. The env var still applies and the contenedor still refuses to start.

**Right move:** clean up both:
1. Remove `OPENCLAW_GATEWAY_TOKEN` from the service's env vars in Easypanel.
2. Remove `gateway.auth.token` from the JSON config (`openclaw config set gateway.auth.token null` or omit the key in your patch).
3. Redeploy.

---

## `Service is not reachable. Make sure the service is running and healthy.`

**Meaning:** Easypanel's Traefik couldn't reach a healthy backend for the public domain. Either there's no running container, or all containers are unhealthy, or Traefik's config doesn't have the domain.

**Common dead-end:** clicking "Implement" repeatedly. Each click adds another phantom replica to a stuck rollout. After three retries you have five containers competing for the same volume, none reaching "ready", all failing the health check.

**Right move:** open the contenedor logs (Easypanel UI → service → log icon, or `docker logs <container>` via SSH) and read the actual startup error. Usually it's an `Invalid config` or `Refusing to bind` line — fix that, then before redeploying, set `zeroDowntime: false` and run `docker service scale <svc>=0; docker service scale <svc>=1` to force a clean single-replica restart.

---

## `gateway.mode is unset; gateway start will be blocked.` (from `openclaw doctor`)

**Meaning:** an undocumented invariant. `gateway.mode` (`local` | `remote`) is required for the gateway to start. `local` keeps it loopback-only. `remote` allows non-loopback bind. Without it set, doctor blocks startup.

**Right move:** `openclaw config set gateway.mode remote` for any reverse-proxy setup. Always run `openclaw doctor` first when stuck — it surfaces invariants that the runtime errors don't always make obvious.

---

## Five containers running, none healthy, "health: starting" for everyone

**Meaning:** zero-downtime rollouts plus slow plugin install (~40s on first start) plus health checks that fire too quickly mean Swarm thinks every new task is failing and spins up replacements. Within 2-3 minutes you have multiple replicas all writing to the same persistent volume.

**Right move:**

```bash
# Stop the rollout cascade
docker service scale openclaw_<svc>=0
# Wait until docker ps shows zero containers
docker service scale openclaw_<svc>=1
# Now exactly one task starts. Wait for it to go healthy.
```

Set `zeroDowntime: false` in the service definition (via `services.app.updateDeploy`) until the configuration is stable. Re-enable it once the dashboard is reachable and you've confirmed it stays up across a manual redeploy.

---

## Telegram `getUpdates conflict 409` spamming the logs

**Meaning:** more than one process is polling Telegram with the same bot token. Common during rollovers when both the old and new contenedor are alive briefly.

**Right move:** ignore unless it persists after the rollover settles. If it persists, you have either two services with the same `TELEGRAM_BOT_TOKEN` or a leftover process somewhere. The dashboard works regardless of this — it's a separate channel.

---

## When the symptom doesn't match anything above

Read the most recent 60 lines of contenedor logs and look for the line immediately before "starting..." or "ready". Most blocking errors print a one-line summary right before the contenedor falls back. The traceback is often noise; the human-language line above it is the real diagnosis.

If the logs are clean but the dashboard still doesn't load, check Traefik:

```bash
grep -A 3 '<your-host>' /etc/easypanel/traefik/config/main.yaml
```

If your domain isn't in `main.yaml`, Traefik doesn't know about it. Re-create the domain via the API; an `updateDeploy` alone doesn't always trigger a Traefik regen.
