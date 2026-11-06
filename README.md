# Lantern

A lean, view-only macOS markdown viewer. Claude (or you) opens `.md` files; Lantern renders them live in its own window.

- Multiple files become horizontally scrolling tabs across the top.
- Live reload: edits to an open file appear instantly and changed blocks glow.
- Code highlighting, tables, task lists, Mermaid diagrams, frontmatter card, clickable `file:line` refs, system light/dark.
- No editing, approval, notes or settings.

## Install

    ./scripts/install.sh      # builds, installs /Applications/Lantern.app and ~/.local/bin/lantern, smoke-tests

## CLI

    lantern open <file|dir>... [--focus]
    lantern switch <file|index|name>
    lantern close [file]
    lantern list
    lantern window [--width N] [--height N] [--x N] [--y N] [--center] [--minimize|--restore|--fullscreen]
    lantern snapshot <out.png>
    lantern mcp                 # MCP server over stdio

## MCP (for Claude)

    claude mcp add lantern -- ~/.local/bin/lantern mcp

Tools: `lantern_open`, `lantern_switch`, `lantern_close`, `lantern_list`, `lantern_window`, `lantern_screenshot`.

## Develop

    xcodegen generate
    ./scripts/test.sh           # background end-to-end suite, screenshots in tests/screenshots
