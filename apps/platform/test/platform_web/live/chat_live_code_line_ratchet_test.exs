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
       `@fabrikam_admin?` gate at `chat_live.ex:511..524`; the drawer-query note at
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
  @chat_live_code_line_count 2346

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

      assert comment_line_count(@chat_live_path) > 2_000,
             """
             THE THING THIS GUARD PROTECTS HAS MOSTLY VANISHED.
             `chat_live.ex` now holds only #{comment_line_count(@chat_live_path)} comment
             lines; this guard was built when it held 2,133 (42% of the file).
             Either a large amount of load-bearing explanation was deleted — in
             which case restore it, that deletion is the defect this task
             exists to prevent — or the comment style changed wholesale, in
             which case update this floor in the SAME commit with the reason in
             the commit message.
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
