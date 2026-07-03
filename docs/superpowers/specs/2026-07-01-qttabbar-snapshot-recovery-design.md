# QTTabBar Snapshot Recovery Design

## Goal

Provide a stable recovery path for the "menu strip remains but the actual QTTabBar tab band is missing or collapsed" failure mode.

## Decision

Use snapshot-based recovery as the primary long-term mechanism:

- Save a known-good Explorer/QTTabBar layout snapshot while tabs are visibly healthy.
- Restore that snapshot later instead of depending on layout deletion and spontaneous QTTabBar regeneration.
- Keep `-ResetLayout` and menu `[9]` as an experimental fallback only.

## Scope

Add two user-facing operations:

1. Save the current healthy snapshot.
2. Restore the latest saved healthy snapshot and restart Explorer.

## Snapshot Contents

The first version stores the two registry keys already proven to matter in live debugging:

- `HKCU:\Software\Microsoft\Internet Explorer\Toolbar\ShellBrowser`
- `HKCU:\Software\Quizo\QTTabBar\Volatile`

Each save operation exports both keys into a dedicated snapshot folder under `Backup\Snapshots`.

## Restore Rules

- Restore only from an explicit saved snapshot.
- Import both snapshot files as one unit.
- Restart Explorer after restore.
- If no snapshot exists, fail with a clear message instead of guessing.

## UX

- Add one menu entry for saving a healthy snapshot.
- Add one menu entry for restoring the latest healthy snapshot.
- Update post-fix guidance to recommend snapshot restore before experimental layout reset.

## Testing

Add Pester coverage for:

- worker argument parsing and menu routing
- snapshot save exporting both keys
- snapshot restore importing both files and restarting Explorer
- missing snapshot failure path
