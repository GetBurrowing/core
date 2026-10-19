defmodule PlatformWeb.ChatLiveCodeLineRatchetTest do
  @moduledoc """
  Ratchet `chat_live.ex` on CODE lines, not raw lines (task `01a0312e-b8e4`).

  A raw `wc -l` cap on this file would be a cap on *commentary*: on
  `origin/main` `chat_live.ex` is 5,115 newlines of which 2,133 are
  leading-`#` comment lines — 42% of the file. A raw pin makes deleting a
  comment the cheapest way to buy room for code, which is exactly backwards.
  This guard counts code and leaves prose free.

  Stage 1 established the counting rule and derived the pin; stage 2 attached
  the assertions, the self-explaining failure messages and the anti-vacuity
  controls that keep the rule honest.

  ## MEASURED DETONATIONS (2026-08-25, branch `task/01a0312e-b8e4…`)

  Every assertion below was detonated against a deliberately broken tree and
  the firing assertion recorded verbatim. A guard that has never been observed
  to fail is a comment. Each probe was applied alone and reverted with
  `git checkout --` before the next; the pin was 2,346 throughout.

  | injected defect | assertion that fired |
  | --- | --- |
  | one line of real code (`_ratchet_probe = :probe`) added inside `anchor_highlight_ms/0` in `chat_live.ex` | THE PIN: `assert measured == @chat_live_code_line_count` — "CHAT_LIVE CODE-LINE RATCHET TRIPPED. measured: 2347 / pinned: 2346 / delta: +1" |
  | one `#` comment line added at the SAME site | *none — stayed green (1 test, 0 failures)*. This is the probe that proves the rule pins CODE, not lines. |
  | one line of prose added inside the `@doc` heredoc on `handle_embedded_mount` (`chat_live.ex:75`) | *none — stayed green (1 test, 0 failures)*. This is the observation rule 3 buys: doc prose is free. |
  | body of `code_line_count/1` replaced with `line_count/1` (the degradation a future simplifier performs) | DISCRIMINATOR 1, not the pin: `assert code_line_count(@chat_live_path) < line_count(@chat_live_path)` — "THE COUNTING RULE HAS STOPPED DISCRIMINATING. code_line_count/1 returned 5115 and the raw line count is 5115." |
  | 140 leading-`#` comment lines deleted from `chat_live.ex`, counting rule untouched | DISCRIMINATOR 2, alone: `assert comment_line_count(@chat_live_path) > 2_000` — "THE THING THIS GUARD PROTECTS HAS MOSTLY VANISHED. `chat_live.ex` now holds only 1993 comment lines". |
  | ALL 2,133 comment lines deleted at once | the CHARACTER floor absorbed it first: `assert String.length(source) > 100_000` — "read back only 95778 characters". Recorded because it is a real ordering fact: a wholesale comment deletion is reported as a truncated read, not as the deletion it is. The narrower 140-line probe above is what isolates discriminator 2. |

  The two discriminating assertions were therefore killed INDEPENDENTLY:
  degrading the rule fires only the first, deleting comments fires only the
  second. Neither is decorative, and neither subsumes the other.

  ## REDUCTION CONSIDERED AND DECLINED (2026-08-25, stage 4)

  Stage 4 was asked to measure whether `do_mount/3` could be reduced by
  extracting its assign-seeding into named helpers, and to extract only if the
  case was provable. It was measured, and the extraction was DECLINED. The
  numbers, so the next reader does not re-run the analysis:

  MEASURED at `chat_live.ex:264..751` (the whole of `do_mount/3`, `defp` head
  through its closing `end`), by the same rule this module pins:

      488  total lines
      - 17  blank
      -305  leading-`#` comment lines
      =166  code lines

  Two thirds of `do_mount/3` — 305 of 488 lines, 62.5% — is prose. There are
  **64** `assign/3` calls in the body and **zero** `assign_new/3`; the ticket's
  figure of 65 is one high. They span `chat_live.ex:346..734`, a region of 389
  lines that is 258 comment / 6 blank / 125 code.

  WHY THE EXTRACTION WAS DECLINED. Three findings, any one of which is
  sufficient:

    1. **There are no independently-named seeding groups to extract.** Lines
       344..636 are ONE expression: a single `socket = socket |> ... |> ...`
       pipeline. The 64 assigns fall into 7 runs of code-adjacent `assign/3`
       calls (4, 16, 2, 4, 11, 21 and 6 calls), but the runs are separated only
       by other stages of the SAME pipeline — `SpaceTopics.ensure_holders/1`,
       multi-line `assign/3` calls, `assign_active_space/2`, two
       `allow_upload/3` calls. They are pipeline segments, not groups.

    2. **Extraction would RAISE the number this module pins, not lower it.**
       Each `|> assign(:k, v)` is one code line wherever it lives. Lifting a
       run into `defp seed_x(socket)` removes nothing and adds three code
       lines — the `defp` head, its closing `end`, and the `|> seed_x()` call
       site that replaces the run. Across the 7 runs that is +21 code lines
       minimum, before any argument threading. `do_mount/3` would read shorter;
       `chat_live.ex` would be longer. The pin is file-wide, so the refactor
       sold as a reduction is measurably an increase.

    3. **Comments would be separated from the branches they document.** The
       assign region is 66% prose, and that prose is attached line-by-line to
       individual assigns: 25 of the comment lines inside the candidate runs
       name a condition, a resting value, a gate or a scope
       (e.g. `@sidebar_edit` / `@sidebar_menu_open` mutual exclusion and its
       `@root_admin?` gate at `chat_live.ex:511..524`; the drawer-query note at
       `chat_live.ex:568..573` explaining that the underlying assigns stay
       UNFILTERED because the desktop rail reads the same data). Moving the
       code without moving each of those, or moving them into a helper where
       they no longer sit beside the surface they constrain, is the
       described-bug failure this file exists to avoid.

  Criterion 2 of the stage brief (behaviour preservation around
  `Platform.Chat.ExternalScope.for_user/1`) was never reached: the single call
  is at `chat_live.ex:298`, inside the embedded short-circuit
  (`if embedded?, do: nil, else: ...`) at `chat_live.ex:296..300`, which sits
  48 lines ABOVE the first assign and outside every candidate run. No proposed
  extraction touched it.

  Baseline recorded green before and after (no `lib/` change was made):
  `chat_live_external_rail_test.exs`, `chat_live_external_host_mount_test.exs`,
  `chat_live_canvas_scope_leak_test.exs`, `chat_live_test.exs` and this file —
  163 tests, 0 failures.

  THE PIN IS UNCHANGED at 2,346. Landing this guard with the count pinned where
  it is today is the complete delivery; the reduction was the optional half and
  the measurement says not to do it.
  """

  use ExUnit.Case, async: true

  # `apps/platform` — this file lives at `test/platform_web/live/`.
  @app_root Path.expand("../../..", __DIR__)
  @chat_live_path Path.join(@app_root, "lib/platform_web/live/chat_live.ex")
  @render_helpers_path Path.join(@app_root, "lib/platform_web/live/chat/render_helpers.ex")
  @external_rail_path Path.join(@app_root, "lib/platform_web/live/chat/partials/external_rail.ex")
  @rail_path Path.join(@app_root, "lib/platform_web/live/chat/partials/rail.ex")
  @mobile_browser_path Path.join(
                         @app_root,
                         "lib/platform_web/live/chat/partials/mobile_browser.ex"
                       )
  @conversation_path Path.join(
                       @app_root,
                       "lib/platform_web/live/chat/partials/conversation.ex"
                     )
  @composer_path Path.join(@app_root, "lib/platform_web/live/chat/partials/composer.ex")
  @overlays_path Path.join(@app_root, "lib/platform_web/live/chat/partials/overlays.ex")

  # Every file the chat surface's load-bearing explanation is allowed to live
  # in. The comment FLOOR below sums over this list so an extraction cannot
  # look like a deletion, and a deletion cannot hide behind an extraction.
  @explained_paths [
    @chat_live_path,
    @render_helpers_path,
    @external_rail_path,
    @rail_path,
    @mobile_browser_path,
    @conversation_path,
    @composer_path,
    @overlays_path
  ]

  # MEASURED on `origin/main` @ f1311a42, 2026-08-25, by `code_line_count/1`
  # below. The arithmetic, so a reader can check it rather than trust it:
  #
  #     5,115  total lines (`wc -l`, i.e. newline count)
  #     -  521  blank / whitespace-only         (rule 1)
  #     -2,133  leading-`#` comment lines       (rule 2)
  #     =2,461  code lines under a `#`-only rule
  #     -  115  @doc/@moduledoc heredoc lines   (rule 3)
  #     =2,346  <- the pin
  #
  # On the rule-3 subtraction: the file has 18 `"""` delimiters and 141 lines
  # that sit inside (or delimit) an `@doc`/`@moduledoc` heredoc. 23 of those
  # are blank and 3 are `#`-prefixed, so rules 1 and 2 had already removed
  # them; rule 3 removes the remaining **115**. 2,461 - 115 = 2,346.
  #
  # WHY RULE 3 EXISTS. It is the one addition beyond the ticket's own
  # arithmetic. Doc heredoc bodies are prose, and under a `#`-only rule that
  # prose counts as CODE — so writing a `@doc` would raise the pinned number
  # and documenting this module would cost budget. That is the same pressure
  # the ticket exists to remove, only narrower, so the rule excludes it.
  #
  # NOT generalised to all heredocs, deliberately: a non-doc heredoc (a query
  # string, a message body, a prompt template) is code, and hiding code inside
  # `"""` must not buy budget.
  #
  # REJECTED: adding `chat_live.ex` to `scripts/surface-budgets.txt`. That
  # file is a RAW `wc -l` cap enforced by the "Check surface line budgets" CI
  # step. Listing chat_live there would re-create comment-deletion pressure
  # through the CI door this test closes — the two guards would pull in
  # opposite directions. The pin lives here and only here.
  # RE-MEASURED on `task/01a0312e-3f44-7dc5-8b90-52658cd04228` (base
  # `origin/main` @ efe28d06), 2026-08-26, after task 01a0312e stage 1 moved
  # sixteen template-only `defp` helpers (plus their private dependencies
  # `mask_space_name/2`, `movable_channel?/1`, `drawer_match?/2`,
  # `pinned_task_actions_target/3`, `blank?/1`) into
  # `PlatformWeb.ChatLive.RenderHelpers`. The pin DROPS, which is the guard
  # working: it fires on any delta, and this stage removes code.
  #
  #     4,776  total lines (`wc -l`)
  #     -  482  blank / whitespace-only         (rule 1)
  #     -1,988  leading-`#` comment lines       (rule 2)
  #     -  115  @doc/@moduledoc heredoc lines   (rule 3)
  #     =2,191  <- the new pin
  #
  # Reconciling against the old pin: 2,346 - 2,191 = 156 code lines left the
  # file and 1 arrived (`import PlatformWeb.ChatLive.RenderHelpers`), so the
  # net is -155. `render_helpers.ex` measures 160 code lines by the same rule:
  # the 156 moved bodies plus its own `defmodule` / `import` / `alias` / `end`.
  # No helper body was rewritten and no comment was dropped to reach this
  # number — the reduction is entirely relocation.
  # RE-MEASURED again on the same branch, 2026-08-26, after task 01a0312e
  # stage 2 moved the external rail and its mobile switcher out of
  # `chat_live.html.heex` into `PlatformWeb.ChatLive.Partials.ExternalRail`.
  # That stage removes ~290 lines of MARKUP, which this pin does not count —
  # it measures `chat_live.ex` only. The single code line it adds there is
  # `import PlatformWeb.ChatLive.Partials.ExternalRail`, so:
  #
  #     2,191  stage 1 pin
  #     +    1  the new import
  #     =2,192  <- the pin
  #
  # `partials/external_rail.ex` is in `@explained_paths` above, so the comment
  # prose that travelled with the markup still counts toward the floor rather
  # than leaving the guard's sight.
  # RE-MEASURED again on the same branch, 2026-08-26, after task 01a0312e
  # stage 3 moved `<aside id="chat-sidebar">` — the whole internal desktop
  # channel rail, ~1,348 lines of markup — out of `chat_live.html.heex` into
  # `PlatformWeb.ChatLive.Partials.Rail`. Same shape as stage 2: the markup
  # this pin does not count leaves a `.heex`, and the single code line it adds
  # to `chat_live.ex` is the new `import`:
  #
  #     2,192  stage 2 pin
  #     +    1  `import PlatformWeb.ChatLive.Partials.Rail`
  #     =2,193  <- the pin
  #
  # `partials/rail.ex` is registered in `@explained_paths` above. Stated
  # plainly because the number does NOT move and a reader will expect it to:
  # `comment_line_count/1` counts LEADING-`#` lines, and the prose that
  # travelled with this markup is `<%!-- --%>` HEEx comments plus `@moduledoc`
  # / `@doc` heredocs — none of which the floor counts. `chat_live.ex` still
  # measures 1,988. The registration is prophylactic: it earns its keep the
  # first time a slice carries real `#` comments out of one of these files.
  #
  # It is worth naming the blind spot rather than leaving it implied. For a
  # task whose entire purpose is relocating markup and its explanation out of
  # a `.heex`, THE COMMENT FLOOR CANNOT SEE THE THING MOST AT RISK. It guards
  # `#` comments in `.ex` files; the ~700 lines of `<%!-- --%>` design
  # rationale that moved in stages 2 and 3 are outside its reach entirely.
  # Nothing here is a reason to lower the floor — it is a reason not to read a
  # green ratchet as proof the prose survived. The proof that it survived in
  # stage 3 is the diff: the move was byte-identical.
  # RE-MEASURED again on the same branch, 2026-08-26, after task 01a0312e
  # stage 4 moved `<div id="mobile-channel-browser">` — the mobile channel
  # browser drawer, ~917 lines of markup — out of `chat_live.html.heex` into
  # `PlatformWeb.ChatLive.Partials.MobileBrowser`. Same shape as stages 2 and
  # 3: the markup this pin does not count leaves a `.heex`, and the single
  # code line it adds to `chat_live.ex` is the new `import`:
  #
  #     2,193  stage 3 pin
  #     +    1  `import PlatformWeb.ChatLive.Partials.MobileBrowser`
  #     =2,194  <- the pin
  #
  # `partials/mobile_browser.ex` is registered in `@explained_paths` above,
  # and the comment floor does NOT move for the same reason stage 3 recorded:
  # the prose that travelled with this drawer is `<%!-- --%>` HEEx comments
  # and `@moduledoc` / `@doc` heredocs, and `comment_line_count/1` counts
  # leading-`#` lines only. That is expected, not a miss. The proof this move
  # preserved the drawer is again the diff, not this pin: 19 fixture states
  # rendered before and after, with a byte-identical tag-and-attribute
  # surface (2,720 elements) in every one.
  # RE-MEASURED again on the same branch, 2026-08-26, after task 01a0312e
  # stage 5 moved the top half of the conversation pane — the space
  # `<header>`, the mobile Pinned strip, the mobile channel-pills strip and
  # the search / pins / canvases drawers, ~720 lines of markup — out of
  # `chat_live.html.heex` into `PlatformWeb.ChatLive.Partials.Conversation`.
  # Unlike stages 2-4 the pin DROPS, and the arithmetic is worth stating
  # because "an extraction that lowers the code count" is exactly the shape
  # this guard exists to catch:
  #
  #     2,194  stage 4 pin
  #     +    1  `import PlatformWeb.ChatLive.Partials.Conversation`
  #     -    1  `import PlatformWeb.Components.ChatHelpers` (now unused)
  #     -    1  `import PlatformWeb.Components.ScopePill` (now unused)
  #     =2,193  <- the pin
  #
  # The two removed imports are not a deletion of behaviour: `present?/1`,
  # `local_time/1` (dropped from the `ChatMessage` import list, which is why
  # that line is edited rather than removed) and `scope_pill/1` were called
  # ONLY from the markup that moved. They are imported by
  # `partials/conversation.ex` now. Leaving them behind would have compiled
  # with three `unused import` warnings.
  #
  # `partials/conversation.ex` is registered in `@explained_paths` above. The
  # comment FLOOR does not move, for the third stage running and for the same
  # reason: `comment_line_count/1` counts leading-`#` lines, and everything
  # that travelled here is `<%!-- --%>` HEEx prose plus `@moduledoc` / `@doc`
  # heredocs. Expected, not a miss. The proof this move preserved the header
  # is the render diff, not this pin — and specifically that BOTH breakpoint
  # branches of the space title still mask (task 01a00c66's bug shape), which
  # no line count can see.
  # Stage 7 (task 01a0312e) — `partials/overlays.ex`. The template's overlay
  # layer (reaction picker, long-press pill, edit-removal warning, the
  # message-actions `<.sheet>`, junk-batch modal) moved out of
  # `chat_live.html.heex`. `chat_live.ex` itself gains exactly ONE code line:
  #
  #     2,193  the stage-6 pin
  #     +    1  `import PlatformWeb.ChatLive.Partials.Overlays`
  #     -    1  `alias Phoenix.LiveView.JS` (now unused)
  #     =2,193  <- the pin, unchanged by coincidence, not by construction
  #
  # No IMPORT was removed — `sheet/1` arrives through `use PlatformWeb,
  # :live_view`, not through a line in this module — but the `Phoenix.LiveView.JS`
  # ALIAS went with the markup. The long-press pill's `JS.push(...) |> JS.push(...)`
  # chain was the last caller of the short form in `chat_live.html.heex`; the
  # message-actions sheet spells `Phoenix.LiveView.JS` out in full, so it never
  # needed the alias. Leaving it behind would have compiled with an
  # `unused alias JS` warning. `partials/overlays.ex` carries the alias now.
  #
  # `partials/overlays.ex` is registered in `@explained_paths` above. The
  # comment FLOOR does not move, for the fourth stage running and for the same
  # reason: everything that travelled is `<%!-- --%>` HEEx prose plus
  # `@moduledoc` / `@doc` heredocs, and `comment_line_count/1` counts
  # leading-`#` lines only. Expected, not a miss. The proof this move was pure
  # is the per-overlay OPEN-state render diff, not this pin — no line count can
  # see an overlay that never opened.
  # RE-MEASURED on `task/01a03c76-1e6f-72a6-a060-cfbfc063f643`, rebased onto
  # `origin/main` after task 01a0312e's extraction landed (#810). The
  # jump-to-latest work adds three code lines to `chat_live.ex`, all assigns:
  # two seed `:jump_away_from_bottom` and `:jump_new_message_count` in
  # `mount/3`, one resets the count in `assign_active_space/2` so it does not
  # follow the reader into the next conversation. No logic, no new function,
  # no branch — the two `handle_event/3` clauses that drive these assigns live
  # in `live/chat/messages_hooks.ex`, which this pin deliberately does not
  # cover.
  #
  # The pin is RE-DERIVED from the merged tree, not summed from the two sides:
  #
  #     2,193  the stage-7 pin on `origin/main` after the extraction
  #     +    3  the jump-to-latest assigns
  #     =2,196  <- the pin, confirmed by running `code_line_count/1` on the
  #               merged tree rather than by adding the pre-rebase delta
  #               (2,349) to main's movement.
  #
  # The chip's own markup is a `<%!-- --%>`-commented `<button>` in
  # `chat_live.html.heex`, which this pin does not measure at all.
  # RE-MEASURED for task 01a0419a stage 4 (visibility bands). Three more code
  # lines, all assigns, no logic and no branch:
  #
  #     +1  `mount/3` seeds `:jump_deep_in_history`, the second position
  #         boolean the ScrollToBottom hook now reports.
  #     +2  `assign_active_space/2` resets BOTH position booleans on a
  #         conversation switch. It previously reset only the count, which
  #         was sufficient while visibility was `@jump_away_from_bottom` and
  #         the hook re-reported within ~110ms. It is not sufficient now:
  #         `:jump_deep_in_history` raises the control ON ITS OWN, so a stale
  #         `true` would offer a reader a way back to a tip they are already
  #         at.
  #
  # The rule those assigns feed — `MessagesHooks.jump_chip_visible?/3` — lives
  # in `live/chat/messages_hooks.ex`, which this pin deliberately does not
  # cover, so composing five visibility bands costs `chat_live.ex` nothing.
  #
  # RE-MEASURED for task 01a01d0e (the internal admission gate). Seventeen more
  # code lines, all of them the gate and its two helpers:
  #
  #     +2  `handle_params/3`'s deny condition gains
  #         `implicit_join_denied?(socket, space)`, wrapped over two lines by
  #         the formatter.
  #     +4  `implicit_join_denied?/2` — one clause that defers to the external
  #         gate for external sessions rather than stacking on top of it.
  #     +5  `internal_join_denied?/2` — the kind allowlist head plus the
  #         membership clause.
  #     +5  `space_member?/2` — the participant lookup and its nil-user head.
  #     +1  the `@implicitly_joinable_kinds` attribute.
  #
  # No branch was added to the success path: the gate joins the SAME condition
  # the external gate already occupies, so a denial stays one branch with one
  # outcome and the refusal remains indistinguishable from "did not resolve".
  #
  # RE-MEASURED for task 01a01ccf (`:sidebar_changed` refreshes
  # `@dm_conversations`, so a conversation the viewer is added to mid-session
  # gets a rail row and a live badge). Eight more code lines, net, and the
  # extraction that costs them is what the stage was for:
  #
  #     +14  `rail_dm_conversations/1` plus the three heads of
  #          `dm_conversations_for/3` — the DM/group derivation lifted out
  #          whole, as a third sibling of `rail_channels/1` and
  #          `rail_archived_channels/1`.
  #      -7  `do_mount/3`'s eight-line inline copy collapses to one call.
  #      -1  `handle_params/3`'s two-line copy collapses to one call.
  #      +1  the `:sidebar_changed` handler derives the fresh list.
  #      +2  it assigns that list, ahead of `recompute_pinned/1`, and takes
  #          the local binding the two channel lists above it already use.
  #
  # The handler needed a THIRD copy of one query-and-filter, and the two that
  # existed had already drifted: only `do_mount/3` carried the embedded /
  # nil-user short-circuit. Eight lines is the price of holding that rule in
  # one place, and it is a price this ratchet is designed to let a stage pay —
  # the guard pins growth so growth has to be argued for, and the argument
  # here is a duplication the architecture gate rejects.
  #
  # No branch was added to any hot path. `dm_conversations_for/3`'s two guard
  # heads are the short-circuit `do_mount/3` already applied, moved rather
  # than introduced, and `handle_params/3` reaches them with `embedded` false
  # and `user_id` non-nil in every case (`ChatLive.Embedded` is a nested
  # LiveView, which Phoenix forbids from defining `handle_params/3` at all).
  #
  # ── 2026-09-18, task 01a0b491 stage 4: +42 (2,224 -> 2,266) ────────────────
  #
  # The agents goal surface: three mount assigns, the `goal_panel` /
  # `goal_edit` pair in the `assign_active_space/2` funnel, one
  # `{:role_assignment_changed, ...}` handler, and the three goal-editing
  # events (`edit_goal`, `cancel_goal_edit`, `save_goal`).
  #
  # The derivation lives in `Platform.Chat.Sidebar` — `agents_rail_block/0`,
  # `goal_panel/1` and `agents_leader/1` — and the markup lives in
  # `partials/rail.ex` and `partials/conversation.ex`. What remains in this
  # file is only what has to: assigns, the PubSub handler and the events. The
  # `save_goal` clause is the largest single piece at ~20 lines, and it is a
  # `cond` over three outcomes (refused / no space / written) rather than a
  # write with the gate implied.
  #
  # RE-DERIVED from the guard's own measurement of this tree (2,266), not by
  # adding a remembered delta to a remembered pin.
  #
  # 2,266 -> 2,283 (+17), task 01a0ca8b stage 1: the agents space leaves its
  # org list while the rail block shows it. `resolve_sidebar_sections/4`
  # takes the block (one arg at each call site plus the filter line), mount
  # reads the block once into a local, and `assign_agents_block/2`
  # recomputes the org list at the two sites that re-assign the block.
  # Measured by this file's `code_line_count/1` rule.
  #
  # ── 2026-09-22, task 01a0ca99 stage 1: +7 (2,266 -> 2,273) ────────────────
  #
  # The first-goal scope: a `:goal_invite?` mount default, its recompute in
  # the `assign_active_space/2` funnel, and ONE extra `save_goal` cond clause
  # refusing a blank-goal write unless `Sidebar.first_goal_offered?/1` holds.
  # The predicate itself lives in `Platform.Chat.Sidebar`.
  #
  # RE-DERIVED from the guard's own measurement of this tree (2,273), not by
  # adding a remembered delta to a remembered pin.
  #
  # ── 2026-09-22, task 01a0ca99 merge of origin/main (01a0ca8b, #1055) ─────
  #
  # Both sides started from 2,266. 01a0ca8b pinned 2,283; 01a0ca99 pinned
  # 2,273. The merged tree was RE-MEASURED by this file's `code_line_count/1`
  # rule on the merged chat_live.ex (2,290), not computed as a sum of deltas.
  #
  # ── 2026-09-23, task 01a0cef1 stage 2: +10 (2,290 -> 2,300) ──────────────
  #
  # The goal editor's project select: `:goal_scope_options` and
  # `:goal_scope_error` seeded in mount and reset in `assign_active_space/2`
  # (+4), `edit_goal` assigning the options (+3 after `mix format`), and
  # `save_goal` threading `goal_project_id` into `Sidebar.save_goal/3` with
  # its `:unknown_project` branch (+3). The option list and the write live
  # in `Platform.Chat.Sidebar` / `AgentsGoalHeartbeat`.
  #
  # RE-DERIVED from the guard's own counting rule on this tree (2,300), not by
  # adding a remembered delta to a remembered pin.
  # ── 2026-09-25, task 01a0d8de stage 3: +3 (2,300 -> 2,303) ──────────────
  #
  # The "Context" affordance on agent messages: one `import` of
  # `ChatLive.Partials.MessageContext.message_context_overlay/1`, one `alias`
  # of `ChatLive.MessageContextHooks`, and its `attach()` in the mount
  # pipeline. Every event, info message and assign lives in the hook module,
  # not here.
  #
  # RE-DERIVED from the guard's own measurement on this tree (measured: 2303).
  #
  # ── 2026-09-26, task 01a0db5f stage 4: +2 (2,303 -> 2,305) ──────────────
  #
  # The `game_stream` canvas: one `alias` of Play's live-hooks module and
  # its `attach()` in the mount pipeline, next to `CanvasHooks.attach()`.
  # (Since task 01a0ee08 that module lives in Play's own project and the
  # call is `PlatformWeb.Extensions.attach_live_hooks/1`; ADR 0055.)
  # Every event, info message and assign lives in the hook module, not here.
  #
  # RE-DERIVED from the guard's own measurement on this tree (measured: 2305).
  #
  # ── 2026-09-26, task 01a0938b: +15 (2,305 -> 2,320) ─────────────────────
  #
  # Scope pills for runtime-created orgs. `org_indexes/0` builds the
  # id->name bucket map and a name->org-row map in one `list_orgs/0` pass
  # (replacing `org_bucket_index/0`'s body), with the `bucket_org` type and
  # helper. `org_scope/1` maps a slug to its shipped atom or the stored slug
  # binary (never `String.to_atom`). `space_scope_atom/1` is split into
  # `space_org/1` + `org_scope_of/1` so `assign_active_space/2` can assign
  # `:active_space_org` (name/slug for the header pill) from the same lookup.
  # Offset: the 7-clause `bucket_for_scope/1` closed map is deleted.
  #
  # RE-DERIVED from the guard's own measurement on this tree (CI run
  # 36276668869 at 7aff3118: measured 2320).
  #
  # ── 2026-09-27, task 01a08212 stage 1: +3 (2,320 -> 2,323) ──────────────
  #
  # `channel_sections.name` became a nullable label override, so the move
  # dialog's two section readers (`section_summary/2`,
  # `source_section_name/2`) read `Section.display_name/1` instead of
  # `.name`: one `alias Platform.Chat.Section`, and the second reader's
  # clause no longer fits one line, so the formatter breaks both of that
  # `fn`'s clauses onto two lines each. Pulled forward from stage 2 because a
  # nil name silently dropped the move toast on this stage's tip.
  #
  # RE-DERIVED from the guard's own measurement on this tree (measured: 2323).
  #
  # ── 2026-09-27, task 01a08212 stage 2: -5 (2,323 -> 2,318) ──────────────
  #
  # `rename_section_default` no longer no-ops on a blank name: a blank submit
  # CLEARS the sidebar label so the header follows the org (the admin-edit
  # "Use organisation name" reset sends exactly that). The `cond` that
  # guarded the blank case is gone, leaving the bare `case` on
  # `Sidebar.rename_section/3`. `reassign_destinations/2` reads
  # `Section.display_name/1` in place of `.name` (same line count).
  #
  # RE-DERIVED from the guard's own measurement on this tree (measured: 2318).
  #
  # ── 2026-09-28, task 01a0e882 stages 3-4: +32 (2,318 -> 2,350) ──────────
  #
  # The goal editor's Check progress control. What stays in ChatLive is
  # wiring only: two mount assigns (`:goal_cadence_form`, `:goal_time_zone`,
  # the latter read from connect params, which is legal only in mount), the
  # editor opening on the stored cadence in `edit_goal`, closing it in
  # `cancel_goal_edit` and `assign_active_space`, a preview-only
  # `goal_form_change` handler, and a one-call `maybe_save_goal_cadence/2`
  # after a successful `save_goal` that maps a refusal to a flash. Parsing,
  # comparison, labels, preview and the write itself live in
  # `PlatformWeb.ChatLive.GoalCadenceForm` (moved there in stage 4, from +56).
  #
  # RE-DERIVED from the guard's own measurement on this tree (measured: 2350).
  #
  # Elixir 1.20 upgrade (task 019f5931 stage 1, commit 5aa722491): -2. The
  # 1.20 type checker reported two clauses as unreachable and they were
  # deleted rather than suppressed: the catch-all
  # `section_summary(_sidebar_sections, _section_id)` and
  # `fetch_user_email_for_pins(nil)`. The `if(user_id, ..., else: %{})` around
  # `unread_counts_for_user/1` collapsed to the call itself, one line either
  # way. 2350 - 2 = 2348, re-derived from the guard's own measurement on
  # 1.20.2 (task 019f5931 stage 2).
  #
  # Channel creator admin (task 01a0fd62 stage 1): +5. `bootstrap_space/2`
  # became `bootstrap_space/3` so the navigating user is stamped as the new
  # channel's `created_by`: the user_id threaded through
  # `maybe_bootstrap_space/4` (+1, the one-line clause split across two), the
  # `maybe_put_created_by/2` pipeline step (+1) and its two clauses (+3).
  # 2348 + 5 = 2353, re-derived from the guard's own measurement.
  #
  # Channel members panel (task 01a0fd62 stage 3): +11. The
  # `MembersComponent` alias (+1), the `:show_members` assign (+1), the
  # `"members_open"` handle_event (+3) and the `{:members_closed}` and
  # `{:members_flash, _, _}` handle_info clauses (+3 each), mirroring the
  # settings modal's wiring. 2353 + 11 = 2364, re-derived from the guard's
  # own measurement.
  #
  # Native app share endpoint (task 01a10882 stage 1, pin bumped in stage 2):
  # +2. `@spec max_upload_size()` and `def max_upload_size, do:
  # @max_upload_size`, so `PlatformWeb.AppApiController` enforces the
  # composer's attachment cap instead of a second copy of the number. Stage 1
  # landed the code without the bump; stage 2's full-suite run caught it.
  # 2364 + 2 = 2366, re-derived from the guard's own measurement.
  #
  # Root org from its row (task 01a116de stage 3): +32. The nil-org default
  # bucket became the root row's name (`default_bucket/1`, a third element on
  # `org_indexes/0`, threaded through `bucket_names/2`, `channel_scope/3` and
  # `sub_org_order/0`), the recolor whitelist gained the section's own org
  # token (`valid_scope_token?/3`, `own_scope_token/2`,
  # `section_own_token/1`, `sibling_scope_tokens/0`), and the root's dot
  # reads its row colour through `section_dot_scope/1`. The four compiled
  # "acme" clauses went (-4). 2366 + 32 = 2398, re-derived with the guard's
  # counting rule over the formatted file.
  #
  # Merge of origin/main into 01a116de (deploy stage): main moved the base
  # 2366 -> 2363 (#1209). 2363 + 32 = 2395, re-measured with the guard's
  # counting rule over the merged file.
  #
  # Large file uploads (task 01a120be stage 3): +2. The `LargeUploadHooks`
  # alias and its `attach/1` pipeline step; the feature lives in
  # `PlatformWeb.ChatLive.LargeUploadHooks`, the dialog partial and the
  # composer partial. 2363 + 2 = 2365.
  #
  # Merge of origin/main into 01a120be (deploy stage): main's pin was 2395
  # (01a116de +32 on the 2363 base); this branch adds +2 on that base.
  # 2395 + 2 = 2397, re-measured with the guard's counting rule over the
  # merged file.
  #
  # Prototype hosting (task 01a1316b-4e46 stage 2, commit 32f23bcf4 on
  # stack/prototype-runtime): +50, the New canvas form's Prototype tab
  # (upload wiring and its handle_event clauses) in chat_live.ex. That commit
  # did not move this pin, so the rollup tip failed here; task 01a1316b-677a
  # stage 1 (which does not touch chat_live.ex) records it. Measured by the
  # guard on test_host: 2397 + 50 = 2447.
  # Task 01a1386e-59d1 remediation adds the denied-link landing branch so a
  # restricted deep link stops at /chat instead of opening another channel.
  # Rebasing onto the rollup also brought 21 ChatLive code lines from sibling
  # members. The test-host guard measured 2521 + 21 = 2542 at the merged SHA.
  # RBAC member 6 stage 3 (7efd11c6d): +27 code lines for the shared
  # access-change/sidebar refresh and active-space revocation navigation.
  # The member-6 rebase onto rollup 9c5b4eacc measures 2569 with this
  # guard's code-line rule; the prior sibling-only rollup measured 2542.
  # Ticket 01a14721 stage 1 (the org fence): +9 code lines, 2569 + 9 = 2578.
  # The URL-open gate `internal_read_denied?/2` (4 lines) and its clause in
  # the admission condition (1), the two `ReadScope.within_org_fence/2` pipes
  # on the listed-channel reads (2) and the archived read's fenced scope
  # binding (2). The fence helpers themselves live in
  # `PlatformWeb.ChatLive.ReadScope`, not here.
  # Task 01a14dd9 stage 2 (the compiled scope palette to org rows): +17. Out
  # went `@sibling_scope_tokens` / `sibling_scope_tokens/0`, the five-clause
  # `section_scope_atom/1`, `section_dot_class/1` and `parse_scope/1`, and
  # `org_scope/1`'s atom lookup. In came `section_palette/2`,
  # `section_dot_scope/2`, `section_dot_modifier/2`, `section_scope_entries/2`,
  # `parse_scope/2` over the loaded org index, `org_indexes/1` threading the
  # one `list_orgs/0` read into `channel_sections/5`'s new `scope_orgs` and
  # `scope_palette` keys, and the reassign picker's `scope` lookup.
  # 2582 + 17 = 2599, measured by this guard on the formatted file.
  @chat_live_code_line_count 2599

  @doc """
  Count the CODE lines of a source file.

  The rule, stated precisely enough to reproduce by hand:

    1. drop blank / whitespace-only lines;
    2. drop lines whose first non-whitespace character is `#`;
    3. drop `@moduledoc` / `@doc` heredoc BODIES and their `\"""` delimiters.

  Rule 3 is a line-wise state machine: it enters on a line matching
  `~r/^\\s*@(module)?doc\\s+\"""/` and leaves on the next line whose trimmed
  content is `\"""`. Both delimiter lines are dropped along with the body.
  Rule 3 applies before rules 1 and 2, so a blank or `#` line inside a doc
  heredoc is dropped once, as a doc line.
  """
  def code_line_count(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> drop_trailing_newline_artifact()
    |> strip_doc_heredocs()
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
    |> length()
  end

  # `String.split/2` on a file ending in a newline yields a trailing "" that is
  # not a line. Drop it so the total matches `wc -l`.
  defp drop_trailing_newline_artifact(lines) do
    case List.last(lines) do
      "" -> Enum.drop(lines, -1)
      _ -> lines
    end
  end

  @doc_open ~r/^\s*@(module)?doc\s+"""/

  defp strip_doc_heredocs(lines) do
    {kept, _in_doc?} =
      Enum.reduce(lines, {[], false}, fn line, {kept, in_doc?} ->
        cond do
          in_doc? and String.trim(line) == ~s(""") -> {kept, false}
          in_doc? -> {kept, true}
          Regex.match?(@doc_open, line) -> {kept, true}
          true -> {[line | kept], false}
        end
      end)

    Enum.reverse(kept)
  end

  @doc """
  Total lines of a source file — the raw `wc -l` number.

  Exists only so the guard can assert that `code_line_count/1` returns
  something STRICTLY SMALLER. See the anti-vacuity note on the test.
  """
  def line_count(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> drop_trailing_newline_artifact()
    |> length()
  end

  @doc """
  Count leading-`#` comment lines. Same anti-vacuity purpose as `line_count/1`:
  it proves the thing `code_line_count/1` excludes is large, not incidental.
  """
  def comment_line_count(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> drop_trailing_newline_artifact()
    |> Enum.count(&String.starts_with?(String.trim_leading(&1), "#"))
  end

  describe "chat_live.ex code-line ratchet" do
    # WHY COMMENTS ARE DELIBERATELY EXCLUDED FROM THIS COUNT.
    #
    # `chat_live.ex` is a file whose commentary is load-bearing. The concrete
    # example is the `# SECURITY (task 019f9257):` block inside `do_mount/3`
    # (around `chat_live.ex:274` on this ref): it records why
    # `chat_mode => "external"` may be merged from exactly one place, and the
    # failure it prevents — "EVERY channel across EVERY org leaked". That block
    # is prose that a raw line cap would price. Measured on this ref,
    # `do_mount/3` spans lines 264..751: 488 lines, of which 305 are comment,
    # 17 blank and 166 code. Two thirds of the function is explanation.
    #
    # Under a raw `wc -l` pin the cheapest way to land a five-line change in
    # this file is to delete five lines of that explanation. The guard would be
    # green and the codebase strictly worse. Counting only code removes the
    # trade entirely: prose is free, and the only way to move the number is to
    # write code.
    #
    # TO A FUTURE READER WHO WANTS TO SIMPLIFY THIS: replacing
    # `code_line_count/1` with a raw line count reintroduces exactly the
    # pressure this guard was built to remove. It is not a simplification, it
    # is a reversal. The complexity is the point.
    #
    # The assertion ORDER below is also deliberate, and each block says why.
    test "code lines are pinned; comments are free" do
      source = File.read!(@chat_live_path)

      # (1) THE PIN IS NON-EMPTY. A path that resolved to the wrong file, or a
      # truncated read, would make every assertion below vacuously true — the
      # failure mode called out in `tasks_live_board_invariance_test.exs`.
      # Prove we are looking at the real ChatLive source before measuring it.
      assert source =~ "defmodule PlatformWeb.ChatLive",
             """
             ANTI-VACUITY FAILURE: #{@chat_live_path} does not contain
             `defmodule PlatformWeb.ChatLive`. This guard is measuring the wrong
             file (or no file), so every count below would be meaningless.
             Fix the path in `@chat_live_path`, do NOT relax this assertion.
             """

      assert String.length(source) > 100_000,
             """
             ANTI-VACUITY FAILURE: #{@chat_live_path} read back only
             #{String.length(source)} characters, which is far short of the
             ~238,000 this file holds. That means a truncated or partial read,
             and every count below is measuring a fragment.
             Fix the read, do NOT lower this floor.
             """

      # (2) THE RULE IS DISCRIMINATING. Without this, a `code_line_count/1`
      # that silently degraded into `wc -l` would still satisfy the pin on the
      # day the pin was set, and would then carry raw-line pressure forever
      # under a name that promises otherwise. These two assertions separate
      # "pins code" from "pins lines" statically. Stage 3 proves it dynamically.
      assert code_line_count(@chat_live_path) < line_count(@chat_live_path),
             """
             THE COUNTING RULE HAS STOPPED DISCRIMINATING.
             code_line_count/1 returned #{code_line_count(@chat_live_path)} and the raw
             line count is #{line_count(@chat_live_path)}. A code count equal to the raw
             count means the rule is no longer excluding anything — it has
             degraded into `wc -l`, and this guard is now silently pinning
             COMMENTS as well as code, which is the exact pressure it exists to
             remove. Fix `code_line_count/1` in
             `test/platform_web/live/chat_live_code_line_ratchet_test.exs`.
             Do NOT delete this assertion to make the suite green.
             """

      # The floor is a SUM over both files, not a floor on `chat_live.ex`
      # alone (amended task 01a0312e stage 1). Stage 1 moved sixteen
      # template-only helpers into `ChatLive.RenderHelpers` and their comments
      # went with them, which dropped `chat_live.ex` from 2,133 comment lines
      # to 1,988 and fired this assertion — correctly, since a floor on one
      # file cannot tell a deletion from a move.
      #
      # Summing keeps the threshold at 2,000 rather than lowering it, so the
      # guard is not weakened to accommodate the move: the explanation still
      # has to exist, it is simply allowed to live in either file. A deletion
      # from EITHER file still counts against the same number. Raise this
      # floor, never lower it, and add the new file to `@explained_paths` when
      # the next slice is extracted — otherwise the next extraction buys
      # itself budget by moving comments out of the guard's sight.
      explained = Enum.sum(Enum.map(@explained_paths, &comment_line_count/1))

      assert explained > 2_000,
             """
             THE THING THIS GUARD PROTECTS HAS MOSTLY VANISHED.
             #{Enum.map_join(@explained_paths, ", ", &Path.basename/1)} now hold only
             #{explained} comment lines between them; this guard was built when
             `chat_live.ex` alone held 2,133 (42% of the file).
             Either a large amount of load-bearing explanation was deleted — in
             which case restore it, that deletion is the defect this task
             exists to prevent — or a helper slice was extracted to a file that
             is not in `@explained_paths`, in which case ADD IT rather than
             lowering this floor.
             """

      # (3) THE PIN ITSELF.
      measured = code_line_count(@chat_live_path)

      assert measured == @chat_live_code_line_count,
             """
             CHAT_LIVE CODE-LINE RATCHET TRIPPED.

               measured: #{measured}
                 pinned: #{@chat_live_code_line_count}
                  delta: #{if measured > @chat_live_code_line_count, do: "+", else: ""}#{measured - @chat_live_code_line_count}

             COMMENTS ARE NOT COUNTED. Blank lines, `#` comment lines and
             `@doc`/`@moduledoc` heredoc bodies are all excluded, so deleting a
             comment buys you NOTHING here. The only way to move this number is
             to add or remove code. That is the entire point of the guard —
             prose in this file is free.

             HOW TO CHANGE THIS NUMBER: update `@chat_live_code_line_count` in
             `test/platform_web/live/chat_live_code_line_ratchet_test.exs` to
             #{measured}, in the SAME commit as the code edit, with the reason
             in that commit message. A reviewer must be able to read one commit
             and see both the change and its justification.

             Do NOT delete the guard to make a diff pass.
             """

      # (4) THE COMMENTS ARE STILL THERE. The pin above is a budget; this is
      # the thing the budget was spent to protect. A guard that stays green
      # while the `019f9257` security rationale in `do_mount/3` is deleted has
      # failed at its actual job. Both literals were verified present on this
      # ref before being asserted.
      assert source =~ "019f9257",
             """
             THE SECURITY RATIONALE HAS BEEN DELETED.
             `chat_live.ex` no longer mentions task `019f9257`. That comment
             block in `do_mount/3` explains why `chat_mode => "external"` may be
             merged from exactly one place. Restore it. This guard counts only
             code precisely so that keeping this explanation costs nothing.
             """

      assert source =~ "EVERY channel across EVERY org leaked",
             """
             THE SECURITY RATIONALE HAS BEEN GUTTED.
             The `019f9257` block in `do_mount/3` no longer states the failure
             it prevents ("EVERY channel across EVERY org leaked"). A rule
             without its consequence is a rule the next reader will drop.
             Restore the sentence rather than weakening this assertion.
             """
    end
  end
end
