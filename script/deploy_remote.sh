#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: deploy_remote.sh <staging|production> <immutable-image-ref>" >&2
  exit 2
fi

ENVIRONMENT="$1"
IMAGE="$2"
case "$ENVIRONMENT" in
  staging|production) ;;
  *) echo "Environment must be staging or production" >&2; exit 2 ;;
esac

DEPLOY_DIR="${DEPLOY_DIR:-/opt/marketmate}"
cd "$DEPLOY_DIR"
test -f docker-compose.yml || { echo "Missing docker-compose.yml" >&2; exit 1; }


exec 9>"$DEPLOY_DIR/.deploy.lock"
flock -n 9 || { echo "Another deploy is running" >&2; exit 1; }


STATE="$DEPLOY_DIR/.last-good-image-$ENVIRONMENT"
PREVIOUS=""
if [[ -f "$STATE" ]]; then PREVIOUS="$(cat "$STATE")"; fi

check_health() {
  for i in $(seq 1 5); do
    if curl --fail --silent --show-error --max-time 2 http://127.0.0.1:8000/health >/dev/null 2>&1; then
      [[ "$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose -p "marketmate-$ENVIRONMENT" ps -q app)" 2>/dev/null)" == "healthy" ]] && return 0
    fi
    sleep 5
  done
  return 1
}

rollback() {
  echo "Deployment failed; attempting to restore previous release" >&2
  if [[ -n "$PREVIOUS" ]]; then
    APP_IMAGE="$PREVIOUS" APP_ENV="$ENVIRONMENT" \
      docker compose -p "marketmate-$ENVIRONMENT" up -d --no-deps --no-build app || true
    check_health || echo "CRITICAL: rollback not healthy; operator action required" >&2
  else
    echo "No last-known-good image recorded; first deployment needs manual recovery" >&2
  fi
}

export APP_IMAGE="$IMAGE" APP_ENV="$ENVIRONMENT"
if ! docker compose -p "marketmate-$ENVIRONMENT" pull app; then
  echo "Image pull failed; running release unchanged" >&2
  exit 1
fi
if ! docker compose -p "marketmate-$ENVIRONMENT" up -d --no-deps --no-build app; then
  rollback; exit 1
fi
if ! check_health; then
  rollback; exit 1
fi
printf '%s\n' "$IMAGE" > "$STATE"
chmod 600 "$STATE"
echo "Deployment successful: $ENVIRONMENT image=$IMAGE"
