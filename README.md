# OpenClaw on Easypanel — Fix Guide

A debugged, end-to-end recipe for deploying **OpenClaw** behind **Traefik** on **Easypanel**, plus a Claude Code skill that walks an AI agent through the same fix automatically.

This repo exists because getting OpenClaw to expose its Web Dashboard via a public domain on Easypanel is a *minefield* of conflicting auth modes, undocumented schema fields, and silent rejects. We hit every trap. This is the working configuration after 50+ iterations.

---

## What problem this solves

You deployed OpenClaw on Easypanel. You added a domain. You opened the Dashboard at `https://your-openclaw.example.com` and got, in sequence:

1. `origin not allowed (… allow it in gateway.controlUi.allowedOrigins)`
2. `device pairing required (requestId: …)`
3. `unauthorized: gateway token missing`
4. `Service is not reachable`
5. `Refusing to bind gateway to lan without auth`
6. `missing scope: operator.admin`
7. `Proxy headers detected from untrusted address`
8. `gateway auth mode is trusted-proxy, but a shared token is also configured`

Every error fix triggered the next one. This guide ends the loop.

---

## TL;DR — the working setup

**Easypanel side** (managed via API or UI):
- Image: `ghcr.io/openclaw/openclaw:latest`
- Command: `node dist/index.js gateway --bind auto --port 18789 --allow-unconfigured`
- Mounts: volume `config` → `/home/node/.openclaw`, volume `workspace` → `/home/node/.openclaw/workspace`
- Domain: HTTPS to port 18789, protocol `http` on backend, `letsencrypt` resolver
- Env vars: **NO `OPENCLAW_GATEWAY_TOKEN`** (incompatible with trusted-proxy)
- `zeroDowntime: false` while you're stabilising (else 5-replica race during plugin install)

**OpenClaw config** (`/home/node/.openclaw/openclaw.json`):
```json
{
  "gateway": {
    "controlUi": {
      "allowedOrigins": ["https://your-openclaw.example.com"]
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

**Why this works:**
- Easypanel's Traefik fronts the service at the Easypanel overlay network (`10.11.0.0/16`).
- `trusted-proxy` mode delegates auth to Traefik; the gateway accepts the request because its source IP is in `trustedProxies`.
- `allowUsers: []` permits any user (Traefik in this setup doesn't authenticate; the dominio is the access boundary).
- Device pairing is **bypassed** when trusted-proxy auth passes — that's the only documented escape from the pairing loop for non-loopback access.

---

## Detailed walkthrough — every iteration that failed

[ITERATIONS.md](./ITERATIONS.md) — the full chronology of what we tried, why it broke, and what the error message actually meant. Useful if your symptom doesn't match the TL;DR exactly.

---

## How this was actually fixed (Easypanel API + SSH)

The Easypanel web console terminal becomes unusable when the container restarts in a loop, and the config file lives inside a volume only reachable from inside a healthy container. We used **two access channels in tandem**:

### 1. Easypanel tRPC API (`https://<panel>/api/trpc/...`)

Bearer-token authenticated. We used it for service-level operations:
- `services.app.createService` — recreate the corrupted service from scratch
- `services.app.updateSourceImage` — set Docker image
- `services.app.updateEnv` — set env vars (without `OPENCLAW_GATEWAY_TOKEN`)
- `services.app.updateDeploy` — set command + replicas + zeroDowntime
- `mounts.createMount` — add the two persistent volumes (note: namespace is `mounts.*`, body needs a `values` wrapper)
- `domains.createDomain` — bind the domain (requires full schema: `id`, `host`, `https`, `path`, `middlewares`, `certificateResolver`, `wildcard`, `destinationType`, `serviceDestination` with `protocol` field)
- `services.app.deployService` — kick the rollout

Get a permanent token from `users.generateApiToken`. Don't use `auth.login` session tokens (30-day expiry).

### 2. SSH to the Easypanel host (`root@<server-ip>`)

Used for everything that touches the container's filesystem:
- `docker ps`, `docker logs`, `docker service ps` — see why it's failing
- `docker exec <container> openclaw config patch --stdin` — apply the auth/origins config to the volume
- `docker exec <container> openclaw doctor` — surfaced `gateway.mode is unset` and other invariants
- `docker service scale openclaw_openclaw-gateway=0 → =1` — force-reset when zero-downtime spawned 5 phantom replicas competing for the same volume
- `docker network inspect`, `docker exec traefik wget …` — confirm Traefik can reach the backend
- Read `/etc/easypanel/traefik/config/main.yaml` to verify the router and service blocks were written

You need both. The API can't `docker exec`; SSH can't easily mutate Easypanel's service definition without leaving it inconsistent with the panel's database.

---

## The Claude Code skill

[skill/](./skill/) — drop-in skill for [Claude Code](https://docs.anthropic.com/claude/docs/claude-code) that automates the diagnostic + fix loop. Install:

```bash
mkdir -p ~/.claude/skills/openclaw-easypanel-fix
cp -r skill/* ~/.claude/skills/openclaw-easypanel-fix/
```

Then in a Claude Code session: `/openclaw-easypanel-fix` (or just describe the symptom and the skill will trigger).

The skill expects two credentials in the conversation:
- Easypanel API token (Bearer)
- SSH access to the host (user/password or key)

It will not touch your panel without both.

---

## Reference

- [OpenClaw docs — gateway/trusted-proxy-auth](https://docs.openclaw.ai/gateway/trusted-proxy-auth)
- [OpenClaw docs — gateway/remote](https://docs.openclaw.ai/gateway/remote)
- [OpenClaw docs — web/control-ui](https://docs.openclaw.ai/web/control-ui)
- [Easypanel MCP server (tRPC procedure list)](https://github.com/dray-supadev/easypanel-mcp)
- [Issue #17608 — missing scope operator.admin on LAN](https://github.com/openclaw/openclaw/issues/17608)
- [Issue #29809 — origin not allowed](https://github.com/openclaw/openclaw/issues/29809)
- [Issue #1690 — gateway token missing in URL](https://github.com/openclaw/openclaw/issues/1690)

## License

MIT. Use freely, fork, improve. PRs welcome — particularly any newer OpenClaw version where these traps no longer apply.
