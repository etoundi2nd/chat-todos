# Chat Todos

A tiny macOS menu-bar app for the small bits of AI-assisted work: answers you want to keep, links, half-formed ideas, and prompts you want to try next. It's a to-do list, a clipboard, and a scratchpad in one floating panel that sits next to ChatGPT, Claude, Cursor, or your terminal.

Inspired by [Copper](https://shadcn.com/copper) by shadcn. This is an independent re-creation, not affiliated with it.

## How it works

1. **Capture** – select text in any app and tap **Left Shift twice**. It's saved to the active section and a small "Saved" toast confirms it. You never leave the app you're in.
2. **Queue** – tap **Right Shift twice** (or **⌘⇧Space**) to open the panel and type a prompt you want to try next.
3. **Use** – select an item, **⌘C**, paste it into your AI tool, and press **Space** to check it off. **⌘↩** does both at once.
4. **Organize** – type `# Name` in the composer to start (or switch to) a section. New captures go there until you switch with **⌘K**.

Everything stays on your Mac in one JSON file. No account, no sync, no telemetry, no network access at all.

## Shortcuts

| Where | Keys | Action |
|---|---|---|
| Anywhere | Left ⇧ ⇧ | Save selected text |
| Anywhere | Right ⇧ ⇧ | Show / hide panel |
| Anywhere | ⌘⇧Space | Show / hide panel (works without Accessibility) |
| Panel | ↑ ↓ | Move selection (⇧ extends, ⌥ reorders) |
| Panel | Space | Check off / uncheck |
| Panel | ⌘C / ⌘⇧C | Copy / copy as Markdown list |
| Panel | ⌘↩ | Copy and check off |
| Panel | ↩ or double-click | Edit (links open, files reveal in Finder) |
| Panel | ⌫ then ⌘Z | Delete, undo |
| Panel | 1–6, 0 | Color tag, clear tag |
| Panel | ⌘V or drag & drop | Add text, image, screenshot, or file |
| Panel | ⌘K | Switch or create section |
| Panel | ⌘F | Search |
| Panel | ⌘E | Export as Markdown |
| Panel | Tab or just type | Jump to the composer |
| Panel | Esc | Hide and return focus to the previous app |
| Panel | ⌘/ | Shortcut sheet |

Right-click a section header to rename, clear completed, or delete it. Click a color dot in the header to filter by tag.

## Build & install

Requires macOS 14+ and Xcode (or the Swift toolchain).

```bash
scripts/install.sh
```

That builds `build/Chat Todos.app`, copies it to `/Applications`, and launches it. To build only:

```bash
scripts/build.sh
```

On first launch macOS asks for **Accessibility** access (System Settings → Privacy & Security → Accessibility). It's needed to see the double-Shift taps and read your text selection. Until it's granted, the panel shows a banner and ⌘⇧Space still works.

> The default build is ad-hoc signed, so macOS treats every rebuild as a new app and you'll have to re-enable Accessibility after rebuilding (toggle it off/on, or remove and re-add it). Set `SIGN_IDENTITY="Apple Development: …"` when running the scripts to keep the grant across builds.

Enable **Launch at Login** from the menu-bar icon's right-click menu.

## Data

- `~/Library/Application Support/Chat Todos/chat-todos.json` – sections and items (human-readable, millisecond timestamps)
- `~/Library/Application Support/Chat Todos/images/` – pasted or dropped images

If the JSON file can't be read, it's copied to `chat-todos.corrupt-<timestamp>.json` before a fresh one is started, so nothing is silently lost.

## Development

```bash
swift test
```

```bash
swift build && CHAT_TODOS_DATA_DIR=/tmp/chat-todos-dev .build/debug/ChatTodos
```

`CHAT_TODOS_DATA_DIR` points the app at a throwaway data folder. In debug builds, `CHAT_TODOS_SNAPSHOT=/tmp/shot` additionally writes PNGs of the panel in a few states.

Layout:

- `Store.swift` – model state, persistence, undo, sections, clipboard, export
- `ShiftTapMonitor.swift` – listen-only CGEvent tap that detects lone double Shift taps
- `SelectionCapture.swift` – reads the selection via the Accessibility API, falling back to a synthetic ⌘C that restores your clipboard afterwards
- `HotKey.swift` – Carbon global hotkey fallback
- `AppDelegate.swift` – menu-bar item, panel lifecycle, keyboard handling
- `Views.swift`, `Windows.swift` – SwiftUI UI, floating panel, capture toast
