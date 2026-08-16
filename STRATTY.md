# Stratty downstream notes

Stratty is a focused Linux GTK downstream of Ghostty. Ghostty remains authoritative for PTYs, process ownership, terminal emulation, rendering, scrollback, and native tabs.

## Runtime configuration

Stratty inherits two executable-only environment variables from the application process:

```sh
export EDITOR=nvim
export AGENT=pi
```

`EDITOR` defaults to `nvim`; `AGENT` defaults to `pi`. Values may be executable names or paths. Shell fragments, arguments, whitespace, and control characters are intentionally rejected. New contextual tabs use a normal interactive Fish startup and submit the configured executable only after the first prompt, so normal direnv initialization runs first.

Default direct actions:

- `Ctrl+,` — shell
- `Ctrl+.` — agent
- `Ctrl+/` — editor

The configurable Ghostty action is `focus_contextual_tab:{shell,agent,editor}`.

Optional editor and agent icon overrides use normal Ghostty config paths:

```ini
stratty-editor-icon = ~/.config/ghostty/icons/editor.svg
stratty-agent-icon = ~/.config/ghostty/icons/agent.svg
```

Missing override files fall back to the bundled Neovim and Pi icons. The bundled Cannoli Shell icon is fixed.

The sidebar targets about 17.1% of the live window width (236px at the validated 1380px reference), bounded to 210–320px. Its final width snaps to the nearest valid size that leaves the terminal viewport on a whole-cell boundary. GTK sidebar widths are converted from logical pixels through the active widget's integer buffer scale, including GTK's observed request-to-allocation offset, before they are compared with Ghostty's buffer-pixel cell metrics and padding; window, display-scale, and font-cell changes all reschedule this calculation. The shared terminal edge has zero explicit right padding, and the panel edge overlaps the compositor's fractional-filter footprint so no uncovered strip appears. The sidebar uses the active terminal palette's Base16 mapping. Its subtle base0B panel accent and selected-row gradient use Q16 alpha with independent, non-periodic dithering of every premultiplied channel, avoiding both low-alpha stop bands and repeating-matrix moire. Idle is a hollow muted dot, running is solid base0B, and native BEL attention is solid base0A. Attention wins over lifecycle state and clears on focus. Agent programs can explicitly report idle/running with iTerm2's `SetUserVar`:

```text
OSC 1337 ; SetUserVar=STRATTY_AGENT_STATE=<base64("idle"|"running")> BEL
```

Stratum Pi emits this automatically and sends a separate BEL after `agent_settled` to request attention only when its tab is in the background.

## Downstream organization

Pure policy lives under `src/stratty/`:

- `controller.zig` — window-local focus, creation, pending state, and lifecycle ordering
- `commands.zig` — `EDITOR`/`AGENT` validation and role recognition
- `lifecycle.zig` — Fish OSC 133 metadata parsing and command classification
- `workspace.zig` — canonical Git-worktree identity with exact-CWD fallback
- `labels.zig` — stable workspace qualification and duplicate numbering
- `linux_process.zig` — foreground-process role and working-directory refinement
- `icons/` — bundled role icons and attribution

GTK adaptation lives under `src/apprt/gtk/stratty/`. `adapter.zig` translates runtime events and `sidebar.zig` owns the Quiet List widgets and palette-derived CSS. Upstream-facing files should contain only transport, action-dispatch, or widget-mounting hooks; policy does not belong in Ghostty window or surface classes.

## Development

The repository has an `upstream` remote pointing at `ghostty-org/ghostty`.

```sh
nix develop --no-write-lock-file -c zig build
nix develop --no-write-lock-file -c zig build test -Dtest-filter=Stratty
zig test src/stratty.zig
fish -n src/shell-integration/fish/vendor_conf.d/*.fish
```

Use a linear downstream patch stack when committing:

1. pure controller and policy;
2. Fish/OSC lifecycle transport;
3. GTK contextual actions;
4. managed labels;
5. vertical tab presentation;
6. branding and packaging.

Before rebasing, fetch `upstream/main`, run the tests above, rebase the downstream commits, then run the same tests and a GTK startup smoke test again.
