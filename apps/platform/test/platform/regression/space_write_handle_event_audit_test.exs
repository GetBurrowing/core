defmodule Platform.Regression.SpaceWriteHandleEventAuditTest do
  @moduledoc """
  Source-scan guard keeping LiveView space writes at ONE choke point:
  `Platform.Chat.SpaceAccess.authorize_writer/2`, composed inside the
  `Platform.Chat` context function (task 01a01ce0, stage 2).

  ## Why a guard at all

  `org_scope_choke_point_audit_test.exs` in this directory is the template,
  and its stated reason applies here verbatim: extraction without an enforced
  budget decays, the third copy costs one `defp` to write, and nobody notices
  it until the copies disagree about who may see what.

  The budget being enforced here is narrower and blunter. Stage 1 found two
  live handlers taking a space id straight out of client event params and
  handing it to a `Platform.Chat` write with no membership check:
  `PinHooks`'s `"pin_toggle"` (guarded only by
  `socket.assigns.current_participant`, which is membership of the space being
  VIEWED) and `ShellLive`'s utility-bar agent Remove event (no membership
  check at all; the event and its dropdown were deleted in task 01a1557a-8f80).
  Neither was a hard case. Both were written by people who had no reason to
  think a `space-id` param needed checking, because nothing said so.

  This file is what says so.

  ## The rule

  A client-supplied space id must not reach a `Platform.Chat` write from a
  LiveView event handler without composing `SpaceAccess.authorize_writer/2`.
  A clause satisfies it by calling a function listed in
  `@space_authorized_chat_calls`, and test 2 independently verifies that each
  of those functions really does compose the choke point inside its OWN `def`
  block in `chat.ex`.

  ## Four clause forms, all four scanned

  Missing any one of them makes the guard measure nothing, and two of the four
  are exactly where the stage-1 defects lived:

    1. `def handle_event(...)` — the ordinary LiveView callback.
    2. `defp handle_event(...)` — the hook-module form, which is what
       `pin_hooks.ex` uses. The template's `defp_blocks/1` filters to PRIVATE
       definitions only, so copying it verbatim would have missed every public
       callback; this file's splitter takes `defp?`.
    3. An anonymous `fn` clause inside `attach_hook(_, :handle_event, fn ...
       end)`. This is the form the utility-bar Remove event used. Only
       `shell_live.ex` uses it today, at two sites, and a splitter keyed on
       `def` would see neither.
    4. A named function captured under a DIFFERENT name, resolved from
       `attach_hook(_, :handle_event, &<name>/3)` rather than assumed to be
       `handle_event`. `meeting_hooks.ex` attaches `&handle_guest_event/3`.

  ## The template's clause grouping is deliberately dropped

  `org_scope_choke_point_audit_test.exs` groups clauses by function name
  before judging, because a `defp scope_org(q, nil), do: q` pass-through has
  no `Tenancy.scope(` in it and reads as a hand-rolled filter when judged
  alone. That protection cannot be carried over: EVERY clause here shares the
  name `handle_event`, so grouping by name would merge a whole module into one
  head-blob and one body-blob. `chat_live.ex` alone would then present as a
  single clause whose head contains a `"space_id"` key and whose body contains
  a `Chat.` call, from two handlers hundreds of lines apart. That is a
  guaranteed false positive, and worse, a guaranteed false NEGATIVE the moment
  any registered call anywhere in the file satisfies the whole module.

  So judgement is PER CLAUSE. The cost is that a genuine multi-clause
  delegation is judged one clause at a time; that costs nothing here, because
  a clause that merely delegates carries no `Chat.` call and cannot be flagged.

  ## Prose is stripped before matching

  This is the recorded failure mode of source-text guards in this repo: one
  stayed green after its only call site was deleted, because its own moduledoc
  satisfied the regex. `strip_prose/1` blanks `#` comment lines and heredoc
  bodies while PRESERVING line numbering, so offender reports still cite real
  lines. Copied from `pubsub_topic_inventory_audit_test.exs`, which needs it
  for the same reason.

  ## What this guard CANNOT defend

  Stated because a guard that overclaims is worse than a narrow one. It sees
  `handle_event` clauses and nothing else. Invisible to it:

    * Controllers.
    * Phoenix channel `handle_in/3` (`runtime_channel.ex`), covered separately
      by `test/security/runtime_channel_capability_test.exs` and
      `transport_capability_parity_test.exs`.
    * `handle_info/2`.
    * `handle_params/3`. The one critical live exposure this repo has recorded
      came through `handle_params/3` (task 01a01d0e) and was fixed at the
      resolution point instead of here.
    * The federation MCP tool surface, where `space_leave` is a live
      same-class gap: it takes a client `space_id` and an arbitrary `agent_id`
      into `Chat.remove_participant/1` with no membership check on the calling
      agent.

  No dataflow analysis either. A clause that hands a param space id to a
  private helper which then calls `Chat.` is invisible, and `chat_live.ex`'s
  `"close_dm"` is exactly that shape. Aliased or dynamic module names
  (`alias Platform.Chat, as: C`, `apply(Chat, fun, args)`) defeat the
  `Chat.<fn>(` match. READS are out of scope. Writers that never enter
  `Platform.Chat` are invisible.

  ## Shape

  Pure `File.read!` plus `Regex` — no DB, no PubSub, `async: true`. Peer of
  `org_scope_choke_point_audit_test.exs` and
  `pubsub_topic_inventory_audit_test.exs` in this directory.
  """

  use ExUnit.Case, async: true

  # `__DIR__` is `apps/platform/test/platform/regression`, so three levels up
  # is `apps/platform`. Same shape the sibling audits use.
  @app_root Path.expand("../../..", __DIR__)
  @web_root Path.join(@app_root, "lib/platform_web")
  @chat_context Path.join(@app_root, "lib/platform/chat.ex")

  # SCAN ROOT is `lib/platform_web`, NOT `lib/platform_web/live`.
  # Components outside `live/` carry `handle_event` clauses too (the deleted
  # `components/chat/add_participant_sheet.ex` called `Chat.add_participant/2`
  # and `Chat.add_agent_participant/2` from one, until task 01a0fd62 stage 3
  # removed it), and it is the PREDICATE that should clear such a clause (a
  # space id from `socket.assigns`, never a param), not a directory boundary
  # that never looked.

  # ── Anti-vacuity floors ───────────────────────────────────────────────────
  #
  # A scanner that visits zero files passes vacuously, and so does a correct
  # root with a broken clause splitter. Both are measured, because they fail
  # independently and both fail SILENTLY.
  #
  # Measured on this branch at commit c7a539cb on 2026-08-28: 169 `.ex` files
  # under the scan root, of which 48 contain at least one handler clause, and
  # 547 clauses split out in total. The planner measured 161 / 47 / 515 on
  # `origin/main` at f1311a42 on 2026-08-24; the tree grew between the two
  # readings and this splitter also counts anonymous `fn` hook clauses.
  #
  # The FILE floor counts EVERY `.ex` file under the root (the 169), not the
  # 48 that happen to contain a handler. A root that resolves outside the tree
  # yields zero of the former, which is the failure being caught.
  #
  # The CLAUSE floor counts handler clauses across all files (the 547). Both
  # floors sit at roughly half the measurement, so ordinary deletion never
  # trips them and a broken root or a broken splitter always does.
  @min_scanned_files 80
  @min_clauses 260

  # ── The registry ──────────────────────────────────────────────────────────
  #
  # `Platform.Chat` functions that compose `SpaceAccess.authorize_writer/2`.
  # A handler calling one of these has been through the choke point. Test 2
  # verifies the claim against `chat.ex` per function, so an entry cannot be
  # added here to silence the audit without the function actually composing.
  @space_authorized_chat_calls ~w(pin_message unpin_message reserve_space_upload
                                 set_agent_silenced set_agents_awake set_agent_attention_policy)

  # ── The allowlist ─────────────────────────────────────────────────────────
  #
  # Keyed `{relative_path, event_name}`, NOT path alone. `control_center_live.ex`
  # has 55 `handle_event` clauses; a file-granular exemption would silently
  # exempt every handler anyone adds to it in future.
  @allowlist []

  # NOT allowlisted, on purpose, and each one is a claim this file re-checks
  # on every run rather than a memory:
  #
  #   * `pin_hooks.ex` and `shell_live.ex`. After stage 1 both call registered
  #     functions and fall outside the predicate. If either ever trips this
  #     audit, stage 1 has been undone — do not allowlist it.
  #
  #   * `chat_live.ex`'s `"toggle_pinned"`, `"pinned_reordered"`,
  #     `"open_row_actions"`, `"move_pinned"`, `"hide_channel"`, `"close_dm"`,
  #     `"unhide_channel"` and `"undo_hide"`. They write only the caller's own
  #     sidebar preferences, keyed on `socket.assigns.user_id` via
  #     `Platform.Chat.Sidebar` or `Platform.Accounts`, and `"open_row_actions"`
  #     is assign-only with no write at all. A forged id in any of them
  #     pollutes only the attacker's own rail, so routing them through a
  #     membership check would be cost with no defect behind it. They already
  #     fall OUTSIDE the predicate because none of them calls a `Chat.<fn>(`.
  #     An allowlist entry for them would be stale on arrival and test 4 would
  #     reject it.

  # ── Patterns ──────────────────────────────────────────────────────────────

  # A space id taken from CLIENT PARAMS. Three shapes, because a handler that
  # pulls the id out in its body rather than destructuring it in the head would
  # otherwise slip past:
  #
  #   * a destructured string key, `%{"space_id" => _}` / `%{"space-id" => _}`
  #   * a bound variable named `space_id`, e.g. `%{"id" => space_id}`
  #   * bracket extraction, `params["space-id"]`
  #
  # All three are keyed on a STRING key or on the variable name, which is what
  # separates them from `socket.assigns[:space_id]` (an atom key, and not
  # caller-supplied).
  @param_space_id_head_regexes [
    ~r/"space[-_]id"\s*=>/,
    ~r/=>\s*space_id\b/
  ]

  @param_space_id_body_regex ~r/\[\s*"space[-_]id"\s*\]/

  # The CALL SHAPE, never a bare reference. Both spellings: `control_center_live.ex`
  # uses the fully qualified `Platform.Chat.`, the hook modules use the alias.
  @chat_call_regex ~r/(?:Platform\.)?Chat\.(\w+)\(/

  @choke_point_regex ~r/SpaceAccess\.authorize_writer\(/

  # ── 1. No offending handler ───────────────────────────────────────────────

  describe "client space ids reaching a Chat write from a LiveView event" do
    test "no handler writes to a client-supplied space without the choke point" do
      offenders = scan_offenders()

      assert offenders == [], format_offenders(offenders)
    end

    # ── 2. Registry cross-check ─────────────────────────────────────────────

    test "every registered Chat function composes the choke point in its own def block" do
      source = @chat_context |> File.read!() |> strip_prose()
      blocks = def_blocks(source)

      uncomposed =
        Enum.reject(@space_authorized_chat_calls, fn name ->
          case Map.get(blocks, name) do
            nil -> false
            body -> Regex.match?(@choke_point_regex, body)
          end
        end)

      missing = Enum.filter(@space_authorized_chat_calls, &(not Map.has_key?(blocks, &1)))

      assert missing == [], """
      @space_authorized_chat_calls names #{length(missing)} function(s) that no
      longer exist in lib/platform/chat.ex:

      #{Enum.map_join(missing, "\n", &"  - Chat.#{&1}/_")}

      A registry entry naming nothing exempts nothing and reads as a review that
      happened. Remove it, or fix the name.
      """

      assert uncomposed == [], """
      @space_authorized_chat_calls names #{length(uncomposed)} function(s) whose
      OWN def block in lib/platform/chat.ex does not contain
      `SpaceAccess.authorize_writer(`:

      #{Enum.map_join(uncomposed, "\n", &"  - Chat.#{&1}/_")}

      Every handler in lib/platform_web that calls one of these is treated by
      this audit as having gone through the space-membership choke point. If the
      function does not actually compose it, that treatment is a lie and the
      audit is worse than absent.

      This is checked PER FUNCTION, against that function's own block, on
      purpose. Asserting only that chat.ex contains the string somewhere would
      let ONE composed function green-light the whole registry.
      """
    end

    # ── 3. Anti-vacuity, two floors ─────────────────────────────────────────

    test "the scan visits a plausible number of files and finds a plausible number of clauses" do
      sources = web_sources()
      clause_count = sources |> Enum.map(fn {_rel, src} -> length(clauses(src)) end) |> Enum.sum()

      assert length(sources) > @min_scanned_files, """
      The space-write audit scanned only #{length(sources)} file(s), below the
      floor of #{@min_scanned_files}. This almost certainly means the scan root
      is broken, NOT that the tree shrank by half:

        @web_root = #{@web_root}

      A path typo, a `Path.expand` resolving outside the tree, or a
      `Path.wildcard` returning `[]` all produce a green suite that guards
      nothing, silently, for years.
      """

      assert clause_count > @min_clauses, """
      The scan visited #{length(sources)} file(s) but split out only
      #{clause_count} handler clause(s), below the floor of #{@min_clauses}.

      A correct root with a broken clause splitter is the same vacuity one level
      down: every file is read, no clause is ever judged, and the audit is
      green. Check `clauses/1` — in particular whether it still resolves hook
      names from `attach_hook(_, :handle_event, &name/3)` and still finds
      anonymous `fn` clauses inside `attach_hook(_, :handle_event, fn ... end)`,
      which is the form the `dismiss_agent` defect used.
      """
    end

    # ── 4. Stale allowlist ──────────────────────────────────────────────────

    test "every @allowlist entry still matches the offender predicate" do
      stale =
        Enum.filter(@allowlist, fn {relative_path, event} ->
          case File.read(Path.join(Path.dirname(@web_root), relative_path)) do
            {:ok, source} ->
              source
              |> strip_prose()
              |> offenders_in()
              |> Enum.all?(fn %{event: e} -> e != event end)

            {:error, _} ->
              true
          end
        end)

      assert stale == [], """
      @allowlist in this file exempts #{length(stale)} handler(s) that no longer
      match the offender predicate (or whose file no longer exists):

      #{Enum.map_join(stale, "\n", fn {path, event} -> "  - #{path}  \"#{event}\"" end)}

      An exemption for a handler the scan cannot see is dead code reading as
      "this was reviewed and exempted", when the handler may have been fixed or
      deleted long ago. Remove the entry.
      """
    end

    # ── 5. Checked-in detonation ────────────────────────────────────────────

    test "the offender predicate detonates against synthetic fixtures" do
      # A mutation probe performed once at authorship decays: a pin that was
      # falsifiable when written becomes an identity three commits later. These
      # four fixtures make the falsification a checked-in claim that re-runs.
      #
      # Invented module and event names throughout — `core` is public.

      flagged = fn source -> source |> strip_prose() |> offenders_in() |> Enum.map(& &1.event) end

      # (a) A `def handle_event` clause taking a space id from params and
      #     calling an UNREGISTERED Chat write IS flagged.
      unguarded = """
      defmodule Fixture.Unguarded do
        def handle_event("widget_stash", %{"space_id" => space_id}, socket) do
          Chat.remove_participant(space_id)
          {:noreply, socket}
        end
      end
      """

      assert "widget_stash" in flagged.(unguarded),
             "the predicate no longer flags the plain unguarded shape, which is the whole rule"

      # (b) The same clause calling a REGISTERED function is NOT flagged.
      guarded = """
      defmodule Fixture.Guarded do
        def handle_event("widget_stash", %{"space_id" => space_id}, socket) do
          Chat.unpin_message({:user, socket.assigns.user_id}, space_id, "m")
          {:noreply, socket}
        end
      end
      """

      refute "widget_stash" in flagged.(guarded),
             "a handler routed through a registered function must clear, or the audit is unfixable"

      # (c) The anonymous `attach_hook(_, :handle_event, fn ... end)` form of
      #     (a) IS flagged. This is the shape a `def`-keyed splitter misses
      #     entirely, and it is the shape the `dismiss_agent` defect used.
      anonymous = """
      defmodule Fixture.Anonymous do
        def on_mount(_, _, _, socket) do
          socket
          |> attach_hook(:widget_events, :handle_event, fn
            "widget_evict", %{"agent-id" => agent_id, "space-id" => space_id}, socket ->
              Chat.remove_participant(space_id, agent_id)
              {:halt, socket}

            _event, _params, socket ->
              {:cont, socket}
          end)
        end
      end
      """

      assert "widget_evict" in flagged.(anonymous),
             "the anonymous fn hook form is invisible to the splitter, so shell_live.ex is unguarded"

      # (d) The offending text inside a `#` comment is NOT flagged. A guard
      #     that its own prose can satisfy is the recorded failure mode this
      #     repo has already hit once.
      commented = """
      defmodule Fixture.Commented do
        # def handle_event("widget_stash", %{"space_id" => space_id}, socket) do
        #   Chat.remove_participant(space_id)
        # end
        def handle_event("widget_noop", _params, socket), do: {:noreply, socket}
      end
      """

      assert flagged.(commented) == [],
             "prose satisfies the predicate, so a deleted call site would keep this audit green"
    end
  end

  # ── Scanning ──────────────────────────────────────────────────────────────

  defp scan_offenders do
    allowed = MapSet.new(@allowlist)

    web_sources()
    |> Enum.flat_map(fn {relative_path, source} ->
      source
      |> offenders_in()
      |> Enum.reject(fn %{event: event} ->
        MapSet.member?(allowed, {relative_path, event})
      end)
      |> Enum.map(&Map.put(&1, :path, relative_path))
    end)
    |> Enum.sort_by(fn %{path: p, line: l} -> {p, l} end)
  end

  # `{relative_path, prose_stripped_source}`, relative to `lib/` so the
  # allowlist key reads `platform_web/live/...` — the same convention
  # `repo_lookup_boundary_test.exs` uses for its inventory.
  defp web_sources do
    lib_root = Path.dirname(@web_root)

    @web_root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      {Path.relative_to(path, lib_root), path |> File.read!() |> strip_prose()}
    end)
  end

  # THE OFFENDER PREDICATE, factored to take a source STRING so test 5 can
  # detonate it against synthetic fixtures rather than against the tree.
  #
  # Returns `[%{line:, event:, head:, calls:}]`.
  defp offenders_in(source) do
    source
    |> clauses()
    |> Enum.filter(fn clause ->
      param_space_id?(clause) and unregistered_chat_calls(clause) != []
    end)
    |> Enum.map(fn %{line: line, event: event, head: head} = clause ->
      %{
        line: line,
        event: event,
        head: head |> String.split("\n") |> hd() |> String.trim(),
        calls: unregistered_chat_calls(clause)
      }
    end)
  end

  defp param_space_id?(%{head: head, body: body}) do
    Enum.any?(@param_space_id_head_regexes, &Regex.match?(&1, head)) or
      Regex.match?(@param_space_id_body_regex, head <> "\n" <> body)
  end

  defp unregistered_chat_calls(%{body: body}) do
    @chat_call_regex
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
    |> Enum.reject(&(&1 in @space_authorized_chat_calls))
    |> Enum.uniq()
  end

  # ── Clause splitting ──────────────────────────────────────────────────────

  # Returns one entry PER CLAUSE — see the moduledoc on why the template's
  # group-by-name pass is deliberately dropped.
  defp clauses(source) do
    lines = String.split(source, "\n")
    regions = anonymous_hook_regions(lines)

    starts =
      (named_clause_starts(lines, hook_names(source)) ++
         Enum.flat_map(regions, &anonymous_clause_starts(lines, &1)))
      |> Enum.uniq()
      |> Enum.sort()

    starts
    |> Enum.with_index()
    |> Enum.map(fn {start, index} ->
      # A clause ends at the next clause start, or — for an anonymous clause —
      # at its enclosing `end)` at the latest, so a clause never swallows the
      # code that follows the hook.
      region_end = Enum.find_value(regions, fn {from, to} -> if start in from..to, do: to end)
      next = Enum.at(starts, index + 1, (region_end || length(lines)) + 1)
      stop = min(next - 1, region_end || length(lines))

      text =
        if stop >= start,
          do: lines |> Enum.slice((start - 1)..(stop - 1)) |> Enum.join("\n"),
          else: ""

      {head, body} = split_head(text)

      %{
        line: start,
        head: head,
        body: body,
        event: event_name(head)
      }
    end)
  end

  # Hook names are RESOLVED from the attach, not assumed. `meeting_hooks.ex`
  # attaches `&handle_guest_event/3`, and a scanner keyed on the literal name
  # `handle_event` would read that module as having no guest handlers at all.
  defp hook_names(source) do
    ~r/attach_hook\(\s*[^,]+,\s*:handle_event\s*,\s*&(\w+)\/3/
    |> Regex.scan(source, capture: :all_but_first)
    |> List.flatten()
    |> Enum.concat(["handle_event"])
    |> Enum.uniq()
  end

  # `defp?`, not `defp` — the template filters to PRIVATE definitions and a
  # verbatim copy would have missed every `def handle_event`.
  defp named_clause_starts(lines, names) do
    alternation = Enum.map_join(names, "|", &Regex.escape/1)
    regex = Regex.compile!("^\\s{0,6}defp?\\s+(?:#{alternation})\\s*\\(")

    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _index} -> Regex.match?(regex, line) end)
    |> Enum.map(fn {_line, index} -> index end)
  end

  # `{first_line_of_fn, line_of_the_closing_end)}` for every
  # `attach_hook(_, :handle_event, fn` block. Closed on an `end)` at the SAME
  # indent as the `|> attach_hook(` line that opened it.
  defp anonymous_hook_regions(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _index} ->
      Regex.match?(~r/attach_hook\(\s*[^,]+,\s*:handle_event\s*,\s*fn\s*$/, line)
    end)
    |> Enum.map(fn {line, index} ->
      indent = indent_of(line)

      closing =
        lines
        |> Enum.with_index(1)
        |> Enum.find(fn {candidate, candidate_index} ->
          candidate_index > index and indent_of(candidate) == indent and
            String.starts_with?(String.trim_leading(candidate), "end)")
        end)

      {index, (closing && elem(closing, 1)) || length(lines)}
    end)
  end

  # Inside an anonymous hook, a clause head starts with the matched event
  # (a string literal or an `_`-prefixed catch-all) followed by a comma, and
  # the head reaches a `->` within a few lines. The `->` lookahead is what
  # stops a multi-line list literal in some clause's BODY reading as a new
  # clause head.
  defp anonymous_clause_starts(lines, {from, to}) do
    Enum.filter(from..to, fn index ->
      line = Enum.at(lines, index - 1) || ""

      Regex.match?(~r/^\s*(?:"[^"]+"|_\w*)\s*,/, line) and
        Enum.any?(index..min(index + 3, to), fn lookahead ->
          (Enum.at(lines, lookahead - 1) || "")
          |> String.trim_trailing()
          |> String.ends_with?("->")
        end)
    end)
  end

  # The head runs to the first line that closes it: ` do`, `->`, or a `, do:`
  # one-liner. Multi-line heads are the norm rather than the exception —
  # `control_center_live.ex`'s `"add_agent_to_space"` spans five lines, and its
  # `"space_id"` key is on none of them but the third.
  defp split_head(text) do
    {before, rest} =
      text
      |> String.split("\n")
      |> Enum.split_while(fn line ->
        trimmed = String.trim_trailing(line)

        not (String.ends_with?(trimmed, " do") or String.ends_with?(trimmed, "->") or
               String.contains?(trimmed, ", do:"))
      end)

    {Enum.join(before ++ Enum.take(rest, 1), "\n"), rest |> Enum.drop(1) |> Enum.join("\n")}
  end

  # The first string literal in the head. `nil` for a catch-all clause, which
  # can never be allowlisted — deliberately, since an allowlist entry keyed on
  # a catch-all would exempt every event that falls through to it.
  defp event_name(head) do
    case Regex.run(~r/"([^"]+)"/, head, capture: :all_but_first) do
      [event] -> event
      _ -> nil
    end
  end

  defp indent_of(line), do: String.length(line) - String.length(String.trim_leading(line))

  # ── chat.ex `def` blocks, for the registry cross-check ────────────────────

  # `%{function_name => block_body}`. A block runs from its `def` head to the
  # next top-level definition, so `SpaceAccess.authorize_writer(` is attributed
  # to the function that actually contains it and not to its neighbour.
  defp def_blocks(source) do
    lines = String.split(source, "\n")

    starts =
      lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _index} -> Regex.match?(~r/^\s{0,4}defp?\s+\w/, line) end)
      |> Enum.map(fn {_line, index} -> index end)

    starts
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {start, index}, acc ->
      head = Enum.at(lines, start - 1)

      case Regex.run(~r/^\s{0,4}def\s+(\w+)/, head, capture: :all_but_first) do
        [name] ->
          next = Enum.at(starts, index + 1, length(lines) + 1)
          body = lines |> Enum.slice((start - 1)..(next - 2)) |> Enum.join("\n")
          # Multiple clauses of one function accumulate, so a guard clause
          # cannot hide the composed clause from the cross-check.
          Map.update(acc, name, body, &(&1 <> "\n" <> body))

        _ ->
          acc
      end
    end)
  end

  # ── Prose ─────────────────────────────────────────────────────────────────

  # Blanks `#` comment lines and heredoc bodies, preserving line COUNT so
  # offender reports still cite real line numbers. Copied from
  # `pubsub_topic_inventory_audit_test.exs`.
  defp strip_prose(source) do
    source
    |> String.split("\n")
    |> Enum.map_reduce(false, fn line, in_heredoc? ->
      delimiters = length(String.split(line, ~s("""))) - 1
      next? = if rem(delimiters, 2) == 1, do: not in_heredoc?, else: in_heredoc?

      cond do
        in_heredoc? or delimiters > 0 -> {"", next?}
        String.starts_with?(String.trim_leading(line), "#") -> {"", next?}
        true -> {line, next?}
      end
    end)
    |> elem(0)
    |> Enum.join("\n")
  end

  # ── Reporting ─────────────────────────────────────────────────────────────

  defp format_offenders(offenders) do
    sites =
      Enum.map_join(offenders, "\n\n", fn %{
                                            path: path,
                                            line: line,
                                            event: event,
                                            head: head,
                                            calls: calls
                                          } ->
        """
          #{path}:#{line}  event #{inspect(event)}
              #{head}
              unregistered Chat call(s): #{Enum.map_join(calls, ", ", &"Chat.#{&1}/_")}
        """
      end)

    """
    #{length(offenders)} LiveView event handler(s) take a space id from CLIENT
    PARAMS and hand it to a `Platform.Chat` function that does not compose
    `Platform.Chat.SpaceAccess.authorize_writer/2`.

    That is the shape of the defect this guard exists for: before task
    01a01ce0, `"pin_toggle"` and the shell's agent Remove event both let a session open on
    one space write to a different one by editing a single field of a LiveView
    event. A membership check in the HANDLER protects one caller; the check
    belongs in the context function, where every future caller inherits it.

    Fix ONE of:

      (a) Route the write through a `Platform.Chat` function that takes an
          actor and composes `SpaceAccess.authorize_writer/2`, then add that
          function's name to @space_authorized_chat_calls in this file. Test 2
          verifies the composition against the function's own def block in
          chat.ex, so a name added without the composition fails there instead.
          See `Chat.pin_message/2` for the shape.

      (b) If the handler genuinely must not carry a membership check, add
          `{path, event_name}` to @allowlist in this file DELIBERATELY, with a
          comment stating the reason. The key is per EVENT, not per file, so
          the exemption cannot silently spread to handlers nobody reviewed. An
          uncommented entry is not an exemption, it is a silenced test.

    Offending sites:

    #{sites}
    """
  end
end
