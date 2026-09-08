# Seed fixture for the canvas search snippet geometry guard (task 01a077e6).
#
# Creates ONE canvas in the `general` space whose BODY carries a distinctive
# nonsense phrase and whose TITLE does not. Both halves of that sentence are
# load-bearing:
#
#   BODY carries it       `Chat.search_canvases/3` only produces a snippet when
#                         the body matched. A title-only match returns
#                         `snippet: nil` and there is nothing to measure.
#
#   TITLE does NOT        `canvas_search_snippet/1` (chat.ex:2769-2773) returns
#                         nil whenever the title ALSO matched, by design. A
#                         fixture whose title contains the phrase renders a
#                         row with no snippet line at all, and every geometry
#                         assertion downstream would fail for the wrong reason.
#
#   NONSENSE phrase       "zorbling" is the word the Elixir drawer suite
#                         already uses, for the reason it records: the drawer's
#                         own copy and the chat fixtures share a lot of
#                         ordinary English, so a real word matches the
#                         empty-state text as readily as the row under test.
#
# The phrase sits 60 words into the paragraph and 48 words from its end. Both
# distances matter:
#
#   * at least 40 words in, so `ts_headline`'s fragment lands MID-DOCUMENT and
#     `Chat.ellipsised_headline/2` prepends "… " and appends " …" rather than
#     reporting the fragment as the document's opening or closing line;
#   * enough words on the leading side that the leading context run genuinely
#     OVERFLOWS at 375px. A run that never needed to clip is anchored at both
#     ends at once, so the end-anchoring case would pass on any implementation,
#     including the right-clipping one it exists to reject. The spec verifies
#     `scrollWidth > clientWidth` before asserting, and this text is what makes
#     that precondition true.
#
# Idempotent. A previous fixture canvas is SOFT-DELETED rather than reused or
# hard-deleted: `search_canvases/3` filters on `is_nil(c.deleted_at)`, so the
# search returns exactly one hit however many times this has been run, and no
# FK from `chat_canvas_search` or the versions table has to be unpicked.
#
# Run from apps/platform:
#   mix run priv/scripts/seed_canvas_search_snippet_fixture.exs
#
# Prints SPACE_SLUG and PHRASE on the last lines for the caller to capture.

import Ecto.Query

alias Platform.Chat
alias Platform.Chat.Canvas
alias Platform.Chat.CanvasSearchIndex
alias Platform.Repo

phrase = System.get_env("FIXTURE_PHRASE") || "zorbling"

title = "Release checklist for the archival step"

body =
  "The quarterly review process begins when a contributor submits their draft " <>
    "to the shared queue, where it waits for a reviewer to claim it, and every " <>
    "reviewer is expected to leave at least one substantive comment before " <>
    "approving, because a silent approval teaches the author nothing about what " <>
    "convinced anyone. After the second reviewer signs off the document moves " <>
    "into #{phrase}, the internal name for the archival step that stamps a " <>
    "permanent revision number onto the record and freezes its attachments, " <>
    "after which no further edits are accepted and any correction has to arrive " <>
    "as a new document that cites the frozen one by number and explains what " <>
    "changed."

if String.contains?(String.downcase(title), String.downcase(phrase)) do
  raise """
  The fixture title contains #{inspect(phrase)}. A title match suppresses the
  snippet by design (apps/platform/lib/platform/chat.ex:2769-2773), so this
  fixture would render a row with nothing to measure.
  """
end

space =
  Chat.get_space_by_slug("general") ||
    (fn ->
       {:ok, s} =
         Chat.create_space(%{
           name: "General",
           slug: "general",
           kind: "channel"
         })

       s
     end).()

# `chat_canvases.created_by` is an FK onto `chat_participants(id)`, not onto
# `users(id)` — the same trap `seed_canvas_chip_fixture.exs` records.
participant =
  Repo.one(
    from(p in Chat.Participant,
      where: p.space_id == ^space.id,
      order_by: [asc: p.joined_at],
      limit: 1
    )
  ) ||
    (fn ->
       {:ok, p} =
         Chat.add_participant(space.id, %{
           participant_type: "agent",
           participant_id: Ecto.UUID.generate(),
           display_name: "Snippet Fixture Author",
           joined_at: DateTime.utc_now()
         })

       p
     end).()

# Retire every earlier run's fixture. Soft deletion is what takes it out of
# `search_canvases/3`, which is what keeps the browser selector unambiguous —
# two live fixtures would put two `<mark>`s in the results list and the
# geometry helpers would (correctly) raise rather than measure one of them.
retired =
  Repo.all(from(c in Canvas, where: c.space_id == ^space.id and c.title == ^title))
  |> Enum.reject(&(&1.deleted_at != nil))
  |> Enum.map(fn canvas ->
    {:ok, c} =
      canvas
      |> Canvas.delete_changeset(%{deleted_at: DateTime.utc_now()})
      |> Repo.update()

    c.id
  end)

document = %{
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

{:ok, canvas} =
  Chat.create_canvas(%{
    "space_id" => space.id,
    "created_by" => participant.id,
    "title" => title,
    "document" => document
  })

# `create_canvas/1` writes the index row inside its own transaction
# (`CanvasSearchIndex.upsert_multi/3`). Asserted rather than assumed: a fixture
# that silently failed to index would make the search return nothing and every
# geometry assertion would fail on a missing row rather than on a real defect.
index = Repo.get(CanvasSearchIndex, canvas.id) || raise("fixture canvas was not indexed")

unless String.contains?(index.body_text, phrase) do
  raise """
  The indexed body_text does not contain #{inspect(phrase)}. Extraction goes
  through `Platform.Chat.Canvas.SearchText.extract/1`; a node kind it does not
  know renders in the UI and indexes as an empty string.

  Indexed text was: #{inspect(index.body_text)}
  """
end

# Prove the fixture through the READ PATH the drawer uses, not only through the
# rows written. A hit whose `snippet` is nil renders a row with no snippet
# element, and the browser spec would then fail on a missing selector rather
# than on geometry.
hit =
  Chat.search_canvases([space.id], phrase)
  |> Enum.find(&(&1.canvas.id == canvas.id)) ||
    raise("fixture canvas is not returned by Chat.search_canvases/3")

if is_nil(hit.snippet) do
  raise """
  The fixture matched but carries no snippet. That is the title-match
  suppression rule (chat.ex:2769-2773): title_matched?=#{inspect(hit.title_matched?)},
  body_matched?=#{inspect(hit.body_matched?)}.
  """
end

unless String.contains?(hit.snippet, "<mark>") do
  raise("fixture snippet carries no <mark> — nothing to measure: #{inspect(hit.snippet)}")
end

IO.puts("retired #{length(retired)} earlier fixture canvas(es)")
IO.puts("snippet: #{hit.snippet}")
IO.puts("CANVAS_ID=#{canvas.id}")
IO.puts("SPACE_SLUG=#{space.slug}")
IO.puts("PHRASE=#{phrase}")
