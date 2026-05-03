# Easypanel tRPC API — quick reference

Easypanel exposes a tRPC API at `https://<panel>/api/trpc/<procedure>`. Every request needs `Authorization: Bearer <TOKEN>`. Queries are GET with `?input=<urlencoded-json>`. Mutations are POST with body `{"json": {…}}`.

This file is a working reference for the operations needed to fix an OpenClaw deployment. It's not a full API doc — for the complete procedure list, see [dray-supadev/easypanel-mcp](https://github.com/dray-supadev/easypanel-mcp/blob/main/api-endpoints.txt).

## Authentication

```bash
# Test the token works:
curl -s "https://<panel>/api/trpc/projects.listProjects" \
  -H "Authorization: Bearer <TOKEN>"
# A working token returns {"result":{"data":{"json":[…]}}}.
# A bad token returns 401 or a Zod error.
```

If the user only has a `auth.login` session token (30-day expiry), generate a permanent one once via `users.generateApiToken` and tell them to save it.

## Inspect existing service

```bash
# tRPC queries use GET with urlencoded input
curl -s "https://<panel>/api/trpc/services.app.inspectService?input=$(
  printf '%s' '{"json":{"projectName":"<proj>","serviceName":"<svc>"}}' \
  | python -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read()))'
)" -H "Authorization: Bearer <TOKEN>"
```

Returns the full service definition: image, env (multiline string), deploy command, mounts, primaryDomainId. **Read this first** before changing anything — it tells you the current state and confirms whether the service even exists in Easypanel's database.

If you get `"Service not found."` for a service the user expects to be there, it was probably destroyed by a failed `deployService` or removed from the panel UI. Move to the recreation flow below.

## Recreate a service from scratch

When the existing service is in an unrecoverable state (config volume is corrupt, swarm replicas are stuck, etc.), it's faster to delete and recreate than to patch.

```bash
# 1. Create the empty service
curl -s -X POST "https://<panel>/api/trpc/services.app.createService" \
  -H "Authorization: Bearer <TOKEN>" -H "Content-Type: application/json" \
  -d '{"json":{"projectName":"<proj>","serviceName":"<svc>"}}'

# 2. Set the Docker image
curl -s -X POST "https://<panel>/api/trpc/services.app.updateSourceImage" \
  -H "Authorization: Bearer <TOKEN>" -H "Content-Type: application/json" \
  -d '{"json":{"projectName":"<proj>","serviceName":"<svc>","image":"ghcr.io/openclaw/openclaw:latest"}}'

# 3. Set env vars (multiline string, no OPENCLAW_GATEWAY_TOKEN)
curl -s -X POST "https://<panel>/api/trpc/services.app.updateEnv" \
  -H "Authorization: Bearer <TOKEN>" -H "Content-Type: application/json" \
  -d '{"json":{"projectName":"<proj>","serviceName":"<svc>","env":"HOME=/home/node\nLLM_PROVIDER=openai\nDEFAULT_MODEL=gpt-4o\nOPENAI_API_KEY=<KEY>\n"}}'

# 4. Set deploy command — note the nested "deploy" object
curl -s -X POST "https://<panel>/api/trpc/services.app.updateDeploy" \
  -H "Authorization: Bearer <TOKEN>" -H "Content-Type: application/json" \
  -d '{"json":{"projectName":"<proj>","serviceName":"<svc>","deploy":{"replicas":1,"command":"node dist/index.js gateway --bind auto --port 18789 --allow-unconfigured","zeroDowntime":false}}}'

# 5. Add mounts — note the namespace is "mounts.*" and the body needs a "values" wrapper
curl -s -X POST "https://<panel>/api/trpc/mounts.createMount" \
  -H "Authorization: Bearer <TOKEN>" -H "Content-Type: application/json" \
  -d '{"json":{"projectName":"<proj>","serviceName":"<svc>","serviceType":"app","values":{"type":"volume","name":"config","mountPath":"/home/node/.openclaw"}}}'

curl -s -X POST "https://<panel>/api/trpc/mounts.createMount" \
  -H "Authorization: Bearer <TOKEN>" -H "Content-Type: application/json" \
  -d '{"json":{"projectName":"<proj>","serviceName":"<svc>","serviceType":"app","values":{"type":"volume","name":"workspace","mountPath":"/home/node/.openclaw/workspace"}}}'

# 6. Add domain — full schema needed
curl -s -X POST "https://<panel>/api/trpc/domains.createDomain" \
  -H "Authorization: Bearer <TOKEN>" -H "Content-Type: application/json" \
  -d '{"json":{"id":"<svc>-domain-1","host":"<public-host>","https":true,"path":"/","middlewares":[],"certificateResolver":"letsencrypt","wildcard":false,"destinationType":"service","serviceDestination":{"protocol":"http","port":18789,"path":"/","projectName":"<proj>","serviceName":"<svc>"}}}'

# 7. Trigger the rollout
curl -s -X POST "https://<panel>/api/trpc/services.app.deployService" \
  -H "Authorization: Bearer <TOKEN>" -H "Content-Type: application/json" \
  -d '{"json":{"projectName":"<proj>","serviceName":"<svc>"}}'
```

## Schema gotchas

- **`mounts.createMount` body shape.** The inner mount config goes inside a `values` object, not at the top level. Wrong: `{"type":"volume","name":"config",…}`. Right: `{"values":{"type":"volume","name":"config",…}}`. The error message is a Zod union failure that doesn't make this obvious.
- **`domains.createDomain` requires every field.** Missing fields return `Required` errors in `zodErrors`. The mandatory list: `id`, `host`, `https`, `path`, `middlewares` (array, can be `[]`), `certificateResolver` (`"letsencrypt"` is fine), `wildcard`, `destinationType` (`"service"` for app services), and `serviceDestination` containing `{protocol, port, path, projectName, serviceName}`. Missing `serviceDestination.protocol` is the most common slip.
- **Some procedures live under `services.app.*` and others under sibling namespaces** (`mounts.*`, `domains.*`). Don't assume everything is under one path. The operation name doesn't always include `Service`. Check the endpoint list when in doubt.
- **Queries vs mutations.** Queries are GET (with urlencoded `input` query param). Mutations are POST (with JSON body). Calling a query as POST returns `METHOD_NOT_SUPPORTED`. Calling a mutation as GET returns nothing useful.
- **`services.app.deployService` returns `{"result":{"data":{"json":null,…}}}` on success.** Yes, `null` is success. The actual rollout happens asynchronously in Swarm; check the result with `docker service ps <service>` from SSH.

## Other useful procedures

- `services.app.restartService` — kicks the running task without a fresh image pull. Useful after editing the config volume directly.
- `services.app.destroyService` — deletes the service AND the volumes. Don't run this casually; the user's persisted state goes with it.
- `domains.listDomains?input=…` — confirms a domain is registered after creating it.
- `traefik.restart` — last-resort "Traefik isn't picking up the new domain" workaround. Check `/etc/easypanel/traefik/config/main.yaml` first to verify the domain is even in the config.

## Verifying via SSH after API operations

The API tells you what Easypanel's database thinks. SSH tells you what Docker actually did. They can disagree.

```bash
ssh root@<host>
docker service ls | grep <svc>            # is the swarm service there?
docker service ps openclaw_<svc> | head   # rollout state, failed tasks
docker ps --filter name=<svc>             # running containers + health
docker logs --tail 60 <container>         # actual errors
```

When in doubt, trust SSH. Easypanel's "deployed" indicator can stay green even when the swarm service is in a crash loop.
