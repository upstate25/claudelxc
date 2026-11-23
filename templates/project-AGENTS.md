# Antigravity Workspace

## Environment
- **OS**: Ubuntu 26.04 LXC container on Proxmox
- **Working directory**: /project
- **Timezone**: America/New_York
- **User**: root

## Available Tools
- **Languages**: Node.js (latest LTS), Python 3 (system default), Go (latest), Rust (latest)
- **Package managers**: npm, pip (use --break-system-packages), cargo, go install
- **Docker**: Docker Engine + Compose plugin, running and ready
- **Search tools**: ripgrep (rg), fd-find (fdfind), fzf
- **Databases**: PostgreSQL client (psql), Redis client (redis-cli), SQLite3
- **Browser testing**: Python Playwright + Chromium (used by the webapp-testing skill)

## Permissions
agentMode is "auto" (~/.gemini/antigravity-cli/settings.json): workspace edits are
auto-approved and risky commands still pause. A deny list in the same file applies
in every mode and blocks reading secrets (.env files, SSH keys, the agy API key
file, OAuth tokens) and catastrophic commands (dd, mkfs, rm -rf /). Do not try to
work around it.

## Docker Usage
Docker compose files should go in /docker/<service-name>/docker-compose.yml.
There is no always-on Watchtower daemon. Container images are refreshed one-shot
by the nightly `claudelxc-update` run, so give containers you want updated
`restart: unless-stopped`.
All Docker containers in this LXC need `security_opt: [apparmor=unconfined]`.

## Conventions
- Prefer creating files over printing long code blocks
- Use git for version control on all projects in /project/src/
- When installing Python packages, use: pip install --break-system-packages <package>

## Skills, plugins and MCP
- **webapp-testing** skill (~/.gemini/config/skills/webapp-testing): Playwright-based
  browser testing for UI verification and debugging
- **superpowers** plugin (best-effort install; check with `agy plugin list`)
- **context7** MCP server (~/.gemini/config/mcp_config.json): live, version-specific
  library docs lookup

## Remote access
- SSH in and run `agy`, or connect the Antigravity desktop app to this box over SSH.
- Phone/other devices: `agy remote-control start --name "<name>"` (after signing in).

## Staying up to date
This box self-updates nightly from upstate25/claudelxc (antigravity branch) — see
`claudelxc-update`. Sign-in, files under /project, and your own settings
additions are preserved. This file is a seed written only on first deploy — edit
it freely; the updater will not overwrite it.
