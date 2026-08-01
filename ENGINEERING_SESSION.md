# IR Blaster Bulk Import Engineering Session

## Goal
Add reliable one-tap bulk import for supported IR formats from local folders and GitHub repositories.

## Supported formats
- Flipper Zero `.ir`
- IRPlus `.irplus` / XML
- LIRC `.conf` / `.cfg` / `.lirc`
- Existing app backup JSON

## Planned milestones
1. Identify current import, GitHub Store, parser, and persistence architecture.
2. Add recursive local-folder import with progress, cancellation, and per-file error isolation.
3. Add repository-wide GitHub import with pagination/rate-limit handling.
4. Add duplicate detection and batched persistence.
5. Add tests and build validation.

## Status
Repository fork connected. Architecture inspection started.
