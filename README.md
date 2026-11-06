# Lantern

Native macOS plan viewer for Claude + Ghostty workflows. Claude writes markdown plans; Lantern shows them live, you approve or request changes, Claude reads your decision. Your `.md` files are never modified — decisions, notes and history live in a sidecar under `~/.lantern/data`.

## Install
```
./scripts/install.sh      # -> ~/Applications/Lantern.app and ~/.local/bin/lantern
```

## CLI (what Claude runs)
```
lantern plan.md | lantern ./plans/     open a plan / watch a folder (no focus steal)
lantern open plan.md --window --full   normal window instead of a Ghostty pane
lantern open plan.md --split           ask Ghostty to create a right split first (AppleScript)
lantern status plan.md                 pending | approved | changes     (exit 4 / 0 / 2)
lantern wait plan.md [--timeout 600]   block until decided; prints status + notes
lantern comments plan.md               review notes, formatted for Claude
lantern switch <name|index>  lantern width 50  lantern list  lantern close [plan.md]
```
A decision applies to the exact content it was made on: when Claude edits the plan afterwards, status goes back to **pending**.

## Keys
`⌘↩` approve · `⇧⌘↩` request changes · select text + `C` note · `⌘,` settings · `⌘F` find · `⌘Y` history · `⌘L` lite/full · `⌘\` side/top tabs · `Esc` hand focus back to Ghostty (pane mode)
Vim: `j k` `5j` `⌃d ⌃u` `gg G` `]] [[` `gt gT` `/ n N` `:q :approve :reject`

## Tell Claude (CLAUDE.md snippet)
```
After writing a plan, run `lantern <plan.md>`, then `lantern wait <plan.md>`.
If approved, implement it. If changes were requested, read the notes it prints, revise the file, and wait again. Run `lantern close` when done.
```

## Tests
`./scripts/test.sh` runs the real app in the background (accessory app, off-screen window, isolated `LANTERN_HOME`, never touches your Ghostty) and writes screenshots to `tests/screenshots/`.

## Claude control (MCP)

`lantern mcp` is a stdio MCP server. Register it once and Claude can open, switch, close and resize the viewer on its own:

```
claude mcp add --scope user lantern -- ~/.local/bin/lantern mcp
```

Tools: `lantern_open` (files or folders, `mode` pane|window, `width`, `side`, `focus`), `lantern_close`, `lantern_switch`, `lantern_list`, `lantern_layout` (pane width/side), `lantern_screenshot`. The server sends usage instructions in the MCP handshake, so Claude knows to open plans it writes, not to re-open after edits (files update live), and not to steal focus.
