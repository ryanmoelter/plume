# Linear sync

Plume keeps a local copy of each connected Linear workspace and reads from it. Rows, the info pane and future features (issue search, @-mentions of tickets) ask `LinearStore`, which answers from the cache. They never fetch.

Real-time push is not available to a desktop client. Linear pushes only through webhooks, which need a public HTTPS endpoint and a workspace admin. A webhook relay could feed the same cache later; nothing here assumes polling is the only source.

## Pieces

- **`LinearSyncCache`** (`Plume/Linear/LinearSyncCache.swift`) is a pure value per workspace. It holds issues, workflow states and users, each keyed by Linear id, plus an `updatedAt` cursor and an alias table for issues that moved teams. All merge, cursor and prune rules live here and are unit-tested.
- **`LinearCacheDisk`** is an actor that reads and writes the files off the main thread. Files live in `AppPaths.applicationSupport/linear/`: `catalog-<orgID>.json` (teams and their states) and `issues-<orgID>.json` (the sync cache). Debug and worktree builds get their own directory through `AppPaths`.
- **`LinearStore`** owns the caches, runs the syncs and lookups, and publishes per-identifier state to views.

## The delta sync

Every 45 seconds while Plume is frontmost, and when it comes to the front (at most every 15 seconds), each workspace runs one query:

```
issues(orderBy: updatedAt, includeArchived: true, filter: { updatedAt: { gte: <cursor - 30s> } })
```

Pages are 100 issues, newest first, up to 5 pages per sync. The cache merges each issue by id. A snapshot older than the one held is ignored, so the same row seen twice is harmless. The cursor becomes the newest `updatedAt` seen. Afterwards the store republishes every wanted identifier from the cache.

- **Clock edge.** The query starts 30 seconds before the cursor, with `gte`. A write that commits late with an earlier timestamp still falls inside the next window, and dedupe by id makes the overlap free. The cursor comes from server timestamps, never the local clock, except for the first sync's lower bound.
- **First sync.** It backfills issues updated in the last 14 days, capped by the page limit. Issues the user's tasks reference but the backfill missed are looked up by identifier (below). The cache never tries to hold the whole workspace.
- **Overflow.** If the page cap stops a delta early, the issues held but not covered may have missed an update. The cache drops them and keeps only what the delta fetched. Wanted identifiers that were dropped are looked up again.
- **Deletion and archival.** Archived issues stay in the cache and display as before. A trashed issue (`trashed: true`, Linear's delete) is removed. A permanent deletion never appears in any delta, so the store re-verifies wanted cached issues by identifier once they are older than `verifyInterval` (30 minutes). A lookup that finds nothing removes the issue.
- **Renames.** States and users are separate tables. A renamed state reaches every issue in it once the catalog or any issue payload carries the new name.

## Lookups by identifier

A wanted identifier is looked up in batches of 50 only when one of these holds:

- the cache lacks it and its last answer has expired;
- a sync just dropped it;
- it is cached but unverified for `verifyInterval`;
- an agent wrote to it (an early refetch).

A lookup goes only to the workspaces whose catalog has the identifier's team key. Its answer merges into the cache, and the requested identifier is kept as an alias when the issue has moved.

## Budget and failures

- A workspace with under a tenth of its rate limit left skips syncs until the reset.
- A rate-limit response pauses all requests until the reset Linear names. An auth failure stops the workspace until its key changes.
- Any other sync failure backs off exponentially, from 30 seconds up to 15 minutes. Wanted issues from that workspace show as stale meanwhile.

## Retention

Each save prunes issues untouched for 30 days that no current view wants, and users no issue references. A cache file from another `formatVersion` is discarded, and the next sync backfills from scratch.
