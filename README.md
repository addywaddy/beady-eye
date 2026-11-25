# Beady Eye

A native macOS front end for [beads](https://github.com/gastownhall/beads) (`bd`), the issue tracker that stores its data in [Dolt](https://www.dolthub.com/).

Beady Eye drives the `bd` command line (`bd --json`) and never talks to Dolt directly. Anything beads defines, such as statuses, categories, issue types, what counts as blocked, ready or overdue, and who you are, comes from `bd` itself rather than being reimplemented in the app.

## Features

- **Three views.** A list with a detail pane, a kanban board and a dependency graph.
- **Board columns are bd's status categories** (active, wip, done, frozen). Every card shows its exact status. Dragging a card to a column sets a status in that category.
- **Sidebar filters** for statuses, epics, labels and assignees. Rows are toggles: select several, click again to clear. They combine with each other and with search.
- **Issue details.** Editable title and description with Markdown rendering, status, priority, assignee, due date, defer date, epic, labels, comments, child issues for epics and relations.
- **Assignees.** Claim an issue as yourself ("Me" is whoever bd says you are) or assign it to someone else.
- **Due and defer dates.** Overdue is bd's own rule. Deferring sets an issue aside, until a date or until you undefer it.
- **History and diff.** Per-issue history from Dolt with line diffs of what changed and who changed it.
- **Memories.** Browse, add, edit and forget the notes stored with `bd remember`.
- **Live updates.** The app polls `bd` every few seconds, so changes made by agents or the CLI appear on their own.
- **Several projects.** Add any bd project as a connection and switch between them.
- Light and dark appearance follow the system setting.

## Download

Get the latest `BeadyEye-<version>.dmg` from the [Releases](https://github.com/addywaddy/beady-eye/releases) page, open it and drag Beady Eye to Applications. The app is signed and notarized by Apple.

## Requirements

To run the app:

- macOS 14 or later, on Apple silicon
- [`bd`](https://github.com/gastownhall/beads) 1.3 or later, installed on your machine. Beady Eye drives it and does not bundle it.
- A project initialised with `bd init --server`, backed by a running Dolt server

To build it yourself you also need a Swift 6 toolchain (Xcode 16 or later, or the command line tools).

The app finds `bd` through your login shell, then falls back to Homebrew's location. Embedded-mode and legacy server workspaces need migrating before a current `bd` can open them. See the beads upgrade notes.

## Build and run

```bash
Scripts/bundle.sh debug      # or: Scripts/bundle.sh release
open build/BeadyEye.app
```

This builds the Swift package and wraps it in `build/BeadyEye.app`, signed ad-hoc by default. Launch the app from the bundle, not the bare binary, so it uses the right preferences domain.

On first launch choose **Add Connection** (⌘O) and pick a folder that contains a `.beads` directory.

### Signing

For a build you want to distribute, name a certificate:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/bundle.sh release
```

`security find-identity -v -p codesigning` lists what is available. The script signs with the hardened runtime and a timestamp. Notarization is done by `Scripts/release.sh`.

### Releasing

`Scripts/release.sh` builds, signs with your Developer ID, notarizes, staples and packages `dist/BeadyEye-<version>.dmg`. It expects a notarytool keychain profile (see the comments in the script).

```bash
VERSION=0.1.0 Scripts/release.sh
```

### App icon

`Scripts/make-icon.swift` draws the icon and writes `Resources/AppIcon.icns`:

```bash
swift Scripts/make-icon.swift
```

## How it works

| File | Role |
| --- | --- |
| `BdClient.swift` | An actor that runs `bd` as a subprocess and decodes its JSON. Writes are logged to `~/Library/Logs/BeadyEye/bd.log`. |
| `Store.swift` | The observable app state: issues, filters, selection and every action. It polls `bd list`, `bd ready` and `bd blocked`. |
| `Models.swift` | `Issue`, `StatusInfo`, `Memory` and friends. |
| `ContentView.swift`, `BoardView.swift`, `GraphView.swift`, `IssueDetail.swift` | The interface. |
| `MarkdownParse.swift`, `MarkdownView.swift` | A small Markdown block renderer. |
| `History.swift`, `HistoryView.swift` | Per-issue Dolt history and diffs. |

The app only ever reads beads data through `bd`, so it works with whatever your installed version supports. It reads the status list with `bd statuses`, the types with `bd types`, blocked issues with `bd blocked` and ready work with `bd ready`.

## Limits

- It is built for projects with up to a few thousand issues. Every refresh lists all issues, closed ones included.
- Images are not rendered, because beads has no image support.
- There are no push, pull or remote controls yet.

## Issues

This project tracks its own work with beads. See `CLAUDE.md` and `bd prime` for the workflow.

## Licence

MIT. See `LICENSE`.
