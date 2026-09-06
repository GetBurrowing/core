defmodule Platform.Chat.CanvasSearchTest do
  @moduledoc """
  Task `01a07402` stage 4: `Platform.Chat.search_canvases/3`.

  Every fixture here is built to be DISCRIMINATING — the correct
  implementation and the plausible bug produce different output. The two that
  matter most:

    * the ranking fixture puts the *newer* canvas on the *body* side, so
      `order_by: updated_at` cannot pass it; and
    * the unindexed fixture has no `chat_canvas_search` row at all, so an
      INNER join cannot pass it.

  Both were confirmed by mutation: flipping `left_join` to `join`, and
  replacing the rank ordering with `c.updated_at`, each turn exactly the
  matching test red.
  """

  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Chat.CanvasSearchIndex
  alias Platform.Repo

  setup do
    Application.put_env(:platform, :canvas_persist_sync, true)
    on_exit(fn -> Application.put_env(:platform, :canvas_persist_sync, true) end)

    space = new_space()

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: "Search Author",
        joined_at: DateTime.utc_now()
      })

    %{space: space, participant: participant}
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp new_space do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "CS #{n}", slug: "cs-#{n}", kind: "channel"})

    space
  end

  # A minimal valid canonical document carrying `body` as its only text.
  defp text_doc(body) do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 12},
        "children" => [
          %{"id" => "t1", "type" => "text", "props" => %{"value" => body}, "children" => []}
        ]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }
  end

  defp canvas(space, participant, title, body) do
    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => participant.id,
        "title" => title,
        "document" => text_doc(body)
      })

    canvas
  end

  defp ids(hits), do: Enum.map(hits, & &1.canvas.id)

  defp hit_for(hits, %Canvas{id: id}), do: Enum.find(hits, &(&1.canvas.id == id))

  # ── ranking ──────────────────────────────────────────────────────────────

  describe "ranking" do
    test "a TITLE match outranks a BODY match even when the body row is newer",
         %{space: s, participant: p} do
      titled = canvas(s, p, "Zorbling Quimbat Review", "nothing relevant in this body at all")

      # Created AFTER, and touched again after that, so `updated_at` desc alone
      # would put this row FIRST. Only real ranking can put `titled` first.
      bodied = canvas(s, p, "Unrelated Notes", "a paragraph mentioning zorbling once")

      {:ok, bodied} =
        Chat.update_canvas(:system, bodied, %{
          "document" => text_doc("a paragraph mentioning zorbling once")
        })

      assert DateTime.compare(bodied.updated_at, titled.updated_at) == :gt

      hits = Chat.search_canvases([s.id], "zorbling")

      assert ids(hits) == [titled.id, bodied.id]
    end

    test "the measured weights are B=0.4 for a title hit and D=0.1 for a body hit",
         %{space: s, participant: p} do
      titled = canvas(s, p, "Frimsy Toadlark Review", "nothing relevant here")
      bodied = canvas(s, p, "Unrelated Notes", "one mention of frimsy in the prose")

      hits = Chat.search_canvases([s.id], "frimsy")

      # Pinned as NUMBERS, not as an ordering. The whole reason stage 2 chose
      # weight D for the body was to get title-beats-body out of Postgres'
      # default `{D,C,B,A} = {0.1, 0.2, 0.4, 1.0}` for free; if these drift,
      # the free ordering is gone and stage 2's choice needs revisiting rather
      # than a bespoke scoring factor being bolted on here.
      assert_in_delta hit_for(hits, titled).rank, 0.4, 0.0001
      assert_in_delta hit_for(hits, bodied).rank, 0.1, 0.0001
    end

    test "term frequency in the body DOES overtake a single title hit — measured, not assumed",
         %{space: s, participant: p} do
      titled = canvas(s, p, "Wumberton Ledger", "nothing relevant here")

      repeated =
        canvas(
          s,
          p,
          "Unrelated Notes",
          String.duplicate("wumberton reconciles nightly across every shard. ", 20)
        )

      hits = Chat.search_canvases([s.id], "wumberton")

      # `ts_rank_cd` defaults to `normalization = 0`, which SUMS cover
      # densities rather than dividing by document length. Weights B and D
      # order a single occurrence against a single occurrence; they do not
      # order one occurrence against twenty. Recorded so the boundary of the
      # "weights give it to us for free" claim is written down instead of
      # being discovered by a confused reader.
      assert hit_for(hits, repeated).rank > hit_for(hits, titled).rank
      assert ids(hits) == [repeated.id, titled.id]
    end
  end

  # ── match kind and snippet ───────────────────────────────────────────────

  describe "match kind and snippet" do
    test "a title hit reports title_matched? with no snippet; a body hit carries a marked one",
         %{space: s, participant: p} do
      titled = canvas(s, p, "Plinthwark Obelating Notes", "this body says nothing of interest")
      bodied = canvas(s, p, "Unrelated Notes", "the prose mentions plinthwark in passing")

      hits = Chat.search_canvases([s.id], "plinthwark")

      title_hit = hit_for(hits, titled)
      assert title_hit.title_matched?
      refute title_hit.body_matched?
      assert title_hit.snippet == nil

      body_hit = hit_for(hits, bodied)
      assert body_hit.body_matched?
      refute body_hit.title_matched?
      assert body_hit.snippet =~ "<mark>plinthwark</mark>"
    end

    test "when BOTH title and body match, the snippet is still nil",
         %{space: s, participant: p} do
      _both = canvas(s, p, "Grendlewick Review", "the body also discusses grendlewick at length")

      [hit] = Chat.search_canvases([s.id], "grendlewick")

      assert hit.title_matched?
      assert hit.body_matched?

      # The rule is `body_matched? and not title_matched?`, enforced in Elixir
      # after the query. This is the case that rule exists for: the headline
      # WOULD be non-empty here, and the caller must not be handed it.
      assert hit.snippet == nil
    end

    test "a fragment from the middle of the body is marked at both ends",
         %{space: s, participant: p} do
      body =
        "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi " <>
          "omicron rho sigma tau sopor upsilon phi chi psi omega one two three four " <>
          "five six seven eight nine ten eleven twelve"

      _mid = canvas(s, p, "Unrelated Notes", body)

      [hit] = Chat.search_canvases([s.id], "sopor")

      assert String.starts_with?(hit.snippet, "… ")
      assert String.ends_with?(hit.snippet, " …")
      assert hit.snippet =~ "<mark>sopor</mark>"
    end

    test "a fragment that starts at the top of the body gets NO leading ellipsis",
         %{space: s, participant: p} do
      body =
        "glissade opens this document immediately. alpha beta gamma delta epsilon " <>
          "zeta eta theta iota kappa lambda mu nu xi omicron rho sigma tau upsilon " <>
          "phi chi psi omega one two three four five"

      _top = canvas(s, p, "Unrelated Notes", body)

      [hit] = Chat.search_canvases([s.id], "glissade")

      refute String.starts_with?(hit.snippet, "…")
      assert String.starts_with?(hit.snippet, "<mark>glissade</mark>")
      # It does not reach the end of the body, so that end IS marked.
      assert String.ends_with?(hit.snippet, " …")
    end

    test "leading whitespace in the body does not fake a mid-document match",
         %{space: s, participant: p} do
      # `MarkdownExporter` preserves a text node's leading spaces, so
      # `body_text` here really does begin `"  quibbleton ..."` while
      # `ts_headline` — which drops leading non-token characters — returns a
      # fragment beginning `"quibbleton"`. A byte-exact prefix test would call
      # that a mid-document match and prepend an ellipsis that lies. The
      # comparison trims both sides for exactly this case.
      _padded = canvas(s, p, "Unrelated Notes", "  quibbleton opens this padded body")

      [hit] = Chat.search_canvases([s.id], "quibbleton")

      assert String.starts_with?(hit.snippet, "<mark>quibbleton</mark>")
      refute String.starts_with?(hit.snippet, "…")
      refute String.ends_with?(hit.snippet, "…")
    end

    test "a body short enough to be shown whole gets no ellipsis at either end",
         %{space: s, participant: p} do
      _whole = canvas(s, p, "Unrelated Notes", "toadlark sits alone here")

      [hit] = Chat.search_canvases([s.id], "toadlark")

      refute String.starts_with?(hit.snippet, "…")
      refute String.ends_with?(hit.snippet, "…")
      assert hit.snippet == "<mark>toadlark</mark> sits alone here"
    end
  end

  # ── soft delete ──────────────────────────────────────────────────────────

  describe "soft delete" do
    test "a soft-deleted canvas drops out and comes BACK when deleted_at is cleared",
         %{space: s, participant: p} do
      survivor = canvas(s, p, "Survivor", "both of these bodies mention quimbat clearly")
      doomed = canvas(s, p, "Doomed", "both of these bodies mention quimbat clearly")

      before_ids = ids(Chat.search_canvases([s.id], "quimbat"))
      assert survivor.id in before_ids
      assert doomed.id in before_ids

      {:ok, doomed} = Chat.delete_canvas(doomed)
      assert doomed.deleted_at

      after_ids = ids(Chat.search_canvases([s.id], "quimbat"))

      # Positive AND negative: "exactly one row" alone is satisfied vacuously.
      assert survivor.id in after_ids
      refute doomed.id in after_ids

      # Restoring proves the exclusion was the `deleted_at` filter and not a
      # lost or clobbered `chat_canvas_search` row.
      {:ok, _restored} =
        doomed
        |> Canvas.delete_changeset(%{deleted_at: nil})
        |> Repo.update()

      restored_ids = ids(Chat.search_canvases([s.id], "quimbat"))
      assert survivor.id in restored_ids
      assert doomed.id in restored_ids
    end
  end

  # ── the left join ────────────────────────────────────────────────────────

  describe "unindexed canvases" do
    test "a canvas with NO chat_canvas_search row is still returned on a TITLE match",
         %{space: s, participant: p} do
      canvas = canvas(s, p, "Obelating Ledger", "body text that mentions nothing searched for")

      # Title search has shipped since 019fb954-c848 and must keep working for
      # rows the 01a07402 backfill has not reached. Delete the index row to BE
      # such a row.
      {1, _} =
        Repo.delete_all(from(i in CanvasSearchIndex, where: i.canvas_id == ^canvas.id))

      refute Repo.get(CanvasSearchIndex, canvas.id)

      hits = Chat.search_canvases([s.id], "obelating")

      assert ids(hits) == [canvas.id]

      hit = hd(hits)
      assert hit.title_matched?
      refute hit.body_matched?
      assert hit.snippet == nil
    end
  end

  # ── space scope ──────────────────────────────────────────────────────────

  describe "space scope" do
    test "a matching canvas in a space outside space_ids is not returned",
         %{space: s, participant: p} do
      mine = canvas(s, p, "Mine", "this body mentions sopranino once")

      other = new_space()

      {:ok, other_p} =
        Chat.add_participant(other.id, %{
          participant_type: "agent",
          participant_id: Ecto.UUID.generate(),
          display_name: "Elsewhere",
          joined_at: DateTime.utc_now()
        })

      theirs = canvas(other, other_p, "Sopranino Elsewhere", "sopranino here too")

      hits = Chat.search_canvases([s.id], "sopranino")

      assert ids(hits) == [mine.id]
      refute theirs.id in ids(hits)

      # Both spaces together DO return both, so the exclusion above is the
      # scope filter and not the row simply being unfindable.
      both = ids(Chat.search_canvases([s.id, other.id], "sopranino"))
      assert mine.id in both
      assert theirs.id in both
    end
  end

  # ── the blank-query guard ────────────────────────────────────────────────

  describe "blank and non-binary queries" do
    setup %{space: s, participant: p} do
      _canvas = canvas(s, p, "Anything", "a body with words in it")
      :ok
    end

    test "an empty, whitespace-only or non-binary query returns [] without querying",
         %{space: s} do
      assert Chat.search_canvases([s.id], "") == []
      assert Chat.search_canvases([s.id], "   ") == []
      assert Chat.search_canvases([s.id], "\n\t ") == []
      assert Chat.search_canvases([s.id], nil) == []
      assert Chat.search_canvases([s.id], 42) == []
      assert Chat.search_canvases([s.id], %{}) == []
    end

    test "an empty space list returns [] too", %{} do
      assert Chat.search_canvases([], "anything") == []
    end
  end

  # ── limit ────────────────────────────────────────────────────────────────

  describe "limit" do
    test ":limit caps the result set and defaults to 25", %{space: s, participant: p} do
      for i <- 1..27 do
        canvas(s, p, "Limitcheck #{i}", "body #{i}")
      end

      assert length(Chat.search_canvases([s.id], "limitcheck")) == 25
      assert length(Chat.search_canvases([s.id], "limitcheck", limit: 3)) == 3
    end
  end
end
