#!/bin/zsh
# Builds Porthole's agent for the Unraid server, copies the image over SSH,
# and (re)starts the porthole-agent container there, with its Unraid template.
#
# Usage: agent/deploy.sh               build, copy, start
#        PORTHOLE_ACTIONS=1 agent/deploy.sh   also allow Start/Stop/Restart from the web page
set -euo pipefail
here=${0:A:h}
target=${PORTHOLE_SERVER:-root@192.168.40.210}
key=${PORTHOLE_KEY:-$HOME/.ssh/id_ed25519_homeserver}
actions=${PORTHOLE_ACTIONS:-0}
ssh=(ssh -i "$key" "$target")

# The image builds on this Mac: start OrbStack (or Docker Desktop) when it's off.
if ! docker info >/dev/null 2>&1; then
  echo "→ start Docker on this Mac"
  open -ga OrbStack 2>/dev/null || open -ga Docker 2>/dev/null || { echo "✗ no Docker on this Mac (OrbStack or Docker Desktop)"; exit 1; }
  for _ in {1..60}; do docker info >/dev/null 2>&1 && break; sleep 2; done
  docker info >/dev/null 2>&1 || { echo "✗ Docker didn't start"; exit 1; }
fi
echo "→ build (linux/amd64)"
docker build -q --platform linux/amd64 -t porthole-agent:latest "$here" >/dev/null
echo "→ copy the image ($(docker image inspect porthole-agent:latest --format '{{.Size}}' | awk '{printf "%.1f MB", $1/1e6}'))"
docker save porthole-agent:latest | gzip | "${ssh[@]}" 'gunzip | docker load -q' >/dev/null
echo "→ template"
"${ssh[@]}" 'cat > /boot/config/plugins/dockerMan/templates-user/my-porthole-agent.xml' < "$here/unraid/my-porthole-agent.xml"
echo "→ start"
"${ssh[@]}" "docker rm -f porthole-agent >/dev/null 2>&1; docker run -d --name porthole-agent --restart unless-stopped \
  -p 7080:7080 -v /var/run/docker.sock:/var/run/docker.sock -v /proc:/host/proc:ro -e PORTHOLE_ACTIONS=$actions \
  -l net.unraid.docker.managed=dockerman -l 'net.unraid.docker.webui=http://[IP]:[PORT:7080]/' \
  -l net.unraid.docker.icon=https://cdn.jsdelivr.net/gh/selfhst/icons/png/docker.png porthole-agent:latest >/dev/null
  grep -qx porthole-agent /var/lib/docker/unraid-autostart 2>/dev/null || echo porthole-agent >> /var/lib/docker/unraid-autostart
  docker image prune -f >/dev/null"
sleep 3
host=${target#*@}
curl -fsS "http://$host:7080/health" >/dev/null && echo "✓ http://$host:7080/" || { echo "✗ not answering yet: ${ssh[*]} docker logs porthole-agent"; exit 1; }
