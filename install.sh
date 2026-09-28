#!/usr/bin/env bash
# =============================================================================
#  Minecraft Discord Bot — all-in-one VPS installer / updater
#
#  What it does (safe to re-run, it doubles as the updater):
#    1. Installs base packages (curl, git, unzip, ...) non-interactively
#    2. Installs Node.js 22 (replaces old/ancient distro Node if found)
#    3. Installs PM2 (keeps the bot alive + starts it on boot)
#    4. Clones your GitHub repo (or pulls the latest if already installed)
#    5. Asks for DISCORD_TOKEN / DISCORD_CLIENT_ID / BOT_OWNER_ID -> writes .env
#    6. npm install, then starts/restarts the bot under PM2
#
#  Usage (as root, Ubuntu/Debian):
#    bash <(curl -fsSL https://raw.githubusercontent.com/USERNAME/REPO/main/install.sh)
#  or:
#    curl -fsSL https://raw.githubusercontent.com/USERNAME/REPO/main/install.sh | bash
#
#  Options:
#    --reconfigure   re-enter token / client id / owner id and rewrite .env
#    --help          show this help
#
#  FULLY AUTOMATIC (no prompts) — secrets never live in the repo:
#    Option A, inline (token only ever typed on the VPS):
#      DISCORD_TOKEN='xxx' BOT_OWNER_ID='123' bash <(curl -fsSL URL)
#    Option B, secrets file on the VPS (create once, script reads it every run):
#      /root/.mc-bot.env   containing lines like
#        DISCORD_TOKEN=xxx
#        BOT_OWNER_ID=123
#    DISCORD_CLIENT_ID and BOT_OWNER_ID are public IDs, so they are baked in below.
#    Anything still missing is prompted for (only if a terminal is available).
#
#  CLOUD BACKUP (optional, recommended): survive the VPS expiring.
#    Encrypts data/ (accounts, servers, captured passwords) and pushes it to a
#    PRIVATE GitHub repo every few minutes; a brand-new VPS restores it
#    automatically before the bot starts. Provide these three (inline or in
#    the secrets file):
#      BACKUP_REPO=username/private-repo     (create it empty + private)
#      BACKUP_TOKEN=github_pat_...           (fine-grained: that repo, Contents R/W)
#      BACKUP_PASSPHRASE=...                 (8+ chars: letters/digits . _ -  — KEEP IT SAFE,
#                                             without it the backup cannot be decrypted)
#    Optional: BACKUP_INTERVAL_MIN (default 5)
#    After install:  mc-bot-backup status | backup | restore
#
#  Overridable env vars: REPO_URL, BRANCH, INSTALL_DIR, APP_NAME
# =============================================================================

# >>> EDIT THIS to your own repository <<<
REPO_URL="${REPO_URL:-https://github.com/USERNAME/REPO.git}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/minecraft-bot}"
APP_NAME="${APP_NAME:-mc-bot}"
NODE_MAJOR=22

# Application ID is NOT a secret (it's visible in invite links) — fine to keep here.
# NEVER put the bot token or other secrets in this file if it goes on GitHub.
DEFAULT_CLIENT_ID="1553982041886822440"
# Owner's Discord user ID — also public, safe to keep here.
DEFAULT_OWNER_ID="1058735047521349662"

APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
BACKUP_ENABLED=0
BACKUP_BIN="/usr/local/bin/mc-bot-backup"
SECRETS_FILE="${SECRETS_FILE:-/root/.mc-bot.env}"

set -euo pipefail

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[36m'
else
  C_RESET=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""
fi

step() { echo; echo "${C_BLUE}==>${C_RESET} $*"; }
ok()   { echo "${C_GREEN}[ok]${C_RESET} $*"; }
warn() { echo "${C_YELLOW}[!]${C_RESET} $*"; }
die()  { echo "${C_RED}[error]${C_RESET} $*" >&2; exit 1; }

show_help() {
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0" 2>/dev/null || true
}

# ask VAR "Prompt text" [secret]
# Skips the prompt when VAR is already set in the environment.
ask() {
  local __var="$1" __prompt="$2" __secret="${3:-}" __val=""
  if [ -n "${!__var:-}" ]; then return 0; fi
  [ -r /dev/tty ] || die "No terminal available for input. Set $__var as an environment variable and re-run."
  while [ -z "$__val" ]; do
    if [ -n "$__secret" ]; then
      read -r -s -p "$__prompt: " __val < /dev/tty
      echo > /dev/tty
    else
      read -r -p "$__prompt: " __val < /dev/tty
    fi
    # strip whitespace and stray quotes from pasted values
    __val="$(printf '%s' "$__val" | tr -d '[:space:]"'"'"'')"
  done
  printf -v "$__var" '%s' "$__val"
}

# Reads KEY=VALUE lines for the 3 known keys only (never executes the file).
load_secrets() {
  [ -f "$SECRETS_FILE" ] || return 0
  local key val line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      DISCORD_TOKEN=*|DISCORD_CLIENT_ID=*|BOT_OWNER_ID=*|DISCORD_DEV_GUILD_ID=*|BACKUP_REPO=*|BACKUP_TOKEN=*|BACKUP_PASSPHRASE=*|BACKUP_INTERVAL_MIN=*)
        key="${line%%=*}"; val="${line#*=}"
        val="$(printf '%s' "$val" | tr -d '[:space:]"'"'"'')"
        # environment variables win over the file
        if [ -z "${!key:-}" ] && [ -n "$val" ]; then printf -v "$key" '%s' "$val"; fi
        ;;
    esac
  done < "$SECRETS_FILE"
  ok "Loaded secrets from $SECRETS_FILE"
}

# Installs the backup tool + cron job, and restores from the cloud on a fresh VPS.
setup_backup() {
  local app_dir="$1"
  if [ -z "${BACKUP_REPO:-}" ] || [ -z "${BACKUP_TOKEN:-}" ] || [ -z "${BACKUP_PASSPHRASE:-}" ]; then
    warn "Cloud backup NOT configured — data lives only on this VPS (set BACKUP_REPO, BACKUP_TOKEN, BACKUP_PASSPHRASE)."
    return 0
  fi
  [[ "$BACKUP_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "BACKUP_REPO must look like username/repo-name"
  [[ "$BACKUP_PASSPHRASE" =~ ^[A-Za-z0-9._-]{8,}$ ]] || die "BACKUP_PASSPHRASE must be 8+ characters, only letters, digits, . _ -"
  local interval="${BACKUP_INTERVAL_MIN:-5}"
  [[ "$interval" =~ ^[0-9]+$ ]] && [ "$interval" -ge 1 ] && [ "$interval" -le 59 ] || die "BACKUP_INTERVAL_MIN must be 1-59"

  step "Setting up encrypted cloud backup"
  apt-get install "${APT_OPTS[@]}" openssl cron git tar gzip util-linux
  systemctl enable --now cron >/dev/null 2>&1 || service cron start >/dev/null 2>&1 || true

  # Persist backup settings (cron needs them). Keep any other lines already in the file.
  ( umask 077
    touch "$SECRETS_FILE"
    { grep -v '^BACKUP_' "$SECRETS_FILE" || true; } > "$SECRETS_FILE.tmp"
    {
      cat "$SECRETS_FILE.tmp"
      printf 'BACKUP_REPO=%s\n' "$BACKUP_REPO"
      printf 'BACKUP_TOKEN=%s\n' "$BACKUP_TOKEN"
      printf 'BACKUP_PASSPHRASE=%s\n' "$BACKUP_PASSPHRASE"
    } > "$SECRETS_FILE"
    rm -f "$SECRETS_FILE.tmp" )
  chmod 600 "$SECRETS_FILE"

  # Install the backup tool with this machine's paths baked in.
  cat > "$BACKUP_BIN" <<'MCBOT_BACKUP_EOF'
#!/usr/bin/env bash
# mc-bot-backup — encrypted cloud backup/restore for the bot's data/ folder.
# Stores ONE AES-256 encrypted file in a private git repo (GitHub).
#   mc-bot-backup backup    push a new backup if data changed (cron runs this)
#   mc-bot-backup restore   restore data/ from the cloud (only if local data/ is empty)
#   mc-bot-backup status    show config + last backup info
set -euo pipefail

APP_DIR="__APP_DIR__"
SECRETS_FILE="__SECRETS_FILE__"
STATE_DIR="${MC_BACKUP_STATE_DIR:-/var/lib/mc-bot-backup}"
WORK_DIR="$STATE_DIR/repo"
BACKUP_FILE="data.tar.gz.enc"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"

# Config comes from the secrets file; real environment variables win.
BACKUP_REPO="${BACKUP_REPO:-}"; BACKUP_TOKEN="${BACKUP_TOKEN:-}"; BACKUP_PASSPHRASE="${BACKUP_PASSPHRASE:-}"
if [ -f "$SECRETS_FILE" ]; then
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in
      BACKUP_REPO|BACKUP_TOKEN|BACKUP_PASSPHRASE)
        if [ -z "${!k}" ]; then printf -v "$k" '%s' "$v"; fi ;;
    esac
  done < "$SECRETS_FILE"
fi
BACKUP_GIT_URL="${BACKUP_GIT_URL:-https://github.com/${BACKUP_REPO}.git}"

need_config() {
  if [ -z "$BACKUP_REPO" ] || [ -z "$BACKUP_TOKEN" ] || [ -z "$BACKUP_PASSPHRASE" ]; then
    die "backup not configured (BACKUP_REPO / BACKUP_TOKEN / BACKUP_PASSPHRASE missing in $SECRETS_FILE)"
  fi
}

has_data() {
  [ -d "$APP_DIR/data" ] && [ -n "$(find "$APP_DIR/data" -type f -print -quit 2>/dev/null)" ]
}

# git with auth passed as a header (token never written into .git/config)
gitc() {
  local auth; auth="$(printf 'x-access-token:%s' "$BACKUP_TOKEN" | base64 -w0)"
  git -c "http.extraheader=Authorization: Basic $auth" \
      -c user.name="mc-bot-backup" -c user.email="backup@localhost" "$@"
}

sync_repo() {
  if [ ! -d "$WORK_DIR/.git" ]; then
    rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR"
    git -C "$WORK_DIR" init -q
    git -C "$WORK_DIR" symbolic-ref HEAD refs/heads/main
    git -C "$WORK_DIR" remote add origin "$BACKUP_GIT_URL"
  fi
  git -C "$WORK_DIR" remote set-url origin "$BACKUP_GIT_URL"
  local rc=0
  gitc -C "$WORK_DIR" ls-remote --exit-code --heads origin main >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) gitc -C "$WORK_DIR" fetch -q origin main
       gitc -C "$WORK_DIR" reset -q --hard origin/main ;;
    2) : ;; # empty repo — the first backup creates the branch
    *) die "cannot reach backup repo (check BACKUP_REPO and that the token has Contents: read/write)" ;;
  esac
}

# Deterministic tar.gz so "nothing changed" really produces the same hash.
make_tar() {
  tar -C "$APP_DIR" --sort=name --mtime='2020-01-01 00:00:00' \
      --owner=0 --group=0 --numeric-owner -cf - data | gzip -n > "$1"
}

do_backup() {
  need_config
  exec 9>"$STATE_DIR/lock"; flock -n 9 || exit 0
  has_data || { log "no data yet, nothing to back up"; exit 0; }
  tmp="$(mktemp -d)"; trap 'rm -rf "${tmp:-}"' EXIT

  make_tar "$tmp/data.tar.gz"
  local hash; hash="$(sha256sum "$tmp/data.tar.gz" | cut -d' ' -f1)"
  if [ -f "$STATE_DIR/last.sha256" ] && [ "$(cat "$STATE_DIR/last.sha256")" = "$hash" ]; then
    exit 0   # unchanged since last successful backup
  fi

  sync_repo
  # Safety: never overwrite an existing cloud backup this host hasn't restored/adopted.
  if [ -f "$WORK_DIR/$BACKUP_FILE" ] && [ ! -f "$STATE_DIR/initialized" ] && [ "${BACKUP_FORCE:-0}" != "1" ]; then
    die "cloud already has a backup that this host never restored — refusing to overwrite it. Run: mc-bot-backup restore   (or BACKUP_FORCE=1 to override)"
  fi

  openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
    -pass env:BACKUP_PASSPHRASE -in "$tmp/data.tar.gz" -out "$WORK_DIR/$BACKUP_FILE" \
    || die "encryption failed"
  gitc -C "$WORK_DIR" add "$BACKUP_FILE"
  if ! gitc -C "$WORK_DIR" diff --cached --quiet; then
    gitc -C "$WORK_DIR" commit -q -m "backup $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    gitc -C "$WORK_DIR" push -q origin main || die "push failed"
  fi
  echo "$hash" > "$STATE_DIR/last.sha256"; touch "$STATE_DIR/initialized"
  log "backup pushed (${hash:0:12})"
}

do_restore() {
  need_config
  exec 9>"$STATE_DIR/lock"; flock -n 9 || die "another backup/restore is running"
  tmp="$(mktemp -d)"; trap 'rm -rf "${tmp:-}"' EXIT

  sync_repo
  if [ ! -f "$WORK_DIR/$BACKUP_FILE" ]; then
    touch "$STATE_DIR/initialized"
    log "no cloud backup yet — nothing to restore (fresh start)"
    exit 0
  fi
  if has_data && [ "${BACKUP_FORCE:-0}" != "1" ]; then
    die "local data/ already has files — refusing to overwrite (BACKUP_FORCE=1 to force)"
  fi

  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
    -pass env:BACKUP_PASSPHRASE -in "$WORK_DIR/$BACKUP_FILE" -out "$tmp/data.tar.gz" 2>/dev/null \
    || die "decrypt failed — wrong BACKUP_PASSPHRASE?"
  gzip -t "$tmp/data.tar.gz" 2>/dev/null || die "backup is corrupt or the passphrase is wrong"

  mkdir -p "$tmp/x" "$APP_DIR"
  tar -xzf "$tmp/data.tar.gz" -C "$tmp/x"
  [ -d "$tmp/x/data" ] || die "backup archive has no data/ folder"
  rm -rf "$APP_DIR/data"
  mv "$tmp/x/data" "$APP_DIR/data"
  chmod 700 "$APP_DIR/data"

  make_tar "$tmp/re.tar.gz"
  sha256sum "$tmp/re.tar.gz" | cut -d' ' -f1 > "$STATE_DIR/last.sha256"
  touch "$STATE_DIR/initialized"
  log "restored data/ from cloud backup"
}

do_status() {
  echo "repo:         ${BACKUP_REPO:-<not set>}"
  if [ -n "$BACKUP_REPO" ] && [ -n "$BACKUP_TOKEN" ] && [ -n "$BACKUP_PASSPHRASE" ]; then echo "configured:   yes"; else echo "configured:   NO"; fi
  if [ -f "$STATE_DIR/initialized" ]; then echo "initialized:  yes"; else echo "initialized:  no"; fi
  if [ -d "$APP_DIR/data" ]; then echo "data files:   $(find "$APP_DIR/data" -type f | wc -l)"; else echo "data files:   0"; fi
  echo "last backup:  $(git -C "$WORK_DIR" log -1 --format=%cd 2>/dev/null || echo never)"
}

case "${1:-backup}" in
  backup)  do_backup ;;
  restore) do_restore ;;
  status)  do_status ;;
  *) echo "usage: mc-bot-backup [backup|restore|status]"; exit 1 ;;
esac
MCBOT_BACKUP_EOF
  sed -i -e "s|__APP_DIR__|${app_dir}|" -e "s|__SECRETS_FILE__|${SECRETS_FILE}|" "$BACKUP_BIN"
  chmod 700 "$BACKUP_BIN"
  ok "Backup tool installed: $BACKUP_BIN"

  # Fresh VPS? Pull the data down BEFORE the bot starts. Abort on failure so the
  # bot never starts empty and silently diverges from the cloud copy.
  if [ -z "$(ls -A "$app_dir/data" 2>/dev/null)" ]; then
    step "Restoring data from cloud backup (if one exists)"
    "$BACKUP_BIN" restore || die "Restore failed — NOT starting the bot with empty data. Fix BACKUP_* (repo/token/passphrase) and re-run."
  else
    ok "Local data/ present — skipping restore"
  fi

  cat > /etc/cron.d/mc-bot-backup <<CRON_EOF
# Encrypted cloud backup of the Minecraft bot's data/ (only pushes when data changed)
*/${interval} * * * * root ${BACKUP_BIN} backup >> /var/log/mc-bot-backup.log 2>&1
CRON_EOF
  chmod 644 /etc/cron.d/mc-bot-backup
  BACKUP_ENABLED=1
  ok "Auto-backup scheduled every ${interval} min"
}

main() {
  # Never let apt/npm/nodesource steal the script when it's piped from curl.
  exec < /dev/null

  local RECONFIGURE=0
  for arg in "$@"; do
    case "$arg" in
      --reconfigure) RECONFIGURE=1 ;;
      --help|-h) show_help; exit 0 ;;
      *) die "Unknown option: $arg (try --help)" ;;
    esac
  done

  [ "$(id -u)" -eq 0 ] || die "Run this as root (you're not). Try: sudo bash install.sh"
  command -v apt-get >/dev/null 2>&1 || die "This script supports Debian/Ubuntu (apt) only."
  case "$REPO_URL" in
    *USERNAME/REPO*) die "REPO_URL still has the placeholder. Edit REPO_URL at the top of install.sh (or run with REPO_URL=... )." ;;
  esac

  load_secrets

  # Make apt fully non-interactive (this is what froze the browser terminal before).
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  export NEEDRESTART_SUSPEND=1
  local APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

  # ---------------------------------------------------------------- 1. base
  step "Installing base packages"
  apt-get update -y
  apt-get install "${APT_OPTS[@]}" curl git unzip ca-certificates gnupg
  ok "Base packages ready"

  # ---------------------------------------------------------------- 2. node
  step "Checking Node.js (need v${NODE_MAJOR}+)"
  local current_major=0
  if command -v node >/dev/null 2>&1; then
    current_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  fi
  if [ "$current_major" -lt "$NODE_MAJOR" ]; then
    warn "Found Node v${current_major} (or none) — installing Node ${NODE_MAJOR}"
    apt-get remove -y nodejs npm libnode-dev libnode72 >/dev/null 2>&1 || true
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install "${APT_OPTS[@]}" nodejs
  fi
  current_major="$(node -p 'process.versions.node.split(".")[0]')"
  [ "$current_major" -ge "$NODE_MAJOR" ] || die "Node install failed (still v${current_major})."
  ok "Node $(node -v), npm $(npm -v)"

  # ---------------------------------------------------------------- 3. pm2
  step "Checking PM2"
  if ! command -v pm2 >/dev/null 2>&1; then
    npm install -g pm2 --no-audit --no-fund
  fi
  ok "PM2 $(pm2 -v)"

  # ---------------------------------------------------------------- 4. code
  step "Fetching bot source"
  if [ -d "$INSTALL_DIR/.git" ]; then
    git -C "$INSTALL_DIR" fetch --all --prune
    git -C "$INSTALL_DIR" reset --hard "origin/${BRANCH}"
    ok "Updated to latest ${BRANCH}"
  else
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR" \
      || die "git clone failed. Check REPO_URL / BRANCH (private repos need a token in the URL)."
    ok "Cloned into $INSTALL_DIR"
  fi

  # The zip we shipped has the project inside a bot/ folder — support both layouts.
  local APP_DIR="$INSTALL_DIR"
  if [ ! -f "$APP_DIR/package.json" ] && [ -f "$APP_DIR/bot/package.json" ]; then
    APP_DIR="$INSTALL_DIR/bot"
  fi
  [ -f "$APP_DIR/package.json" ] || die "No package.json found in the repo (looked in repo root and bot/)."
  [ -f "$APP_DIR/src/index.js" ] || die "No src/index.js found in $APP_DIR."

  # ---------------------------------------------------------------- 5. .env
  step "Configuring .env"
  local ENV_FILE="$APP_DIR/.env"
  if [ -f "$ENV_FILE" ] && [ "$RECONFIGURE" -eq 0 ]; then
    ok ".env already exists — keeping it (use --reconfigure to change)"
  else
    DISCORD_CLIENT_ID="${DISCORD_CLIENT_ID:-$DEFAULT_CLIENT_ID}"
    BOT_OWNER_ID="${BOT_OWNER_ID:-$DEFAULT_OWNER_ID}"
    if [ -z "${DISCORD_TOKEN:-}" ] || [ -z "${BOT_OWNER_ID:-}" ]; then
      echo "Missing bot details — enter them (token input is hidden):"
    fi
    ask DISCORD_TOKEN "DISCORD_TOKEN" secret
    ask DISCORD_CLIENT_ID "DISCORD_CLIENT_ID"
    ask BOT_OWNER_ID "BOT_OWNER_ID (your own Discord user ID)"

    [[ "$DISCORD_CLIENT_ID" =~ ^[0-9]{15,25}$ ]] || warn "DISCORD_CLIENT_ID doesn't look like a Discord ID — double-check it."
    [[ "$BOT_OWNER_ID" =~ ^[0-9]{15,25}$ ]] || warn "BOT_OWNER_ID doesn't look like a Discord ID — double-check it."

    umask 077
    {
      printf 'DISCORD_TOKEN=%s\n' "$DISCORD_TOKEN"
      printf 'DISCORD_CLIENT_ID=%s\n' "$DISCORD_CLIENT_ID"
      printf 'BOT_OWNER_ID=%s\n' "$BOT_OWNER_ID"
      printf 'DISCORD_DEV_GUILD_ID=%s\n' "${DISCORD_DEV_GUILD_ID:-}"
    } > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok ".env written (permissions 600)"
  fi

  # ---------------------------------------------------------------- 6. deps
  step "Installing npm dependencies"
  ( cd "$APP_DIR" && npm install --omit=dev --no-audit --no-fund )
  mkdir -p "$APP_DIR/data"
  chmod 700 "$APP_DIR/data"   # user data (incl. captured passwords) — root only
  ok "Dependencies installed"

  # ---------------------------------------------------------------- 6b. backup/restore
  setup_backup "$APP_DIR"

  # ---------------------------------------------------------------- 7. run
  step "Starting bot with PM2"
  if pm2 describe "$APP_NAME" >/dev/null 2>&1; then
    pm2 delete "$APP_NAME" >/dev/null 2>&1 || true
  fi
  # --cwd matters: the bot stores its data under <cwd>/data
  pm2 start src/index.js --name "$APP_NAME" --cwd "$APP_DIR" --time
  pm2 save
  pm2 startup systemd -u root --hp /root >/dev/null 2>&1 || warn "pm2 startup could not be configured automatically — run: pm2 startup"
  pm2 save >/dev/null 2>&1 || true
  ok "Bot running and set to auto-start on boot"

  if [ "$BACKUP_ENABLED" -eq 1 ]; then
    "$BACKUP_BIN" backup || warn "Initial backup failed — check /var/log/mc-bot-backup.log and your BACKUP_* settings"
  fi

  sleep 4
  step "Last log lines"
  pm2 logs "$APP_NAME" --lines 15 --nostream || true

  echo
  echo "${C_GREEN}Done!${C_RESET} Look for:  [Discord] Logged in as ..."
  echo
  echo "Handy commands:"
  echo "  pm2 logs $APP_NAME          # live logs (Ctrl+C to exit)"
  echo "  pm2 restart $APP_NAME       # restart"
  echo "  pm2 stop $APP_NAME          # stop"
  echo "  pm2 monit                   # CPU / RAM per process"
  echo "  Update to latest code:      re-run this same install command"
  echo "  Change token/IDs:           re-run with --reconfigure"
  echo "  Install location:           $APP_DIR"
  if [ "$BACKUP_ENABLED" -eq 1 ]; then
    echo "  Cloud backup:               mc-bot-backup status | backup | restore"
  fi
}

main "$@"
