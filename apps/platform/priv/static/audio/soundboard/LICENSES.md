# Soundboard audio files

Seven sound effects wired to keys 1–7 in the meeting soundboard.

| File | Key | Label | Source | License |
|------|-----|-------|--------|---------|
| 1-gong.mp3      | 1 | Gong      | _TODO: add source URL + author_ | _TODO_ |
| 2-airhorn.mp3   | 2 | Air horn  | _TODO: add source URL + author_ | _TODO_ |
| 3-applause.mp3  | 3 | Applause  | _TODO: add source URL + author_ | _TODO_ |
| 4-crickets.mp3  | 4 | Crickets  | _TODO: add source URL + author_ | _TODO_ |
| 5-faahh.mp3     | 5 | Faahh     | _TODO: add source URL + author_ | _TODO_ |
| 6-shocked.mp3   | 6 | Shocked   | _TODO: add source URL + author_ | _TODO_ |
| 7-suspense.mp3  | 7 | Suspense  | _TODO: add source URL + author_ | _TODO_ |

Before merging, confirm each file is licensed for free distribution (CC0,
CC-BY with attribution below, or pixabay-equivalent). Fill in the TODO
cells above with the original source URL, author, and license.

## Adding new sounds

1. Drop a trimmed, mono-or-stereo MP3 into this directory named `N-slug.mp3`.
2. Add a matching entry to `SOUNDS` in `apps/platform/assets/js/hooks/meeting_soundboard.js`.
3. Add a row to the popover in `apps/platform/lib/platform_web/live/chat/partials.ex` (`soundboard_menu/1`).
4. Update this README.

Keep files under ~150 KB each — the browser caches them but the initial
miss shouldn't pause a call. Keep duration under 10s; the hook's safety
timeout will force-kill nodes that play longer than that.
