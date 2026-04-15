# codeboard

A canvas of ghostly terminals (and browser windows).

<video src="demo.mp4" autoplay loop muted playsinline></video>

## Shortcuts

### Tiles

| Shortcut | Action |
|----------|--------|
| `Cmd+T` | New terminal (+ arrow key within 0.25s to pick direction) |
| `Cmd+D` | Duplicate focused tile (+ arrow key for direction) |
| `Cmd+B` | New browser |
| `Cmd+Delete` | Close focused tile |

### Navigation

| Shortcut | Action |
|----------|--------|
| `Cmd+Arrow` | Focus adjacent tile |
| `Cmd+0` | Center on focused tile |

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

## Config

Reads from `~/Library/Application Support/com.jackdigilov.codeboard/config.ghostty` (Ghostty format — theme, font-size, font-family, etc).
