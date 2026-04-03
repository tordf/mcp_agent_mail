#!/usr/bin/env bash
set -euo pipefail

# GSD-2 Integration (HTTP MCP) - Bash
# Configures project-local GSD-2 settings for Agent Mail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

YES=${AUTO_YES:-0}
PROJECT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=1 ;;
    --project-dir) shift; PROJECT_DIR="${1:-}" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift || true
done

log_step "GSD-2 Integration (one-stop MCP config) - Bash"

ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_DIR="${PROJECT_DIR:-${ROOT_DIR}}"
if [[ ! -d "${TARGET_DIR}" ]]; then
  log_err "Target directory not found: ${TARGET_DIR}"
  exit 1
fi

if [[ "${YES}" -ne 1 ]]; then
  read -r -p "Proceed with GSD-2 integration in ${TARGET_DIR}? [y/N] " confirm
  if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
    log_warn "Aborted."
    exit 0
  fi
fi

log_step "Resolving HTTP endpoint from settings"
SETTINGS_RAW=$(uv run python -c "from mcp_agent_mail.config import get_settings; s = get_settings(); print(f'{s.http.host}|{s.http.port}|{s.http.path}')")
IFS='|' read -r HOST PORT PATH_PREFIX <<< "${SETTINGS_RAW}"
URL="http://${HOST}:${PORT}${PATH_PREFIX}"
log_ok "Detected MCP HTTP endpoint: ${URL}"

# Resolve token
TOKEN=$(grep "^HTTP_BEARER_TOKEN=" "${ROOT_DIR}/.env" | cut -d'=' -f2- | tr -d '"' | tr -d "'") || TOKEN=""
if [[ -z "${TOKEN}" ]]; then
  TOKEN=$(uv run python -c "import secrets; print(secrets.token_hex(32))")
  # Update .env (naively)
  if grep -q "^HTTP_BEARER_TOKEN=" "${ROOT_DIR}/.env"; then
    sed -i "s/^HTTP_BEARER_TOKEN=.*/HTTP_BEARER_TOKEN=${TOKEN}/" "${ROOT_DIR}/.env"
  else
    echo "HTTP_BEARER_TOKEN=${TOKEN}" >> "${ROOT_DIR}/.env"
  fi
  log_ok "Generated bearer token."
fi

# Write GSD MCP config
GSD_DIR="${TARGET_DIR}/.gsd"
mkdir -p "${GSD_DIR}"
OUT_JSON="${GSD_DIR}/mcp.json"
TOP_JSON="${TARGET_DIR}/.mcp.json"

MCP_CONFIG=$(cat <<EOF
{
  "mcpServers": {
    "mcp-agent-mail": {
      "type": "http",
      "url": "${URL}",
      "headers": {
        "Authorization": "Bearer ${TOKEN}"
      }
    }
  }
}
EOF
)

echo "${MCP_CONFIG}" > "${OUT_JSON}"
log_ok "Wrote GSD-specific MCP config to ${OUT_JSON}"

echo "${MCP_CONFIG}" > "${TOP_JSON}"
log_ok "Wrote discoverable .mcp.json to ${TARGET_DIR}"

# Bootstrap
if curl -s -f -X POST "${URL}" -H "Content-Type: application/json" -H "Authorization: Bearer ${TOKEN}" \
   -d '{"jsonrpc":"2.0","id":"1","method":"tools/call","params":{"name":"ensure_project","arguments":{"human_key":"'"${TARGET_DIR}"'"}}}' >/dev/null 2>&1; then
  
  log_ok "Ensured project on server"
  
  # register_agent
  AGENT_NAME="${USER:-agent}"
  curl -s -f -X POST "${URL}" -H "Content-Type: application/json" -H "Authorization: Bearer ${TOKEN}" \
    -d '{"jsonrpc":"2.0","id":"2","method":"tools/call","params":{"name":"register_agent","arguments":{"project_key":"'"${TARGET_DIR}"'","program":"gsd-pi","model":"gsd-2","name":"'"${AGENT_NAME}"'","task_description":"setup"}}}' >/dev/null 2>&1
  log_ok "Registered agent on server"
else
  log_warn "Server not reachable or bootstrap failed. Skipping registration."
fi

log_ok "==> Done."
