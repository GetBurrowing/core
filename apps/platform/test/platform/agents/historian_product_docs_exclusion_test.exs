defmodule Platform.Agents.HistorianProductDocsExclusionTest do
  @moduledoc """
  Burrow product docs (`burrow/page/*`) are not in any Historian corpus
  (task 01a10a44 stage 2). A deploy that changes a doc rewrites its row and
  bumps `updated_at`; without the exclusion, every release would feed
  product docs into a `pages` digest window and charge their bytes against
  the digest budget.

  `Wiki.exclude_product_docs/1` must be composed at EVERY `pages` site,
  the same list the card partition names in `Platform.Agents.Historian`'s
  moduledoc:

    * `ActivityDigest.corpus_items("pages", …)` (via
      `Wiki.list_pages_updated_since/2`)
    * `Historian.pending_bytes_in_range/3,4` and
      `Historian.pending_bytes_per_day/3,4` (`per_day_bytes_query/4`, both
      workspace variants)
    * `Historian.pending_bytes/1` (`sum_corpus_bytes/3`, both workspace
      variants)
    * `HistorianAudit.raw_row_count/3`

  Every assertion runs beside a control: an org page in the same window IS
  counted, so a zero here is the exclusion and not an empty window.
  """

  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.TenancyFixtures

  alias Platform.Agents.ActivityDigest
  alias Platform.Agents.Historian
  alias Platform.Agents.HistorianAudit
  alias Platform.Org.Wiki
  alias Platform.Org.WikiPage
  alias Platform.Repo

  # A quiet historical window, so the seeded rows are the only rows in it.
  @window_start ~U[2001-06-01 00:00:00.000000Z]
  @window_end ~U[2001-06-02 00:00:00.000000Z]
  @row_at ~U[2001-06-01 12:00:00.000000Z]

  defp seed!(file_key, content, opts \\ []) do
    {:ok, page} =
      Wiki.upsert_page(file_key, %{content: content, org_id: fabrikam_org_id()}, opts)

    {1, _} =
      Repo.update_all(from(p in WikiPage, where: p.id == ^page.id), set: [updated_at: @row_at])

    Repo.get!(WikiPage, page.id)
  end

  defp seed_burrow!(file_key, content, opts \\ []),
    do: seed!(file_key, content, [product_docs: true] ++ opts)

  describe "a burrow page updated inside the window" do
    test "is not counted at any org-scope pages site; an org page is (CONTROL)" do
      burrow = seed_burrow!("burrow/page/tasks.md", "BURROW product doc body")
      org = seed!("org/page/notes.md", "an org page")
      org_bytes = byte_size(org.content)

      ids = Enum.map(ActivityDigest.corpus_items("pages", @window_start, @window_end), & &1.id)
      assert org.id in ids
      refute burrow.id in ids

      assert Historian.pending_bytes_in_range("pages", @window_start, @window_end) == org_bytes

      assert Historian.pending_bytes_per_day("pages", @window_start, @window_end) == %{
               ~D[2001-06-01] => org_bytes
             }

      assert HistorianAudit.raw_row_count("pages", @window_start, @window_end) == 1
    end

    test "is not counted in pending_bytes/1 (sum_corpus_bytes, org scope)" do
      before = Historian.pending_bytes(nil)

      seed_burrow!("burrow/page/tasks.md", String.duplicate("b", 1000))
      assert Historian.pending_bytes(nil) == before

      # CONTROL: the same bytes on an org page move the signal.
      seed!("org/page/notes.md", String.duplicate("o", 1000))
      assert Historian.pending_bytes(nil) == before + 1000
    end

    test "is not counted at the workspace-scoped variants either" do
      ws = Ecto.UUID.generate()

      seed_burrow!("burrow/page/tasks.md", String.duplicate("b", 700), workspace_id: ws)
      assert Historian.pending_bytes(ws) == 0
      assert Historian.pending_bytes_in_range("pages", @window_start, @window_end, ws) == 0

      # CONTROL: an org page in the same workspace is.
      seed!("org/page/notes.md", String.duplicate("o", 300), workspace_id: ws)
      assert Historian.pending_bytes(ws) == 300
      assert Historian.pending_bytes_in_range("pages", @window_start, @window_end, ws) == 300

      assert Historian.pending_bytes_per_day("pages", @window_start, @window_end, ws) == %{
               ~D[2001-06-01] => 300
             }
    end

    test "is in neither pages nor files: the card partition is untouched" do
      burrow = seed_burrow!("burrow/page/tasks.md", "BURROW")

      files_ids =
        Enum.map(ActivityDigest.corpus_items("files", @window_start, @window_end), & &1.id)

      refute burrow.id in files_ids
      assert Historian.pending_bytes_in_range("files", @window_start, @window_end) == 0
    end
  end
end
