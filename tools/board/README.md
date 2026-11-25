# board

Read-only Kanban board generated from `~/AI-Brain/Active Priorities.md` (column = `###` heading, card = `- [ ]` item, title = first bold text, project = first backtick slug, `→ [[Note]]` at the end = note link). Shown on top of Homepage in an iframe; changes are made in the note (through J.A.R.E.K. or a Claude session), never on the board.

- `board.py` + `template.html`: the generator (stdlib Python).
- `build.sh`: fetches the vault's `origin/main` and writes `index.html` (standalone, with background) and `embed.html` (transparent, for Homepage) into `/opt/board/www`.
- `systemd/`: user timer, every 5 minutes (`~/.config/systemd/user/`).
- `deploy/`: the `/opt/board` stack (nginx, read-only, `caddy_net` only) and its config.
- Caddy: `board.home.example.com` → `board:80`, Tailscale + home LAN only.
- Homepage: group "Board" with an `iframe` widget on `embed.html`; `custom.js` resizes the iframe from the page's `board-height` messages.
