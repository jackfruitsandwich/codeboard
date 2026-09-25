# codeboard

A canvas of ghostly terminals (and browser windows).

![demo](demo.gif)

## Build and install

Codeboard embeds Ghostty through its (unstable) embedding API, so it is built against one pinned Ghostty commit. You need:

- macOS 14+, full Xcode (`sudo xcode-select --switch /Applications/Xcode.app`)
- `zig` 0.15.x (`brew install zig`)
- `tmux` (`brew install tmux`), for terminals that survive app reloads

```sh
./scripts/setup-ghosttykit.sh      # clones Ghostty into vendor/, checks out the pinned commit, builds GhosttyKit
./scripts/install-macos-app.sh     # swift build -c release, then installs /Applications/Codeboard.app
```

If the first step complains about the Metal compiler, run `./scripts/fix-metal-toolchain.sh` and retry. On Xcode 27 the Ghostty build ends with a `libghostty-vt` / libc++ error; the script ignores it because GhosttyKit itself was built. Already have a Ghostty checkout? Point `GHOSTTY_SOURCE_DIR` at it; the script checks out the pinned commit there.

Codeboard's terminals put small `claude` and `claude-ev` shims first on `PATH` so forks know the exact Claude Code session ID; everything else in your shell is untouched.

## Shortcuts

### Tiles

| Shortcut | Action |
|----------|--------|
| `Cmd+T` | New terminal (+ arrow key within 0.25s to pick direction) |
| `Cmd+Shift+T` | Fork the focused Claude or Wuwei conversation into a new tile |
| `Cmd+D` | Duplicate focused tile (+ arrow key for direction) |
| `Cmd+B` | New browser |
| `Cmd+Delete` | Close focused tile |

### Navigation

| Shortcut | Action |
|----------|--------|
| `Cmd+Arrow` | Focus adjacent tile, or expand the focused tile one grid unit in that direction if there is no destination |
| `Cmd+0` | Center on focused tile |

After a keyboard expansion, press `Cmd+Arrow` in the opposite direction within two seconds to undo it.

### Zoom

| Shortcut | Action |
|----------|--------|
| `Cmd+=` / `Cmd+-` | Zoom in / out |
| `Option+Scroll` | Zoom with scroll wheel |
| `Pinch` | Trackpad zoom |

### Browser

| Shortcut | Action |
|----------|--------|
| `Cmd+[` / `Cmd+]` | Back / Forward |
| `Cmd+R` | Reload |

### Edit

| Shortcut | Action |
|----------|--------|
| `Cmd+C` | Copy |
| `Cmd+V` | Paste |
| `Cmd+Shift+V` | Paste as plain text |

Plain dragging selects scrollback and copies it on release. In mouse-aware TUIs, hold `Shift` while dragging, then `Cmd+C`.

## Config

Reads `~/Library/Application Support/com.jackdigilov.codeboard/config.ghostty` (Ghostty format: theme, font-size, font-family, etc). `./scripts/copy-ghostty-config.sh` copies your existing Ghostty config there.

## Conversation forks

Press `Cmd+Shift+T` or right-click a terminal and choose **Fork Conversation**. Works for Claude Code (`claude`, `claude-ev`, either wrapped in Context Surgeon) and Wuwei. The fork opens to the right in the same working directory; the original conversation is untouched.

## Agent control

Agents and scripts can drive the running canvas with `scripts/codeboard-canvas`: list tiles, open terminals, browsers or Claude sessions (as forks) at chosen grid cells, move and arrange tiles atomically, focus, zoom, fit the view, close tiles. It talks to Codeboard through request/response files in `~/Library/Application Support/com.jackdigilov.codeboard/control/`.

```sh
./scripts/codeboard-canvas state
./scripts/codeboard-canvas open-claude <session-id> --at 10,5 --size 2x2
./scripts/codeboard-canvas fit
```

To give Claude Code the skill, symlink the skill folder (the CLI is linked inside it):

```sh
ln -s "$PWD/skills/codeboard-canvas" ~/.claude/skills/codeboard-canvas
```

## Development reloads

Terminals run in private tmux sessions (`tmux -L codeboard`), so shells, editors and agents survive a rebuild. Your own tmux config is not used. After a change passes its checks:

```sh
swift test
./scripts/codeboardctl reload
```

`reload` builds a debug candidate while the current app keeps running, verifies the bundle, then hands off. A build failure leaves the running app untouched; a failed startup restores the previous bundle. `--dry-run` validates packaging only, `--release` builds optimized. Terminal sessions and canvas state survive reloads and normal Quit; closing a tile ends its session.

If `swift test` fails at codesign with "resource fork, Finder information, or similar detritus", the repo is in an iCloud-synced folder; run it with `--scratch-path` pointing outside that folder.
