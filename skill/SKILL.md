---
name: openclaw-easypanel-fix
description: Diagnose and fix OpenClaw Web Dashboard deployments on Easypanel that are failing with errors like "origin not allowed", "device pairing required", "missing scope operator.admin", "Refusing to bind gateway to lan without auth", "Proxy headers detected from untrusted address", "gateway auth mode is trusted-proxy but a shared token is also configured", or "Service is not reachable" / 404 from the dashboard URL. Use this whenever a user reports their OpenClaw dashboard is unreachable, stuck in a pairing loop, returning 1008 close codes, or failing to start after auth changes — even if they don't name the specific error. Also use it when the user mentions Easypanel + OpenClaw together, or asks for help getting OpenClaw past Traefik.
---

# OpenClaw on Easypanel — diagnostic & fix workflow

OpenClaw's Control UI was designed for loopback access (SSH tunnel, Tailscale Serve). Putting it behind a generic reverse proxy like Easypanel's Traefik is possible but lands in a maze of mutually-exclusive auth modes, undocumented invariants, and silent rejects. The successful path is narrow:

- The gateway must be in `trusted-proxy` auth mode.
- `OPENCLAW_GATEWAY_TOKEN` must NOT be set anywhere — env vars, config file, none.
- `trustedProxies` must contain real CIDRs that cover Easypanel's overlay network.
- The control flow needs both Easypanel's tRPC API (for service-level mutations) and SSH to the Docker host (for `docker exec` into the container, since the panel's web terminal becomes unusable when the contenedor restarts in a loop).

This skill walks through the diagnosis, gathers the right credentials, applies the working configuration, and verifies it end-to-end.

## When this applies

The clearest signals are these error strings appearing in either the browser or the contenedor logs:

- `origin not allowed (… allow it in gateway.controlUi.allowedOrigins)`
- `device pairing required (requestId: …)`
- `unauthorized: gateway token missing`
- `missing scope: operator.admin`
- `Refusing to bind gateway to lan without auth`
- `Proxy headers detected from untrusted address. Connection will not be treated as local.`
- `gateway auth mode is trusted-proxy, but a shared token is also configured`
- `Service is not reachable` from the Easypanel-served error page on the dashboard URL

Any one of these means you're on the path this skill is built for. If the user describes a different OpenClaw symptom (e.g., a specific channel like Telegram failing), this skill is probably the wrong one — the dashboard layer is what we fix here.

## Step 1 — Ask for credentials before touching anything

You need both, and you should ask for them explicitly, with a short note about why each is required:

1. **Easypanel API token** (Bearer). The user gets it from their Easypanel UI or from the `users.generateApiToken` tRPC procedure. Used for service-level operations: create/update services, set env vars, set deploy command, manage mounts and domains, kick redeploys.
2. **SSH access to the Easypanel host** — IP/host plus user (typically `root`) and either a password or a private key. Used for `docker exec`-ing into the OpenClaw container to write the config file, run `openclaw doctor`, force-reset the service replica count, and read Traefik's generated config.

Also ask for the **panel URL** (e.g. `https://<subdomain>.easypanel.host` or the user's custom panel domain) and the **public domain** they want OpenClaw served on.

Do not store these credentials anywhere outside the active session. If the user has a password manager / credentials file pattern (Friday-style memory or similar), suggest they save them there themselves; you read them from there but don't write them.

## Step 2 — Gather diagnostic context

Use both channels in parallel before changing anything. Report findings back as a short summary so the user sees what state things are in.

**Via Easypanel API** (`https://<panel>/api/trpc`, all requests with `Authorization: Bearer <TOKEN>`; queries are GET with `?input=<urlencoded-json>`, mutations are POST with JSON body wrapped in `{"json": …}`):

- `services.app.inspectService` — get the current service definition (image, env, command, mounts, primaryDomainId).
- `domains.listDomains` — verify the public domain is registered and points at the right port.

**Via SSH** to the Docker host:

- `docker service ls | grep openclaw` — is the swarm service even there? Replica count `0/1` means it's failing to start.
- `docker ps --filter name=openclaw` — how many containers are running, are they healthy, how many phantom replicas. More than one almost always means a zero-downtime rollout got stuck.
- `docker logs --tail 60 <container>` — the actual error message that's blocking startup.
- `docker exec <healthy-container> openclaw doctor` — surfaces blocking invariants like "gateway.mode is unset" that are otherwise undocumented.
- `docker exec <healthy-container> cat /home/node/.openclaw/openclaw.json` — current config in the persistent volume.

If there's no healthy contenedor at all, you can still inspect the volume from the host: `cat /var/lib/docker/volumes/openclaw_<service>_config/_data/openclaw.json`.

References:
- `references/easypanel-api.md` — tRPC procedure names, request shapes, and the gotchas (e.g. `mounts.createMount` needing a `values` wrapper, `domains.createDomain` needing the full schema).
- `references/error-decoder.md` — what each error message actually means and the iteration history of every approach that did NOT work, so you don't waste time retrying them.

## Step 3 — Apply the working configuration

This is the configuration that ends the cycle. Each piece matters; skipping any one of them lands you back on a previous error.

**Easypanel service definition** (via API):

- Image: `ghcr.io/openclaw/openclaw:latest` (set with `services.app.updateSourceImage`).
- Command: `node dist/index.js gateway --bind auto --port 18789 --allow-unconfigured` (set with `services.app.updateDeploy` — the body needs a nested `deploy` object with `replicas`, `command`, and `zeroDowntime`).
- `zeroDowntime: false` until the service is stable. Bundled-plugin install on first start takes about 40 seconds; with zero-downtime on, Swarm spawns multiple replicas competing for the same persistent volume and none of them reach "healthy". Once the configuration is settled and validated, you can flip it back to `true` for normal operations.
- Env vars (via `services.app.updateEnv`): only the ones the user needs (LLM provider, API keys, Telegram if used). **Do NOT include `OPENCLAW_GATEWAY_TOKEN`.** Trusted-proxy auth and token auth are mutually exclusive, and an env-var token will silently win and break startup.
- Mounts (via `mounts.createMount`, body shape `{"projectName", "serviceName", "serviceType":"app", "values":{"type":"volume", "name":"<config|workspace>", "mountPath":"…"}}`):
  - `config` → `/home/node/.openclaw`
  - `workspace` → `/home/node/.openclaw/workspace`
- Domain (via `domains.createDomain`, full schema in `references/easypanel-api.md`): public hostname → port 18789 over `http`, `letsencrypt` resolver.

**OpenClaw config inside the container** — write the file directly via `docker exec <container> sh -c 'cat > /home/node/.openclaw/openclaw.json << EOF … EOF'` or apply with `openclaw config patch --stdin`. The minimal working state is:

```json
{
  "gateway": {
    "controlUi": {
      "allowedOrigins": ["https://<your-public-host>"]
    },
    "trustedProxies": ["10.11.0.0/16", "10.0.0.0/8"],
    "auth": {
      "mode": "trusted-proxy",
      "trustedProxy": {
        "userHeader": "x-forwarded-for",
        "allowUsers": [],
        "allowLoopback": true
      }
    }
  }
}
```

Why each line:

- `allowedOrigins` — the gateway rejects WebSocket upgrades whose `Origin` header doesn't match. The public domain has to be listed verbatim, with the scheme.
- `trustedProxies` — Easypanel's overlay network is `10.11.0.0/16` and Docker's wider overlay range is `10.0.0.0/8`. Use real CIDRs. `["0.0.0.0/0"]` looks tempting but the gateway treats it as a misconfiguration and silently ignores it, so requests still appear "untrusted". Your Easypanel install may use different ranges — verify with `docker network inspect easypanel`.
- `auth.mode: trusted-proxy` — when this passes, the gateway treats the request as authorised and (crucially) **bypasses device pairing**. This is the only documented escape from the pairing-required loop for non-loopback access.
- `userHeader: x-forwarded-for` — Traefik in Easypanel's default config emits this header for free. The doc's example uses `x-forwarded-user`, which would require setting up forward-auth in Traefik first.
- `allowUsers: []` — empty allowlist means "any user". Acceptable here because Traefik isn't authenticating users; the public domain is the only access boundary. If the user wants per-user gating, layer Traefik basic-auth or forward-auth on top and tighten this list.
- `allowLoopback: true` — allows requests that ALSO appear loopback-sourced (e.g. CLI commands run from inside the same container) to be treated as trusted, which the diagnostic step relies on.

After patching the config, redeploy via `services.app.deployService`. Then **wait for a single healthy container** before declaring victory. If five containers are competing, run `docker service scale openclaw_<service>=0` followed by `=1` to reset cleanly.

## Step 4 — Verify

A successful state has all five of these:

1. `curl -I https://<public-host>` returns `200 OK` with `Content-Type: text/html` (the dashboard SPA).
2. Browser DevTools → Network shows the `wss://…` WebSocket connection upgrading and staying open.
3. Container logs show `[ws] ⇄ res ✓ health …` and similar lines after the dashboard is opened — those are the dashboard's RPC calls landing successfully.
4. `docker exec <container> openclaw doctor` reports no blocking issues. Warnings about "Plugin registry stale" or "No command owner configured" are non-blocking and can be addressed later.
5. Exactly one container in `docker ps --filter name=openclaw_<service>`.

If all five are true, you're done. Tell the user the dashboard is reachable and recommend they re-enable `zeroDowntime: true` for normal operations once they've used it for a few minutes and confirmed it stays stable.

## Common dead-ends (don't go here)

These are approaches we tried that DON'T work — including them so the skill doesn't waste cycles relitigating them:

- **Setting allowedOrigins via env var.** OpenClaw reads its config from `~/.openclaw/openclaw.json`, not from `OPENCLAW_GATEWAY_*` env vars (a few sub-features use them, but the gateway init does not). Always go through the file.
- **Approving device pairing from the CLI.** `openclaw devices approve` itself requires the CLI to be paired. Chicken and egg. Skip pairing entirely with trusted-proxy mode instead.
- **`auth.mode: none`.** The gateway refuses to bind to non-loopback interfaces with auth disabled. The log line `"gateway.remote.token" is for remote CLI calls; it does not enable local gateway auth.` will appear and the contenedor will restart-loop.
- **Adding a `scopes` array under `gateway.auth`.** That field doesn't exist in the schema; adding it is a config validation error.
- **`trustedProxies: ["0.0.0.0/0"]`.** Silently rejected as a misconfiguration.
- **Keeping `OPENCLAW_GATEWAY_TOKEN` "just in case".** Mutually exclusive with `trusted-proxy`. Remove it from env vars and remove `gateway.auth.token` from the config.

The full chronology of what we tried and why each one failed is in `references/error-decoder.md`. Read it when an error message doesn't match the patterns above, before guessing.

## Notes on credentials and safety

Read credentials from where the user has them; don't write them anywhere new. Don't put real credentials, IPs, hostnames, or org names into reports, summaries, or any file the user might share. Mask values you echo back ("Bearer eyJ…<redacted>"). Easypanel API tokens give full panel access, so accidental leakage is a real incident.
