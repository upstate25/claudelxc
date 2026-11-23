# claudelxc — antigravity branch

**A Proxmox LXC running Google's Antigravity CLI (`agy`) instead of Claude Code, with one command.**

This branch of [upstate25/claudelxc](https://github.com/upstate25/claudelxc) (a fork of
[serversathome/claudelxc](https://github.com/serversathome/claudelxc)) keeps the same
container, toolchain and nightly self-update. Only the agent layer is different.

## Quick start

Run on your **Proxmox host**, as root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/upstate25/claudelxc/antigravity/install.sh)
```

Then SSH into the box and run `agy`. The first run prints a sign-in URL: open it on
your PC, sign in with Google, and paste the code back into the terminal.

**If sign-in loops** (agy keeps its login in a desktop keyring, which a headless box may
not have), use a Gemini API key instead:
1. Put `GEMINI_API_KEY=your-key` in `/etc/claudelxc/agy.env` (it is already `chmod 600`).
2. Add `"modelProvider": "gemini"` to `/root/.gemini/antigravity-cli/settings.json`.
3. Open a new shell and run `agy`.

## What you get

- **Antigravity CLI** (`agy`) in `agentMode: auto`, with a deny list that blocks
  reading secrets (`.env` files, SSH keys, the API key file, OAuth tokens) and
  catastrophic commands (`dd`, `mkfs`, `rm -rf /`).
- **Dev toolchain**: Node.js (LTS), Python 3, Go, Rust, Docker + Compose, git,
  ripgrep, fzf, fd, database clients and build tools.
- **Skills/plugins/MCP**: the webapp-testing skill (Playwright + Chromium), the
  superpowers plugin (best-effort install) and the context7 docs MCP server.
- **Rules file**: `/project/AGENTS.md`, seeded once and then yours to edit.

There is **no web UI**: CloudCLI doesn't support agy. Use `agy` over SSH, connect the
Antigravity desktop app to the box over SSH, or run `agy remote-control start` to
reach it from other devices.

## It keeps itself updated

Every night at 04:00 the box pulls this branch, re-applies the setup, patches the OS,
re-runs the agy installer (agy has no `update` command), refreshes container images and
runs a health check. Your sign-in and everything under `/project` are kept.

```bash
claudelxc-update      # full update pass now
claudelxc-doctor      # just the health check
```

Log: `/var/log/claudelxc-update.log`. To turn nightly updates off, delete `/etc/cron.d/claudelxc`.

## Files

| What | Where |
|---|---|
| agy settings (managed keys merged, your additions kept) | `/root/.gemini/antigravity-cli/settings.json` |
| MCP servers | `/root/.gemini/config/mcp_config.json` |
| Skills | `/root/.gemini/config/skills/` |
| Optional API key | `/etc/claudelxc/agy.env` |
| Deploy checkout | `/opt/claudelxc` |

## Good to know

- The box clones this **public** repo anonymously. No credentials are stored in the repo.
- Runs as root inside a **privileged** LXC with nesting, keyctl and unconfined AppArmor
  (for Docker-in-LXC). agy's own terminal sandbox needs user namespaces and may not
  work here. Treat the box as trusted-network equipment, not an isolation boundary.
- Names (`claudelxc-update`, `/opt/claudelxc`, `/etc/claudelxc`) are kept from upstream
  so the scripts stay easy to compare with the Claude version.
