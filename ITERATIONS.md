# Iterations — every step we tried, in order

Reference for matching your error to ours. Each section names the symptom, the action we took, what we observed, and what we learned. Read the ones whose error message matches yours.

---

## Iteration 1 — `origin not allowed`

**Symptom (browser):**
> `origin not allowed (open the Control UI from the gateway host or allow it in gateway.controlUi.allowedOrigins)`

**Hypothesis:** missing the public dominio in the allowlist.

**Tried:**
- Set env var `GATEWAY_CONTROL_UI_ALLOWED_ORIGINS=*` in Easypanel.
- Then `OPENCLAW_GATEWAY_CONTROLUI_ALLOWEDORIGINS=["https://openclaw.example.com"]`.
- Then `OPENCLAW_GATEWAY_BIND=auto`, removed `GATEWAY_MODE=local`.

**Result:** none worked. The error stayed.

**Learning:** OpenClaw config is a **JSON5 file**, not env vars. The names like `OPENCLAW_GATEWAY_*` are read by some sub-features but not the gateway init proper. The canonical path is `~/.openclaw/openclaw.json` with `gateway.controlUi.allowedOrigins`.

---

## Iteration 2 — config file persistence

**Tried:** wrote the JSON file directly inside the container (heredoc into `~/.openclaw/openclaw.json`).

**Result:** the change applied (logs showed the new origin), then disappeared on the next restart.

**Learning:** the `config` volume mount **does** persist the file, *but* OpenClaw normalises and rewrites the file at startup, dropping fields it doesn't recognise (or that conflict with auto-config). Use `openclaw config patch --stdin` or `openclaw config set <path> <value>` instead — they go through schema validation and survive the restart.

---

## Iteration 3 — `device pairing required`

**Symptom (browser, after origin was fixed):**
> `device pairing required (requestId: <uuid>)`

**Hypothesis:** approve the pairing from the CLI.

**Tried:**
```bash
openclaw devices approve <requestId>
```

**Result:** the command failed:
> `pair is a runtime slash command (/pair), not a CLI command. Use /pair in a chat session.`

**Learning:** the docs are wrong. The CLI command is `openclaw devices approve <id>`, not `openclaw pair approve`. (The slash command `/pair` exists separately for chat channels like Telegram.)

---

## Iteration 4 — CLI can't reach the gateway

**Tried:**
```bash
openclaw devices approve --latest --url ws://$(hostname -i):18789 --token <T>
```

**Result:** `Gateway closed (1006 abnormal closure)`.

Then:
```bash
openclaw devices approve --latest --url ws://127.0.0.1:18789 --token <T>
```

**Result:** worked — the gateway responded — but only when bind was `loopback` or `auto`. With `bind: lan`, loopback wasn't bound at all.

**Learning:** `--bind auto` listens on `0.0.0.0` (all interfaces), so loopback works too. `--bind lan` skips loopback. The CLI inside the container needs *some* listening interface; loopback is the simplest.

---

## Iteration 5 — `OPENCLAW_ALLOW_INSECURE_PRIVATE_WS`

**Symptom:**
> `SECURITY ERROR: Gateway URL "ws://10.x.x.x" uses plaintext ws:// to a non-loopback address`

**Tried:** prefixed env: `OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=1`.

**Result:** the security check passed, the connection attempt continued.

**Learning:** when connecting CLI→gateway across a non-loopback IP without TLS, you must opt in. Documented in the runtime warning, not in any guide.

---

## Iteration 6 — `gateway connect failed: device pairing` (the loop)

**Tried:** `openclaw devices approve <requestId> --url ws://127.0.0.1:18789 --token <T>` from inside the container.

**Result:**
> `gateway connect failed: GatewayClientRequestError: device pairing`

**Learning:** the **CLI itself** needs to be paired before it can approve a pairing. Classic chicken-and-egg. Every documented approval path assumed the CLI was already trusted by the gateway, which fresh installs aren't.

---

## Iteration 7 — `missing scope: operator.admin`

**Symptom:** got past the auth, hit:
> `Failed to start CLI: GatewayClientRequestError: missing scope: operator.admin`

**Tried:** `openclaw config set gateway.auth.scopes '["operator.admin", …]'`

**Result:** `Config validation failed: gateway.auth: Unrecognized key: 'scopes'`. Field doesn't exist in the schema.

**Learning:** scopes are not configurable per-token via the file. OpenClaw has a "localhost trust assumption" — only **127.0.0.1 connections** automatically receive operator scopes. Any other source needs **trusted-proxy mode** to get admin scope without device pairing. Searched the GitHub issue tracker (#17608) to find this — the docs don't say it.

---

## Iteration 8 — `gateway.mode is unset`

**Tried:** ran `openclaw doctor`. It reported:
> `gateway.mode is unset; gateway start will be blocked.`

**Tried:** `openclaw config set gateway.mode remote`

**Result:** `Updated gateway.mode. Restart the gateway to apply.`

**Learning:** `gateway.mode` (`local` | `remote`) is a separate, undocumented invariant. `local` keeps you on loopback only; `remote` allows the gateway to bind to interfaces reachable from outside. Without it set, the doctor blocks startup with a vague error. Always run `openclaw doctor` first when stuck.

---

## Iteration 9 — `auth.mode: none` won't bind

**Tried:** disable auth entirely: `openclaw config set gateway.auth.mode none`.

**Result, in logs:**
> `auth mode=none explicitly configured; all gateway connections are unauthenticated.`
> `Refusing to bind gateway to lan without auth.`
> `"gateway.remote.token" is for remote CLI calls; it does not enable local gateway auth.`

**Learning:** OpenClaw refuses to start with `auth.mode: none` AND a non-loopback bind, *unless* you provide a token/password via env or CLI flag. The auto-emitted log line above is the cleanest summary of OpenClaw's auth contract — quote it back to anyone who tells you "just turn off auth".

Also: `gateway.remote.token` ≠ `gateway.auth.token`. The first is what *clients* send. The second is what the *server* validates. They have to match if you want token auth, but **neither** of them disables auth.

---

## Iteration 10 — `Service is not reachable`

**Symptom:** Easypanel started showing the cute "Service is not reachable" page even though earlier the dashboard at least loaded.

**Cause:** the gateway entered a restart loop after a misconfiguration, Easypanel's health check failed enough times that Docker Swarm pulled the task out of the routing mesh. Traefik had no backend to send to.

**Fix:** check the **logs** in Easypanel (icon □ at the top) before changing anything else. If you see `Refusing to bind…` or `Invalid config…`, the new contenedor is not arriving at "ready". Roll back the last config change.

---

## Iteration 11 — switching to `auth.mode: trusted-proxy`

This is the working setup. Critical pieces:

```json
{
  "gateway": {
    "controlUi": {
      "allowedOrigins": ["https://openclaw.example.com"]
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

**Trap 1: CIDR ranges in `trustedProxies` actually have to be valid.** We tried `["0.0.0.0/0"]` (all IPs) — the gateway still rejected requests with:
> `Proxy headers detected from untrusted address. Connection will not be treated as local.`

Why: OpenClaw treats `0.0.0.0/0` as a misconfiguration (it would defeat the whole trust model) and silently ignores it. Use the actual private CIDRs of your overlay networks. Easypanel's default Swarm overlay is `10.11.0.0/16`; the global Docker overlay range is `10.0.0.0/8`.

**Trap 2: `gateway.auth.token` and `auth.mode: trusted-proxy` are mutually exclusive.** We left the token from a previous iteration. Logs:
> `gateway auth mode is trusted-proxy, but a shared token is also configured; remove gateway.auth.token / OPENCLAW_GATEWAY_TOKEN because trusted-proxy and token auth are mutually exclusive`

You **must remove `OPENCLAW_GATEWAY_TOKEN` from the Easypanel environment variables** as well. Easypanel reads them as process env, which OpenClaw picks up in addition to the file.

**Trap 3: `userHeader` needs a header Traefik actually emits.** Traefik in default mode passes `x-forwarded-for`. If you set `userHeader: x-forwarded-user` (the doc's recommendation) without configuring forward-auth in Traefik, every request fails because the header is absent.

**Trap 4: zero-downtime rollouts make this 10× harder.** Every redeploy spins a new container that takes ~2 minutes to install bundled plugins. While it's installing, the old container is still serving. If the new one is *also* unhealthy, Swarm spins yet another. We saw 5 simultaneous tasks competing for the same volume — config writes from the new ones overwrote the old, but none reached "ready". 

Fix: temporarily set `zeroDowntime: false` on the service, then `docker service scale openclaw_openclaw-gateway=0`, then `=1`. Single clean replacement.

---

## What we learned about Easypanel

- Service definitions live in Easypanel's database, not in Docker Swarm directly. Recreating the service via API regenerates Traefik config in `/etc/easypanel/traefik/config/main.yaml` (a single file with all routers and services for all projects). If you don't see your domain there after creating it via API, the rollout to Traefik hasn't run yet.
- Domains require the full schema on creation: `id`, `host`, `https`, `path`, `middlewares`, `certificateResolver`, `wildcard`, `destinationType`, and a nested `serviceDestination` object with its own `protocol` field. Missing any field returns a Zod validation error with the exact field name.
- `services.app.deployService` kicks the rollout but does NOT regenerate Traefik labels on its own. The service-creation flow does it implicitly. If you `updateEnv` and redeploy and your domain stops working, the labels were not regenerated — workaround: edit the domain (any field) to force a Traefik regen.

---

## What we learned about OpenClaw

- The bundled-plugin install on first start is **slow** (~40 seconds) and runs every time a new container starts (it's per-container, not per-volume). This breaks naive zero-downtime configs and Easypanel's default health-check window.
- `openclaw doctor` is the **only** reliable way to surface "blocking invariants" like `gateway.mode is unset`. Run it before changing anything.
- The Telegram channel will spam `getUpdates conflict` 409s any time more than one container has the same `TELEGRAM_BOT_TOKEN`. This is **not** a problem for the dashboard — but it generates a lot of log noise during rollouts. Single-replica services with Telegram enabled need clean transitions.
- The browser dashboard at `/` connects via WebSocket to `/ws/...` (same host). You don't need to open a separate port. Traefik with default WebSocket support is enough; no `traefik.http.services.X.loadbalancer.server.scheme=http` is needed.

---

## Closing checklist for "did the dashboard come up?"

1. `curl -I https://your-openclaw.example.com` returns `200 OK` and `Content-Type: text/html`. (HTML page is the dashboard SPA.)
2. Browser DevTools → Network → `wss://…` connection upgrades to WebSocket and stays open.
3. Server logs show `[ws] ⇄ res ✓ health` lines after you open the page.
4. `openclaw doctor` from inside the container reports zero blocking issues (warnings about Plugin registry / Command owner are non-blocking).
5. Only **one** container in `docker ps --filter name=openclaw_openclaw-gateway` after the rollout settles.

If all five are green, you're done. Welcome to the small club of people who got OpenClaw working on Easypanel without giving up.
