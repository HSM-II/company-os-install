#!/usr/bin/env bash
# HSM-II Company OS installer.
#
#   curl -fsSL https://raw.githubusercontent.com/HSM-II/company-os-install/main/install.sh | bash
#
# Docker is the only prerequisite. Nothing is compiled here: this pulls a
# published image, generates one set of credentials for this install, starts
# Postgres + the API + the console, and verifies the stack answers before it
# claims to be done.
#
# Options:
#   --dir PATH        install directory (default: $HSMII_INSTALL_DIR or ~/.hsm-ii)
#   --image REF       runtime image (production persists an immutable digest)
#   --profile NAME    companion (default), full, or dev
#   --no-start        write configuration only
#   --no-open         do not open a browser
#   --uninstall       stop the stack and remove its containers (keeps data volumes)
set -euo pipefail
umask 077

DEFAULT_IMAGE="ghcr.io/permutationresearch/company-os:latest"
DEFAULT_INSTALL_DIR="${HOME}/.hsm-ii"
RAW_BASE="${HSMII_RAW_BASE:-https://raw.githubusercontent.com/HSM-II/company-os-install/main}"

INSTALL_DIR="${HSMII_INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
IMAGE="${COMPANY_OS_IMAGE:-$DEFAULT_IMAGE}"
IMAGE_EXPLICIT=$([[ -n "${COMPANY_OS_IMAGE:-}" ]] && echo 1 || echo 0)
PROFILE="companion"
PROFILE_EXPLICIT=0
START_STACK=1
OPEN_BROWSER=1
UNINSTALL=0
CREDENTIAL_GATEWAY_REQUESTED=0
PROVIDER_KEY_FILE=""
CREDENTIAL_MODE=0
CREDENTIAL_GATEWAY_TOKEN=""
CREDENTIAL_SECRETS_DIR=""
INSTALL_UID="$(id -u)"
INSTALL_GID="$(id -g)"

API_PORT="${COMPANY_OS_API_PORT:-3847}"
CONSOLE_PORT="${COMPANY_OS_CONSOLE_PORT:-3050}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Not derived from the file: piped through `curl | bash` there is no file to read.
usage() {
  cat <<'EOF'
HSM-II Company OS installer. Docker is the only prerequisite.

  curl -fsSL https://raw.githubusercontent.com/HSM-II/company-os-install/main/install.sh | bash

  --dir PATH     install directory (default: ~/.hsm-ii)
  --image REF    runtime image to pull
  --profile NAME companion (default), full, or dev
  --no-start     write configuration only
  --no-open      do not open a browser
  --credential-gateway  route the native provider through the local credential gateway
  --provider-key-file PATH  private OpenRouter key (required for a fresh gateway install)
  --uninstall    stop the stack, keeping data volumes
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) INSTALL_DIR="${2:?missing value for --dir}"; shift 2 ;;
    --image) IMAGE="${2:?missing value for --image}"; IMAGE_EXPLICIT=1; shift 2 ;;
    --profile) PROFILE="${2:?missing value for --profile}"; PROFILE_EXPLICIT=1; shift 2 ;;
    --no-start) START_STACK=0; shift ;;
    --no-open) OPEN_BROWSER=0; shift ;;
    --credential-gateway) CREDENTIAL_GATEWAY_REQUESTED=1; shift ;;
    --provider-key-file) PROVIDER_KEY_FILE="${2:?missing value for --provider-key-file}"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$PROFILE" in
  companion|full|dev) ;;
  *) die "invalid profile '$PROFILE' (expected companion, full, or dev)" ;;
esac

if [[ "$CREDENTIAL_GATEWAY_REQUESTED" == "1" && -z "$PROVIDER_KEY_FILE" && ! -f "$INSTALL_DIR/.env" ]]; then
  die "--credential-gateway requires --provider-key-file PATH for a fresh install"
fi
if [[ -n "$PROVIDER_KEY_FILE" && "$CREDENTIAL_GATEWAY_REQUESTED" != "1" ]]; then
  die "--provider-key-file requires --credential-gateway"
fi

# ── Prerequisites ────────────────────────────────────────────────────────────
require_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker is required: https://docs.docker.com/get-docker/"
  if ! docker version >/dev/null 2>&1; then
    die "Docker is installed but the daemon is not responding — start Docker Desktop (or \`colima start\`) and rerun."
  fi
  docker compose version >/dev/null 2>&1 \
    || die "Docker Compose v2 is required (\`docker compose version\` failed)."
}

is_secure_env_file() {
  [[ -f "$1" ]] && grep -q '^HSM_CREDENTIAL_BOUNDARY=openrouter-gateway-v1$' "$1"
}

compose() {
  local -a files=(-f "$INSTALL_DIR/docker-compose.company-os.yml") compose_args=(--project-directory "$INSTALL_DIR") scrubbed_env=(env)
  local name
  # Docker Compose gives the inherited shell precedence over --env-file. A
  # secured install must therefore resolve from its persisted .env rather
  # than ambient provider/profile/credential overrides.
  if [[ "$CREDENTIAL_MODE" == "1" ]]; then
    for name in \
      COMPANY_OS_IMAGE COMPANY_OS_POSTGRES_IMAGE COMPANY_OS_SUPERUSER COMPANY_OS_DATABASE \
      COMPANY_OS_SUPERUSER_PASSWORD COMPANY_OS_MIGRATION_PASSWORD COMPANY_OS_RUNTIME_PASSWORD \
      COMPANY_OS_EXECUTOR_PASSWORD COMPANY_OS_RECONCILER_PASSWORD COMPANY_OS_READONLY_PASSWORD \
      COMPANY_OS_VCS_BROKER_PASSWORD COMPANY_OS_API_TOKEN COMPANY_OS_PROFILE \
      COMPANY_OS_API_PORT COMPANY_OS_CONSOLE_PORT COMPANY_OS_POSTGRES_PORT RUST_LOG \
      HSM_COMPANY_OS_COMPANION HSM_OPTIONAL_BACKGROUND_WORKERS HSM_MEMORY_EMBED_ENABLED \
      HSM_COMPANY_OS_ALLOW_IMAGE_MIGRATIONS HSM_COMPANY_LLM_MAX_CONCURRENT \
      HSM_GATEWAY_DEFAULT_DAILY_SPEND_CAP_USD HSM_GATEWAY_DEFAULT_MONTHLY_SPEND_CAP_USD \
      HSM_GATEWAY_DEFAULT_MAX_THREAD_TURNS HSM_GATEWAY_DEFAULT_MAX_COMPLETION_TOKENS_PER_RUN \
      HSM_COMPANY_OS_ALLOW_DEGRADED HSM_CREDENTIAL_BOUNDARY HSM_CREDENTIAL_GATEWAY_TOKEN \
      HSM_CREDENTIAL_GATEWAY_SECRETS_DIR HSM_CREDENTIAL_GATEWAY_UID HSM_CREDENTIAL_GATEWAY_GID \
      COMPOSE_PROJECT_NAME \
      HSM_LLM_PROVIDER_ORDER HSM_LLM_PROVIDER DEFAULT_LLM_MODEL HSM_AGENT_CHAT_MODEL \
      OPENROUTER_API_KEY OPENROUTER_BASE_URL OPENROUTER_API_BASE; do
      scrubbed_env+=(-u "$name")
    done
  fi
  if [[ -f "$INSTALL_DIR/.env" ]]; then
    compose_args+=(--env-file "$INSTALL_DIR/.env")
  fi
  if [[ "$CREDENTIAL_MODE" == "1" ]]; then
    files+=(-f "$INSTALL_DIR/docker-compose.credential-gateway.yml")
  fi
  "${scrubbed_env[@]}" docker compose "${compose_args[@]}" "${files[@]}" "$@"
}

# ── Configuration ────────────────────────────────────────────────────────────
secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    # `head` closing the pipe SIGPIPEs `tr`, which `pipefail` would turn into a
    # failed install. Read a fixed number of bytes instead of racing the reader.
    dd if=/dev/urandom bs=1 count=24 2>/dev/null | od -An -tx1 | tr -d ' \n'
  fi
}

fetch_stack_files() {
  mkdir -p "$INSTALL_DIR"
  INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd -P)"
  local script_dir local_compose local_override
  # Piped through `curl | bash` there is no BASH_SOURCE, and `set -u` would abort
  # on the bare reference.
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || echo .)"
  local_compose="$script_dir/docker-compose.company-os.yml"

  if [[ -f "$local_compose" ]]; then
    log "Using the checkout's compose file"
    cp "$local_compose" "$INSTALL_DIR/docker-compose.company-os.yml"
  else
    log "Fetching the Company OS stack definition"
    curl -fsSL "$RAW_BASE/docker-compose.company-os.yml" \
      -o "$INSTALL_DIR/docker-compose.company-os.yml" \
      || die "could not download the compose file from $RAW_BASE"
  fi

  if [[ "$CREDENTIAL_MODE" == "1" ]]; then
    local_override="$script_dir/docker-compose.credential-gateway.yml"
    if [[ -f "$local_override" ]]; then
      cp "$local_override" "$INSTALL_DIR/docker-compose.credential-gateway.yml"
    else
      log "Fetching the credential gateway compose overlay"
      curl -fsSL "$RAW_BASE/docker-compose.credential-gateway.yml" \
        -o "$INSTALL_DIR/docker-compose.credential-gateway.yml" \
        || die "could not download the credential gateway overlay from $RAW_BASE"
    fi
  fi
}

is_immutable_image() {
  [[ "$1" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]]
}

# Production Compose files never retain a mutable tag. A started install may
# use a tag only to discover the registry's current digest; --no-start cannot
# perform that lookup and therefore requires the caller to supply the digest.
govern_image_reference() {
  local resolved
  if [[ "$PROFILE" == "dev" ]]; then
    return 0
  fi
  if is_immutable_image "$IMAGE"; then
    return 0
  fi
  if [[ "$START_STACK" != "1" ]]; then
    die "production --no-start requires an immutable image reference containing @sha256:<64 hex characters>"
  fi

  log "Resolving $IMAGE to an immutable registry digest"
  docker pull --quiet "$IMAGE" >/dev/null
  resolved="$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null || true)"
  is_immutable_image "$resolved" \
    || die "registry did not return an immutable sha256 digest for $IMAGE"
  IMAGE="$resolved"
}

persist_image_reference() {
  local env_file="$1" env_tmp
  env_tmp="$(mktemp "$INSTALL_DIR/.env.image.XXXXXX")"
  chmod 600 "$env_tmp"
  awk -v image="$IMAGE" '
    BEGIN { replaced = 0 }
    /^COMPANY_OS_IMAGE=/ {
      if (!replaced) print "COMPANY_OS_IMAGE=" image
      replaced = 1
      next
    }
    { print }
    END { if (!replaced) print "COMPANY_OS_IMAGE=" image }
  ' "$env_file" >"$env_tmp"
  mv "$env_tmp" "$env_file"
}

credential_file_mode_owner() {
  local path="$1"
  if stat -f '%Lp' "$path" >/dev/null 2>&1; then
    CREDENTIAL_FILE_MODE="$(stat -f '%Lp' "$path")"
    CREDENTIAL_FILE_OWNER="$(stat -f '%u' "$path")"
  else
    CREDENTIAL_FILE_MODE="$(stat -c '%a' "$path")"
    CREDENTIAL_FILE_OWNER="$(stat -c '%u' "$path")"
  fi
  while [[ "$CREDENTIAL_FILE_MODE" == 0* && ${#CREDENTIAL_FILE_MODE} -gt 3 ]]; do
    CREDENTIAL_FILE_MODE="${CREDENTIAL_FILE_MODE#0}"
  done
}

validate_provider_key_file() {
  [[ -n "$PROVIDER_KEY_FILE" ]] || die "--provider-key-file PATH is required for a fresh credential gateway install"
  [[ ! -L "$PROVIDER_KEY_FILE" && -f "$PROVIDER_KEY_FILE" ]] \
    || die "provider key input must be a regular non-symlink file"
  credential_file_mode_owner "$PROVIDER_KEY_FILE"
  [[ "$CREDENTIAL_FILE_OWNER" == "$INSTALL_UID" ]] \
    || die "provider key input must be owned by the current user"
  [[ "$CREDENTIAL_FILE_MODE" =~ ^[0-7]{3}$ && "${CREDENTIAL_FILE_MODE:1:2}" == "00" ]] \
    || die "provider key input must be private (mode 0400 or 0600)"
  local bytes
  bytes="$(wc -c < "$PROVIDER_KEY_FILE")"
  bytes="${bytes//[[:space:]]/}"
  (( bytes >= 32 && bytes <= 4097 )) || die "provider key input must be between 32 and 4096 token bytes"
  # A single trailing newline is accepted. Keep the result in `valid` so END
  # cannot override a body-level rejection (the old exit-in-body form did).
  if ! LC_ALL=C awk '
    NR == 1 {
      valid = (length($0) >= 32 && length($0) <= 4096)
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c < "!" || c > "~") valid = 0
      }
    }
    NR > 1 { valid = 0 }
    END { exit (NR == 1 && valid ? 0 : 1) }
  ' "$PROVIDER_KEY_FILE"; then
    die "provider key input must contain 32-4096 printable non-whitespace ASCII bytes (optional trailing newline)"
  fi
}

validate_installed_credential_file() {
  local path="$1" label="$2"
  [[ ! -L "$path" && -f "$path" ]] || die "$label must be a regular non-symlink file"
  credential_file_mode_owner "$path"
  [[ "$CREDENTIAL_FILE_OWNER" == "$INSTALL_UID" ]] || die "$label is not owned by the current user"
  [[ "$CREDENTIAL_FILE_MODE" =~ ^[0-7]{3}$ && "${CREDENTIAL_FILE_MODE:1:2}" == "00" ]] \
    || die "$label must not be readable or writable by group/other"
}

prepare_fresh_gateway_secrets() {
  CREDENTIAL_SECRETS_DIR="$INSTALL_DIR/secrets"
  [[ ! -e "$CREDENTIAL_SECRETS_DIR" && ! -L "$CREDENTIAL_SECRETS_DIR" ]] \
    || die "refusing to overwrite an existing credential secrets directory"
  local temp_dir="$INSTALL_DIR/.credential-secrets.tmp.$$"
  mkdir "$temp_dir"
  chmod 700 "$temp_dir"
  cp "$PROVIDER_KEY_FILE" "$temp_dir/openrouter-key"
  chmod 400 "$temp_dir/openrouter-key"
  printf '%s\n' "$CREDENTIAL_GATEWAY_TOKEN" >"$temp_dir/gateway-token"
  chmod 400 "$temp_dir/gateway-token"
  mv "$temp_dir" "$CREDENTIAL_SECRETS_DIR"
}

load_existing_gateway_state() {
  local env_file="$INSTALL_DIR/.env" token secrets_dir model
  [[ -f "$env_file" ]] || die "credential gateway state is missing $env_file"
  token="$(grep '^HSM_CREDENTIAL_GATEWAY_TOKEN=' "$env_file" | tail -n 1 | cut -d= -f2- || true)"
  [[ "$token" =~ ^hsmgw_[0-9a-f]{48}$ ]] || die "existing credential gateway token is invalid"
  secrets_dir="$(grep '^HSM_CREDENTIAL_GATEWAY_SECRETS_DIR=' "$env_file" | tail -n 1 | cut -d= -f2- || true)"
  [[ -n "$secrets_dir" && "$secrets_dir" == "$INSTALL_DIR/secrets" ]] \
    || die "existing credential gateway secrets directory is invalid"
  [[ -d "$secrets_dir" && ! -L "$secrets_dir" ]] || die "existing credential gateway secrets directory is missing"
  credential_file_mode_owner "$secrets_dir"
  [[ "$CREDENTIAL_FILE_OWNER" == "$INSTALL_UID" ]] || die "existing credential secrets directory is not owned by the current user"
  [[ "$CREDENTIAL_FILE_MODE" =~ ^[0-7]{3}$ && "${CREDENTIAL_FILE_MODE:1:2}" == "00" ]] || die "existing credential secrets directory is not private"
  validate_installed_credential_file "$secrets_dir/openrouter-key" "existing provider key"
  validate_installed_credential_file "$secrets_dir/gateway-token" "existing gateway token"
  token="$(tr -d '\r\n' < "$secrets_dir/gateway-token")"
  [[ "$token" =~ ^hsmgw_[0-9a-f]{48}$ ]] || die "existing gateway token file is invalid"
  [[ "$token" == "$(grep '^HSM_CREDENTIAL_GATEWAY_TOKEN=' "$env_file" | tail -n 1 | cut -d= -f2-)" ]] || die "gateway token env and secret file disagree"
  local project_name
  project_name="$(grep '^COMPOSE_PROJECT_NAME=' "$env_file" | tail -n 1 | cut -d= -f2- || true)"
  [[ "$project_name" =~ ^company-os-secured-[0-9a-f]{12}$ ]] || die "existing secure install is missing a valid Compose project name"
  model="$(grep -E '^(HSM_AGENT_CHAT_MODEL|DEFAULT_LLM_MODEL)=' "$env_file" | tail -n 1 | cut -d= -f2- || true)"
  [[ -n "$model" && "$model" != *$'\n'* && "$model" != *$'\r'* ]] || die "existing secure install is missing its model"
  CREDENTIAL_GATEWAY_TOKEN="$token"
  CREDENTIAL_SECRETS_DIR="$secrets_dir"
}

write_secure_env() {
  [[ "$PROFILE" == "full" && "$PROFILE_EXPLICIT" == "1" ]] \
    || die "a fresh credential gateway install requires --profile full"
  local model="${HSM_AGENT_CHAT_MODEL:-${DEFAULT_LLM_MODEL:-}}"
  [[ -n "$model" && "$model" != *$'\n'* && "$model" != *$'\r'* ]] \
    || die "a fresh credential gateway install requires a non-empty DEFAULT_LLM_MODEL or HSM_AGENT_CHAT_MODEL"
  validate_provider_key_file
  govern_image_reference
  CREDENTIAL_GATEWAY_TOKEN="hsmgw_$(secret)"
  local project_name="company-os-secured-$(secret | cut -c1-12)"
  prepare_fresh_gateway_secrets
  local env_file="$INSTALL_DIR/.env" env_tmp
  env_tmp="$(mktemp "$INSTALL_DIR/.env.tmp.XXXXXX")"
  chmod 600 "$env_tmp"
  cat >"$env_tmp" <<EOF
# Generated by install.sh. Provider credentials stay in $CREDENTIAL_SECRETS_DIR.
COMPANY_OS_IMAGE=$IMAGE
COMPANY_OS_PROFILE=full
COMPANY_OS_SUPERUSER=hsm
COMPANY_OS_DATABASE=hsm_company_os
COMPANY_OS_SUPERUSER_PASSWORD=$(secret)
COMPANY_OS_MIGRATION_PASSWORD=$(secret)
COMPANY_OS_RUNTIME_PASSWORD=$(secret)
COMPANY_OS_EXECUTOR_PASSWORD=$(secret)
COMPANY_OS_RECONCILER_PASSWORD=$(secret)
COMPANY_OS_READONLY_PASSWORD=$(secret)
COMPANY_OS_VCS_BROKER_PASSWORD=$(secret)
COMPANY_OS_API_TOKEN=$(secret)
COMPANY_OS_API_PORT=$API_PORT
COMPANY_OS_CONSOLE_PORT=$CONSOLE_PORT
COMPANY_OS_POSTGRES_PORT=${COMPANY_OS_POSTGRES_PORT:-55432}

# Finite model-gateway ceilings for companies without an explicit gateway
# policy row. Raise them here. Images built before 2026-09-15 treat an empty
# value as unbounded; current source falls back to these same platform defaults.
HSM_GATEWAY_DEFAULT_DAILY_SPEND_CAP_USD=25
HSM_GATEWAY_DEFAULT_MONTHLY_SPEND_CAP_USD=250
HSM_GATEWAY_DEFAULT_MAX_THREAD_TURNS=200
HSM_GATEWAY_DEFAULT_MAX_COMPLETION_TOKENS_PER_RUN=200000
# Output price used to meter spend against those ceilings, USD per 1k completion
# tokens. Unset means the gateway refuses paid work; set your model's real price.
HSM_LLM_PRICE_PER_1K_OUTPUT_TOKENS_USD=0.002
# RTK v0.49.0 ships in the Company OS image. Auto mode compresses eligible
# model-facing shell output and falls back to the original command if needed.
HSM_RTK_MODE=auto
COMPOSE_PROJECT_NAME=$project_name
HSM_COMPANY_OS_COMPANION=0
HSM_OPTIONAL_BACKGROUND_WORKERS=0
HSM_MEMORY_EMBED_ENABLED=0
HSM_COMPANY_OS_ALLOW_DEGRADED=0
HSM_CREDENTIAL_BOUNDARY=openrouter-gateway-v1
HSM_CREDENTIAL_GATEWAY_TOKEN=$CREDENTIAL_GATEWAY_TOKEN
HSM_CREDENTIAL_GATEWAY_SECRETS_DIR=$CREDENTIAL_SECRETS_DIR
HSM_CREDENTIAL_GATEWAY_UID=$INSTALL_UID
HSM_CREDENTIAL_GATEWAY_GID=$INSTALL_GID
OPENROUTER_API_KEY=$CREDENTIAL_GATEWAY_TOKEN
OPENROUTER_BASE_URL=http://credential-gateway:3850/api/v1
OPENROUTER_API_BASE=http://credential-gateway:3850/api/v1
HSM_LLM_PROVIDER_ORDER=openrouter
HSM_LLM_PROVIDER=openrouter
DEFAULT_LLM_MODEL=$model
HSM_AGENT_CHAT_MODEL=$model
EOF
  mv "$env_tmp" "$env_file"
}

# Credentials are generated once. Regenerating them on a second run would leave
# the database holding the old passwords and every lane failing to authenticate,
# so an existing .env is preserved as-is.
write_env() {
  local env_file="$INSTALL_DIR/.env"
  local credential mode owner key env_tmp existing_profile existing_image
  if [[ "$CREDENTIAL_MODE" == "1" && ! -e "$env_file" && ! -L "$env_file" ]]; then
    write_secure_env
    return 0
  fi
  if [[ -e "$env_file" || -L "$env_file" ]]; then
    [[ ! -L "$env_file" && -f "$env_file" ]] \
      || die "existing credential path must be a regular non-symlink file: $env_file"
    if is_secure_env_file "$env_file"; then
      CREDENTIAL_MODE=1
      load_existing_gateway_state
      if [[ -n "$PROVIDER_KEY_FILE" ]]; then
        validate_provider_key_file
        cmp -s "$PROVIDER_KEY_FILE" "$CREDENTIAL_SECRETS_DIR/openrouter-key" \
          || die "supplied provider key differs from the existing secured install; refusing to replace it"
      fi
      existing_profile="$(grep -E '^COMPANY_OS_PROFILE=(companion|full|dev)$' "$env_file" | tail -n 1 | cut -d= -f2- || true)"
      [[ "$existing_profile" == "full" ]] || die "existing credential gateway install must use the full profile"
      if [[ "$PROFILE_EXPLICIT" == "1" && "$PROFILE" != "$existing_profile" ]]; then
        die "existing install uses profile '$existing_profile'; refusing to change it silently"
      fi
      PROFILE="$existing_profile"
    elif [[ "$CREDENTIAL_GATEWAY_REQUESTED" == "1" ]]; then
      die "refusing to enable the credential gateway over an existing unsealed install"
    fi
    if stat -f '%Lp' "$env_file" >/dev/null 2>&1; then
      mode="$(stat -f '%Lp' "$env_file")"
      owner="$(stat -f '%u' "$env_file")"
    else
      mode="$(stat -c '%a' "$env_file")"
      owner="$(stat -c '%u' "$env_file")"
    fi
    [[ "$owner" == "$(id -u)" ]] || die "existing credential file is not owned by the current user: $env_file"
    [[ "$mode" == "600" ]] || die "existing credential file must have mode 0600 (got $mode): $env_file"
    for key in \
      COMPANY_OS_SUPERUSER_PASSWORD COMPANY_OS_MIGRATION_PASSWORD \
      COMPANY_OS_RUNTIME_PASSWORD COMPANY_OS_EXECUTOR_PASSWORD \
      COMPANY_OS_RECONCILER_PASSWORD COMPANY_OS_READONLY_PASSWORD \
      COMPANY_OS_VCS_BROKER_PASSWORD COMPANY_OS_API_TOKEN; do
      credential="$(grep -E "^${key}=.+$" "$env_file" || true)"
      [[ -n "$credential" ]] || die "existing credential file is missing non-empty $key: $env_file"
    done
    existing_profile="$(grep -E '^COMPANY_OS_PROFILE=(companion|full|dev)$' "$env_file" | tail -n 1 | cut -d= -f2- || true)"
    # Installs created before profiles existed ran the full stack. Preserve that
    # behavior rather than silently turning off their workers on upgrade.
    existing_profile="${existing_profile:-full}"
    if [[ "$PROFILE_EXPLICIT" == "1" && "$PROFILE" != "$existing_profile" ]]; then
      die "existing install uses profile '$existing_profile'; refusing to change it silently"
    fi
    PROFILE="$existing_profile"
    existing_image="$(grep -E '^COMPANY_OS_IMAGE=.+$' "$env_file" | tail -n 1 | cut -d= -f2- || true)"
    [[ -n "$existing_image" ]] || die "existing credential file is missing non-empty COMPANY_OS_IMAGE: $env_file"
    if [[ "$IMAGE_EXPLICIT" != "1" ]]; then
      IMAGE="$existing_image"
    fi
    govern_image_reference
    if [[ "$IMAGE" != "$existing_image" ]]; then
      persist_image_reference "$env_file"
      log "Pinned the runtime image to $IMAGE"
    fi
    log "Keeping existing credentials and $PROFILE profile in $env_file"
    return 0
  fi

  govern_image_reference
  log "Generating credentials for this install"
  env_tmp="$(mktemp "$INSTALL_DIR/.env.tmp.XXXXXX")"
  trap '[[ -z "${env_tmp:-}" ]] || rm -f "$env_tmp"' EXIT
  chmod 600 "$env_tmp"
  cat >"$env_tmp" <<EOF
# Generated by install.sh. These credentials exist only on this machine.
# Deleting this file orphans the database volume — back it up before you do.
COMPANY_OS_IMAGE=$IMAGE
COMPANY_OS_PROFILE=$PROFILE

COMPANY_OS_SUPERUSER=hsm
COMPANY_OS_DATABASE=hsm_company_os
COMPANY_OS_SUPERUSER_PASSWORD=$(secret)

# One NOINHERIT LOGIN per authority lane; startup refuses shared credentials.
COMPANY_OS_MIGRATION_PASSWORD=$(secret)
COMPANY_OS_RUNTIME_PASSWORD=$(secret)
COMPANY_OS_EXECUTOR_PASSWORD=$(secret)
COMPANY_OS_RECONCILER_PASSWORD=$(secret)
COMPANY_OS_READONLY_PASSWORD=$(secret)
COMPANY_OS_VCS_BROKER_PASSWORD=$(secret)

# Bearer for the Company OS HTTP API.
COMPANY_OS_API_TOKEN=$(secret)

COMPANY_OS_API_PORT=$API_PORT
COMPANY_OS_CONSOLE_PORT=$CONSOLE_PORT
COMPANY_OS_POSTGRES_PORT=${COMPANY_OS_POSTGRES_PORT:-55432}

# Finite model-gateway ceilings for companies without an explicit gateway
# policy row. Raise them here. Images built before 2026-09-15 treat an empty
# value as unbounded; current source falls back to these same platform defaults.
HSM_GATEWAY_DEFAULT_DAILY_SPEND_CAP_USD=25
HSM_GATEWAY_DEFAULT_MONTHLY_SPEND_CAP_USD=250
HSM_GATEWAY_DEFAULT_MAX_THREAD_TURNS=200
HSM_GATEWAY_DEFAULT_MAX_COMPLETION_TOKENS_PER_RUN=200000
# Output price used to meter spend against those ceilings, USD per 1k completion
# tokens. Unset means the gateway refuses paid work; set your model's real price.
HSM_LLM_PRICE_PER_1K_OUTPUT_TOKENS_USD=0.002
HSM_RTK_MODE=auto
EOF
  if [[ "$PROFILE" == "companion" ]]; then
    cat >>"$env_tmp" <<'EOF'

# The connected host supplies its own model. Company OS remains the governed
# ledger, memory, policy, and tool substrate and requires no provider key.
HSM_COMPANY_OS_COMPANION=1
HSM_OPTIONAL_BACKGROUND_WORKERS=0
HSM_MEMORY_EMBED_ENABLED=0
HSM_COMPANY_OS_ALLOW_DEGRADED=1
EOF
  else
    cat >>"$env_tmp" <<EOF

# Full/dev profiles may run native workers and therefore accept a model provider.
HSM_COMPANY_OS_COMPANION=0
HSM_OPTIONAL_BACKGROUND_WORKERS=1
HSM_MEMORY_EMBED_ENABLED=1
HSM_COMPANY_OS_ALLOW_DEGRADED=$([[ -n "${OPENROUTER_API_KEY:-}" ]] && echo 0 || echo 1)
EOF
    [[ -z "${OPENROUTER_API_KEY:-}" ]] || printf 'OPENROUTER_API_KEY=%s\n' "$OPENROUTER_API_KEY" >>"$env_tmp"
    [[ -z "${DEFAULT_LLM_MODEL:-}" ]] || printf 'DEFAULT_LLM_MODEL=%s\n' "$DEFAULT_LLM_MODEL" >>"$env_tmp"
    [[ -z "${HSM_AGENT_CHAT_MODEL:-}" ]] || printf 'HSM_AGENT_CHAT_MODEL=%s\n' "$HSM_AGENT_CHAT_MODEL" >>"$env_tmp"
  fi
  mv "$env_tmp" "$env_file"
  env_tmp=""
}

# ── Lifecycle ────────────────────────────────────────────────────────────────
wait_for_health() {
  local url="http://127.0.0.1:${API_PORT}/api/company/health"
  local boundary_url="http://127.0.0.1:${API_PORT}/api/health"
  local deadline=$((SECONDS + 300)) company_health boundary_health gateway_id gateway_status
  log "Waiting for the API (first boot applies the schema)"
  while (( SECONDS < deadline )); do
    # The health endpoint answers 200 with postgres_configured=false when the
    # ledger is absent, so a bare 200 is not readiness.
    company_health="$(curl -fsS "$url" 2>/dev/null || true)"
    if [[ "$company_health" == *'"postgres_ok":true'* ]]; then
      if [[ "$CREDENTIAL_MODE" != "1" ]]; then
        return 0
      fi
      [[ "$company_health" == *'"postgres_configured":true'* ]] || continue
      boundary_health="$(curl -fsS "$boundary_url" 2>/dev/null || true)"
      if [[ -n "$boundary_health" &&
            ( "$boundary_health" != *'"credential_boundary":"openrouter-gateway-v1"'* ||
              "$boundary_health" != *'"credential_boundary_valid":true'* ||
              "$boundary_health" != *'"credential_boundary_native_worker_backend":"hsm_native_worker"'* ) ]]; then
        die "credential boundary health contract was not satisfied"
      fi
      if [[ "$boundary_health" == *'"credential_boundary":"openrouter-gateway-v1"'* &&
            "$boundary_health" == *'"credential_boundary_valid":true'* &&
            "$boundary_health" == *'"credential_boundary_native_worker_backend":"hsm_native_worker"'* ]]; then
        gateway_id="$(compose ps -q credential-gateway 2>/dev/null || true)"
        if [[ -n "$gateway_id" ]]; then
          gateway_status="$(docker inspect --format '{{.State.Health.Status}}' "$gateway_id" 2>/dev/null || true)"
          if [[ "$gateway_status" == "unhealthy" || "$gateway_status" == "exited" ]]; then
            die "credential gateway is not healthy"
          fi
          [[ "$gateway_status" == "healthy" ]] && return 0
        fi
      fi
    fi
    if [[ "$(compose ps -q api)" == "" ]]; then
      die "the api container is gone — see: docker compose -f $INSTALL_DIR/docker-compose.company-os.yml logs api"
    fi
    sleep 2
  done
  compose logs --tail 40 api >&2 || true
  die "the API did not become healthy within 5 minutes"
}

verify_stack() {
  local api="http://127.0.0.1:${API_PORT}"
  local health boundary_health gateway_id gateway_status token
  health="$(curl -fsS "$api/api/company/health")" || die "health endpoint did not answer"
  printf '    health   %s\n' "$health"

  if [[ "$CREDENTIAL_MODE" == "1" ]]; then
    boundary_health="$(curl -fsS "$api/api/health")" \
      || die "credential boundary health endpoint did not answer"
    [[ "$boundary_health" == *'"credential_boundary":"openrouter-gateway-v1"'* &&
       "$boundary_health" == *'"credential_boundary_valid":true'* &&
       "$boundary_health" == *'"credential_boundary_native_worker_backend":"hsm_native_worker"'* ]] \
      || die "credential boundary health contract was not satisfied"
    gateway_id="$(compose ps -q credential-gateway 2>/dev/null || true)"
    [[ -n "$gateway_id" ]] || die "credential gateway container is not running"
    gateway_status="$(docker inspect --format '{{.State.Health.Status}}' "$gateway_id" 2>/dev/null || true)"
    [[ "$gateway_status" == "healthy" ]] || die "credential gateway is not healthy"
    printf '    gateway  healthy on the private credential network\n'
  fi

  # An unauthenticated read proves the port is live; the governed surface is
  # proven by an authenticated call, which is the one that matters.
  token="$(grep '^COMPANY_OS_API_TOKEN=' "$INSTALL_DIR/.env" | cut -d= -f2-)"
  if curl -fsS -H "Authorization: Bearer $token" "$api/api/company/companies" >/dev/null 2>&1; then
    printf '    auth     bearer token accepted on /api/company/companies\n'
  elif [[ "$CREDENTIAL_MODE" == "1" ]]; then
    die "authenticated read failed — check the API and gateway logs"
  else
    printf '    auth     WARNING: authenticated read failed — check `docker compose logs api`\n'
  fi

  if curl -fsS -o /dev/null "http://127.0.0.1:${CONSOLE_PORT}/" 2>/dev/null; then
    printf '    console  serving on %s\n' "$CONSOLE_PORT"
  elif [[ "$CREDENTIAL_MODE" == "1" ]]; then
    die "console did not answer on ${CONSOLE_PORT}"
  else
    printf '    console  WARNING: not answering yet on %s\n' "$CONSOLE_PORT"
  fi
}

open_browser() {
  local url="http://127.0.0.1:${CONSOLE_PORT}"
  if [[ "$OPEN_BROWSER" != "1" ]]; then return 0; fi
  if command -v open >/dev/null 2>&1; then open "$url" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 || true
  fi
}

print_summary() {
  local degraded profile compose_files compose_prefix update_command stop_command
  degraded="$(grep '^HSM_COMPANY_OS_ALLOW_DEGRADED=' "$INSTALL_DIR/.env" | cut -d= -f2-)"
  profile="$(grep '^COMPANY_OS_PROFILE=' "$INSTALL_DIR/.env" | cut -d= -f2-)"
  compose_files="-f \"$INSTALL_DIR/docker-compose.company-os.yml\""
  if [[ "$CREDENTIAL_MODE" == "1" ]]; then
    compose_files="$compose_files -f \"$INSTALL_DIR/docker-compose.credential-gateway.yml\""
  fi
  compose_prefix="docker compose --project-directory \"$INSTALL_DIR\" --env-file \"$INSTALL_DIR/.env\" $compose_files"
  stop_command="$compose_prefix down"
  update_command="bash install.sh --dir \"$INSTALL_DIR\" --image ghcr.io/permutationresearch/company-os:latest --no-open"
  if [[ "$CREDENTIAL_MODE" == "1" ]]; then
    stop_command="bash install.sh --dir \"$INSTALL_DIR\" --uninstall"
    compose_prefix="env -u COMPOSE_PROJECT_NAME $compose_prefix"
    update_command="bash install.sh --dir \"$INSTALL_DIR\" --profile full --credential-gateway --image ghcr.io/permutationresearch/company-os@sha256:YOUR_REVIEWED_DIGEST --no-open"
  fi
  cat <<EOF

Company OS is running.

  Console  http://127.0.0.1:${CONSOLE_PORT}
  API      http://127.0.0.1:${API_PORT}/api/company/health
  Config   $INSTALL_DIR/.env   (credentials — chmod 600, not in any repo)

  Stop     $stop_command
  Logs     $compose_prefix logs -f api
  Update   $update_command

EOF
  if [[ "$profile" == "companion" ]]; then
    cat <<EOF
Companion mode is host-managed: Claude Code or Codex supplies its own model.
Company OS is ready as the governed ledger, memory, policy, and tool substrate;
no Company OS model provider or model key is required.

Connect your agent from the project you work in:

  npx --yes @hsm/company-os-mcp-server connect claude   # or: connect codex

That writes .mcp.json (Claude Code) or .codex/config.toml (Codex) without any
credential. Reload the agent and ask it to start the Company Passport.

EOF
  elif [[ "$degraded" == "1" ]]; then
    cat <<EOF
Native Company OS workers are enabled but no model provider is configured, so
those workers cannot execute work. Add a key and restart:

  echo 'OPENROUTER_API_KEY=sk-or-...' >> $INSTALL_DIR/.env
  docker compose -f $INSTALL_DIR/docker-compose.company-os.yml up -d

EOF
  elif [[ "$CREDENTIAL_MODE" == "1" ]]; then
    cat <<EOF
Native workers use the local credential gateway and the selected model.
The provider key remains in $CREDENTIAL_SECRETS_DIR and is never placed in .env.

EOF
  fi
}

uninstall() {
  require_docker
  [[ -f "$INSTALL_DIR/docker-compose.company-os.yml" ]] || die "no install found at $INSTALL_DIR"
  if is_secure_env_file "$INSTALL_DIR/.env"; then
    CREDENTIAL_MODE=1
  fi
  log "Stopping Company OS (data volumes are kept)"
  compose down
  local compose_files="-f \"$INSTALL_DIR/docker-compose.company-os.yml\""
  if [[ "$CREDENTIAL_MODE" == "1" ]]; then
    compose_files="$compose_files -f \"$INSTALL_DIR/docker-compose.credential-gateway.yml\""
  fi
  local compose_prefix="docker compose --project-directory \"$INSTALL_DIR\" --env-file \"$INSTALL_DIR/.env\" $compose_files"
  if [[ "$CREDENTIAL_MODE" == "1" ]]; then
    compose_prefix="env -u COMPOSE_PROJECT_NAME $compose_prefix"
  fi
  cat <<EOF

Stopped. Data volumes are still present.
To delete them too:

  $compose_prefix down -v

EOF
}

main() {
  if [[ "$UNINSTALL" == "1" ]]; then
    uninstall
    return 0
  fi

  log "Installing HSM-II Company OS"
  # --no-start writes configuration and nothing else, so it has no reason to
  # demand a running daemon.
  if [[ "$START_STACK" == "1" ]]; then
    require_docker
  fi
  if is_secure_env_file "$INSTALL_DIR/.env"; then
    CREDENTIAL_MODE=1
  elif [[ "$CREDENTIAL_GATEWAY_REQUESTED" == "1" ]]; then
    [[ ! -e "$INSTALL_DIR/.env" && ! -L "$INSTALL_DIR/.env" ]] \
      || die "refusing to enable the credential gateway over an existing unsealed install"
    [[ "$PROFILE" == "full" && "$PROFILE_EXPLICIT" == "1" ]] \
      || die "a fresh credential gateway install requires --profile full"
    validate_provider_key_file
    CREDENTIAL_MODE=1
  fi
  fetch_stack_files
  write_env

  # A second run keeps the existing .env, so the ports to verify are the ones
  # recorded there, not whatever this invocation defaulted to.
  API_PORT="$(grep '^COMPANY_OS_API_PORT=' "$INSTALL_DIR/.env" | cut -d= -f2-)"
  CONSOLE_PORT="$(grep '^COMPANY_OS_CONSOLE_PORT=' "$INSTALL_DIR/.env" | cut -d= -f2-)"

  if [[ "$START_STACK" != "1" ]]; then
    log "Wrote configuration to $INSTALL_DIR (--no-start)"
    return 0
  fi

  log "Pulling images"
  compose pull --quiet

  log "Starting Postgres, the role-lane bootstrap, the API, and the console"
  compose up -d --no-build

  wait_for_health
  log "Verifying"
  verify_stack
  print_summary
  open_browser
}

main "$@"
