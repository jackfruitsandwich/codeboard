---
name: codeboard-canvas
description: Control the running Codeboard canvas (a grid of Ghostty terminals and browser tiles). List tiles, open terminals or Claude Code sessions in new tiles, move, resize and arrange tiles, focus, zoom, fit the view, close tiles. Use when asked to open something in Codeboard, lay out or tidy the canvas, or show sessions side by side.
---

# Codeboard canvas control

Codeboard (`/Applications/Codeboard.app`) is an infinite grid of tiles. Every terminal tile is a private tmux session (`tmux -L codeboard`, session `cb-<tile id>`), so shells outlive app reloads.

Drive it with the CLI that sits next to this file (a symlink to `scripts/codeboard-canvas` in the Codeboard repo):

```sh
CANVAS=~/.claude/skills/codeboard-canvas/codeboard-canvas
$CANVAS state            # always start here
```

## The grid

- Positions are integer cells, `x` to the right and `y` **down**. Negative values are fine (limit ±512).
- One cell is 920×620 pt at zoom 1.0. Zoom runs from 0.4 to 1.8.
- **Zoom does not scale terminal text.** It only changes how many columns a tile gets. At 0.4 a 1×1 tile is about 46 columns, which is too narrow for Claude Code. Use at least 2×2 (about 92×29) for agent sessions.
- Tiles never overlap. Every placement is checked, and `arrange`/`grid` are atomic, so tiles can swap cells in one call.
- `state` reports the viewport in grid units, so you can tell what is on screen at the current zoom.

Tile references: a full id, a unique id prefix of 4+ characters (`eb2c`), or the tile index (`3` or `#3`).

## Commands

| Command | Effect |
|---|---|
| `state [--json]` | Tiles (rect, title, cwd, foreground command, Claude session id), zoom, viewport. The row for your own tile is marked `(this tile)`. |
| `new-terminal [--at X,Y] [--size WxH] [--cwd DIR] [--run CMD] [--focus]` | New shell. `--run` is typed into it after startup. Without `--at` it takes free cells next to the focused tile. |
| `open-claude SESSION_ID [--at X,Y] [--size WxH] [--cwd DIR] [--focus]` | Opens that Claude Code conversation as a **fork** (`claude --resume ID --fork-session`) in the directory the session was started in. The original is untouched. |
| `open-claude SESSION_ID --same-session` | Resumes the session itself instead. Refused while another process has it open, because two live writers branch one log. `--force` overrides; only use it when the user asks. |
| `new-browser [URL] [--at] [--size] [--focus]` | Browser tile. |
| `move TILE X,Y [--size WxH]` | Moves or resizes one tile. |
| `arrange T1=X,Y[,WxH] T2=...` | Moves several tiles in one atomic step. |
| `grid T1 T2 ... --cols N [--size WxH] [--at X,Y]` | Lays tiles out row by row. |
| `focus TILE [--center]` | Gives the tile keyboard focus and scrolls it into view. |
| `fit [TILE ...] [--margin PTS]` | Zooms and scrolls so those tiles (default: all) fill the window. Clamped to zoom 0.4. |
| `zoom SCALE` | Sets the zoom. |
| `close TILE [--force]` | Closes the tile **and kills its shell and everything running in it**. It refuses your own tile unless you pass `--force`. |
| `raw NAME '{json}'` | Sends a raw request (see Protocol). |

Add `--json` before the subcommand to get machine-readable output.

## Etiquette

- The user is usually typing into one of these tiles, often the one running you. Don't pass `--focus` or `focus` unless the point is to move them there. Keyboard focus follows it.
- Don't close or move tiles you didn't create unless the user asked for it. `close` ends the processes in the tile.
- To "open" a session that is live somewhere else (another terminal app, another tile), use the default fork. Say that it's a fork.
- Finish with `fit` on the tiles you worked on, so the user sees the result.

## Recipes

Open a few Claude sessions from other terminals side by side:

```sh
# Session ids of the running Claude processes
for pid in $(pgrep -x claude); do ps -o args= -p $pid; cat ~/.claude/sessions/$pid.json 2>/dev/null; echo; done
$CANVAS state                                   # find free cells
$CANVAS open-claude <id1> --at 10,5 --size 2x2
$CANVAS open-claude <id2> --at 12,5 --size 2x2
$CANVAS fit <tile1> <tile2>
```

Tidy existing tiles into two columns: `$CANVAS grid 2 3 4 5 --cols 2 --size 2x2 --at 10,5`.

## Protocol (for non-Python callers)

Codeboard watches `~/Library/Application Support/com.jackdigilov.codeboard/control/`. Write `{"command": ..., "args": {...}, "createdAt": <unix seconds>}` to a dotfile in that directory, then rename it to `<id>.request.json`. Codeboard deletes the request and writes `<id>.response.json` containing `{"ok": true, "result": ...}` or `{"ok": false, "error": "..."}`. Requests older than 30 s are refused. Commands: `state`, `new-terminal` (x, y, width, height, cwd, command, focus), `new-browser` (x, y, width, height, url, focus), `place` (tiles: [{tile, x, y, width?, height?}]), `focus` (tile, center), `close` (tile), `zoom` (scale), `fit` (tiles, margin).

If `state` says the control directory is missing, the running Codeboard predates this channel. Reload it from the repo with `./scripts/codeboardctl reload`, after `swift test` passes (see the repo's AGENTS.md).
