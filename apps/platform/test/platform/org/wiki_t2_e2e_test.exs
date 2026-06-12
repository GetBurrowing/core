defmodule Platform.Org.WikiT2E2ETest do
  @moduledoc """
  T2 task-level adversarial review (ADR-0041).

  Each scenario in this file maps 1:1 to an `e2e_behavior` validation
  on the plan (stage 5, plan `019e425a-c689-7a37-b5be-f838003ed5c7`).
  The planner-authored `actions` / `expected` / `setup` are reproduced
  literally in the test body so the validation can cite the test
  outcome as evidence.

  Cases:

    1. Happy path — frontmatter, two wikilinks (plain + aliased), alias
       fallback, link rows on disk, PubSub event.
    2. Edit-drops-link — A's outbound links change; link table reflects
       the new set; cross-page backlinks update correctly.
    3. Journal namespacing — two appends in `org`, one in `project/abc`;
       projections segregate them; `parse_virtual_path/1` round-trips.
    4. Workspace isolation — same `file_key` in two workspaces; alias
       fallback is workspace-scoped; backlinks never cross.
    5. Scope-creep guard — static check that T2's implementation
       contains no Memory / GenServer / memory-service references and
       that `Platform.Org.Context` was not modified vs T1 HEAD.
  """
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Journal
  alias Platform.Org.WikiJournalEntry
  alias Platform.Org.WikiPage
  alias Platform.Repo

  @sentinel "00000000-0000-0000-0000-000000000000"

  setup do
    Repo.delete_all(WikiPage)
    Repo.delete_all(WikiJournalEntry)
    Phoenix.PubSub.subscribe(Platform.PubSub, Wiki.index_topic())
    :ok
  end

  defp link_rows_for(page) do
    SQL.query!(
      Repo,
      "SELECT target_path, target_id, display_text, position FROM org_wiki_links WHERE source_id = $1 ORDER BY position",
      [Ecto.UUID.dump!(page.id)]
    )
    |> Map.fetch!(:rows)
    |> Enum.map(fn [path, id_bin, display, pos] ->
      %{
        target_path: path,
        target_id: if(is_nil(id_bin), do: nil, else: Ecto.UUID.load!(id_bin)),
        display_text: display,
        position: pos
      }
    end)
  end

  defp insert_alias(workspace_id, old_path, current_id) do
    ws_dumped = Ecto.UUID.dump!(workspace_id || @sentinel)

    SQL.query!(
      Repo,
      "INSERT INTO org_wiki_aliases (workspace_id, old_path, current_id, inserted_at) VALUES ($1, $2, $3, now()) ON CONFLICT (workspace_id, old_path) DO UPDATE SET current_id = EXCLUDED.current_id",
      [ws_dumped, old_path, Ecto.UUID.dump!(current_id)]
    )
  end

  # ── Case 1: happy path ────────────────────────────────────────────────

  test "Case 1 — happy path: frontmatter + wikilinks + alias + :index event" do
    body =
      "---\npreamble: true\nowner: alice\n---\n# Org\n\nSee [[org/values]] and [[org/memory|the memory page]]."

    assert {:ok, %WikiPage{} = page} = Wiki.upsert_page("org/identity.md", %{content: body})

    assert page.frontmatter == %{"preamble" => true, "owner" => "alice"}
    assert page.content == body
    assert page.version == 1

    rows = link_rows_for(page)

    assert [
             %{
               position: 0,
               target_path: "org/values",
               display_text: nil,
               target_id: nil
             },
             %{
               position: 1,
               target_path: "org/memory",
               display_text: "the memory page",
               target_id: nil
             }
           ] = rows

    assert [%WikiPage{file_key: "org/identity.md"}] = Wiki.backlinks("org/values")

    assert_receive {:wiki_page_written,
                    %{
                      page_id: page_id,
                      file_key: "org/identity.md",
                      version: 1,
                      workspace_id: nil
                    }}

    assert page_id == page.id

    # Alias resolution — the migration only seeds aliases for the
    # canonical lowercase paths; insert the org-scoped sentinel alias
    # explicitly to mirror what the migration does on a fresh DB.
    insert_alias(nil, "ORG_IDENTITY.md", page.id)
    assert %WikiPage{id: ^page_id} = Wiki.get_page("ORG_IDENTITY.md")
  end

  # ── Case 2: edit drops a link, adds a new unresolved target ──────────

  test "Case 2 — edit drops c.md link, adds unresolved d.md link" do
    {:ok, b} = Wiki.upsert_page("b.md", %{content: "B body"})
    {:ok, _c} = Wiki.upsert_page("c.md", %{content: "C body"})
    {:ok, _a_v1} = Wiki.upsert_page("a.md", %{content: "see [[b.md]] and [[c.md]]"})

    # Sanity: A links to b and c.
    assert ["b.md", "c.md"] =
             link_rows_for(Wiki.get_page("a.md")) |> Enum.map(& &1.target_path) |> Enum.sort()

    {:ok, a_v2} = Wiki.upsert_page("a.md", %{content: "see [[b.md]] and [[d.md]]"})

    assert a_v2.version == 2

    rows = link_rows_for(a_v2)

    assert length(rows) == 2

    by_path = Map.new(rows, fn r -> {r.target_path, r} end)
    assert by_path["b.md"].target_id == b.id
    assert by_path["d.md"].target_id == nil

    # Old link to c.md is hard-deleted, not soft.
    refute Map.has_key?(by_path, "c.md")

    # Backlink graph reflects new state.
    assert Wiki.backlinks("c.md") == []
    assert [%WikiPage{file_key: "a.md"}] = Wiki.backlinks("b.md")
    assert [%WikiPage{file_key: "a.md"}] = Wiki.backlinks("d.md")
  end

  # ── Case 3: journal namespacing + virtual paths ──────────────────────

  test "Case 3 — journal namespacing + virtual_page_for + parse_virtual_path" do
    {:ok, e1} = Journal.append(%{content: "first entry", date: ~D[2026-05-19]}, namespace: "org")
    {:ok, e2} = Journal.append(%{content: "second entry", date: ~D[2026-05-19]})

    {:ok, e3} =
      Journal.append(%{content: "project entry", date: ~D[2026-05-19]},
        namespace: "project/abc"
      )

    # Three PubSub messages.
    assert_receive {:wiki_journal_appended, %{entry_id: e1_id, namespace: "org"}}
    assert e1_id == e1.id

    assert_receive {:wiki_journal_appended, %{entry_id: e2_id, namespace: "org"}}
    assert e2_id == e2.id

    assert_receive {:wiki_journal_appended, %{entry_id: e3_id, namespace: "project/abc"}}
    assert e3_id == e3.id

    # Org-namespace projection.
    vp_org = Journal.virtual_page_for(~D[2026-05-19], namespace: "org")
    assert vp_org.file_key == "org/journal/2026-05-19.md"
    assert vp_org.content == "first entry\n\n---\n\nsecond entry"
    assert vp_org.entry_ids == [e1.id, e2.id]
    assert vp_org.namespace == "org"
    assert vp_org.date == ~D[2026-05-19]

    # Project-namespace projection.
    vp_project = Journal.virtual_page_for(~D[2026-05-19], namespace: "project/abc")
    assert vp_project.content == "project entry"
    assert vp_project.entry_ids == [e3.id]

    # Round-trip the virtual path.
    assert {:ok, %{namespace: "org", date: ~D[2026-05-19]}} =
             Journal.parse_virtual_path("org/journal/2026-05-19.md")
  end

  # ── Case 4: workspace isolation ──────────────────────────────────────

  test "Case 4 — workspace isolation: pages, backlinks, alias fallback" do
    ws_a = Ecto.UUID.generate()
    ws_b = Ecto.UUID.generate()

    {:ok, identity_a} =
      Wiki.upsert_page("org/identity.md", %{content: "A version with [[org/values]]"},
        workspace_id: ws_a
      )

    {:ok, identity_b} =
      Wiki.upsert_page("org/identity.md", %{content: "B version with [[org/agents]]"},
        workspace_id: ws_b
      )

    {:ok, _values_a} =
      Wiki.upsert_page("org/values", %{content: "values for A"}, workspace_id: ws_a)

    assert identity_a.id != identity_b.id

    assert Wiki.get_page("org/identity.md", workspace_id: ws_a).content ==
             "A version with [[org/values]]"

    assert Wiki.get_page("org/identity.md", workspace_id: ws_b).content ==
             "B version with [[org/agents]]"

    # Backlinks honour the workspace boundary.
    ws_a_backlinks = Wiki.backlinks("org/values", workspace_id: ws_a)
    ws_b_backlinks = Wiki.backlinks("org/values", workspace_id: ws_b)

    assert Enum.map(ws_a_backlinks, & &1.id) == [identity_a.id]
    assert ws_b_backlinks == []

    # Workspace-scoped alias fallback: insert per-workspace aliases
    # for `ORG_IDENTITY.md` and confirm each resolves to its own row.
    insert_alias(ws_a, "ORG_IDENTITY.md", identity_a.id)
    insert_alias(ws_b, "ORG_IDENTITY.md", identity_b.id)

    assert %WikiPage{id: id_a} = Wiki.get_page("ORG_IDENTITY.md", workspace_id: ws_a)
    assert %WikiPage{id: id_b} = Wiki.get_page("ORG_IDENTITY.md", workspace_id: ws_b)
    assert id_a == identity_a.id
    assert id_b == identity_b.id
  end

  # ── Case 5: scope-creep guard (static check) ─────────────────────────

  describe "Case 5 — scope-creep guard" do
    @t2_files [
      "lib/platform/org/wiki.ex",
      "lib/platform/org/wiki/journal.ex"
    ]

    @t2_test_files [
      "test/platform/org/wiki_test.exs",
      "test/platform/org/wiki_parser_test.exs",
      "test/platform/org/wiki_journal_test.exs",
      "test/platform/org/wiki_t2_e2e_test.exs"
    ]

    # Mix runs tests from `apps/platform`; T2 file paths are relative to
    # that. Resolve against `t2_root/0` (Mix project root) to stay
    # portable across containers and host runs.
    defp t2_root, do: Mix.Project.project_file() |> Path.dirname()
    defp read_t2(path), do: File.read!(Path.join(t2_root(), path))

    test "no call-site references to Platform.Memory.* in T2 implementation files" do
      # Match `Platform.Memory.<fn>(` and `alias Platform.Memory` —
      # actual call sites, not narrative mentions in `@moduledoc`
      # describing what is NOT in scope.
      call_pattern = ~r/Platform\.Memory\.[a-z_][\w!?]*\s*\(/
      alias_pattern = ~r/^\s*alias\s+Platform\.Memory(\.|$|\s|,)/m

      for path <- @t2_files do
        contents = read_t2(path)

        refute Regex.match?(call_pattern, contents),
               "T2 file #{path} contains a Platform.Memory.* call site — that's T3 territory."

        refute Regex.match?(alias_pattern, contents),
               "T2 file #{path} aliases Platform.Memory — T2 must not depend on it."
      end
    end

    test "no GenServer / Task.Supervisor / Phoenix.Channel etc. process scaffolding in T2 lib" do
      for path <- @t2_files do
        contents = read_t2(path)

        refute String.contains?(contents, "use GenServer"),
               "T2 file #{path} starts a GenServer — indexers are T3."

        refute String.contains?(contents, "Task.Supervisor.start_child"),
               "T2 file #{path} starts background tasks — indexers are T3."
      end
    end

    test "no HTTP client (Req / HTTPoison) calls in T2 lib — memory-service is T3" do
      for path <- @t2_files do
        contents = read_t2(path)

        refute Regex.match?(~r/Req\.(get|post|patch|delete|put|new)/, contents),
               "T2 file #{path} appears to make Req HTTP calls."

        refute String.contains?(contents, "HTTPoison"),
               "T2 file #{path} appears to use HTTPoison."
      end
    end

    test "Platform.Org.Context file content matches T1 HEAD by sha256" do
      # T1 HEAD (4d6d332) shipped this exact content. The hash is
      # captured at T2 stage 1 (verified by `git show 4d6d332:...`)
      # and embedded here as a runtime guard so the test stays
      # portable to environments without git (e.g. the test
      # container). If you legitimately need to change
      # `Platform.Org.Context` in a future task (e.g. T5 retirement),
      # update this constant in the same commit.
      contents = read_t2("lib/platform/org/context.ex")
      hash = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

      expected = Application.fetch_env!(:platform, :t2_context_sha256_t1_head)

      assert hash == expected,
             """
             Platform.Org.Context content drift vs T1 HEAD detected.
             Expected sha256: #{expected}
             Got sha256:      #{hash}
             T2 scope forbids modifying Org.Context (T5 retires it).
             """
    end

    test "PubSub topic name is `org_wiki:index` in both Wiki and Wiki.Journal" do
      assert Wiki.index_topic() == "org_wiki:index"
      assert Journal.index_topic() == "org_wiki:index"
    end

    test "both modules broadcast on the shared topic (smoke check via test setup subscription)" do
      # The setup/0 in this file subscribed to Wiki.index_topic(). The
      # following two operations should each deliver a message on that
      # subscription, confirming both modules broadcast on it.
      {:ok, _page} = Wiki.upsert_page("smoke.md", %{content: "x"})
      assert_receive {:wiki_page_written, %{file_key: "smoke.md"}}

      {:ok, _entry} = Journal.append(%{content: "x", date: ~D[2026-05-19]})
      assert_receive {:wiki_journal_appended, %{namespace: "org"}}
    end

    test "T2 test files exist where the plan placed them" do
      for path <- @t2_test_files do
        full = Path.join(t2_root(), path)
        assert File.exists?(full), "Missing expected T2 test file: #{path} (looked at #{full})"
      end
    end
  end
end
