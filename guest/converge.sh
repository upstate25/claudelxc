#!/usr/bin/env bash
# ============================================================================
# claudelxc converge (antigravity branch) - idempotent in-container setup.
#
# Runs INSIDE the LXC as root. Invoked once at deploy time by install.sh, and
# again on every nightly claudelxc-update. Re-running is safe: it refreshes
# MANAGED config (settings, systemd unit, skills, update tooling) and installs
# anything missing, while never touching USER STATE:
#   - the agy sign-in (OS keyring) and /etc/claudelxc/agy.env (API key, if used)
#   - your own agy plugins/skills/MCP servers (managed keys are merged, not clobbered)
#   - files under /project                 (your work, incl. an edited AGENTS.md)
#
# Deliberately NOT 'set -e': one step failing must not abort the rest (a browser
# download or a plugin install must never take down Docker/SSH/cron).
# ============================================================================
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
# When install.sh is run on the Proxmox host via sudo, `pct exec` carries the
# host's SUDO_* variables into the container. Tools here (notably vendor
# installers) then think they were run via sudo by a non-root user. We are root
# inside the container on purpose, so drop them (issue #8).
unset SUDO_USER SUDO_UID SUDO_GID SUDO_COMMAND
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES="$REPO_DIR/templates"
BINDIR="$REPO_DIR/bin"
NPM_QUIET=(--no-fund --no-audit --loglevel=error)

log()  { echo ">>> $*"; }
warn() { echo "    [WARN] $*"; }

log "claudelxc converge starting (repo: $REPO_DIR)"

# ── Timezone ────────────────────────────────────────────────────────────────
log "Timezone -> America/New_York"
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
echo "America/New_York" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true

# ── Locale ──────────────────────────────────────────────────────────────────
if ! locale -a 2>/dev/null | grep -qi 'en_US.utf8'; then
  log "Generating en_US.UTF-8 locale"
  apt-get update -qq
  apt-get install -y -qq locales
  sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
  locale-gen en_US.UTF-8 >/dev/null 2>&1
  update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
fi

# ── OS packages: upgrade everything, then ensure the desired set is present ──
# apt upgrade runs on every converge (install AND nightly), so a box is fully
# patched from first boot. apt-get install is a no-op for packages already there.
log "Upgrading OS packages (apt update + upgrade)"
apt-get update -qq
apt-get upgrade -y -qq || warn "apt upgrade reported errors"
log "Ensuring base packages"
apt-get install -y -qq \
  git curl wget unzip zip \
  ca-certificates gnupg lsb-release apt-transport-https software-properties-common \
  bash-completion locales \
  htop nano vim tmux screen \
  jq yq tree \
  net-tools iproute2 iputils-ping dnsutils \
  openssh-server \
  cron logrotate \
  build-essential make cmake pkg-config autoconf automake libtool \
  python3 python3-pip python3-venv python3-dev \
  libssl-dev libffi-dev libsqlite3-dev zlib1g-dev \
  libreadline-dev libbz2-dev libncurses-dev liblzma-dev libxml2-dev libxslt-dev \
  ripgrep fd-find fzf bat \
  rsync sqlite3 \
  postgresql-client redis-tools \
  || warn "some base packages failed to install"

# ── Node.js (latest LTS) ────────────────────────────────────────────────────
# Tooling here targets Node 22+; an older node already on the box (pulled in as a
# dependency, or from a previous release's apt repo) has to be replaced, not
# just left alone — `command -v node` alone would silently accept Node 18.
NODE_MAJOR=0
command -v node >/dev/null 2>&1 && \
  NODE_MAJOR=$(node --version 2>/dev/null | sed -n 's/^v\([0-9]\+\).*/\1/p')
NODE_MAJOR=${NODE_MAJOR:-0}
if [ "$NODE_MAJOR" -lt 22 ]; then
  log "Installing Node.js (latest LTS via NodeSource; found major '${NODE_MAJOR}')"
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y -qq nodejs \
    || warn "Node.js install failed"
  npm install -g "${NPM_QUIET[@]}" npm@latest || warn "npm self-update failed"
fi
if command -v node >/dev/null 2>&1; then
  echo "    Node.js $(node --version 2>/dev/null) / npm $(npm --version 2>/dev/null)"
  # Global dev tools — install only if absent (updater keeps them current).
  command -v prettier >/dev/null 2>&1 || \
    npm install -g "${NPM_QUIET[@]}" typescript ts-node eslint prettier || warn "global npm tools failed"
fi

# ── Go (latest) ─────────────────────────────────────────────────────────────
if [ ! -x /usr/local/go/bin/go ]; then
  log "Installing Go (latest)"
  GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
  # Go's tarballs are per-architecture; the host arch decides (amd64 or arm64).
  GO_ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  if [ -n "${GO_VERSION:-}" ] && curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tar.gz; then
    rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tar.gz && rm -f /tmp/go.tar.gz
    echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
    echo "    Go $(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}')"
  else
    warn "Go install failed"
  fi
fi

# ── Rust (via rustup) ───────────────────────────────────────────────────────
if ! command -v rustc >/dev/null 2>&1 && [ ! -x "$HOME/.cargo/bin/rustc" ]; then
  log "Installing Rust (rustup)"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    || warn "Rust install failed"
fi

# ── Docker + Compose ────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker"
  curl -fsSL https://get.docker.com | sh || warn "Docker install failed"
fi
if command -v docker >/dev/null 2>&1; then
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl is-active --quiet docker || systemctl start docker || true
  dpkg -s docker-compose-plugin >/dev/null 2>&1 || apt-get install -y -qq docker-compose-plugin 2>/dev/null || true
fi

# ── Antigravity CLI (agy) ───────────────────────────────────────────────────
# Official installer: curl -fsSL https://antigravity.google/cli/install.sh | bash
# The docs don't say where the binary lands, so after installing we look in the
# usual per-user bin dirs and symlink it onto /usr/local/bin (on every PATH,
# including cron's) so `agy` works everywhere.
find_agy() {
  local c
  for c in "$(command -v agy 2>/dev/null)" "$HOME/.local/bin/agy" "$HOME/.antigravity/bin/agy" \
           "$HOME/.gemini/bin/agy" "$HOME/.gemini/antigravity-cli/bin/agy"; do
    [ -n "$c" ] && [ -x "$c" ] && [ "$c" != /usr/local/bin/agy ] && { readlink -f "$c"; return 0; }
  done
  # Last resort: search /root shallowly for an executable named agy.
  find "$HOME" -maxdepth 5 -type f -name agy -perm -u+x 2>/dev/null | head -1
}
if ! command -v agy >/dev/null 2>&1; then
  log "Installing Antigravity CLI (agy)"
  curl -fsSL https://antigravity.google/cli/install.sh | bash || warn "Antigravity CLI install failed"
fi
AGY_REAL="$(find_agy)"
if [ -n "$AGY_REAL" ] && [ "$AGY_REAL" != "$(readlink -f /usr/local/bin/agy 2>/dev/null)" ]; then
  ln -sf "$AGY_REAL" /usr/local/bin/agy 2>/dev/null || true
fi
AGY_BIN="$(command -v agy || echo /usr/local/bin/agy)"
echo "    agy: ${AGY_REAL:-not found} ($("$AGY_BIN" --version 2>/dev/null | head -1 || echo 'version unknown'))"

# ── Sign-in support for a headless box ──────────────────────────────────────
# agy keeps its Google sign-in in the OS keyring (Linux Secret Service over
# D-Bus). A bare LXC has neither, which is the likely cause of the reported
# "sign-in loop" on headless Linux. Install a keyring + user D-Bus so an SSH
# login session can provide one. Fallback that needs no keyring: an API key in
# /etc/claudelxc/agy.env (GEMINI_API_KEY=...), loaded by the managed .bashrc
# block below together with "modelProvider": "gemini".
log "Ensuring keyring + D-Bus packages for agy sign-in"
apt-get install -y -qq dbus-user-session gnome-keyring libsecret-1-0 libsecret-tools \
  || warn "keyring packages failed to install"
mkdir -p /etc/claudelxc
if [ ! -f /etc/claudelxc/agy.env ]; then
  cat > /etc/claudelxc/agy.env <<'AGYENV'
# Optional: Gemini API key for agy, used INSTEAD of Google sign-in.
# Uncomment and fill in, then open a new shell. Also set
#   "modelProvider": "gemini"
# in /root/.gemini/antigravity-cli/settings.json (remove it to go back to sign-in).
# GEMINI_API_KEY=
AGYENV
fi
chmod 0600 /etc/claudelxc/agy.env

# ── agy settings (managed keys enforced; user additions preserved) ──────────
# Same merge as the Claude version: the template's keys (agentMode auto + the
# secret deny-floor) are forced every run; anything you add via /config or
# /permissions survives. agy writes this file 0600 itself, so keep that mode.
log "Merging managed agy settings (preserving user additions)"
AGY_SETTINGS=/root/.gemini/antigravity-cli/settings.json
mkdir -p "$(dirname "$AGY_SETTINGS")"
if ! python3 "$REPO_DIR/guest/merge-settings.py" "$TEMPLATES/agy-settings.json" "$AGY_SETTINGS" "$TEMPLATES/agy-settings.retired.json"; then
  warn "agy settings merge failed; falling back to the managed template"
  install -m 0600 "$TEMPLATES/agy-settings.json" "$AGY_SETTINGS"
fi
chmod 0600 "$AGY_SETTINGS"

# ── MCP servers (context7 docs lookup) ──────────────────────────────────────
log "Merging managed MCP servers (context7)"
AGY_MCP=/root/.gemini/config/mcp_config.json
mkdir -p "$(dirname "$AGY_MCP")"
if ! python3 "$REPO_DIR/guest/merge-settings.py" "$TEMPLATES/agy-mcp.json" "$AGY_MCP"; then
  warn "MCP config merge failed; falling back to the managed template"
  install -m 0644 "$TEMPLATES/agy-mcp.json" "$AGY_MCP"
fi

# ── Plugins (best-effort; never blocks a cron run) ──────────────────────────
# superpowers from its GitHub repo. Installs can need a sign-in, and an
# interactive prompt would hang cron, so: no stdin, hard timeout, non-fatal.
# Skipped once present. Before first sign-in this may just warn; the next
# nightly run (or `claudelxc-update`) retries.
log "Ensuring agy plugins (best-effort)"
if [ -x "$AGY_BIN" ]; then
  if "$AGY_BIN" plugin list 2>/dev/null </dev/null | grep -qi superpowers; then
    echo "    superpowers already installed"
  elif timeout 180 "$AGY_BIN" plugin install https://github.com/obra/superpowers </dev/null >/dev/null 2>&1; then
    echo "    installed superpowers"
  else
    warn "could not install superpowers plugin yet (sign in to agy, then run claudelxc-update)"
  fi
fi

# ── webapp-testing skill (MANAGED — refreshed every converge) ───────────────
log "Installing/refreshing webapp-testing skill"
if git clone --depth 1 --filter=blob:none --sparse https://github.com/anthropics/skills.git /tmp/anthropic-skills 2>/dev/null; then
  ( cd /tmp/anthropic-skills && git sparse-checkout set skills/webapp-testing >/dev/null 2>&1 )
  # ~/.gemini/config/skills is the personal skills dir shared by agy and the
  # Antigravity app (one level deep: <name>/SKILL.md).
  mkdir -p /root/.gemini/config/skills
  rm -rf /root/.gemini/config/skills/webapp-testing
  cp -r /tmp/anthropic-skills/skills/webapp-testing /root/.gemini/config/skills/webapp-testing
  rm -rf /tmp/anthropic-skills
else
  warn "could not fetch webapp-testing skill (offline?); leaving existing copy"
fi

# ── Playwright (Python, for the webapp-testing skill) ───────────────────────
# Playwright supports Ubuntu 26.04 natively since 1.61 (microsoft/playwright#40117
# is closed), so the old PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64 hack
# is gone. Scrub it from /etc/environment on boxes that got it from an earlier
# release, so new installs pull the real 26.04 browser builds. Guard the Chromium
# download so we don't re-pull ~600MB every nightly run — install it only when
# the cache has no chromium build.
unset PLAYWRIGHT_HOST_PLATFORM_OVERRIDE
[ -f /etc/environment ] && sed -i '/^PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=/d' /etc/environment

if ! python3 -m pip show playwright >/dev/null 2>&1; then
  log "Installing Python Playwright (webapp-testing skill)"
  python3 -m pip install --break-system-packages -q playwright \
    || warn "pip install playwright failed"
fi
if ! ls -d /root/.cache/ms-playwright/chromium-* >/dev/null 2>&1; then
  log "Downloading Chromium"
  python3 -m playwright install --with-deps chromium \
    || python3 -m playwright install chromium \
    || warn "Chromium download failed (retry later)"
fi

# ── /project + seed AGENTS.md (USER-EDITABLE — written only if absent) ────────
mkdir -p /project
if [ ! -f /project/AGENTS.md ]; then
  log "Seeding /project/AGENTS.md"
  install -m 0644 "$TEMPLATES/project-AGENTS.md" /project/AGENTS.md
else
  echo "    /project/AGENTS.md exists — left as-is"
fi

# ── SSH (idempotent) ────────────────────────────────────────────────────────
# Ubuntu's sshd_config Includes /etc/ssh/sshd_config.d/*.conf from the TOP of the
# file and the FIRST value of a keyword wins, so a drop-in (cloud-init ships one
# with PasswordAuthentication no) silently outranks any edit to the main file.
# Own a drop-in that sorts first instead, and keep the main-file edit for images
# that predate the Include.
log "Configuring sshd (root login + password auth)"
sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/00-claudelxc.conf <<'SSHD'
# Managed by claudelxc. Sorts before any other drop-in, and sshd keeps the first
# value it sees, so these win over cloud-init's defaults.
PermitRootLogin yes
PasswordAuthentication yes
SSHD
  chmod 0644 /etc/ssh/sshd_config.d/00-claudelxc.conf
fi
# Never restart into a config sshd rejects — that locks the box out of SSH.
if sshd -t 2>/dev/null || /usr/sbin/sshd -t 2>/dev/null; then
  systemctl enable ssh >/dev/null 2>&1 || true
  systemctl restart ssh || warn "ssh restart failed (check 'journalctl -u ssh')"
else
  warn "sshd config test failed; leaving the running sshd untouched"
fi

# ── Shell environment (MANAGED BLOCK — replaced, never duplicated) ──────────
log "Applying managed .bashrc block"
BEGIN="# >>> claudelxc managed >>>"
END="# <<< claudelxc managed <<<"
touch /root/.bashrc
# Strip any prior managed block (and the legacy un-marked block from agentic.sh).
sed -i "/$BEGIN/,/$END/d" /root/.bashrc
sed -i '/# ── Claude Code Container ──/,/^cd \/project 2>\/dev\/null/d' /root/.bashrc
cat >> /root/.bashrc <<BASHRC
$BEGIN
export EDITOR=nano
export LANG=en_US.UTF-8
export TZ=America/New_York
export PATH="\$HOME/.local/bin:\$HOME/.cargo/bin:/usr/local/go/bin:\$PATH"
alias ll="ls -lah --color=auto"
alias cls="clear"
alias ..="cd .."
alias ...="cd ../.."
alias gs="git status"
alias gl="git log --oneline -20"
alias dc="docker compose"
alias dps="docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
# Optional agy API key (see /etc/claudelxc/agy.env). Exported only if set.
if [ -r /etc/claudelxc/agy.env ]; then set -a; . /etc/claudelxc/agy.env; set +a; fi
cd /project 2>/dev/null || true
$END
BASHRC

# ── Git defaults (idempotent) ───────────────────────────────────────────────
git config --global init.defaultBranch main
git config --global core.editor nano
git config --global pull.rebase false

# ── CloudCLI UI: not used on this box ───────────────────────────────────────
# CloudCLI only drives Claude Code / Codex / Cursor / Gemini CLI, not agy. If a
# box was converted from the Claude version, stop its leftover service.
if systemctl cat cloudcli.service >/dev/null 2>&1; then
  log "Disabling leftover cloudcli.service (not used with agy)"
  systemctl disable --now cloudcli >/dev/null 2>&1 || true
fi

# ── Update tooling (MANAGED — copied from the repo each converge) ───────────
log "Installing update tooling (claudelxc-update / claudelxc-doctor)"
install -m 0755 "$BINDIR/claudelxc-update" /usr/local/bin/claudelxc-update
install -m 0755 "$BINDIR/claudelxc-doctor" /usr/local/bin/claudelxc-doctor
# Back-compat aliases for the old agentic-* names.
ln -sf /usr/local/bin/claudelxc-update /usr/local/bin/agentic-update
ln -sf /usr/local/bin/claudelxc-doctor /usr/local/bin/agentic-doctor

install -m 0644 "$TEMPLATES/cron.claudelxc" /etc/cron.d/claudelxc
rm -f /etc/cron.d/agentic-update   # remove the legacy weekly cron if present
cat > /etc/logrotate.d/claudelxc <<'LOGROTATE'
/var/log/claudelxc-update.log {
    monthly
    rotate 3
    compress
    missingok
    notifempty
}
LOGROTATE

# ── Tidy up apt ─────────────────────────────────────────────────────────────
apt-get -y -qq autoremove || true
apt-get -qq clean || true

log "claudelxc converge complete"
