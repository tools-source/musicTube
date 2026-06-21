#!/usr/bin/env bash
set -euo pipefail

bundled_python="$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"
if [[ -x "$bundled_python" ]]; then
  export CLOUDSDK_PYTHON="$bundled_python"
fi

PROJECT_ID="musictube-495822"
REGION="us-east4"
SERVICE="musictube-api"
SECRET="musictube-openrouter-api-key"

cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

gcloud config set project "$PROJECT_ID"
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com

if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
  auth_status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --header "Authorization: Bearer ${OPENROUTER_API_KEY}" \
    https://openrouter.ai/api/v1/auth/key)"
  if [[ "$auth_status" != "200" ]]; then
    echo "OpenRouter rejected the configured local key (HTTP ${auth_status})." >&2
    exit 1
  fi

  if gcloud secrets describe "$SECRET" --project "$PROJECT_ID" >/dev/null 2>&1; then
    printf '%s' "$OPENROUTER_API_KEY" | gcloud secrets versions add "$SECRET" \
      --project "$PROJECT_ID" \
      --data-file=-
  else
    printf '%s' "$OPENROUTER_API_KEY" | gcloud secrets create "$SECRET" \
      --project "$PROJECT_ID" \
      --replication-policy=automatic \
      --data-file=-
  fi
elif ! gcloud secrets describe "$SECRET" --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "No valid local key or existing Secret Manager secret is available." >&2
  exit 1
fi

project_number="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
runtime_service_account="${project_number}-compute@developer.gserviceaccount.com"
gcloud secrets add-iam-policy-binding "$SECRET" \
  --project "$PROJECT_ID" \
  --member "serviceAccount:${runtime_service_account}" \
  --role roles/secretmanager.secretAccessor >/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:${runtime_service_account}" \
  --role roles/storage.objectViewer \
  --condition=None >/dev/null

gcloud run deploy "$SERVICE" \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --source . \
  --allow-unauthenticated \
  --max-instances 3 \
  --min-instances 0 \
  --memory 512Mi \
  --cpu 1 \
  --set-env-vars "OPENROUTER_MODEL=google/gemini-3.1-flash-lite,PUBLIC_APP_URL=https://music-tube.me,TRUST_PROXY=true" \
  --set-secrets "OPENROUTER_API_KEY=${SECRET}:latest"

service_url="$(gcloud run services describe "$SERVICE" \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --format='value(status.url)')"
curl --fail --show-error --silent "${service_url}/health"
echo
echo "Cloud Run service: ${service_url}"
