# Codeboard development workflow

Codeboard reloads are deliberately agent-controlled. Never reload merely because a source file changed.

When a coherent change is complete:

1. Run `swift test`.
2. Run any relevant manual or script checks.
3. Run `./scripts/codeboardctl reload` to build, validate, and transactionally hand off to the new app.

If the build or tests fail, keep working in the current session and do not trigger a reload. `codeboardctl` uses a debug build by default; use `--release` only when explicitly requested.

The first upgrade from a pre-tmux Codeboard cannot preserve its direct-shell terminals. If that older app refuses the private reload request, ask the user to finish or close those terminals and quit it manually; never retry reloads in a loop or force-kill it.
