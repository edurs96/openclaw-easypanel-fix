#!/usr/bin/env bash
# Diagnose an OpenClaw-on-Easypanel deployment. Runs from the Easypanel host
# (over SSH). Reads via Docker; doesn't change anything.
#
# Usage:
#   ./diagnose.sh <project-name> <service-name>
# Example:
#   ./diagnose.sh openclaw openclaw-gateway

set -uo pipefail

PROJECT="${1:?project name required}"
SERVICE="${2:?service name required}"
SWARM_NAME="${PROJECT}_${SERVICE}"

hr() { printf '\n=== %s ===\n' "$1"; }

hr "Swarm service"
docker service ls --filter "name=${SWARM_NAME}" --format 'table {{.Name}}\t{{.Mode}}\t{{.Replicas}}\t{{.Image}}'

hr "Service tasks (last 5)"
docker service ps "${SWARM_NAME}" --format 'table {{.Name}}\t{{.CurrentState}}\t{{.Error}}' 2>/dev/null | head -6 || echo "(service not in swarm — may have been destroyed)"

hr "Running containers"
docker ps --filter "name=${SWARM_NAME}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

CONT="$(docker ps --filter "name=${SWARM_NAME}" --filter "health=healthy" --format '{{.Names}}' | head -1)"
[ -z "$CONT" ] && CONT="$(docker ps --filter "name=${SWARM_NAME}" --format '{{.Names}}' | head -1)"

if [ -z "$CONT" ]; then
  hr "No running container — checking volume directly"
  VOL_PATH="/var/lib/docker/volumes/${SWARM_NAME}_config/_data"
  if [ -d "$VOL_PATH" ]; then
    echo "Volume path: $VOL_PATH"
    ls -la "$VOL_PATH" 2>&1 | head -10
    if [ -f "$VOL_PATH/openclaw.json" ]; then
      hr "openclaw.json (from volume)"
      cat "$VOL_PATH/openclaw.json"
    fi
  else
    echo "No config volume found at $VOL_PATH"
  fi
  exit 0
fi

hr "Inspecting container: $CONT"

hr "Networks"
docker inspect "$CONT" --format '{{range $net, $cfg := .NetworkSettings.Networks}}{{$net}}: {{$cfg.IPAddress}}{{println}}{{end}}'

hr "openclaw.json (current config)"
docker exec "$CONT" cat /home/node/.openclaw/openclaw.json 2>/dev/null || echo "(file missing — gateway will auto-generate on next start)"

hr "Last 25 log lines"
docker logs --tail 25 "$CONT" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'

hr "Recent error markers"
docker logs --tail 200 "$CONT" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -iE 'origin not allowed|pairing required|missing scope|untrusted address|refusing to bind|trusted-proxy|gateway failed to start|invalid config' | tail -10 || echo "(no known error markers in recent logs)"

hr "openclaw doctor"
docker exec "$CONT" openclaw doctor 2>&1 | head -50 || echo "(openclaw doctor failed to run)"

hr "Done"
echo ""
echo "Next: read SKILL.md → Step 3 to apply the working configuration."
echo "If an error message above isn't familiar, see references/error-decoder.md"
