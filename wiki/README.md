# wiki/ — emitted mirror

This directory is an **emitted mirror** of the **"Game: War"** wiki workspace (the structured
architecture wiki: ADRs + subsystem docs). It is **not** the source of truth and is **read-only
on disk**.

## How it works

The wiki content lives in a structured workspace served by the **`wiki` MCP server** at
`https://hotseat.thegoldenmule.com/mcp` (workspace **"Game: War"**, id pinned in
`../hotseat.config.json`). A live emitter regenerates this directory on **every change** to the
workspace:

```
wiki/
  game-war/                 the emitted markdown pages (one .md per wiki page)
  game-war/.wiki-md-manifest.json   the emitter's manifest (page → file map, ordering, metadata)
```

- **Read these files freely** — they are a faithful, browseable snapshot of the wiki for grep,
  diffing, and offline reading.
- **Do not edit them by hand.** The emitter overwrites the `.md` files and
  `.wiki-md-manifest.json` from the workspace on every change, so any direct edit is lost.

## Editing wiki content

Edit through the **`wiki` MCP**, not the files:

- Read: `getPage`, `renderPage`, `tree`, `search`, `outline`.
- Write: `createPage`, `mutatePage` / `mutatePageBatch`, `link` / `unlink`, `setPageTitle`, …
- Inspect a page's legal commands first with `describeMutations` / `describePageType`; the wiki
  is self-directing (each write echoes a `next`; `nextActions` rolls up what to do next).

After a write, the on-disk `wiki/game-war/*.md` regenerates automatically — no manual sync.

## What's in it

The architecture wiki for War: design rationale (determinism parity, the hard wall, optimistic
client + reconcile), per-subsystem docs (client logic engine, validator wire, Special Cards /
flip moment), and ADRs. For the always-current engineering docs, see the in-repo
`../game/README.md`, `../game/ARCHITECTURE.md`, and `../game/CLAUDE.md`.
