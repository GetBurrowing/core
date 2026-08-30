defmodule Platform.Chat.MessageOrderTiebreakTest do
  @moduledoc """
  `list_messages/2` must return a STABLE order when messages share an
  `inserted_at`.

  This is not hypothetical. `inserted_at` is `:utc_datetime_usec` and
  production currently holds 7,909 timestamps carried by more than one
  message. With a bare `order_by: inserted_at`, Postgres may return tied
  rows in any order, and an anchored window then places the anchor at a
  different index on different reads — which is how this surfaced, as
  `chat_live_message_anchor_test` failing with "anchor at index 10,
  expected 9" on one run and index 8 on the next.

  The fixture writes identical timestamps DELIBERATELY. A fixture that
  lets the clock separate the rows cannot fail, which is why this defect
  survived: on a slower host the inserts drift apart and the bug hides.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Repo

  @tied_count 12

  setup do
    {:ok, space} =
      Chat.create_space(%{
        "name" => "Tiebreak",
        "slug" => "tiebreak-#{System.unique_integer([:positive])}",
        "kind" => "channel"
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: "Author",
        joined_at: DateTime.utc_now()
      })

    # One timestamp, many messages. This is the collision the production
    # data already exhibits, forced rather than waited for.
    at = ~U[2026-08-30 00:00:00.000000Z]

    ids =
      for i <- 1..@tied_count do
        {:ok, m} =
          %Message{}
          |> Ecto.Changeset.change(%{
            id: Platform.Types.UUIDv7.generate(),
            space_id: space.id,
            participant_id: participant.id,
            content: "tied-#{i}",
            inserted_at: at
          })
          |> Repo.insert()

        m.id
      end

    %{space: space, ids: ids}
  end

  test "tied timestamps produce a deterministic order across repeated reads", %{space: space} do
    reads =
      for _ <- 1..5 do
        space.id
        |> Chat.list_messages(limit: 50, order: :asc)
        |> Enum.map(& &1.id)
      end

    assert length(Enum.uniq(reads)) == 1,
           """
           list_messages/2 returned different orders for the same tied rows.
           Without a tiebreaker Postgres is free to reorder ties, and an
           anchored window then moves the anchor between reads.
           """
  end

  test "tied timestamps still resolve to true insertion order", %{space: space, ids: ids} do
    read =
      space.id
      |> Chat.list_messages(limit: 50, order: :asc)
      |> Enum.map(& &1.id)

    # This assertion got STRONGER partway through the work, and the reason is
    # worth keeping. It originally asserted only that the order was stable,
    # because UUIDv7's `rand_a` was random and ids minted in one millisecond
    # were unordered — so when `inserted_at` tied, true write order was
    # genuinely unrecoverable and determinism was the most the data supported.
    #
    # Making the generator monotonic per RFC 9562 §6.2 method 2 (task
    # `01a0506e`) changed that. Ids now carry their creation order within a
    # millisecond, so the tiebreaker recovers real insertion order rather than
    # merely a repeatable one.
    assert read == ids
  end
end
