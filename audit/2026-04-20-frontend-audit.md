# Startup Suite — Frontend Audit

**Date:** 2026-04-20
**Author:** Saru (synthesis) with architect + frontend-design sub-agents
**Scope:** Broad audit across chat, tasks, canvas, federation, notifications, and mobile surfaces
**Requested by:** Marlowe

## Executive summary

1. **One user-blocker.** Mobile PWA has no way to create a new DM or channel — the affordance is inside a desktop-only `<aside class="hidden lg:flex">`. This is the bug Marlowe flagged, and it's the same root cause as BACKLOG #1. **~20 lines of heex fixes it.**
2. **iOS zoom-on-focus bug.** Composer textarea `font-size: 14px` (`app.css:1123`) triggers iOS Safari's "zoom on focus" behaviour — Safari auto-zooms any input below 16px on focus, and combined with the `maximum-scale=1` lock (kept intentionally for native-app feel), the UI can get "unmoored / stuck zoomed." Fix is at the source: bump to `font-size: 16px`, so no zoom triggers in the first place. **Does NOT require removing `maximum-scale=1`.**
3. **~~WCAG violation~~ → Product philosophy choice.** I initially flagged `maximum-scale=1` as WCAG 2.1 SC 1.4.4 (Resize Text). Per Rowan's correction: Suite operates as an installed PWA intended to feel like a native chat app, and you can't pinch-zoom into arbitrary parts of native chat apps either. The constraint is intentional. **The right a11y path is in-app accessibility settings** (font-size picker, contrast toggle, reduced-motion respect) — Rowan's framing: "I'd sooner offer accessibility settings in app than have a floaty UI that zooms all the time when you try to navigate the app." Also worth verifying the PWA respects OS-level Dynamic Type / Android font scale. Both are separate investigations / feature work — not a viewport-meta change.
4. **Attachment rendering is NOT a template issue.** The grey box is the unstyled `.gallery-item` background showing through when `<img>` fails to load (likely 404 from lost container-local storage volume, or `content_type` misclassification on iOS uploads).
5. **The orientation brief's framing was partially stale.** Hotspots #2 (canvas transition) and #4 (meeting dead code) are already ~90% done. What's left there is *cleanup*, not structural refactor. The audit recommendations reflect the actual current state.
6. **Touch-interaction gaps are pervasive.** The `opacity-0 group-hover:opacity-100` pattern (used for reactions, message actions, thread-open) is invisible on touch. Reaction hit-targets are 22-26px (below 44pt iOS / 48dp Android minimums). Kanban drag-drop uses HTML5 DnD, which does not fire on iOS Safari touch.
7. **"Desktop-first, wrapped in `hidden lg:flex`" is the dominant mobile failure mode.** It doesn't fail loudly — it fails invisibly. Missing search-on-mobile, missing DM creation, missing tasks-project-switcher are all the same anti-pattern.
8. **No E2E tests exist.** Hotspot #11 is the single best argument for adding Playwright — a 20-minute test at `viewport: {width: 375}` would have caught the DM-creation regression before it reached production.

**Proposed PR sequencing (five PRs, ~8 hours total):**

| # | Title | Scope | Why this order |
|---|---|---|---|
| 1 | `fix(mobile): add new-conversation + new-channel buttons to mobile drawer` | 20 LOC heex | Unblocks users today. Zero risk. |
| 2 | `fix(mobile): composer font-size 16px (iOS zoom-on-focus fix) + 44pt touch targets` | ~20 LOC | Eliminates the iOS Safari zoom-on-focus trigger at the source (so `maximum-scale=1` can stay — native-app feel intact) + hit-target a11y. |
| 3 | `fix(chat): attachment render fallback + content-type sniffing` | ~80 LOC | Fixes visible "grey box" bug + makes storage-missing cases legible. |
| 4 | `feat(chat): touch-polish reactions (44pt pills, always-visible "+", responsive picker grid)` | ~300 LOC CSS + heex | Mobile reactions UX polish per BACKLOG #3. |
| 5 | `refactor(chat): namespace MessagesHooks events, standardize param casing, document attach order` | ~60 LOC | Pays down ChatLive modularization tech debt. Low user-visible impact. |

Everything else is captured below as task-list items for future scheduling.

---

## Orientation corrections

The orientation brief framed three hotspots as more broken than they actually are. Posting the corrections prominently so future readers don't redo the investigation:

- **Hotspot #2 (Canvas document transition) is ~90% done.** Legacy `canvas_type`, `state`, `a2ui_content` columns were dropped by migration `20260418120000_canvas_first_class_refactor.exs`. The renderer, `CanvasPatch`, `Canvas.Server`, `Canvas.Tools`, and Chat context helpers all share the canonical `CanvasDocument` schema. What remains is minor cleanup (remove `initial_state` tool alias; remove the shadow `structured_content.canvas_id/title` stamp).
- **Hotspot #4 (Meeting UI dead code) is done.** The dual handlers, double-assigns, and reconnect loop flagged in ADR 0035 are no longer present. `MeetingHooks` documents the cleanup at `meeting_hooks.ex:8-14`. What remains is naming (`ShellLive.meeting_active` collides with `MeetingHooks.in_meeting`) and documentation (no sequence diagram).
- **Hotspot #10 (Mentions) has no "cross-org federation" problem.** Cross-org agents appear as local `chat_participants` rows once they join a space (ADR 0038). Mention resolution is local throughout. The real issues are render-time existence checks (no fallback for deleted/renamed participants) and compose-time minimum-query-length.

This leaves **8 hotspots with real, actionable findings.** Hotspots #2, #4, #10 still have findings, just smaller than the brief implied.

---

## Findings by hotspot

### Hotspot #1 — Attachment rendering is a storage/content-type problem, not a template problem

**Current state:** Render pipeline is wired correctly. `chat_live.html.heex:725-756` renders `<img src={attachment_url(attachment)} loading="lazy">` inside `.image-gallery > .gallery-item`, filtered via `image_attachment?/1` (`chat_live.ex:620`). Served by `ChatAttachmentController.show/2` with `disposition: :inline`. The "grey box" is the unstyled `.gallery-item` background (`app.css:982-991`) showing through when `<img>` fails to load.

**Findings:**
1. **[bug, must-fix]** Most likely root cause: `<img>` loads against a 404. `AttachmentStorage.storage_root` defaults to `System.tmp_dir!()/platform-chat-uploads` (`attachment_storage.ex:116-121`). Container restart without a persistent volume mount → `File.exists?(path)` false → 404 → broken `<img>` → grey background. Matches "upload succeeds, render is grey" exactly (DB row persists, file does not).
2. **[bug, should-fix]** `content_type` is often empty or `application/octet-stream` on mobile uploads. iOS Safari's share-sheet and pasted blobs drop the `type` field; `drag_drop_upload.js:82-84` compensates for paste but the file-picker path doesn't. `MIME.from_path(filename)` fallback requires an extension.
3. **[friction]** No `onerror` handler on `<img>` — broken image shows grey card silently instead of an explicit "image unavailable" affordance.
4. **[friction]** No alt text beyond filename; no lightbox loading state; no blur-up preview.
5. **[friction]** `.image-gallery` fixed `max-width: 400-620px` with `aspect-ratio: 16/10` crops portrait phone photos awkwardly on narrow viewports.

**Tasks:**
- [must-fix] `onerror` handler: swap to "Image unavailable · {filename}" affordance + download-original link. ~15 LOC.
- [must-fix] Content-type sniffing: when `content_type` is `application/octet-stream` / empty AND filename has no ext, inspect first bytes (PNG `89 50 4E 47`, JPEG `FF D8 FF`) during `persist_upload`. Store corrected type. ~30 LOC.
- [must-fix, ops] **Verify deployment has a persistent volume mounted at `AttachmentStorage.storage_root`.** If not, this bug is a timebomb — every restart wipes historical attachments. (Not a code fix; flag to Rowan for infra.)
- [should-fix] Skeleton loading class on `<img>` (animated gradient, removed on `onload`). ~10 LOC.
- [should-fix] Responsive `aspect-ratio: auto` + `max-height: 60vh` at `<640px`. ~5 LOC.
- [nice-to-have] Replace basic lightbox with pan/zoom/swipe-dismiss component.
- [nice-to-have] Generate 300px thumbnail on upload (Mogrify) + `srcset` for mobile.

### Hotspot #2 — Canvas document transition: cleanup, not refactor

**Current state:** Transition is ~90% done. Legacy columns dropped; unified around `CanvasDocument`. Only three visual branches (removed / valid / invalid) remain in the renderer, not three semantic pipelines.

**Findings:**
1. **[friction]** Two write paths don't share scaffolding. `Chat.create_canvas_with_message/3` (`chat.ex:1270`) uses `Canvas.changeset + Repo.insert` directly; `Canvas.Server.apply_patches/3` uses `CanvasPatch.apply_many` with rebase-or-reject. Creation never goes through the server. Gotcha for anyone adding create-time patch bundles.
2. **[bug, should-fix]** `ToolHandlers.create/2` accepts `"document"` OR `"initial_state"` (`tool_handlers.ex:21`). `"initial_state"` is undocumented legacy alias — soft schema drift.
3. **[opportunity]** `render_invalid/1` silently swallows validation errors into a one-line UI message. No telemetry. Invalid docs from a buggy agent are only visible to end-users.
4. **[friction]** Message-to-canvas link has two redundant columns: `chat_messages.canvas_id` (canonical FK) AND `structured_content: %{"canvas_id", "title"}` (shadow stamp). `CanvasHooks.message_canvas_title/2` still reads the shadow map as fallback.

**Tasks:**
- [should-fix] Remove `initial_state` alias or add to JSON Schema. ~10 LOC.
- [should-fix] Remove `structured_content.canvas_id/title` stamping; rewrite `message_canvas_title` to join via `canvas_id` FK. ~30 LOC, 2 files.
- [nice-to-have] Telemetry emit on invalid-document render (parallel `canvas_patched`). ~10 LOC.

**Cross-cutting pattern:** In-memory (`GenServer`) and on-disk (Ecto) canvas documents share one shape — good architectural choice, template for Tasks/Meetings if they ever gain rebase-or-reject concurrency.

### Hotspot #3 — ChatLive modularization: make implicit contracts explicit

**Current state:** Hook decomposition is complete. 9 hook modules attach cleanly. What remains in `ChatLive` (684 LOC) is genuine cross-hook coordinator logic, not leftover feature code.

**Findings:**
1. **[opportunity]** Attach order matters silently. Phoenix invokes hooks in reverse attachment order (last attached = first invoked). No collisions today but `CanvasHooks.handle_event("canvas_open_mobile", …)` and `ChatLive.handle_event("canvas_open", …)` are easy to mis-name.
2. **[friction]** Cross-hook assign dependencies are implicit. `MentionsHooks` at `mentions_hooks.ex:64` reads `participants_map` owned by `PresenceHooks` — undocumented contract.
3. **[bug risk]** Events double-handle param shapes. `PinHooks.handle_event("pin_toggle", …)` at `pin_hooks.ex:64,68` has two clauses — `"message_id"` and `"message-id"`. Same in `MessagesHooks.toggle_inline_thread`. Template vs JS-hook casing divergence.
4. **[opportunity]** `handle_params` at `chat_live.ex:113-175` does 13 things. Extracting a `ChatLive.Coordinator` of pure helpers would make it testable without a full socket.
5. **[friction]** `handle_info(_msg, socket)` catch-all at `chat_live.ex:479` is silent — if a hook accidentally `{:halt, socket}` where it meant `{:cont}`, the parent is skipped silently.
6. **[inconsistency]** `MessagesHooks` owns unprefixed events (`send_message`, `open_thread`, `react`, `open_reaction_picker`, `open_longpress_menu`). A future hook wanting its own `open_thread` would silently steal the event.

**Tasks:**
- [must-fix] Document the attach-order + `@read_from` invariants as moduledoc. ~15 LOC.
- [should-fix] Standardise param casing (`message-id` in HEEx, `message_id` in JS hook push); remove tolerant clauses. ~40 LOC, 6 files.
- [should-fix] Namespace `MessagesHooks` events (`message_send`, `thread_open`, `reaction_react`, etc.). ~60 LOC, affects template + JS hooks.
- [nice-to-have] Extract `ChatLive.Coordinator` for pure helpers. ~80 LOC.
- [nice-to-have] Dev-only `Logger.debug` on unmatched info/event. ~8 LOC.

**Cross-cutting pattern:** Remaining modularization work is **making hook contracts explicit** (attach order, cross-reads, event namespace) rather than moving more code.

### Hotspot #4 — Meeting UI: naming + docs remain

**Current state:** The dead code flagged by ADR 0035 is gone. `MeetingHooks` documents the cleanup. `meeting_client.js` treats `RoomEvent.Disconnected` as terminal — no reconnect loop.

**Findings:**
1. **[inconsistency]** `@meeting_active` migrated to `ShellLive` (not deleted). `shell_live.ex:65,110,122,139` has four branches. Name collides with `MeetingHooks.in_meeting` — two near-synonyms for different concerns.
2. **[bug]** Race between `MeetingHooks.on_terminate/1` and `ShellLive`'s `:meeting_bar_leave`. Tab close: both LV procs terminate; broadcast arrives nowhere. Not severe (LiveKit ends when WebRTC drops) but mini-bar hangs on other tabs until heartbeat.
3. **[friction]** `MeetingBarLive.handle_event("leave_meeting", …)` sends `self() → :meeting_bar_leave`. Works but under-documented — self is parent LV pid.
4. **[opportunity]** Three-surface state machine (chat LV, shell LV, meeting_bar LC) isn't diagrammed.
5. **[bug risk]** `on_terminate/1` reads `socket.assigns[:user_id]` with no fallback — tab close mid-mount before user_id assigned silently skips.

**Tasks:**
- [should-fix] Rename `ShellLive.assigns.meeting_active` → `:mini_bar_visible`. ~30 LOC, 4 files.
- [should-fix] Rename `:meeting_bar_leave` info → `{:meeting_bar_leave_requested, user_id}`. ~6 LOC.
- [nice-to-have] Sequence diagram in `docs/adrs/0030-meetings-on-livekit.md`.
- [nice-to-have] Mid-transition crash tests. ~100 LOC.

### Hotspot #5 — Mobile reactions UX polish

**Current state:** Four surfaces: inline pills (`chat_live.html.heex:773-800`), desktop "+" (line 794, hover-only opacity), quick-react pill via `LongpressMenu` double-tap (lines 1273-1318), full 32-emoji picker (lines 1214-1258).

**Findings:**
1. **[bug, must-fix]** `opacity-0 group-hover:opacity-100` on "+" button — invisible on mobile. No persistent path to the full picker except double-tap gesture.
2. **[bug, must-fix]** Reaction pills `px-2 py-0.5 text-xs` ≈ 22-26px tall — below 44pt iOS / 48dp Android minimums. Mis-tap hazard.
3. **[friction]** Quick-react floating pill buttons 40×40 — still under 44pt.
4. **[friction]** Picker popover fixed `grid-cols-8 w-80` on all viewports. At 320px: ~30px cells.
5. **[friction]** Reaction row `flex flex-wrap` — 8+ reactions wrap onto 2-3 lines, pushing metadata off-screen. No max-rows + "+N" affordance.
6. **[friction]** Only 32 curated emojis. No search, skin tones, recents.
7. **[opportunity]** Picker has `role="dialog"` but no focus trap or Esc handler.

**Tasks:**
- [must-fix] Touch-friendly pills: `min-h-[32px] min-w-[44px] px-2.5 py-1.5 text-sm` at `<lg`, compact on desktop.
- [must-fix] Always-visible "+" pill on mobile. Dashed border for visual distinction.
- [should-fix] Picker grid `grid-cols-6 sm:grid-cols-8`, cells `size-11` (44px), modal `w-[min(20rem,calc(100vw-2rem))]`.
- [should-fix] Cap row at 2 lines on mobile + "+N" pill → full reactor list.
- [should-fix] Esc handler + focus trap on picker + longpress pill.
- [should-fix] Raise quick-react pill buttons to 44×44, reduce gap to 4px.
- [nice-to-have] Replace curated emoji list with `emoji-picker-element` web component.
- [nice-to-have] `aria-live="polite"` announcement on reaction add/remove.

### Hotspot #6 — Search

**Current state:** `Chat.search_messages/3` at `chat.ex:759-800` uses `websearch_to_tsquery` on `search_vector` with `ts_rank_cd` ordering and `ts_headline` for highlighted excerpts. Hook at `search_hooks.ex`. UI in topbar (`chat_live.html.heex:250-276`) and results panel (`:367-428`). Also exposed to agents via `space_search_messages` MCP tool (`tool_surface.ex:399`).

**Findings:**
1. **[bug, must-fix]** Search box is hidden on mobile. Line 255: `class="hidden md:block"`. Mobile PWA users cannot search at all.
2. **[friction]** Hard 12-result limit, no pagination.
3. **[friction]** No cross-space / global search.
4. **[friction]** `maybe_refresh` re-runs full query on every message-list PubSub event (new message, reaction, etc. in an active space).
5. **[friction]** English analyzer hardcoded (`websearch_to_tsquery('english', …)`).
6. **[opportunity]** `ts_rank_cd` rank leaked into UI as "rank 0.037" — dev detail in production.
7. **[opportunity]** No `Cmd/Ctrl+K` shortcut to focus search.
8. **[opportunity, must-fix]** No tests for `Chat.search_messages/3` — the most SQL-complex function with zero coverage.
9. **[opportunity]** Bare zero-result UX — no suggestions, no broader-scope hint.
10. **[inconsistency]** `search_open_result` handler still in parent LV, not SearchHooks (ADR 0035 migration pending).

**Tasks:**
- [must-fix] Mobile search affordance — magnifying-glass icon opening full-width search overlay (Slack mobile pattern). ~45min / ~60 LOC.
- [must-fix] `Chat.search_messages/3` tests — empty query, rank order, headline `<mark>` contents, scope boundary, soft-delete exclusion. ~30 LOC.
- [should-fix] "Load more" pagination (initial 20, +20 per load). ~45 LOC.
- [should-fix] Better zero-result state (spelling hint, cross-space link once that lands). ~20 LOC.
- [nice-to-have] `Cmd/Ctrl+K` focus shortcut. ~15 LOC JS hook.
- [nice-to-have] Remove rank-float UI display. 1 line.
- [nice-to-have] Global (cross-space) search. Own PR, ~2-3hr.
- [nice-to-have] Move `search_open_result` into SearchHooks.

### Hotspot #7 — Push notifications

**Current state:** `Platform.Push` + `push_subscribe.js` implement Web Push with VAPID. Opt-in banner at top of `ChatLive` (`partials.ex:26-45`). Push fires via `AttentionRouter.maybe_send_push/3` when attention routes and user is offline. Payload: `{title: "{sender} in Suite", body: content[0..200], url: "/chat"}`.

**Findings:**
1. **[friction]** Opt-in banner nags on every page load until dismissed by browser "Enable." No contextual onboarding.
2. **[friction, must-fix]** Tap URL hardcoded `/chat`. Should deep-link to `/chat/{space_slug}#{message_id}`.
3. **[bug, must-fix]** No notification preferences UI. `Participant.attention_mode` exists (`"mention" | "active" | "all" | "heartbeat"`) but no user-facing control.
4. **[friction]** No per-space mute.
5. **[friction]** Body = first 200 chars of raw markdown + `@[Alice]` wire format. Raw syntax in notifications.
6. **[friction]** No distinct mention title — "you were mentioned" and "new activity in channel" look identical.
7. **[friction]** No in-app aggregate unread badge. `navigator.setAppBadge()` supported on iOS 16.4+ PWA + desktop.
8. **[bug]** Service worker `fetch` handler intercepts every same-origin GET with no caching benefit (`STATIC_ASSETS = ["/"]`). Adds latency; caches 4xx/5xx when offline.
9. **[friction]** iOS detection always shows manual "Enable" on Safari — no distinction between installed PWA (supports Web Push) vs Safari tab (doesn't).

**Tasks:**
- [must-fix] Deep-link notifications: `url: "/chat/#{space.slug || space.id}##{message.id}"`; `sw.js notificationclick` focuses or opens. ~30 LOC across Elixir + JS.
- [must-fix] Notification preferences panel — global attention_mode dropdown, per-space mute, push on/off toggle. Add `muted_space_ids` to User. ~200 LOC, own PR.
- [should-fix] Strip markdown + resolve mentions in push body. `ContentRenderer.plain_preview/1`. ~20 LOC.
- [should-fix] Distinct mention title. ~15 LOC.
- [should-fix] Contextual opt-in (surface after first mention/DM received). ~30 LOC.
- [should-fix] App badge via `navigator.setAppBadge`. ~15 LOC.
- [nice-to-have] Fix SW: remove blanket fetch handler OR stale-while-revalidate with response-ok gating.
- [nice-to-have] "Test notification" button in preferences.

**Cross-cutting pattern:** Three unread signals (sidebar badge, push, attention) don't share state or preferences. Argues for a single `Platform.Notifications` context.

### Hotspot #8 — Mobile responsive behavior

**Current state:** Viewport meta at `layouts/root.html.heex:5-8` has `viewport-fit=cover` (good) and `maximum-scale=1` (intentional per Rowan — native-app feel; see finding #1 below). Safe-area top/bottom only. Mobile drawer via `@mobile_browser_open`. Canvas/meeting panels have `lg:hidden` overlays. Composer, reactions, tasks kanban, admin screens are desktop-first.

**Findings:**
1. **[product-choice, NOT a bug]** `maximum-scale=1` in viewport meta is **intentional** per Rowan — Suite operates as an installed PWA targeting native-app feel, and native chat apps (Slack, Discord, iMessage) don't allow arbitrary pinch-zoom either. The abstract WCAG 2.1 SC 1.4.4 concern is satisfied via OS-level Dynamic Type / Android font scale, not via pinch-zoom. **Verify** (separate investigation): that Suite's PWA respects `env(font-size)` / iOS Large Text settings. **Do NOT remove `maximum-scale=1`.**
2. **[bug, must-fix]** Composer textarea `font-size: 14px` triggers iOS Safari's zoom-on-focus (Safari auto-zooms any input below 16px on focus). Combined with the locked viewport, the UI becomes "unmoored / stuck zoomed." **Fix at the source: 16px font — no zoom triggers, no unmooring, native-app feel preserved.**
3. **[bug, must-fix]** Composer send 36×36, attach 32×32 — below 44pt.
4. **[friction]** Composer + keyboard: no `interactive-widget=resizes-content` hint. Composer hides behind keyboard on some Android Chrome.
5. **[friction]** `@mention` dropdown fixed `w-64`, anchored bottom-left. Overflows viewport at 320px.
6. **[friction]** Safe area only top/bottom. Landscape iPhone notch left/right — `env(safe-area-inset-left/right)` needed on mobile drawers.
7. **[friction]** Landscape: meeting + canvas overlays expect vertical space; no orientation handling.
8. **[friction]** Tasks sidebar `md:flex` — no mobile equivalent for project switching.
9. **[friction]** Admin screens: dense tables, no responsive fallback.
10. **[opportunity]** No `@media (prefers-reduced-motion: reduce)` despite several animations.

**Tasks:**
- [must-fix] Composer textarea `font-size: 16px` at `<640px`. Fixes iOS zoom-on-focus **at the source** — so `maximum-scale=1` stays locked for native-app feel. ~5 LOC.
- [must-fix] Composer attach/send `min-h-[44px] min-w-[44px]` on touch. ~10 LOC.
- [must-fix] `.safe-area-left/-right` + apply to mobile overlays. ~15 LOC.
- [investigate, separate] Verify PWA respects iOS Large Text / Android font scale (OS-level a11y path, since we're keeping pinch-zoom locked).
- [feature, separate PR] **In-app accessibility settings panel** — font-size picker, contrast toggle, reduced-motion respect. Per Rowan's guidance this is the preferred a11y path over pinch-zoom for a native-feel PWA. Own PR, ~150 LOC (settings UI + user preferences schema + CSS variables driven from user prefs).
- [should-fix] `interactive-widget=resizes-content`. 1 line.
- [should-fix] `@mention` dropdown viewport-aware positioning. ~30 LOC.
- [should-fix] Tasks mobile drawer mirroring `@mobile_browser_open`. ~60 LOC.
- [should-fix] `@media (prefers-reduced-motion: reduce)` block. ~15 LOC.
- [should-fix] Breakpoint audit — standardize Tailwind defaults; `lg` (1024px) alone makes iPad portrait "mobile."
- [nice-to-have] Landscape meeting panel layout.
- [nice-to-have] Admin screens → responsive cards at `<md`.

**Cross-cutting pattern:** Binary mobile/desktop split at `lg`. No tablet layer. No shared mobile-overlay partial (chat, canvas, meeting each reimplement the pattern). Extracting `<.mobile_overlay>` + tablet breakpoints is a 2-day cleanup with outsized polish return.

### Hotspot #9 — Drag-drop accessibility

**Current state:** Two drag-drop hooks, both **native HTML5 DnD** (not Sortable.js as orientation said). `kanban_drag_drop.js` for kanban (`tasks_live.html.heex:133`, cards line 152 `draggable="true"`). `drag_drop_upload.js` for chat file drops (`chat_live.html.heex:173`). Neither has ARIA, keyboard, or touch fallback.

**Findings:**
1. **[bug, must-fix]** Kanban: no keyboard alternative. Keyboard user cannot move tasks — full a11y blocker.
2. **[bug, must-fix]** Kanban: HTML5 DnD does not fire on iOS Safari touch; unreliable on Android Chrome. Effectively desktop-mouse-only.
3. **[bug]** No ARIA announcements. No drop confirmation.
4. **[bug]** Cards have no `role="button"` / explicit label. `<div>` with `phx-click="select_task"` — not tabbable, no a11y name.
5. **[friction]** Drop target highlighting indicates hover only, not accept/reject.
6. **[friction]** Upload drop-zone: visual-only, no keyboard path beyond the paperclip button.
7. **[friction]** Native browser drag ghost inconsistent with `.kanban-dragging` source fade.
8. **[opportunity]** No long-press grab (Notion/Linear pattern).

**Tasks:**
- [must-fix] Keyboard alternative: cards as `<button>` or `role="button" tabindex="0"`. Space/Enter grab-mode, arrows navigate, Space commits, Esc cancels. ~80 LOC JS + template.
- [must-fix] Visible "Move to..." dropdown on each card (3-dot menu). Fallback for keyboard + touch. Fastest shippable fix. ~60 LOC.
- [must-fix] `aria-live="polite"` region; announce "Task '{title}' moved to {column}." ~20 LOC.
- [should-fix] Add `dragdroptouch-polyfill` (4KB) — monkey-patches HTML5 DnD onto touch events. Low-effort touch support.
- [should-fix] Cards wrap in `<button>`, `aria-label={task.title}`, `aria-describedby` column. ~15 LOC.
- [should-fix] Upload drop-zone `aria-label`. 1 line.
- [should-fix] Drop-accepted styling (`border-success` vs `cursor-not-allowed`). ~10 LOC.
- [nice-to-have] Custom drag ghost via `setDragImage`.

**Cross-cutting pattern:** Core interaction patterns (drag, long-press, hover) consistently lack touch + keyboard equivalents. Same gaps in @-mention autocomplete, reaction picker, thread-open.

### Hotspot #10 — Mention resolution: render-time resolver missing

**Current state:** Three surfaces. Compose-time autocomplete from `participants_map` (`MentionsHooks`). Post-time routing via `AttentionRouter.active_participants/1` matching current `display_name`. Render-time `ContentRenderer.decorate_mentions/1` **visually styles only** — no resolution or existence check. `MentionBackfill` is a one-shot migration, not a live resolver.

**Findings:**
1. **[bug]** Renamed participant keeps old `@[Old Name]` in historical messages. Routing works (compares current name); rendered text shows stale.
2. **[bug]** Deleted participant leaves orphan `@[Alice]` styled as if resolving. No existence check. `PresenceHooks.sender_name/2` has the right fallback pattern; `ContentRenderer` doesn't.
3. **[friction]** Three resolution times with three data sources, not documented in one place.
4. **[bug risk]** No minimum-query-length gate in `MentionsHooks`. Empty/one-char returns 8 suggestions via `starts_with?` — O(n) per keystroke on large spaces.
5. **[opportunity]** No caching. Each chat LV rebuilds `participants_map` on every `handle_params`.
6. **[bug]** Legacy-zone substring check at `attention_router.ex:539` treats participant names as prefix — single-char names could match substrings of other mentions.

**Tasks:**
- [should-fix] Render-time resolver: pass `participants_map` into `ContentRenderer.render_message/1`; style unknown-mention differently (greyed, tooltip). ~60 LOC.
- [should-fix] Display_name min length (2 chars) on `Participant.changeset/2`. ~5 LOC.
- [nice-to-have] Consolidate three surfaces into `Platform.Chat.Mentions` moduledoc.
- [nice-to-have] Min-query-length guard + empty-query short-circuit. ~4 LOC.

**Cross-cutting pattern:** Authoritative-current-state vs historical/snapshot fallback is duplicated ad-hoc (`sender_name` has it; `ContentRenderer` doesn't). **Propose: shared `Platform.Chat.Identity` helper with `resolve_name(map, id, fallback_msg)` unifying sender name, mention target, canvas creator.**

### Hotspot #11 — Mobile DM creation: the user-blocker

**Current state:** `+` button opening `NewConversationComponent` is inside `<aside id="chat-sidebar" class="hidden lg:flex">` at `chat_live.html.heex:57-68`. **The mobile drawer at `chat_live.html.heex:101-168` has NO "new conversation" button and NO "new channel" button.** Same for `new_channel_open` at line 22 — desktop-sidebar-only. `NewConversationComponent` itself works fine — it's just unreachable.

**Findings:**
1. **[bug, MUST-FIX]** "New Conversation" affordance **does not exist** in the mobile UI. Marlowe's reported bug. Same root cause as BACKLOG #1.
2. **[bug, MUST-FIX]** Same for channel creation — mobile users collapse everything into `#general`.
3. **[friction]** Even on desktop, `+` buttons are tiny (`size-4` icon, no padding, hover-color-only).
4. **[friction]** Modal mobile layout: `max-h-48` / `max-h-32` scroll areas too small on tall phones. `phx-click-away` tap-outside-to-dismiss aggressive on mobile.
5. **[friction]** No keyboard-accessible Close button (only bottom Cancel; Esc not handled).
6. **[bug]** Zero test coverage. No LiveView or E2E tests exercise this from mobile viewport.

**Tasks:**
- **[MUST-FIX]** Add "New Conversation" and "New Channel" buttons to mobile drawer. Reuses existing `new_conversation_open` / `new_channel_open` events. **~20 LOC heex. Zero backend work. This is the first PR.**
- [must-fix] Closing behaviour: tapping "New Conversation" from mobile drawer also closes the drawer (`JS.push("new_conversation_open") |> JS.push("close_mobile_browser")`).
- [should-fix] Empty-state CTA in mobile drawer ("No conversations yet" → "Start your first conversation").
- [should-fix] Mobile layout for `NewConversationComponent`: `flex-1` scroll areas, viewport-sized modal.
- [should-fix] Esc handler + X button in modal header.
- [must-fix] LiveView test exercising the mobile path (set `@mobile_browser_open = true`, assert button present). ~20 LOC test.

**Would E2E have caught this?** Yes. A Playwright test at `viewport: {width: 375, height: 667}` looking for accessible-named "New Conversation" button would fail immediately. **This bug is the single best argument for adding E2E to the testing scope** — a 20-minute setup catches a user-blocker that made it to production.

**Cross-cutting pattern:** Clearest example of "desktop-first responsive wrapped in `hidden lg:flex`." Features ship with desktop UX complete, mobile alternate is missing or V2'd. **Proposed rule: every primary action must have a reachable trigger at 375px width.** Enforceable via a Playwright smoke suite at 375/768/1280.

---

## Master task list

### Must-fix (blocks users or violates standards)

| # | Task | Hotspot | Est. |
|---|---|---|---|
| 1 | Mobile "New Conversation" + "New Channel" buttons | #11 | ~20 LOC |
| 2 | Composer font-size 16px at `<640px` (iOS zoom-on-focus fix — keeps `maximum-scale=1` locked for native feel) | #8 | ~5 LOC |
| 3 | Composer attach/send `min-h-[44px] min-w-[44px]` on touch | #8 | ~10 LOC |
| 4 | Safe-area left/right on mobile overlays | #8 | ~15 LOC |
| 6 | `<img>` `onerror` fallback for attachments | #1 | ~15 LOC |
| 7 | Content-type sniffing on upload (PNG/JPEG magic bytes) | #1 | ~30 LOC |
| 8 | **Verify persistent volume mount for attachment storage** (ops) | #1 | infra |
| 9 | Mobile search affordance (icon → full-width overlay) | #6 | ~60 LOC |
| 10 | `Chat.search_messages/3` tests | #6 | ~30 LOC |
| 11 | Touch-friendly reaction pills (44pt) | #5 | ~20 LOC |
| 12 | Always-visible "+" reaction button on mobile | #5 | ~10 LOC |
| 13 | Keyboard alternative for kanban ("Move to..." menu) | #9 | ~60 LOC |
| 14 | `aria-live` announcement on kanban drop | #9 | ~20 LOC |
| 15 | Deep-link notifications to `/chat/{space}#{message}` | #7 | ~30 LOC |
| 16 | Notification preferences panel (backend + UI) | #7 | ~200 LOC |
| 17 | Document ChatLive hook attach order + `@read_from` contracts | #3 | ~15 LOC |
| 18 | Mobile DM creation LiveView test | #11 | ~20 LOC |

### Should-fix (quality / friction)

| Task | Hotspot | Est. |
|---|---|---|
| Namespace `MessagesHooks` events | #3 | ~60 LOC |
| Standardize param casing HEEx vs JS hooks | #3 | ~40 LOC |
| Remove `structured_content.canvas_id/title` shadow stamp | #2 | ~30 LOC |
| Remove `initial_state` tool alias | #2 | ~10 LOC |
| Rename `ShellLive.meeting_active` → `mini_bar_visible` | #4 | ~30 LOC |
| Rename `:meeting_bar_leave` info message | #4 | ~6 LOC |
| Search "load more" pagination | #6 | ~45 LOC |
| Better search zero-result UX | #6 | ~20 LOC |
| Reaction picker responsive grid + focus trap | #5 | ~30 LOC |
| Reaction row max 2 lines + "+N" pill | #5 | ~30 LOC |
| Esc handler on picker + longpress pill | #5 | ~10 LOC |
| Quick-react pill buttons to 44×44 | #5 | ~10 LOC |
| Attachment skeleton loading state | #1 | ~10 LOC |
| Responsive attachment `aspect-ratio` | #1 | ~5 LOC |
| `interactive-widget=resizes-content` viewport meta | #8 | 1 line |
| `@mention` dropdown viewport-aware positioning | #8 | ~30 LOC |
| Tasks mobile drawer for project switching | #8 | ~60 LOC |
| `@media (prefers-reduced-motion: reduce)` | #8 | ~15 LOC |
| `dragdroptouch-polyfill` for kanban touch | #9 | ~5 LOC install |
| Kanban cards as `<button>` with a11y | #9 | ~15 LOC |
| Upload drop-zone `aria-label` | #9 | 1 line |
| Drop-accepted styling | #9 | ~10 LOC |
| Render-time mention resolver + unknown styling | #10 | ~60 LOC |
| Display_name min-length validation | #10 | ~5 LOC |
| Strip markdown from push body | #7 | ~20 LOC |
| Distinct mention title in push | #7 | ~15 LOC |
| Contextual opt-in (after first mention/DM) | #7 | ~30 LOC |
| `navigator.setAppBadge` unread aggregate | #7 | ~15 LOC |

### Nice-to-have

(Full list in per-hotspot sections above. 20+ items covering lightbox, thumbnails, emoji-picker-element, global search, mention caching, ChatLive.Coordinator extraction, meeting sequence diagram, landscape handling, admin screens, etc.)

---

## Cross-cutting patterns

1. **Desktop-first responsive, wrapped in `hidden lg:flex`.** Shows up in search, DM creation, channel creation, tasks project switcher, admin screens. Fails invisibly — users don't report missing features they don't know exist. **Proposed rule + enforcement:** every primary action must have a reachable trigger at 375px viewport width, enforced via a Playwright smoke suite at 375/768/1280.

2. **Touch-interaction gaps.** `opacity-0 group-hover:opacity-100` invisible on touch; sub-44pt hit targets everywhere; HTML5 DnD doesn't fire on iOS touch; long-press gestures fight native OS menus. **Proposed:** a single "touch-polish" PR covering hotspots #1/#5/#9 at ~300 LOC.

3. **No shared visual language for empty/loading/broken states.** Attachments fall back to an unstyled grey card; search to a dashed empty card; mentions silently render unknown names as if resolving. **Proposed:** a small design-system utility for "unknown/broken" affordances (icon + copy + optional action).

4. **Authoritative-current vs snapshot-historical name resolution is duplicated ad-hoc.** `PresenceHooks.sender_name` has the pattern (live map → snapshot → fallback); `ContentRenderer` doesn't. **Proposed:** `Platform.Chat.Identity` helper with `resolve_name(map, id, fallback_msg)` used uniformly for sender, mention target, canvas creator.

5. **Hook contracts inside ChatLive are implicit.** Attach order, cross-hook assign reads, event namespace — all currently undocumented and safe only by coincidence. Finishing ADR 0035 modularization means making these explicit, not moving more code.

6. **No E2E tests.** The mobile DM bug is the proof point. LiveView + controller + channel tests verify events fire and queries run, but nothing verifies a user can complete a flow on a real browser at a mobile viewport. **Recommend adding Playwright** with a smoke suite at three viewports as Phase 1.

7. **Notifications, unread badges, and attention signals don't share state.** Three surfaces, three definitions. **Propose:** a `Platform.Notifications` context that owns mute/preference rules and is called by both push sender and sidebar badge renderer.

---

## Recommended PR sequence

Five PRs, sized to ship incrementally:

### PR 1 — `fix(mobile): add new-conversation + new-channel buttons to mobile drawer`
**Unblocks users today.** ~20 LOC heex, zero backend work. Tests: LiveView test exercising the mobile path.
**Hotspot:** #11

### PR 2 — `fix(mobile): composer font-size 16px + 44pt touch targets + safe-area left/right`
**iOS zoom-on-focus fix at the source (keeps `maximum-scale=1` for native-app feel) + hit-target a11y.** ~30 LOC across composer CSS and mobile overlays. Per Rowan's guidance, do **not** remove `maximum-scale=1` — the zoom restriction is intentional product philosophy; the bug is the 14px composer font triggering Safari's auto-zoom, which we fix at the trigger.
**Hotspot:** #8

### PR 3 — `fix(chat): attachment render fallback, content-type sniffing, skeleton loading`
**Fixes the grey-box bug surface.** ~80 LOC + ops check on persistent volume.
**Hotspot:** #1

### PR 4 — `feat(chat): touch-polish reactions (44pt pills, always-visible "+", responsive picker)`
**Mobile reactions polish per BACKLOG #3.** ~300 LOC CSS + heex + ARIA.
**Hotspot:** #5

### PR 5 — `feat(search): mobile search affordance + tests + "load more"`
**Search on mobile, plus the missing tests.** ~150 LOC + 30 LOC tests.
**Hotspot:** #6

Everything else (hotspots #2, #3, #4, #7, #9, #10) remains as task-list items for scheduled PRs. Hotspot #7 (notification preferences) is its own medium PR (~200 LOC) when prioritized. Hotspot #9 (kanban a11y) is worth a dedicated PR after PR 4.

---

## Org context recommendations (per Higgins' framing)

The `ORG_AGENTS.md`, `ORG_IDENTITY.md`, `ORG_MEMORY.md` files are currently sparse/placeholder content. Recommended population for agent+human coordination value:

- **`ORG_AGENTS.md`** — Document the agent roster as a living reference: each agent's purpose, owned surfaces, decision authority, and who operates them (human owner, runtime). Today agents are discovered ad-hoc via `space_list_agents`; a canonical roster doc lowers friction for humans joining new spaces.
- **`ORG_IDENTITY.md`** — Mission + core philosophy is already present but terse. Add: who the user/customer profiles are (e.g. "Marlowe builds Suite daily from a PWA; Rowan owns platform + deploy; external clients use the guest meetings flow"), the North-Star product principles (agents-as-teammates, mobile-first PWA), and non-goals (e.g. "not a Slack replacement for other orgs").
- **`ORG_MEMORY.md`** — Append-only log of architectural decisions and lessons. Seed entries: "2026-04-20: mobile DM creation was broken in prod; root cause was `hidden lg:flex` pattern; rule established — every primary action reachable at 375px." The pattern Marlowe hit today becomes insurance against the same mistake next time.

The files serve best as **context loaded into agent sessions**, not humans-facing docs. Populating them reduces the need to re-explain Suite identity to every new session.

---

## Testing scope recommendation

The audit surfaced one bug (#11 mobile DM) and two near-bugs (#1 attachment storage, #6 search on mobile) that Playwright smoke tests at mobile viewports would have caught before shipping.

**Recommended Phase 1 (after PR 1-5 above land):**
- Playwright harness at three viewports: 375, 768, 1280.
- Smoke suite: sign-in, send message, react, create DM, create channel, search, open thread, upload image, join meeting.
- CI: run on every PR against `main`; block merge on failure.
- Estimated setup: 4-6 hours + ongoing ~15min per new test.

This is outside the scope of the 5-PR plan above — it's a separate initiative, likely owned by whoever next has a bandwidth-rich week.

---

## Raw sub-agent findings

Raw findings from the three workstreams are preserved for traceability:
- `docs/drafts/audit-architect-findings.md` — architect agent on hotspots #2, #3, #4, #10
- `docs/drafts/audit-frontend-design-findings.md` — frontend-design agent on #1, #5, #7, #8, #9, #11
- `docs/drafts/audit-hotspot-6-search.md` — my direct analysis on #6 (Search)
- `docs/drafts/frontend-audit-orientation.md` — orientation brief (now somewhat stale on #2/#4/#10 per corrections above)

These drafts are LOCAL-ONLY (per `docs/drafts/` convention) and not checked in. The synthesized audit in this file is the canonical deliverable.
