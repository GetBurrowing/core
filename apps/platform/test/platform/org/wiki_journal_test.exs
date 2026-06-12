defmodule Platform.Org.WikiJournalTest do
  @moduledoc """
  Behaviour tests for `Platform.Org.Wiki.Journal` — append-only writes,
  date/namespace/workspace-scoped reads, virtual-page projection, and
  PubSub :index emission.
  """
  use Platform.DataCase, async: true

  alias Platform.Org.Wiki.Journal
  alias Platform.Org.WikiJournalEntry
  alias Platform.Repo

  setup do
    Repo.delete_all(WikiJournalEntry)
    Phoenix.PubSub.subscribe(Platform.PubSub, Journal.index_topic())
    :ok
  end

  # ── append/2 ────────────────────────────────────────────────────────

  describe "append/2" do
    test "inserts an entry with default namespace tagged into metadata" do
      assert {:ok, %WikiJournalEntry{} = e} =
               Journal.append(%{content: "first", date: ~D[2026-05-19]})

      assert e.content == "first"
      assert e.date == ~D[2026-05-19]
      assert get_in(e.metadata, ["namespace"]) == "org"
    end

    test "namespace from opts overrides the default" do
      assert {:ok, e} =
               Journal.append(%{content: "x", date: ~D[2026-05-19]},
                 namespace: "project/abc"
               )

      assert get_in(e.metadata, ["namespace"]) == "project/abc"
    end

    test "validation error when :content is missing" do
      assert {:error, %Ecto.Changeset{}} = Journal.append(%{date: ~D[2026-05-19]})
    end
  end

  # ── get_for_date/2 ──────────────────────────────────────────────────

  describe "get_for_date/2" do
    test "returns entries on that date in insertion order" do
      {:ok, _e1} = Journal.append(%{content: "first", date: ~D[2026-05-19]})
      {:ok, _e2} = Journal.append(%{content: "second", date: ~D[2026-05-19]})
      {:ok, _e3} = Journal.append(%{content: "other day", date: ~D[2026-05-18]})

      assert ["first", "second"] =
               Journal.get_for_date(~D[2026-05-19]) |> Enum.map(& &1.content)
    end

    test "namespace isolation" do
      {:ok, _} = Journal.append(%{content: "org-1", date: ~D[2026-05-19]})

      {:ok, _} =
        Journal.append(%{content: "project-1", date: ~D[2026-05-19]},
          namespace: "project/abc"
        )

      assert ["org-1"] = Journal.get_for_date(~D[2026-05-19]) |> Enum.map(& &1.content)

      assert ["project-1"] =
               Journal.get_for_date(~D[2026-05-19], namespace: "project/abc")
               |> Enum.map(& &1.content)
    end

    test "workspace isolation" do
      ws_a = Ecto.UUID.generate()
      ws_b = Ecto.UUID.generate()

      {:ok, _} =
        Journal.append(%{content: "in A", date: ~D[2026-05-19], workspace_id: ws_a})

      {:ok, _} =
        Journal.append(%{content: "in B", date: ~D[2026-05-19], workspace_id: ws_b})

      assert ["in A"] =
               Journal.get_for_date(~D[2026-05-19], workspace_id: ws_a)
               |> Enum.map(& &1.content)

      assert ["in B"] =
               Journal.get_for_date(~D[2026-05-19], workspace_id: ws_b)
               |> Enum.map(& &1.content)
    end
  end

  # ── virtual_page_for/2 ──────────────────────────────────────────────

  describe "virtual_page_for/2" do
    test "concatenates entries with the `\\n\\n---\\n\\n` separator" do
      {:ok, e1} = Journal.append(%{content: "a", date: ~D[2026-05-19]})
      {:ok, e2} = Journal.append(%{content: "b", date: ~D[2026-05-19]})
      {:ok, e3} = Journal.append(%{content: "c", date: ~D[2026-05-19]})

      vp = Journal.virtual_page_for(~D[2026-05-19])

      assert vp.file_key == "org/journal/2026-05-19.md"
      assert vp.content == "a\n\n---\n\nb\n\n---\n\nc"
      assert vp.entry_ids == [e1.id, e2.id, e3.id]
      assert vp.namespace == "org"
      assert vp.date == ~D[2026-05-19]
    end

    test "empty case returns empty content + empty entry_ids" do
      vp = Journal.virtual_page_for(~D[2026-05-19])
      assert vp.content == ""
      assert vp.entry_ids == []
    end

    test "project-namespaced entries are NOT included in the org projection" do
      {:ok, _} = Journal.append(%{content: "org-1", date: ~D[2026-05-19]})

      {:ok, _} =
        Journal.append(%{content: "project-1", date: ~D[2026-05-19]},
          namespace: "project/abc"
        )

      assert Journal.virtual_page_for(~D[2026-05-19]).content == "org-1"

      assert Journal.virtual_page_for(~D[2026-05-19], namespace: "project/abc").content ==
               "project-1"
    end
  end

  # ── parse_virtual_path/1 ────────────────────────────────────────────

  describe "parse_virtual_path/1" do
    test "happy path with org namespace" do
      assert {:ok, %{namespace: "org", date: ~D[2026-05-19]}} =
               Journal.parse_virtual_path("org/journal/2026-05-19.md")
    end

    test "multi-segment namespace (project/abc)" do
      assert {:ok, %{namespace: "project/abc", date: ~D[2026-05-19]}} =
               Journal.parse_virtual_path("project/abc/journal/2026-05-19.md")
    end

    test "missing date segment is :error" do
      assert :error = Journal.parse_virtual_path("org/journal/.md")
    end

    test "wrong extension is :error" do
      assert :error = Journal.parse_virtual_path("org/journal/2026-05-19.txt")
    end

    test "non-iso-date is :error" do
      assert :error = Journal.parse_virtual_path("org/journal/05-19-2026.md")
    end

    test "non-binary input is :error" do
      assert :error = Journal.parse_virtual_path(nil)
    end
  end

  # ── PubSub ──────────────────────────────────────────────────────────

  describe "PubSub :index events" do
    test "append emits :wiki_journal_appended" do
      {:ok, entry} =
        Journal.append(%{content: "x", date: ~D[2026-05-19]}, namespace: "org")

      assert_receive {:wiki_journal_appended,
                      %{
                        entry_id: entry_id,
                        date: ~D[2026-05-19],
                        workspace_id: nil,
                        namespace: "org"
                      }}

      assert entry_id == entry.id
    end
  end

  # ── list_recent/1 ───────────────────────────────────────────────────

  describe "list_recent/1" do
    test "default days_back returns all entries within window, newest first" do
      today = Date.utc_today()

      for i <- 0..9 do
        date = Date.add(today, -rem(i, 3))
        {:ok, _} = Journal.append(%{content: "e#{i}", date: date})
      end

      results = Journal.list_recent()
      assert length(results) == 10
      # Strictly non-increasing inserted_at
      ts = Enum.map(results, & &1.inserted_at)
      assert ts == Enum.sort(ts, {:desc, DateTime})
    end

    test "limit clamps the result set" do
      today = Date.utc_today()
      for i <- 0..9, do: Journal.append(%{content: "e#{i}", date: today})
      assert length(Journal.list_recent(limit: 5)) == 5
    end

    test "days_back excludes older entries" do
      today = Date.utc_today()
      yesterday = Date.add(today, -1)
      week_ago = Date.add(today, -7)

      {:ok, _} = Journal.append(%{content: "today", date: today})
      {:ok, _} = Journal.append(%{content: "yesterday", date: yesterday})
      {:ok, _} = Journal.append(%{content: "week", date: week_ago})

      contents =
        Journal.list_recent(days_back: 1) |> Enum.map(& &1.content) |> Enum.sort()

      assert contents == ["today", "yesterday"]
    end
  end
end
