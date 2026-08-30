defmodule Platform.Chat.CanvasListOrderTest do
  @moduledoc """
  `Chat.list_canvases/2` ordering (task 01a04e9a).

  The fixture is built so that creation order, update order and title order
  produce THREE DIFFERENT sequences. That is the whole point: a fixture whose
  natural order already matches the expected order cannot fail, so it would
  pass against the hardcoded `order_by: [asc: c.inserted_at]` this task
  replaced and prove nothing.

  Mutation check performed while writing: reverting `canvas_order/2` to a
  hardcoded `asc: c.inserted_at` turns `updated_desc` and `title_asc` red.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat

  setup do
    {:ok, space} =
      Chat.create_space(%{
        "name" => "Canvas order",
        "slug" => "canvas-order-#{System.unique_integer([:positive])}",
        "kind" => "channel"
      })

    # Creation order: zebra, apple, middle.
    # Titles sort:    apple, middle, zebra.
    # We then edit `zebra` LAST, so update order is: zebra, middle, apple.
    # All three sequences differ, which is what makes the assertions bite.
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: "Author",
        joined_at: DateTime.utc_now()
      })

    zebra = canvas!(space.id, "Zebra", participant.id)
    apple = canvas!(space.id, "apple", participant.id)
    middle = canvas!(space.id, "Middle", participant.id)

    touch!(middle)
    touch!(zebra)

    %{space: space, zebra: zebra, apple: apple, middle: middle}
  end

  defp canvas!(space_id, title, created_by) do
    {:ok, c} =
      Chat.create_canvas(%{
        "space_id" => space_id,
        "title" => title,
        "created_by" => created_by
      })

    # Distinct inserted_at values. Without this the rows can share a timestamp
    # and the "oldest first" assertion would pass on tiebreaker luck.
    Process.sleep(5)
    c
  end

  # A real document change, so `updated_at` moves for the reason the feature
  # claims it does — not a bare `Repo.update` with no changes, which Ecto may
  # skip entirely.
  defp touch!(canvas) do
    {:ok, updated} =
      canvas
      |> Ecto.Changeset.change(%{document: %{"revision" => System.unique_integer([:positive])}})
      |> Repo.update()

    Process.sleep(5)
    updated
  end

  defp titles(canvases), do: Enum.map(canvases, & &1.title)

  test "defaults to oldest-first, unchanged, for callers that pass no :order", %{space: space} do
    assert titles(Chat.list_canvases(space.id)) == ["Zebra", "apple", "Middle"]
  end

  test "updated_desc puts the most recently edited canvas first", %{space: space} do
    # zebra edited last, then middle; apple never edited.
    assert titles(Chat.list_canvases(space.id, order: :updated_desc)) ==
             ["Zebra", "Middle", "apple"]
  end

  test "inserted_desc is newest-created first", %{space: space} do
    assert titles(Chat.list_canvases(space.id, order: :inserted_desc)) ==
             ["Middle", "apple", "Zebra"]
  end

  test "title_asc is case-insensitive", %{space: space} do
    # The point of the lowercase fragment: a plain `asc: c.title` on Postgres's
    # default collation files "Zebra" and "Middle" before "apple".
    assert titles(Chat.list_canvases(space.id, order: :title_asc)) ==
             ["apple", "Middle", "Zebra"]
  end

  test "an unknown order falls back to the default rather than raising", %{space: space} do
    assert titles(Chat.list_canvases(space.id, order: :nonsense)) ==
             ["Zebra", "apple", "Middle"]
  end
end
