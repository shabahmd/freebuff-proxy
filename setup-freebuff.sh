#!/usr/bin/env bash
#
# setup-freebuff.sh — install & verify freebuff-proxy on THIS machine.
#
# Safe to re-run: every step is idempotent and existing state is left alone.
# The script finishes by checking your exit IP, because a datacenter ASN is the
# thing that gets a Freebuff account banned.
#
# Usage:
#   ./setup-freebuff.sh                 # install/upgrade + verify
#   ./setup-freebuff.sh --dry-run       # print the plan, change nothing
#   ./setup-freebuff.sh --dir ~/fb      # install somewhere else
#   ./setup-freebuff.sh --port 9000
#
# Exit codes:
#   0  installed and verified, exit IP looks residential
#   1  a step failed
#   2  bad usage / unsupported host
#  10  installed and verified, BUT exit IP looks like a datacenter  <-- read this
#
set -euo pipefail

# ---------------------------------------------------------------- settings ---
PORT=8787
DIR=""
DRY_RUN=0
REPO_URL="https://github.com/HengXin666/freebuff-proxy.git"
REPO_DIR_NAME="freebuff-proxy"

# Pinned: bun 1.4.2 linux-x64-musl, verified byte-for-byte.
# The container image is node:22-alpine (musl), so a glibc build will NOT run
# in it. This is the only build that works with the prebuilt GHCR image.
BUN_VERSION="1.4.2"
BUN_URL="https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-x64-musl.zip"
BUN_ZIP_SHA256="4835eca59d6da70f4674f5642f6e459dcadab773695b2ed9922d131057989742"
BUN_EXPECT="1.4.2"

# Substrings that mean "this is a hosting provider, not a home connection".
DATACENTER_HINTS="amazon|aws|google|azure|microsoft|oracle|leaseweb|linode|digitalocean|hetzner|contabo|ovh|vultr|cloudflare|choopa|hosting|datacenter|data ?center|server|vps|dedicated|tenant|proxy|vpn|scaleway|alibaba|tencent|huawei"

STEP=0

# ------------------------------------------------------------------ helpers ---
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
  C_INFO=$'\033[36m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_INFO=""; C_DIM=""; C_OFF=""
fi

step()  { STEP=$((STEP + 1)); printf '\n%s[%02d] %s%s\n' "$C_INFO" "$STEP" "$1" "$C_OFF"; }
ok()    { printf '     %s✓%s %s\n' "$C_OK" "$C_OFF" "$1"; }
info()  { printf '     %s·%s %s\n' "$C_DIM" "$C_OFF" "$1"; }
warn()  { printf '     %s!%s %s\n' "$C_WARN" "$C_OFF" "$1"; }
die()   { printf '\n%s✗ %s%s\n\n' "$C_ERR" "$1" "$C_OFF" >&2; exit 1; }

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '     %s[dry-run]%s %s\n' "$C_DIM" "$C_OFF" "$*"
    return 0
  fi
  "$@"
}

need() { command -v "$1" >/dev/null 2>&1 || die "$2"; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# ---------------------------------------------------------------- arguments ---
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --dir)     [ $# -ge 2 ] || die "--dir needs a path"; DIR=$2; shift ;;
    --port)    [ $# -ge 2 ] || die "--port needs a number"; PORT=$2; shift ;;
    -h|--help) usage 0 ;;
    *)         printf 'unknown option: %s\n\n' "$1" >&2; usage 2 ;;
  esac
  shift
done

case "$PORT" in ''|*[!0-9]*) die "--port must be a number, got '$PORT'" ;; esac

if [ -z "$DIR" ]; then
  if [ -d "$HOME/Documents/Code_Projects/$REPO_DIR_NAME" ]; then
    DIR="$HOME/Documents/Code_Projects/$REPO_DIR_NAME"
  else
    DIR="$PWD/$REPO_DIR_NAME"
  fi
fi

printf '%s' "$C_INFO"
cat <<'BANNER'
╔══════════════════════════════════════════════════════════════╗
║  freebuff-proxy  ·  home setup & verification                ║
╚══════════════════════════════════════════════════════════════╝
BANNER
printf '%s' "$C_OFF"
printf '  target : %s\n  port   : %s\n  mode   : %s\n' \
  "$DIR" "$PORT" "$([ "$DRY_RUN" -eq 1 ] && echo 'dry-run (no changes)' || echo 'install')"

COMPOSE_FILE="$DIR/docker-compose.yml"

# ------------------------------------------------------------- 1. preflight ---
step "Preflight"

[ "$(uname -m)" = "x86_64" ] || die "This script is for x86_64 Linux only (found $(uname -m)). Install Docker and follow RUN-AT-HOME.md manually."

need git   "git is required"
need curl  "curl is required"
need docker "Docker is not installed. Install it first:
  sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2
  sudo usermod -aG docker \"\$USER\"   # then log out and back in"
ok "git, curl present"

docker compose version >/dev/null 2>&1 || die "Docker Compose v2 not found (docker compose). Install docker-compose-v2."
ok "docker compose $(docker compose version --short 2>/dev/null || echo 'available')"

if docker info >/dev/null 2>&1; then
  ok "docker daemon reachable ($(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'))"
elif [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ] && docker info >/dev/null 2>&1; then
  die "docker daemon unreachable"
else
  # group membership often needs a fresh login; retry through sg as a fallback
  if command -v sg >/dev/null 2>&1 && sg docker -c 'docker info' >/dev/null 2>&1; then
    warn "docker daemon not directly reachable, but works via 'sg docker'. Use that prefix."
    DOCKER=(sg docker -c)
  else
    die "docker daemon unreachable. Log out and back in after 'usermod -aG docker \$USER'."
  fi
fi
[ "${DOCKER+x}" = x ] || DOCKER=()

# helper: run docker compose against THIS project's files, from anywhere.
# --project-directory matters: it is what makes compose resolve the relative
# ./data volume and read .env from the project, not from the caller's cwd.
dc() {
  if [ "${#DOCKER[@]}" -gt 0 ]; then
    sg docker -c "docker compose -f $(printf '%q' "$COMPOSE_FILE") --project-directory $(printf '%q' "$DIR") $*"
  else
    docker compose -f "$COMPOSE_FILE" --project-directory "$DIR" "$@"
  fi
}

if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$PORT\$"; then
  if curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/healthz" 2>/dev/null | grep -q '"ok"'; then
    ok "port $PORT already serving freebuff-proxy (previous install — will be reused)"
  else
    warn "port $PORT is in use by another process — startup will likely fail"
  fi
fi

free_mb=$(df -Pm "$(dirname "$DIR")" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
if [ "${free_mb:-0}" -lt 500 ] 2>/dev/null; then
  warn "only ${free_mb}MB free — the image needs ~500MB."
else
  ok "${free_mb}MB free disk"
fi

# ----------------------------------------------------------------- 2. clone ---
step "Source"

if [ -d "$DIR/.git" ]; then
  ok "already cloned: $DIR"
  if [ "$DRY_RUN" -eq 0 ]; then
    info "$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null || echo '?') $(git -C "$DIR" describe --tags --always 2>/dev/null || echo '')"
  fi
else
  run git clone --depth 1 "$REPO_URL" "$DIR"
  ok "cloned into $DIR"
fi

[ -f "$DIR/docker-compose.yml" ] || die "no docker-compose.yml in $DIR — wrong directory?"
[ -d "$DIR" ] || die "$DIR does not exist"

# ------------------------------------------------------------------ 3. .env ---
step "Configuration"

ENV_FILE="$DIR/.env"
if [ -f "$ENV_FILE" ]; then
  ok ".env already exists (left untouched)"
else
  # NOTE: do not write this as `tr ... | head -c 24`. head exits first, tr dies
  # with SIGPIPE, and under `set -o pipefail` that aborts the whole script.
  # Read first, filter second, slice with bash instead.
  PW="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
  PW="${PW:0:24}"
  [ "${#PW}" -eq 24 ] || die "could not generate an admin password"
  if [ "$DRY_RUN" -eq 1 ]; then
    run printf 'PORT=%s\nADMIN_USERNAME=admin\nADMIN_PASSWORD=<generated>\nHTTP_PROXY=\nHTTPS_PROXY=\nNO_PROXY=127.0.0.1,localhost,172.16.0.0/12\nTZ=Asia/Kolkata\n' "$PORT" > "$ENV_FILE"
  else
    printf 'PORT=%s\nADMIN_USERNAME=admin\nADMIN_PASSWORD=%s\nHTTP_PROXY=\nHTTPS_PROXY=\nNO_PROXY=127.0.0.1,localhost,172.16.0.0/12\nTZ=Asia/Kolkata\n' \
      "$PORT" "$PW" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok "created .env (mode 600)"
    printf '\n%s  ┌──────────────────────────────────────────────┐%s\n' "$C_WARN" "$C_OFF"
    printf '%s  │  ADMIN USER : admin                          │%s\n' "$C_WARN" "$C_OFF"
    printf '%s  │  PASSWORD   : %-30s │%s\n' "$C_WARN" "$PW" "$C_OFF"
    printf '%s  │  Save this now — it is not shown again.      │%s\n' "$C_WARN" "$C_OFF"
    printf '%s  └──────────────────────────────────────────────┘%s\n\n' "$C_WARN" "$C_OFF"
  fi
fi

# ------------------------------------------------------------------- 4. bun ---
step "bun runtime (required for upstream chat calls)"

BUN_PATH="$DIR/cli-bridge/bun"
bun_present() { [ -s "$BUN_PATH" ]; }

if bun_present; then
  ok "cli-bridge/bun already present ($(stat -c %s "$BUN_PATH" 2>/dev/null || echo '?') bytes)"
else
  TMP="$(mktemp -d)"
  info "downloading bun ${BUN_VERSION} (linux-x64-musl, ~34MB)"
  if [ "$DRY_RUN" -eq 1 ]; then
    run curl -fsSL -o "$TMP/bun.zip" "$BUN_URL"
  else
    curl -fsSL --retry 3 -o "$TMP/bun.zip" "$BUN_URL" || die "download failed: $BUN_URL"
    got="$(sha256sum "$TMP/bun.zip" | awk '{print $1}')"
    [ "$got" = "$BUN_ZIP_SHA256" ] || die "checksum mismatch for bun.zip
  expected $BUN_ZIP_SHA256
  got      $got
The download is corrupt or upstream changed. Refusing to install."
    ok "download verified (sha256 matches)"
    command -v python3 >/dev/null 2>&1 || die "python3 is required to unzip bun (apt install python3)"
    python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$TMP/bun.zip" "$TMP/x"
    install -m 0755 "$TMP/x/bun-linux-x64-musl/bun" "$BUN_PATH" || die "could not install bun"
    ok "installed to cli-bridge/bun"
  fi
  rm -rf "$TMP" 2>/dev/null || true
fi

if [ "$DRY_RUN" -eq 0 ]; then
  interp="$(readelf -l "$BUN_PATH" 2>/dev/null | grep -oP 'interpreter: \K\S+' | tr -d ']' || echo '?')"
  info "binary interpreter: $interp"
  case "$interp" in
    *musl*) ok "musl build — correct for the alpine-based image" ;;
    *)      warn "this looks like a glibc build; it will NOT execute in the alpine container" ;;
  esac
fi

# ------------------------------------------------------- 5. mount into image ---
step "Wire bun into the container"

COMPOSE="$DIR/docker-compose.yml"
MOUNT_LINE="./cli-bridge/bun:/app/cli-bridge/bun:ro"

if grep -qF "$MOUNT_LINE" "$COMPOSE"; then
  ok "docker-compose.yml already mounts cli-bridge/bun"
else
  run python3 - "$COMPOSE" "$MOUNT_LINE" <<'PY'
import sys
path, line = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
if line in text:
    sys.exit(0)
needle = "      - ./data:/data"
if needle not in text:
    sys.exit("could not find '      - ./data:/data' in docker-compose.yml")
text = text.replace(
    needle,
    needle + "\n      # bun runtime from the official client (not shipped in the image)\n      - " + line,
    1,
)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(text)
PY
  [ $? -eq 0 ] || die "failed to add the volumes entry to docker-compose.yml"
  ok "added mount: $MOUNT_LINE"
fi

dc config --quiet >/dev/null 2>&1 || die "docker-compose.yml is invalid (docker compose config failed)"
ok "compose file is valid"

# ------------------------------------------------------------------ 6. start ---
step "Start the service"

if [ "$DRY_RUN" -eq 0 ]; then
  # build: . means a locally built image (e.g. carrying a local patch) —
  # there is nothing to pull in that case, so build instead.
  if grep -qE '^[[:space:]]+build:' "$COMPOSE_FILE" 2>/dev/null; then
    info "compose uses build: . — building the local image (includes local patches)"
    dc build >/dev/null || die "docker compose build failed"
  else
    info "pulling image (this can take a minute on first run)"
    dc pull >/dev/null || warn "image pull failed — will try the locally cached image"
  fi
  dc up -d || die "docker compose up failed"

  printf '     %s·%s waiting for health' "$C_DIM" "$C_OFF"
  healthy=0
  for _ in $(seq 1 40); do
    st="$(dc ps --format '{{.Status}}' 2>/dev/null | awk 'NR==1')"
    case "$st" in
      *healthy*) healthy=1; break ;;
      *unhealthy*|*Exited*) printf '\n'; die "container is $st" ;;
    esac
    printf '.'
    sleep 2
  done
  printf '\n'
  [ "$healthy" -eq 1 ] || die "container did not become healthy within 80s"
  ok "container healthy"
else
  run dc pull
  run dc up -d
fi

# ---------------------------------------------------------------- 7. verify ---
step "Verify"

if [ "$DRY_RUN" -eq 0 ]; then
  hz="$(curl -fsS --max-time 10 "http://127.0.0.1:${PORT}/healthz" 2>/dev/null || true)"
  case "$hz" in
    *'"ok"'*) ok "/healthz -> $hz" ;;
    *) die "/healthz did not respond (got: ${hz:-nothing}) on port $PORT" ;;
  esac

  # The critical check: the service reports "healthy" even when bun cannot run.
  bv="$(dc exec -T freebuff-proxy /app/cli-bridge/bun --version 2>&1 | tr -d '\r' | tail -n 1)"
  if [ "$bv" = "$BUN_EXPECT" ]; then
    ok "bun executes inside the container ($bv)"
  else
    printf '\n%s  ✗ bun did not run inside the container.%s\n' "$C_ERR" "$C_OFF"
    printf '     got: %s\n' "${bv:-<no output>}"
    cat <<'HINT'
     The image is alpine/musl; a glibc build of bun cannot run in it.
     Re-download the musl build:
       curl -sL -o /tmp/b.zip https://github.com/oven-sh/bun/releases/download/bun-v1.4.2/bun-linux-x64-musl.zip
       python3 -c "import zipfile;zipfile.ZipFile('/tmp/b.zip').extractall('/tmp/bx')"
       sudo install -m 0755 /tmp/bx/bun-linux-x64-musl/bun cli-bridge/bun
       docker compose up -d --force-recreate
HINT
    exit 1
  fi

  nmodels=0
  adm_user="$(grep '^ADMIN_USERNAME=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
  adm_pass="$(grep '^ADMIN_PASSWORD=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
  if [ -n "$adm_user" ] && [ -n "$adm_pass" ]; then
    login="$(curl -fsS --max-time 15 -X POST "http://127.0.0.1:${PORT}/api/auth/login" \
      -H 'Content-Type: application/json' \
      -d "{\"username\":\"$adm_user\",\"password\":\"$adm_pass\"}" 2>/dev/null || true)"
    apikey="$(printf '%s' "$login" | python3 -c 'import sys,json
try:
    print(json.load(sys.stdin)["user"]["apiKey"])
except Exception:
    pass' 2>/dev/null || true)"
    if [ -n "$apikey" ]; then
      ok "admin login works"
      models="$(curl -fsS --max-time 20 -H "Authorization: Bearer $apikey" \
        "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || true)"
      nmodels="$(printf '%s' "$models" | python3 -c 'import sys,json
try:
    print(len(json.load(sys.stdin).get("data") or []))
except Exception:
    print(0)' 2>/dev/null || echo 0)"
      case "$nmodels" in ''|*[!0-9]*) nmodels=0 ;; esac
    else
      warn "admin login failed — check ADMIN_USERNAME/ADMIN_PASSWORD in .env"
    fi
  fi

  if [ "$nmodels" -gt 0 ] 2>/dev/null; then
    ok "/v1/models lists $nmodels models"
  else
    warn "/v1/models empty — expected until you add a Freebuff account in the console"
  fi

  if curl -fsS --max-time 10 -o /dev/null "http://127.0.0.1:${PORT}/"; then
    ok "console reachable at http://127.0.0.1:${PORT} (user: ${adm_user:-admin})"
  fi

  bind="$(grep -oP 'FREEBUFF_PROXY_HOST:\s*\K\S+' "$COMPOSE" 2>/dev/null || echo 0.0.0.0)"
  if [ "$bind" = "0.0.0.0" ]; then
    warn "console is bound to 0.0.0.0 — reachable from your LAN. Set 127.0.0.1 if that is not what you want."
  fi
fi

# ----------------------------------------------------- 8. egress (critical) ---
step "Check your exit IP  (decides whether an account is safe)"

if [ "$DRY_RUN" -eq 1 ]; then
  run curl -fsS https://api.ipquery.io/ -o /dev/null
else
  EJ="$(curl -fsS --max-time 25 'https://api.ipquery.io/?format=json' 2>/dev/null || true)"
  if [ -z "$EJ" ]; then
    warn "could not determine exit IP (offline?) — verify manually before adding an account"
  else
    read -r EIP EASN EORG ECOUNTRY <<EOF
$(printf '%s' "$EJ" | python3 -c 'import sys,json
d=json.load(sys.stdin); i=d.get("isp") or {}; l=d.get("location") or {}
print((d.get("ip") or l.get("ip") or "?"), (i.get("asn") or "?"), (i.get("org") or i.get("isp") or "?").replace(" ","_"), (l.get("country_code") or d.get("country_code") or "?"))' 2>/dev/null || echo "? ? ? ?")
EOF
    EORG="${EORG//_/ }"
    printf '     ip %s | %s %s | %s\n' "$EIP" "$EASN" "$EORG" "$ECOUNTRY"
    if printf '%s %s' "$EASN" "$EORG" | grep -qiE "$DATACENTER_HINTS"; then
      printf '\n%s  ╔══════════════════════════════════════════════════════════════╗%s\n' "$C_ERR" "$C_OFF"
      printf '%s  ║  STOP — this exit IP looks like a DATACENTER, not a home IP   ║%s\n' "$C_ERR" "$C_OFF"
      printf '%s  ╚══════════════════════════════════════════════════════════════╝%s\n' "$C_ERR" "$C_OFF"
      cat <<EOF
     Freebuff uses the exit IP to judge whether an account looks automated.
     Hosting IPs are the main reason accounts get banned.

     DO NOT add your Freebuff account yet. Run this on your home connection
     (a normal broadband ISP is what you want), then re-run this script.

     If you must use this machine, put a residential proxy in the console
     under 代理设置 — but a datacenter IP in front of a residential proxy is
     still a datacenter IP to anyone checking.
EOF
      EGRESS_BAD=1
    else
      ok "looks like a normal ISP — safe to add an account"
      EGRESS_BAD=0
    fi
  fi
fi

# ---------------------------------------------------------------- 9. summary ---
printf '\n%s' "$C_INFO"
cat <<'BANNER'
──────────────────────────────────────────────────────────────
BANNER
printf '%s' "$C_OFF"
printf '  Console : http://127.0.0.1:%s\n' "$PORT"
printf '  Install : %s\n' "$DIR"
printf '  Endpoint: http://127.0.0.1:%s/v1\n' "$PORT"
printf '  API key : console -> 用户管理 -> your key (sk-fb-...)\n\n'
cat <<'NEXT'
  Remaining steps (in the console):
    1. 代理设置  -> leave EMPTY (you are the exit; no proxy needed at home)
    2. 总览 -> ＋ 添加账号  -> sign in to Freebuff in the browser
    3. 测试对话  -> send one short message to confirm it works

  Then add this to ~/.config/opencode/opencode.json:
NEXT
cat <<'JSON'
  {
    "provider": {
      "freebuff": {
        "npm": "@ai-sdk/openai-compatible",
        "name": "Freebuff (home)",
        "options": {
          "baseURL": "http://127.0.0.1:PORT/v1",
          "apiKey": "sk-fb-..."
        },
      }
    }
  }
JSON
cat <<'TAIL'

  Model ids must match /v1/models exactly. Restart OpenCode, then /models.
TAIL

if [ "${EGRESS_BAD:-0}" -eq 1 ]; then
  exit 10
fi
exit 0