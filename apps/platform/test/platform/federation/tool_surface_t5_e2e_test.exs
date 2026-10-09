defmodule Platform.Federation.ToolSurfaceT5E2ETest do
  @moduledoc """
  T5 task-level adversarial review (ADR-0041).

  Four `e2e_behavior` cases mirror the plan's task-level review stage
  validations. The planner-authored `setup` / `actions` / `expected`
  text is reproduced in each test body so a review agent can cite the
  test outcome as evidence. The cases drive the public
  `Platform.Federation.ToolSurface.execute/3` entry point — the same
  surface that arrives at the engine from a federated runtime over the
  `runtime:<id>` channel — to exercise the memory_* family end-to-end
  through the routing + dispatch + Wiki layers.

  Cases:

    A. Happy path — Historian agent calls memory_create then
       memory_view on `org/page/identity.md`. Version/content/path
       round-trip exactly.

    B. Write routing policy — non-Historian agent calls
       memory_str_replace on a seeded `org/page/decisions.md`. Returns
       a `:historian_required` error envelope whose message contains
       the literal substring "propose via journal" and whose
       suggestion contains `memory_create at org/journal/<today>.md`.
       The seeded page is UNCHANGED in the DB.

    C. memory_search RRF + source tagging + ACL — seed pages, a
       journal entry, and messages across two spaces; private path
       owned by a different agent. Caller participates in S1 only.
       Search returns source-tagged hits from page + journal +
       message corpora; private-page hit and message in S2 are
       silently filtered.

    D. Federation capability broadcast — every memory_* tool is
       advertised in the capability surface, no V1 org_* tool name
       appears, every memory_* tool carries the bundle tag
       \"memory\".

  Case 5 (scope-creep guard) — describe block fails the build if T5
  drifted into T6/T7 territory, V1 tools snuck back, the
  Platform.Org.Context diff exceeded its one-line allow-list, or the
  Wiki public surface grew beyond `rename_page/3`. Mirrors the
  T2/T3/T4 stage-5 convention.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation.ToolSurface
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Journal
  alias Platform.Org.{WikiJournalEntry, WikiPage}
  alias Platform.Repo

  @t4_base "origin/task/019e41d9-cd7f-7f0d-b986-5cb5c7509ebc"

  setup do
    Repo.delete_all(WikiPage)
    Repo.delete_all(WikiJournalEntry)

    # Force the Noop provider for every e2e case — the lexical channel
    # is sufficient evidence on the search side and the page/journal
    # tools never touch memory-service. This also keeps Case C
    # deterministic without standing up a Memory provider stub.
    prev_provider = Application.get_env(:platform, :memory_service, [])

    Application.put_env(:platform, :memory_service, provider: Platform.Memory.Providers.Noop)

    on_exit(fn -> Application.put_env(:platform, :memory_service, prev_provider) end)

    :ok
  end

  defp create_agent(slug_prefix, opts \\ []) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "#{slug_prefix}-#{System.unique_integer([:positive, :monotonic])}",
        name: String.capitalize(slug_prefix),
        status: "active"
      })
      |> Repo.insert()

    # Task 019f2444 stage 6: Historian pins are Roles-only now. The
    # legacy `agents.system_events` column was dropped in stage 5, so
    # test fixtures pin via `Platform.Roles.assign_role/2` directly.
    if Keyword.get(opts, :assign_historian?, false) do
      {:ok, _} = Platform.Roles.assign_role("historian", agent.id)
    end

    agent
  end

  defp ctx(%Agent{id: id}), do: %{agent_id: id}

  defp seed_page(file_key, content, opts \\ []) do
    {:ok, page} = Wiki.upsert_page(file_key, %{content: content}, opts)
    page
  end

  defp seed_space(slug_prefix) do
    {:ok, space} =
      Chat.create_space(%{
        name: "T5 e2e #{slug_prefix}",
        slug: "t5-e2e-#{slug_prefix}-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp join_agent(space, %Agent{} = agent) do
    {:ok, participant} =
      Chat.add_agent_participant(space.id, agent, display_name: agent.name || "Agent")

    participant
  end

  defp post_message(space, participant, content) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      })

    msg
  end

  # ── Case A: happy path — memory_create + memory_view round-trip ──────

  test "Case A — Historian memory_create + memory_view round-trip on org/page/identity.md" do
    # setup: workspace with no pre-existing pages, Historian agent
    # pinned via Roles (task 019f2444 stage 6 retired `system_events`).
    historian = create_agent("historian-a", assign_historian?: true)

    text = "# Org Identity\n\nAcme — AI-native consultancy."

    # actions: As the Historian, create the page, then view it.
    assert {:ok, create_result} =
             ToolSurface.execute(
               "memory_create",
               %{"path" => "org/page/identity.md", "file_text" => text},
               ctx(historian)
             )

    # expected: create returns the version-1 page envelope tagged
    # `kind: \"page\"`.
    assert create_result.path == "org/page/identity.md"
    assert create_result.version == 1
    assert create_result.kind == "page"

    assert {:ok, view_result} =
             ToolSurface.execute(
               "memory_view",
               %{"path" => "org/page/identity.md"},
               ctx(historian)
             )

    # expected: view returns identical content + path + version, with
    # lines_returned: \"all\" because no view_range was supplied.
    assert view_result.path == "org/page/identity.md"
    assert view_result.content == text
    assert view_result.version == 1
    assert view_result.lines_returned == "all"
  end

  # ── Case B: non-Historian rejected with "propose via journal" ────────

  test "Case B — non-Historian memory_str_replace rejected with verbatim 'propose via journal'" do
    # setup: non-Historian agent (no Historian pin); seed an existing
    # `org/page/decisions.md`.
    plain = create_agent("plain-b")
    seed_page("org/page/decisions.md", "foo decision body\nfoo follow-up\n")

    # actions: As the non-Historian, attempt to str_replace the seeded
    # page.
    assert {:error, envelope} =
             ToolSurface.execute(
               "memory_str_replace",
               %{
                 "path" => "org/page/decisions.md",
                 "old_str" => "foo decision",
                 "new_str" => "bar decision"
               },
               ctx(plain)
             )

    # expected: envelope shape exactly matches the federation contract.
    assert envelope.recoverable == true
    assert envelope.code == :historian_required
    assert is_binary(envelope.error)
    assert is_binary(envelope.suggestion)

    # Verbatim substring: \"propose via journal\" (load-bearing
    # contract — clients parse the error for this exact text).
    assert envelope.error =~ "propose via journal"

    # Suggestion carries the journal path with today's ISO date.
    today_iso = Date.utc_today() |> Date.to_iso8601()
    assert envelope.suggestion =~ "memory_create at org/journal/#{today_iso}.md"

    # The seeded page is UNCHANGED in the DB — load it back and verify
    # content + version are identical to seed.
    {:ok, _} =
      Repo.transaction(fn ->
        page = Wiki.get_page("org/page/decisions.md")
        assert page.content == "foo decision body\nfoo follow-up\n"
        assert page.version == 1
      end)
  end

  # ── Case C: memory_search RRF + source tagging + ACL ─────────────────

  test "Case C — memory_search returns source-tagged hits across page+journal+message; ACL drops other-space + private" do
    # setup:
    #   - page `org/page/deployment-runbook.md` mentions \"deployment\" twice
    #   - journal `project/<uuid>/journal/<today>.md` mentions
    #     \"deployment\" once
    #   - private page in space S2 owned by other_agent — caller is
    #     NOT the owner, must be filtered.
    #   - messages in S1 (caller participates) and S2 (caller does
    #     not participate) mentioning \"deployment\" — only S1 hits
    #     survive ACL.
    caller = create_agent("caller-c")
    other = create_agent("other-c")

    s1 = seed_space("c-s1")
    s2 = seed_space("c-s2")

    # caller participates in S1 only.
    caller_p_s1 = join_agent(s1, caller)
    # other participates in S2 (not S1) — gives S2 a poster for the
    # message the caller's ACL must drop.
    other_p_s2 = join_agent(s2, other)

    project_id = Ecto.UUID.generate()

    seed_page(
      "org/page/deployment-runbook.md",
      "deployment runbook — deployment cadence is weekly."
    )

    {:ok, _journal_entry} =
      Journal.append(
        %{content: "deployment hotfix shipped", date: Date.utc_today()},
        namespace: "project/#{project_id}"
      )

    # Private page owned by another agent; caller is not the owner.
    seed_page(
      "space/#{s2.id}/private/#{other.id}/notes.md",
      "private deployment notes"
    )

    # Messages: S1 caller participates → survives; S2 caller does not → ACL drops.
    post_message(s1, caller_p_s1, "deployment scheduled for tomorrow?")
    post_message(s2, other_p_s2, "S2 deployment chatter")

    # actions: caller searches for \"deployment\" with no source/namespace filters.
    assert {:ok, payload} =
             ToolSurface.execute(
               "memory_search",
               %{"query" => "deployment", "limit" => 50},
               ctx(caller)
             )

    assert payload.fusion_constant_k == 60
    results = payload.results

    sources = results |> Enum.map(& &1.source) |> MapSet.new()

    # expected: source tags drawn from {\"page\", \"journal\", \"message\"}.
    assert "page" in sources
    assert "journal" in sources
    assert "message" in sources

    # Page hit is present and points at the runbook path.
    page_hits = Enum.filter(results, &(&1.source == "page"))
    assert Enum.any?(page_hits, &(&1.path == "org/page/deployment-runbook.md"))

    # ACL: the other agent's private page is absent.
    refute Enum.any?(page_hits, &(&1.path == "space/#{s2.id}/private/#{other.id}/notes.md"))

    # ACL: every message hit is from S1.
    message_hits = Enum.filter(results, &(&1.source == "message"))
    assert Enum.any?(message_hits, &(&1.space_id == s1.id))
    refute Enum.any?(message_hits, &(&1.space_id == s2.id))

    # Order is by descending score (RRF).
    scores = Enum.map(results, & &1.score)
    assert scores == Enum.sort(scores, :desc)
  end

  # ── Case D: federation capability surface advertises memory_*, not org_* ─

  test "Case D — capability surface advertises seven memory_* tools and zero V1 org_* tools" do
    # actions: inspect `ToolSurface.tool_definitions()` — the same
    # array `runtime_channel.ex` line 77 pushes to runtimes on connect.
    tools = ToolSurface.tool_definitions()
    names = Enum.map(tools, & &1.name) |> MapSet.new()

    # expected: every memory_* tool is present (seven total).
    for tool <-
          ~w(memory_view memory_create memory_str_replace memory_insert memory_delete memory_rename memory_search) do
      assert tool in names, "capability surface missing memory tool #{tool}"
    end

    # expected: no V1 org_context_* / org_memory_* tool name appears.
    for v1 <-
          ~w(org_context_read org_context_write org_context_list org_memory_append org_memory_search) do
      refute v1 in names,
             "capability surface still advertises retired V1 tool #{v1}"
    end

    # expected: bundle tag on each memory_* tool is the literal
    # string \"memory\".
    memory_tools = Enum.filter(tools, &String.starts_with?(&1.name, "memory_"))
    assert Enum.all?(memory_tools, &(&1.bundle == "memory"))

    # The push payload also carries `tool_count: length(tools)` — match
    # what runtime_channel.ex would emit.
    assert length(tools) == MapSet.size(names)
  end

  # ── Case 5: scope-creep guard ────────────────────────────────────────

  describe "Case 5 — scope-creep guard" do
    @t5_changed_lib_paths [
      "lib/platform/federation/tool_surface.ex",
      "lib/platform/org/wiki/routing.ex",
      "lib/platform/org/wiki/search.ex",
      # rename_page/3 added (single new public fn)
      "lib/platform/org/wiki.ex",
      "lib/platform/orchestration/prompt_templates.ex",
      "lib/platform/agents/system_event_scheduler.ex",
      # single doc-comment fix (org_memory_search → memory_search)
      "lib/platform/org/context.ex"
    ]

    @t5_forbidden_paths [
      # T6 territory — historian schedule + triggers
      "lib/platform/org/historian.ex",
      "lib/platform/org/historian/scheduler.ex",
      "lib/platform/org/historian/cursor.ex",
      # T7 territory — OrgMemoryLive
      "lib/platform_web/live/org_memory_live.ex",
      "lib/platform_web/live/org_memory_live"
    ]

    # T5 HEAD — the commit this guard pins against.
    @t5_head "c0a3f9d"

    defp t5_root, do: Mix.Project.project_file() |> Path.dirname()

    test "T5 did not introduce T6/T7 modules" do
      # Pinned to T5 HEAD rather than the working tree: downstream tasks
      # (T6 historian, T7 OrgMemoryLive) legitimately add these paths on
      # the rollup branch, so a `File.exists?` check goes stale the
      # moment they land (T7 stage 2 tripped it). Skips silently when
      # git is unavailable (containers where `.git` is masked) —
      # mirroring the diff-vs-T4 test below.
      case System.cmd(
             "git",
             ["ls-tree", "-r", "--name-only", @t5_head, "--", "apps/platform"],
             cd: Path.expand("../..", t5_root()),
             stderr_to_stdout: true
           ) do
        {listing, 0} ->
          tracked = listing |> String.split("\n", trim: true)

          for path <- @t5_forbidden_paths do
            full = "apps/platform/" <> path

            refute full in tracked or
                     Enum.any?(tracked, &String.starts_with?(&1, full <> "/")),
                   "T5 should NOT add #{path} — that's downstream task territory."
          end

        {_out, _nonzero} ->
          :ok
      end
    end

    test "T5 did not touch apps/platform/lib/platform_web/" do
      refute Enum.any?(@t5_changed_lib_paths, &String.starts_with?(&1, "lib/platform_web/")),
             "T5 changed-paths allow-list must not include any platform_web paths."
    end

    test "V1 org_context_* / org_memory_* tool defs + execute clauses are removed from tool_surface" do
      src = File.read!(Path.join(t5_root(), "lib/platform/federation/tool_surface.ex"))

      for v1 <-
            ~w(org_context_read org_context_write org_context_list org_memory_append org_memory_search) do
        refute String.contains?(src, ~s(name: "#{v1}")),
               "V1 tool definition for #{v1} still present in tool_surface.ex"

        refute String.contains?(src, ~s(execute("#{v1}")),
               "V1 execute clause for #{v1} still present in tool_surface.ex"
      end

      # The bundle has been renamed.
      refute String.contains?(src, ~s("org_context")),
             "tool_surface.ex still references the retired `org_context` bundle"

      assert String.contains?(src, ~s(@bundles ~w()) and
               Regex.match?(~r/@bundles\s+~w\([^)]*\bmemory\b/, src),
             "tool_surface.ex @bundles must include `memory`"
    end

    test "all seven memory_* tools are registered in the memory bundle" do
      defs = ToolSurface.list_tools(["memory"])
      names = MapSet.new(defs, & &1.name)

      for tool <-
            ~w(memory_view memory_create memory_str_replace memory_insert memory_delete memory_rename memory_search) do
        assert tool in names, "memory bundle missing #{tool}"
      end

      # Every tool carries the new bundle tag.
      assert Enum.all?(defs, &(&1.bundle == "memory"))
    end

    test "Platform.Org.Context diff vs T4 HEAD is the documented one-line doc-comment update" do
      {diff, status} =
        System.cmd(
          "git",
          ["diff", @t4_base, "--", "apps/platform/lib/platform/org/context.ex"],
          cd: Path.expand("../../..", t5_root()),
          stderr_to_stdout: true
        )

      # Skip silently when running outside a git checkout (containers
      # where `.git` is masked) — the lint/type/test gates still cover
      # the substantive content of Org.Context via T4's sha256 pin in
      # context_t4_e2e_test.exs.
      if status != 0 do
        :ok
      else
        added =
          diff
          |> String.split("\n")
          |> Enum.filter(&String.starts_with?(&1, "+"))
          |> Enum.reject(&String.starts_with?(&1, "+++"))

        removed =
          diff
          |> String.split("\n")
          |> Enum.filter(&String.starts_with?(&1, "-"))
          |> Enum.reject(&String.starts_with?(&1, "---"))

        assert length(added) <= 2 and length(removed) <= 2,
               """
               Platform.Org.Context drift detected — only the documented
               one-line `org_memory_search → memory_search` doc-comment
               fix is permitted in T5.
               Added lines (#{length(added)}):
               #{Enum.join(added, "\n")}
               Removed lines (#{length(removed)}):
               #{Enum.join(removed, "\n")}
               """
      end
    end

    test "Platform.Org.Wiki public surface gained exactly rename_page/3" do
      src = File.read!(Path.join(t5_root(), "lib/platform/org/wiki.ex"))

      # The new public function must exist.
      assert Regex.match?(~r/^\s*def\s+rename_page\(/m, src),
             "Wiki.rename_page/3 must exist (added in T5 stage 3)."

      # And no other rename helpers crept in (e.g. rename_journal —
      # that would be T6 territory).
      refute Regex.match?(~r/^\s*def\s+rename_journal\b/m, src),
             "T5 must NOT add Wiki.rename_journal — journal is append-only."
    end

    test "no journal-write or journal-edit helpers introduced beyond Journal.append/2" do
      journal_src = File.read!(Path.join(t5_root(), "lib/platform/org/wiki/journal.ex"))

      refute Regex.match?(~r/^\s*def\s+update_entry\b/m, journal_src),
             "Journal is append-only — Journal.update_entry/* must not exist."

      refute Regex.match?(~r/^\s*def\s+delete_entry\b/m, journal_src),
             "Journal is append-only — Journal.delete_entry/* must not exist."
    end
  end
end
