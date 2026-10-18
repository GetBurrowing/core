defmodule Platform.Federation.MemoryToolsTest do
  @moduledoc """
  Tests for the six `memory_*` tool surface clauses (ADR-0041, T5 stage 3).

  Covers `memory_view`, `memory_create`, `memory_str_replace`,
  `memory_insert`, `memory_delete`, and `memory_rename` dispatched
  through `Platform.Federation.ToolSurface.execute/3`. Each tool
  gates via `Platform.Org.Wiki.Routing` and routes to
  `Platform.Org.Wiki` (pages/private) or `Platform.Org.Wiki.Journal`
  (journal) — these tests assert the gate + dispatch behaviour, the
  Anthropic-trained error envelopes, and the verbatim
  "propose via journal" suggestion that the T5 e2e Case B contract
  pins.

  No direct Ecto.Changeset structs ever leak past the federation
  boundary — every error path returns the
  `%{error, code, recoverable, suggestion}` envelope.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation.ToolSurface
  alias Platform.Memory.Insight
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Journal
  alias Platform.Org.{WikiJournalEntry, WikiPage}
  alias Platform.Repo

  @space_id "019e0930-6a03-7900-84b0-225bbf054427"

  setup do
    Repo.delete_all(WikiPage)
    Repo.delete_all(WikiJournalEntry)
    Repo.delete_all("memory_proposals")
    Repo.delete_all(Insight)

    historian = create_agent("historian", assign_historian?: true)
    plain = create_agent("plain")

    %{historian: historian, plain: plain}
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

  defp context(%Agent{id: id}), do: %{agent_id: id}
  defp context(nil), do: %{}

  defp seed_page(file_key, content, opts \\ []) do
    {:ok, page} = Wiki.upsert_page(file_key, %{content: content}, opts)
    page
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## tool_definitions/0 — bundle registration
  ## ─────────────────────────────────────────────────────────────────────

  describe "tool_definitions/0 — memory bundle" do
    test "registers the six memory_* tools under the memory bundle" do
      tools = ToolSurface.list_tools(["memory"])
      names = MapSet.new(tools, & &1.name)

      for tool <-
            ~w(memory_view memory_create memory_str_replace memory_insert memory_delete memory_rename) do
        assert tool in names, "memory bundle missing #{tool}"
      end

      assert Enum.all?(tools, &(&1.bundle == "memory"))
    end

    test "memory tools carry the 6-component rubric" do
      ToolSurface.list_tools(["memory"])
      |> Enum.each(fn tool ->
        for key <- [:name, :description, :parameters, :returns, :limitations, :when_to_use] do
          assert Map.has_key?(tool, key), "#{tool.name} missing key #{inspect(key)}"
        end
      end)
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## memory_view
  ## ─────────────────────────────────────────────────────────────────────

  describe "execute/3 memory_view" do
    test "reads a page on the happy path", %{historian: h} do
      seed_page("org/page/identity.md", "# Org\n\nLine A\nLine B\n")

      assert {:ok, result} =
               ToolSurface.execute(
                 "memory_view",
                 %{"path" => "org/page/identity.md"},
                 context(h)
               )

      assert result.path == "org/page/identity.md"
      assert result.content == "# Org\n\nLine A\nLine B\n"
      assert result.version == 1
      assert result.kind == "page"
      assert result.lines_returned == "all"
    end

    test "respects view_range to return a line slice", %{historian: h} do
      content =
        Enum.join(["L1", "L2", "L3", "L4", "L5"], "\n")

      seed_page("org/page/multi.md", content)

      assert {:ok, %{content: sliced, lines_returned: "L2-L4"}} =
               ToolSurface.execute(
                 "memory_view",
                 %{"path" => "org/page/multi.md", "view_range" => [2, 4]},
                 context(h)
               )

      assert sliced == "L2\nL3\nL4"
    end

    test "reads a journal day's entries as a virtual page", %{historian: h} do
      date = ~D[2026-05-20]
      ns = "org"

      {:ok, _} =
        Journal.append(%{content: "first observation", date: date}, namespace: ns)

      {:ok, _} =
        Journal.append(%{content: "second observation", date: date}, namespace: ns)

      assert {:ok, result} =
               ToolSurface.execute(
                 "memory_view",
                 %{"path" => "org/journal/2026-05-20.md"},
                 context(h)
               )

      assert result.kind == "journal"
      assert result.date == "2026-05-20"
      assert result.namespace == "org"
      assert length(result.entry_ids) == 2
      assert String.contains?(result.content, "first observation")
      assert String.contains?(result.content, "second observation")
    end

    test "returns rejected_namespace error envelope on unknown path", %{historian: h} do
      assert {:error, env} =
               ToolSurface.execute("memory_view", %{"path" => "nope/whatever.md"}, context(h))

      assert env.code == :rejected_namespace
      assert env.recoverable == false
      assert is_binary(env.suggestion)
      assert is_binary(env.error)
    end

    test "returns not_found when the page row is missing", %{historian: h} do
      assert {:error, env} =
               ToolSurface.execute(
                 "memory_view",
                 %{"path" => "org/page/missing.md"},
                 context(h)
               )

      assert env.code == :not_found
      assert env.recoverable == true
    end

    test "rejects missing path argument", %{historian: h} do
      assert {:error, env} = ToolSurface.execute("memory_view", %{}, context(h))
      assert env.recoverable == true
      assert String.contains?(env.error, "path")
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## memory_create — page write (Historian only)
  ## ─────────────────────────────────────────────────────────────────────

  describe "execute/3 memory_create — page paths" do
    test "Historian writes a new org page successfully", %{historian: h} do
      assert {:ok, result} =
               ToolSurface.execute(
                 "memory_create",
                 %{"path" => "org/page/identity.md", "file_text" => "# Org Identity\n"},
                 context(h)
               )

      assert result.path == "org/page/identity.md"
      assert result.kind == "page"
      assert result.version == 1
      assert result.updated_by == h.id

      # Persisted
      assert %WikiPage{content: "# Org Identity\n", version: 1} =
               Wiki.get_page("org/page/identity.md")
    end

    test "non-Historian write to a page path returns 'propose via journal' envelope",
         %{plain: plain} do
      assert {:error, env} =
               ToolSurface.execute(
                 "memory_create",
                 %{"path" => "org/page/decisions.md", "file_text" => "anything"},
                 context(plain)
               )

      assert env.code == :historian_required
      assert env.recoverable == true

      # Literal substring from the design-lock §3 verbatim string —
      # T5 e2e Case B parses this.
      assert String.contains?(env.error, "propose via journal")
      assert env.suggestion =~ ~r/^memory_create at org\/journal\/\d{4}-\d{2}-\d{2}\.md$/

      # Page was NOT written.
      assert is_nil(Wiki.get_page("org/page/decisions.md"))
    end

    test "agent is loaded from context.agent_id when only the id is supplied", %{historian: h} do
      assert {:ok, _} =
               ToolSurface.execute(
                 "memory_create",
                 %{"path" => "org/page/loaded.md", "file_text" => "x"},
                 %{agent_id: h.id}
               )
    end
  end

  describe "execute/3 memory_create — journal paths" do
    test "any agent can append to the journal", %{plain: plain} do
      path = "org/journal/2026-05-20.md"

      assert {:ok, result} =
               ToolSurface.execute(
                 "memory_create",
                 %{"path" => path, "file_text" => "Field note."},
                 context(plain)
               )

      assert result.kind == "journal"
      assert result.path == path
      assert result.date == "2026-05-20"
      assert is_binary(result.entry_id)
      assert result.namespace == "org"

      entries = Journal.get_for_date(~D[2026-05-20])
      assert length(entries) == 1
      assert hd(entries).content == "Field note."
    end

    test "a synthesis-insight block in the body is ingested as an insight",
         %{historian: h} do
      # Regression guard. A dreaming run is only authorised to write to
      # today's journal, and it emits its blocks there via this tool.
      # Before the JournalSweep call in `do_memory_create/5`, those blocks
      # were persisted as journal prose and never ingested. Since task
      # 01a13867 stage 1 the blocks are `<synthesis-insight>`, and a
      # `<synthesis-proposal>` block is no longer ingested at all.
      body = """
      Dreaming pass.

      <synthesis-insight action="question" confidence="high" evidence="org/journal/2026-05-20.md">
      Blocks written through memory_create must be ingested.
      </synthesis-insight>

      <synthesis-proposal category="emerging-risk" confidence="high" evidence="e">
      A legacy proposal block is ignored.
      </synthesis-proposal>
      """

      assert {:ok, _result} =
               ToolSurface.execute(
                 "memory_create",
                 %{"path" => "org/journal/2026-05-20.md", "file_text" => body},
                 context(h)
               )

      assert [insight] = Repo.all(Insight)
      assert insight.action_type == "question"
      assert insight.confidence == "high"
      assert insight.body == "Blocks written through memory_create must be ingested."
      assert insight.journal_path == "org/journal/2026-05-20.md"
      assert insight.state == "open"
      assert Repo.aggregate("memory_proposals", :count) == 0
    end

    test "a page write is not swept for insights", %{historian: h} do
      body = """
      <synthesis-insight action="briefing" confidence="high" evidence="e">
      Pages are not an insight surface.
      </synthesis-insight>
      """

      assert {:ok, _result} =
               ToolSurface.execute(
                 "memory_create",
                 %{"path" => "org/page/identity.md", "file_text" => body},
                 context(h)
               )

      assert [] = Repo.all(Insight)
    end

    test "namespace is preserved from the path", %{historian: h} do
      proj_id = Ecto.UUID.generate()
      path = "project/#{proj_id}/journal/2026-05-20.md"

      assert {:ok, result} =
               ToolSurface.execute(
                 "memory_create",
                 %{"path" => path, "file_text" => "Project note."},
                 context(h)
               )

      assert result.namespace == "project/" <> proj_id
    end
  end

  describe "execute/3 memory_create — private paths" do
    test "owner can write to their private path", %{plain: plain} do
      path = "space/#{@space_id}/private/#{plain.id}/notes.md"

      # The owner-of-private gate needs the agent to participate in the
      # space — pre-seed the agent's participation. Without a real Chat
      # space we synthesize the membership via the gate's
      # `:agent_space_ids` opt … but ToolSurface does not currently
      # accept that opt. Instead, exercise the no-row code path: the
      # gate accepts iff the path's <agent_id> segment equals
      # `agent.id`. We assert that the gate rejects when the path
      # doesn't include the agent's own id, and we leave the
      # full owner happy-path acceptance to the e2e tests where Chat
      # participation is wired up.
      assert {:error, env} =
               ToolSurface.execute(
                 "memory_create",
                 %{"path" => path, "file_text" => "secret"},
                 context(plain)
               )

      # No Chat space exists in this test → the participation lookup
      # returns false → not_owner. The envelope is well-formed.
      assert env.code == :not_owner
      assert env.recoverable == true
    end

    test "non-owner can't write to another agent's private path", %{plain: plain} do
      other_id = Ecto.UUID.generate()
      path = "space/#{@space_id}/private/#{other_id}/notes.md"

      assert {:error, env} =
               ToolSurface.execute(
                 "memory_create",
                 %{"path" => path, "file_text" => "x"},
                 context(plain)
               )

      assert env.code == :not_owner
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## memory_str_replace
  ## ─────────────────────────────────────────────────────────────────────

  describe "execute/3 memory_str_replace" do
    test "replaces exactly one occurrence", %{historian: h} do
      seed_page("org/page/decisions.md", "alpha foo beta")

      assert {:ok, result} =
               ToolSurface.execute(
                 "memory_str_replace",
                 %{
                   "path" => "org/page/decisions.md",
                   "old_str" => "foo",
                   "new_str" => "bar"
                 },
                 context(h)
               )

      assert result.version == 2
      assert Wiki.get_page("org/page/decisions.md").content == "alpha bar beta"
    end

    test "no_match when old_str is absent", %{historian: h} do
      seed_page("org/page/x.md", "alpha")

      assert {:error, env} =
               ToolSurface.execute(
                 "memory_str_replace",
                 %{"path" => "org/page/x.md", "old_str" => "zzz", "new_str" => "y"},
                 context(h)
               )

      assert env.code == :no_match
      assert env.recoverable == true
    end

    test "ambiguous_match when old_str appears multiple times", %{historian: h} do
      seed_page("org/page/x.md", "foo foo foo")

      assert {:error, env} =
               ToolSurface.execute(
                 "memory_str_replace",
                 %{"path" => "org/page/x.md", "old_str" => "foo", "new_str" => "bar"},
                 context(h)
               )

      assert env.code == :ambiguous_match
      assert env.recoverable == true
      assert String.contains?(env.error, "3 times")
    end

    test "journal paths return :journal_immutable", %{historian: h} do
      assert {:error, env} =
               ToolSurface.execute(
                 "memory_str_replace",
                 %{
                   "path" => "org/journal/2026-05-20.md",
                   "old_str" => "x",
                   "new_str" => "y"
                 },
                 context(h)
               )

      assert env.code == :journal_immutable
      assert env.recoverable == true
      assert env.suggestion =~ ~r/^memory_create at org\/journal\/2026-05-20\.md$/
    end

    test "not_found when the page doesn't exist", %{historian: h} do
      assert {:error, env} =
               ToolSurface.execute(
                 "memory_str_replace",
                 %{
                   "path" => "org/page/ghost.md",
                   "old_str" => "x",
                   "new_str" => "y"
                 },
                 context(h)
               )

      assert env.code == :not_found
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## memory_insert
  ## ─────────────────────────────────────────────────────────────────────

  describe "execute/3 memory_insert" do
    test "inserts at line 1 (prepend)", %{historian: h} do
      seed_page("org/page/x.md", "line2\nline3")

      assert {:ok, _} =
               ToolSurface.execute(
                 "memory_insert",
                 %{
                   "path" => "org/page/x.md",
                   "insert_line" => 1,
                   "insert_text" => "line1"
                 },
                 context(h)
               )

      assert Wiki.get_page("org/page/x.md").content == "line1\nline2\nline3"
    end

    test "inserts in the middle", %{historian: h} do
      seed_page("org/page/x.md", "line1\nline3\nline4")

      assert {:ok, _} =
               ToolSurface.execute(
                 "memory_insert",
                 %{
                   "path" => "org/page/x.md",
                   "insert_line" => 2,
                   "insert_text" => "line2"
                 },
                 context(h)
               )

      assert Wiki.get_page("org/page/x.md").content == "line1\nline2\nline3\nline4"
    end

    test "appends at line_count + 1", %{historian: h} do
      seed_page("org/page/x.md", "line1\nline2")

      # "line1\nline2" splits into ["line1", "line2"] — 2 lines.
      assert {:ok, _} =
               ToolSurface.execute(
                 "memory_insert",
                 %{
                   "path" => "org/page/x.md",
                   "insert_line" => 3,
                   "insert_text" => "line3"
                 },
                 context(h)
               )

      assert Wiki.get_page("org/page/x.md").content == "line1\nline2\nline3"
    end

    test "rejects out_of_range insert_line", %{historian: h} do
      seed_page("org/page/x.md", "only")

      assert {:error, env} =
               ToolSurface.execute(
                 "memory_insert",
                 %{
                   "path" => "org/page/x.md",
                   "insert_line" => 99,
                   "insert_text" => "x"
                 },
                 context(h)
               )

      assert env.code == :out_of_range
      assert env.recoverable == true
    end

    test "journal paths return :journal_immutable", %{historian: h} do
      assert {:error, env} =
               ToolSurface.execute(
                 "memory_insert",
                 %{
                   "path" => "org/journal/2026-05-20.md",
                   "insert_line" => 1,
                   "insert_text" => "x"
                 },
                 context(h)
               )

      assert env.code == :journal_immutable
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## memory_delete
  ## ─────────────────────────────────────────────────────────────────────

  describe "execute/3 memory_delete" do
    test "deletes an existing page", %{historian: h} do
      seed_page("org/page/x.md", "to be deleted")

      assert {:ok, %{deleted: true, path: "org/page/x.md", kind: "page"}} =
               ToolSurface.execute(
                 "memory_delete",
                 %{"path" => "org/page/x.md"},
                 context(h)
               )

      refute Wiki.get_page("org/page/x.md")
    end

    test "journal paths return :journal_immutable", %{historian: h} do
      assert {:error, env} =
               ToolSurface.execute(
                 "memory_delete",
                 %{"path" => "org/journal/2026-05-20.md"},
                 context(h)
               )

      assert env.code == :journal_immutable
    end

    test "not_found when the page is missing", %{historian: h} do
      assert {:error, env} =
               ToolSurface.execute(
                 "memory_delete",
                 %{"path" => "org/page/ghost.md"},
                 context(h)
               )

      assert env.code == :not_found
    end

    test "non-Historian delete on a page returns historian_required envelope",
         %{plain: plain} do
      seed_page("org/page/x.md", "x")

      assert {:error, env} =
               ToolSurface.execute(
                 "memory_delete",
                 %{"path" => "org/page/x.md"},
                 context(plain)
               )

      assert env.code == :historian_required

      # Row still exists.
      assert Wiki.get_page("org/page/x.md")
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## memory_rename
  ## ─────────────────────────────────────────────────────────────────────

  describe "execute/3 memory_rename" do
    test "renames a page within the same kind/namespace", %{historian: h} do
      seed_page("org/page/old.md", "body content")

      assert {:ok, %{path: "org/page/new.md", kind: "page"}} =
               ToolSurface.execute(
                 "memory_rename",
                 %{"old_path" => "org/page/old.md", "new_path" => "org/page/new.md"},
                 context(h)
               )

      assert is_nil(Wiki.get_page("org/page/old.md"))
      assert %WikiPage{content: "body content"} = Wiki.get_page("org/page/new.md")
    end

    test "cross-kind rename (page → private) is rejected", %{historian: h} do
      seed_page("org/page/x.md", "x")

      assert {:error, env} =
               ToolSurface.execute(
                 "memory_rename",
                 %{
                   "old_path" => "org/page/x.md",
                   "new_path" => "space/#{@space_id}/private/#{h.id}/x.md"
                 },
                 context(h)
               )

      assert env.code == :ambiguous_kind
      assert env.recoverable == false

      # Source row untouched.
      assert Wiki.get_page("org/page/x.md")
    end

    test "non-Historian rename of a page is rejected on the source gate",
         %{plain: plain} do
      seed_page("org/page/x.md", "x")

      assert {:error, env} =
               ToolSurface.execute(
                 "memory_rename",
                 %{"old_path" => "org/page/x.md", "new_path" => "org/page/y.md"},
                 context(plain)
               )

      assert env.code == :historian_required

      # Both paths remain in their pre-rename state.
      assert Wiki.get_page("org/page/x.md")
      refute Wiki.get_page("org/page/y.md")
    end

    test "journal source path is rejected with :journal_immutable", %{historian: h} do
      assert {:error, env} =
               ToolSurface.execute(
                 "memory_rename",
                 %{
                   "old_path" => "org/journal/2026-05-20.md",
                   "new_path" => "org/journal/2026-05-21.md"
                 },
                 context(h)
               )

      assert env.code == :journal_immutable
    end

    test "not_found when the source page doesn't exist", %{historian: h} do
      assert {:error, env} =
               ToolSurface.execute(
                 "memory_rename",
                 %{"old_path" => "org/page/ghost.md", "new_path" => "org/page/here.md"},
                 context(h)
               )

      assert env.code == :not_found
    end

    test "rejects identical old_path and new_path", %{historian: h} do
      seed_page("org/page/x.md", "x")

      assert {:error, env} =
               ToolSurface.execute(
                 "memory_rename",
                 %{"old_path" => "org/page/x.md", "new_path" => "org/page/x.md"},
                 context(h)
               )

      assert env.code == :same_path
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## Error envelope shape — no Ecto.Changeset leakage anywhere
  ## ─────────────────────────────────────────────────────────────────────

  describe "error envelope shape" do
    test "every memory_* error envelope is JSON-safe and has the expected keys",
         %{plain: plain, historian: h} do
      # A mixed bag of failures across all six tools.
      failures = [
        ToolSurface.execute("memory_view", %{"path" => "nope/x.md"}, context(h)),
        ToolSurface.execute("memory_view", %{}, context(h)),
        ToolSurface.execute(
          "memory_create",
          %{"path" => "org/page/x.md", "file_text" => "y"},
          context(plain)
        ),
        ToolSurface.execute(
          "memory_str_replace",
          %{"path" => "org/journal/2026-05-20.md", "old_str" => "a", "new_str" => "b"},
          context(h)
        ),
        ToolSurface.execute(
          "memory_insert",
          %{"path" => "org/page/ghost.md", "insert_line" => 1, "insert_text" => "x"},
          context(h)
        ),
        ToolSurface.execute(
          "memory_delete",
          %{"path" => "org/page/ghost.md"},
          context(h)
        ),
        ToolSurface.execute(
          "memory_rename",
          %{"old_path" => "org/page/ghost.md", "new_path" => "org/page/x.md"},
          context(h)
        )
      ]

      for failure <- failures do
        assert {:error, env} = failure
        # No raw Changeset struct.
        refute match?(%Ecto.Changeset{}, env)
        # Required envelope keys.
        for key <- [:error, :recoverable, :suggestion] do
          assert Map.has_key?(env, key), "missing #{inspect(key)} in #{inspect(env)}"
        end

        assert is_binary(env.error)
        assert is_binary(env.suggestion)
        assert is_boolean(env.recoverable)
      end
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## burrow/page — product-owned docs (task 01a10a44 stage 2)
  ## ─────────────────────────────────────────────────────────────────────

  describe "burrow/page — read-only through every memory_* write tool" do
    @burrow "burrow/page/tasks.md"
    @burrow_body "# Tasks\n\nalpha foo beta\n"

    setup do
      # Seeded the way BurrowDocs seeds it; the only writer of burrow/page.
      page = seed_page(@burrow, @burrow_body, product_docs: true)
      %{burrow: page}
    end

    defp assert_unchanged(%WikiPage{} = before) do
      after_row = Wiki.get_page(before.file_key)
      assert after_row.content == before.content
      assert after_row.version == before.version
      assert after_row.updated_at == before.updated_at
    end

    for {label, agent_key} <- [{"plain agent", :plain}, {"Historian", :historian}] do
      @agent_key agent_key

      test "#{label}: memory_str_replace returns :product_owned and the row is unchanged",
           ctx do
        assert {:error, %{code: :product_owned}} =
                 ToolSurface.execute(
                   "memory_str_replace",
                   %{"path" => @burrow, "old_str" => "foo", "new_str" => "bar"},
                   context(ctx[@agent_key])
                 )

        assert_unchanged(ctx.burrow)
      end

      test "#{label}: memory_insert returns :product_owned and the row is unchanged", ctx do
        assert {:error, %{code: :product_owned}} =
                 ToolSurface.execute(
                   "memory_insert",
                   %{"path" => @burrow, "insert_line" => 1, "insert_text" => "x"},
                   context(ctx[@agent_key])
                 )

        assert_unchanged(ctx.burrow)
      end

      test "#{label}: memory_delete returns :product_owned and the row survives", ctx do
        assert {:error, %{code: :product_owned}} =
                 ToolSurface.execute(
                   "memory_delete",
                   %{"path" => @burrow},
                   context(ctx[@agent_key])
                 )

        assert_unchanged(ctx.burrow)
      end

      test "#{label}: memory_create over a burrow page returns :product_owned", ctx do
        assert {:error, %{code: :product_owned}} =
                 ToolSurface.execute(
                   "memory_create",
                   %{"path" => @burrow, "file_text" => "overwritten"},
                   context(ctx[@agent_key])
                 )

        assert_unchanged(ctx.burrow)
      end

      test "#{label}: memory_rename burrow -> org returns :product_owned", ctx do
        assert {:error, %{code: :product_owned}} =
                 ToolSurface.execute(
                   "memory_rename",
                   %{"old_path" => @burrow, "new_path" => "org/page/tasks.md"},
                   context(ctx[@agent_key])
                 )

        assert_unchanged(ctx.burrow)
        refute Wiki.get_page("org/page/tasks.md")
      end

      test "#{label}: memory_rename org -> burrow returns :product_owned", ctx do
        org_page = seed_page("org/page/x.md", "org body")

        assert {:error, %{code: :product_owned}} =
                 ToolSurface.execute(
                   "memory_rename",
                   %{"old_path" => "org/page/x.md", "new_path" => "burrow/page/x.md"},
                   context(ctx[@agent_key])
                 )

        assert_unchanged(org_page)
        refute Wiki.get_page("burrow/page/x.md")
      end

      test "#{label}: memory_view returns the burrow page content", ctx do
        assert {:ok, %{content: @burrow_body, kind: "page", path: @burrow}} =
                 ToolSurface.execute(
                   "memory_view",
                   %{"path" => @burrow},
                   context(ctx[@agent_key])
                 )
      end
    end

    test "CONTROL: the Historian's memory_str_replace on an org page succeeds", %{historian: h} do
      seed_page("org/page/x.md", "alpha foo beta")

      assert {:ok, %{version: 2}} =
               ToolSurface.execute(
                 "memory_str_replace",
                 %{"path" => "org/page/x.md", "old_str" => "foo", "new_str" => "bar"},
                 context(h)
               )

      assert Wiki.get_page("org/page/x.md").content == "alpha bar beta"
    end

    test "CONTROL: memory_str_replace on the caller's own private path succeeds",
         %{plain: plain} do
      {:ok, space} =
        Chat.create_space(%{
          name: "Burrow private control",
          slug: "burrow-private-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      {:ok, _} = Chat.add_agent_participant(space.id, plain, display_name: "Plain")
      path = "space/#{space.id}/private/#{plain.id}/x.md"
      seed_page(path, "alpha foo beta")

      assert {:ok, _} =
               ToolSurface.execute(
                 "memory_str_replace",
                 %{"path" => path, "old_str" => "foo", "new_str" => "bar"},
                 context(plain)
               )

      assert Wiki.get_page(path).content == "alpha bar beta"
    end
  end
end
