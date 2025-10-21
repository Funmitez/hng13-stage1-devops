#!/bin/sh
# POSIX-friendly automated deployment script for a Dockerized app
# deploy.sh - usage: ./deploy.sh
#
# Exits:
#  0 success
# 10 missing program / prereq
# 20 validation error
# 30 ssh/connection error
# 40 remote exec error
# 50 deploy/runtime error

set -eu

# ---------- helpers ----------
timestamp() {
  /bin/date +"%Y%m%d_%H%M%S"
}

LOGFILE="deploy_$(timestamp).log"

log() {
  ts="$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf "%s %s\n" "$ts" "$1" >> "$LOGFILE"
  printf "%s %s\n" "$ts" "$1"
}

err_exit() {
  log "ERROR: $1"
  exit "$2"
}

# cleanup local temporary files if any (placeholder)
onexit() {
  log "Script exiting. (cleanup hook)"
}
trap onexit EXIT

# ---------- check required local commands ----------
for cmd in ssh scp rsync git curl docker-compose uname; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    # docker-compose and docker may be missing on local machine; we only require ssh/rsync/git/curl
    case "$cmd" in
      docker-compose)
        # optional locally; it's used remotely
        ;;
      docker)
        ;;
      *)
        err_exit "Required command not found: $cmd" 10
        ;;
    esac
  fi
done

log "Starting deployment. Logging to $LOGFILE"

# ---------- collect user input ----------
printf "Enter Git repository HTTPS URL (e.g. https://github.com/user/repo.git): "
read -r GIT_URL

printf "Enter Personal Access Token (PAT) (input will be hidden): "
# hide input
stty_saved="$(stty -g 2>/dev/null || true)"
if stty_saved; then stty -echo || true; fi
read -r PAT
if stty_saved; then stty "$stty_saved" || true; fi
printf "\n"

printf "Enter branch name (press ENTER for main): "
read -r BRANCH
if [ -z "$BRANCH" ]; then BRANCH="main"; fi

printf "Enter remote SSH username (e.g. ubuntu): "
read -r REMOTE_USER

printf "Enter remote server IP or hostname: "
read -r REMOTE_HOST

printf "Enter path to SSH private key for remote (e.g. ~/.ssh/id_rsa): "
read -r SSH_KEY
if [ ! -f "$SSH_KEY" ]; then
  err_exit "SSH key not found at $SSH_KEY" 20
fi

printf "Enter application internal port (container port) (e.g. 8000): "
read -r APP_PORT
case "$APP_PORT" in
  ''|*[!0-9]*)
    err_exit "Invalid port: $APP_PORT" 20
    ;;
esac

printf "Enter remote deploy base folder (default: ~/deploy_app): "
read -r REMOTE_BASE
if [ -z "$REMOTE_BASE" ]; then REMOTE_BASE="~/deploy_app"; fi

# optional cleanup flag
CLEANUP=0
if [ "${1:-}" = "--cleanup" ] || [ "${2:-}" = "--cleanup" ]; then
  CLEANUP=1
fi

# ---------- prepare repo URL with PAT (safer to use token via env, but we keep it simple) ----------
# WARNING: embedding PAT in URL has security implications; prefer ssh keys or ephemeral token via CI
if echo "$GIT_URL" | grep -qE '^https://'; then
  AUTHED_GIT_URL="$(printf "%s" "$GIT_URL" | sed "s#https://#https://$PAT:@#")"
else
  AUTHED_GIT_URL="$GIT_URL"
fi

log "Inputs collected. Repo: $GIT_URL Branch: $BRANCH Remote: $REMOTE_USER@$REMOTE_HOST AppPort: $APP_PORT RemoteBase: $REMOTE_BASE"

# ---------- test SSH connectivity ----------
log "Testing SSH connectivity to $REMOTE_USER@$REMOTE_HOST"
if ! ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE_USER@$REMOTE_HOST" 'echo ok' >/dev/null 2>&1; then
  err_exit "SSH connection failed to $REMOTE_USER@$REMOTE_HOST" 30
fi
log "SSH connectivity OK"

# ---------- remote commands: prepare environment ----------
REMOTE_TMP="/tmp/deploy_$(timestamp)"
REMOTE_PROJECT_DIR="$REMOTE_BASE/$(basename "$GIT_URL" .git)"

# Build a remote script to run (heredoc)
read -r -d '' REMOTE_SCRIPT <<'REMOTE_EOF' || true
set -eu
LOG_REMOTE="/tmp/remote_deploy_$(date +%Y%m%d_%H%M%S).log"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Starting remote setup" >> "$LOG_REMOTE"

# update system
if command -v apt >/dev/null 2>&1; then
  echo "Updating apt..." >> "$LOG_REMOTE"
  sudo apt update -y >> "$LOG_REMOTE" 2>&1 || true
  sudo apt install -y ca-certificates curl gnupg lsb-release >> "$LOG_REMOTE" 2>&1 || true
else
  echo "Non-apt system; manual install required" >> "$LOG_REMOTE"
fi

# Install Docker if missing
if ! command -v docker >/dev/null 2>&1; then
  echo "Installing Docker..." >> "$LOG_REMOTE"
  # Official convenience install (works on Ubuntu/Debian)
  curl -fsSL https://get.docker.com | sh >> "$LOG_REMOTE" 2>&1 || true
fi

# Install docker-compose plugin if missing
if ! docker compose version >/dev/null 2>&1; then
  echo "Installing docker-compose plugin..." >> "$LOG_REMOTE"
  # For modern Docker, 'docker compose' exists; if not, install the plugin
  sudo apt install -y docker-compose-plugin >> "$LOG_REMOTE" 2>&1 || true
fi

# Ensure user is in docker group
if [ "$(id -un)" != "root" ]; then
  sudo usermod -aG docker "$(id -un)" 2>/dev/null || true
fi

# Install nginx if missing
if ! command -v nginx >/dev/null 2>&1; then
  echo "Installing nginx..." >> "$LOG_REMOTE"
  sudo apt install -y nginx >> "$LOG_REMOTE" 2>&1 || true
  sudo systemctl enable nginx >> "$LOG_REMOTE" 2>&1 || true
  sudo systemctl start nginx >> "$LOG_REMOTE" 2>&1 || true
fi

echo "Remote prep done" >> "$LOG_REMOTE"
cat "$LOG_REMOTE"
REMOTE_EOF

# send remote script and execute
log "Uploading and executing remote preflight script"
# write the remote script to a temporary local file
REMOTE_LOCAL_SCRIPT="$(mktemp || true)"
printf "%s\n" "$REMOTE_SCRIPT" > "$REMOTE_LOCAL_SCRIPT"
scp -i "$SSH_KEY" "$REMOTE_LOCAL_SCRIPT" "$REMOTE_USER@$REMOTE_HOST:/tmp/remote_prep.sh" >/dev/null 2>&1 || true
ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_HOST" "sh /tmp/remote_prep.sh" >/dev/null 2>&1 || true
rm -f "$REMOTE_LOCAL_SCRIPT"

log "Remote environment prepared (best-effort)."

# ---------- handle cleanup mode ----------
if [ "$CLEANUP" -eq 1 ]; then
  log "Cleanup mode: removing deployed app and containers on remote"
  ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_HOST" sh -c "'
    set -eu
    REM_DIR=$REMOTE_PROJECT_DIR
    if [ -d \"$REM_DIR\" ]; then
      cd \"$REM_DIR\" || true
      if [ -f docker-compose.yml ]; then
        docker compose down --remove-orphans || true
      fi
      # attempt to stop containers by image or name
    fi
    sudo rm -rf \"$REM_DIR\" || true
    echo cleanup_done
  '" || err_exit "Remote cleanup failed" 40
  log "Remote cleanup completed"
  exit 0
fi

# ---------- transfer the repo (rsync for idempotency) ----------
TMP_DIR="$(mktemp -d || true)"
log "Cloning/pulling repo locally into $TMP_DIR"
cd "$TMP_DIR" || err_exit "Cannot cd to temp dir" 50

# clone or update
if printf "%s" "$GIT_URL" | grep -qE '^https://'; then
  # use the tokenized URL to authenticate
  CLONE_URL="$AUTHED_GIT_URL"
else
  CLONE_URL="$GIT_URL"
fi

if [ -d repo ]; then
  cd repo || true
  git fetch --all || true
  git checkout "$BRANCH" || true
  git pull origin "$BRANCH" || true
  cd ..
else
  git clone --branch "$BRANCH" --single-branch "$CLONE_URL" repo >/dev/null 2>&1 || {
    err_exit "git clone failed" 20
  }
fi

# verify Dockerfile or docker-compose exists
cd repo || err_exit "Repo missing"
if [ ! -f Dockerfile ] && [ ! -f docker-compose.yml ]; then
  err_exit "Neither Dockerfile nor docker-compose.yml found in repo" 20
fi

# Sync project to remote (rsync or scp fallback)
log "Transferring project files to remote $REMOTE_USER@$REMOTE_HOST:$REMOTE_PROJECT_DIR"

RSYNC_OPTIONS="-az --delete"
if command -v rsync >/dev/null 2>&1; then
    log "Using rsync for deployment..."
    rsync -e "ssh -i $SSH_KEY" $RSYNC_OPTIONS repo/ "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PROJECT_DIR/" || {
        log "Rsync failed, switching to SCP..."
        scp -i "$SSH_KEY" -r repo/* "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PROJECT_DIR/" || err_exit "File transfer failed (scp fallback)" 40
    }
else
    log "Rsync not found, using SCP fallback..."
    scp -i "$SSH_KEY" -r repo/* "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PROJECT_DIR/" || err_exit "File transfer failed (scp fallback)" 40
fi

# ---------- remote deployment steps ----------
log "Running remote deployment commands (build/run containers, nginx config)"
ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_HOST" sh -s <<'REMOTE_RUN'
set -eu
PROJECT_DIR='"$REMOTE_PROJECT_DIR"'
APP_PORT='"$APP_PORT"'
# make sure variables are substituted - we'll rebuild with env expansion below
true
REMOTE_LOG="/tmp/deploy_action_$(date +%Y%m%d_%H%M%S).log"
echo "Starting remote deploy" >> "$REMOTE_LOG"

cd '"$REMOTE_PROJECT_DIR"'

# If docker-compose present, use it; else use Dockerfile
if [ -f docker-compose.yml ]; then
  echo "Using docker-compose" >> "$REMOTE_LOG"
  # attempt to stop any existing compose deployment (idempotent)
  docker compose down --remove-orphans || true
  docker compose pull || true
  docker compose up -d --build

else
  echo "Using Dockerfile" >> "$REMOTE_LOG"
  # attempt to stop existing container with same name (use repo dir name as container name)
  NAME="$(basename "$PWD")"
  if docker ps -a --format '{{.Names}}' | grep -q "^$NAME$"; then
    docker rm -f "$NAME" || true
  fi
  docker build -t "$NAME:latest" .
  docker run -d --restart unless-stopped -p "$APP_PORT":"$APP_PORT" --name "$NAME" "$NAME:latest"
fi

# Wait a little and check status
sleep 3
docker ps --filter "status=running" --format '{{.Names}}\t{{.Status}}' >> "$REMOTE_LOG"

# Configure Nginx reverse proxy
# We'll create a simple config that forwards port 80 to container port (APP_PORT)
SITE_CONF="/etc/nginx/sites-available/auto_deploy.conf"
cat <<'NGINX_EOF' > /tmp/auto_deploy.conf
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:APP_PORT_REPLACE;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
NGINX_EOF

# replace placeholder with actual port
sed -i "s/APP_PORT_REPLACE/$APP_PORT/g" /tmp/auto_deploy.conf
sudo mv /tmp/auto_deploy.conf $SITE_CONF
sudo ln -sf $SITE_CONF /etc/nginx/sites-enabled/auto_deploy.conf
# disable default if exists
sudo rm -f /etc/nginx/sites-enabled/default >/dev/null 2>&1 || true

# test and reload nginx
sudo nginx -t >> "$REMOTE_LOG" 2>&1 || true
sudo systemctl reload nginx >> "$REMOTE_LOG" 2>&1 || true

echo "Remote deploy finished" >> "$REMOTE_LOG"
cat "$REMOTE_LOG"
REMOTE_RUN

log "Remote deployment finished. Checking remote service status..."

# ---------- health checks ----------
# check remote nginx and app via curl
if ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_HOST" "curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1/"; then
  HTTP_LOCAL=$(ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_HOST" "curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1/" || true)
  log "Remote nginx returned HTTP status $HTTP_LOCAL"
else
  log "Warning: could not contact remote nginx via 127.0.0.1"
fi

log "Deployment complete. Logfile: $LOGFILE"

# final cleanup of tmp
rm -rf "$TMP_DIR" || true

exit 0
