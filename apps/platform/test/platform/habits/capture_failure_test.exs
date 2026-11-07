defmodule Platform.Habits.CaptureFailureTest do
  @moduledoc """
  Task 01a1b6a1 stage 3: capture never fails the host operation. A CHECK
  constraint that refuses every new `habit_signals` row (added inside the
  test's sandbox transaction, so it rolls back with it) makes every
  `Platform.Habits.record/1` raise; the send, the DM open and the
  assignment still succeed.

  `async: false`: the `ALTER TABLE` takes an exclusive lock on
  `habit_signals` until the sandbox rolls back.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Habits
  alias Platform.Habits.Signal
  alias Platform.Repo

  setup do
    n = System.unique_integer([:positive])

    one =
      Repo.insert!(%User{
        email: "cf-one-#{n}@example.com",
        name: "Member One #{n}",
        oidc_sub: "cf-one-#{n}"
      })

    two =
      Repo.insert!(%User{
        email: "cf-two-#{n}@example.com",
        name: "Member Two #{n}",
        oidc_sub: "cf-two-#{n}"
      })

    {:ok, room} = Chat.create_space(%{name: "room-x #{n}", slug: "cf-room-#{n}", kind: "channel"})

    {:ok, one_p} =
      Chat.add_participant(room.id, %{
        participant_type: "user",
        participant_id: one.id,
        display_name: one.name,
        joined_at: DateTime.utc_now()
      })

    {:ok, two_p} =
      Chat.add_participant(room.id, %{
        participant_type: "user",
        participant_id: two.id,
        display_name: two.name,
        joined_at: DateTime.utc_now()
      })

    %{one: one, two: two, room: room, one_p: one_p, two_p: two_p}
  end

  defp break_signals! do
    Repo.query!(
      "ALTER TABLE habit_signals ADD CONSTRAINT habit_signals_forced_failure CHECK (false) NOT VALID"
    )
  end

  test "the Habits write really fails once the table is broken", %{one: one, room: room, two: two} do
    break_signals!()

    assert catch_error(
             Habits.record(%{
               actor_user_id: one.id,
               space_id: room.id,
               action: "chat.mention",
               target_type: "user",
               target_id: two.id,
               outcome: "chosen",
               rung: "none"
             })
           )
  end

  test "a forced Habits error does not fail the send or the DM open",
       %{one: one, two: two, room: room, one_p: one_p, two_p: two_p} do
    break_signals!()

    assert {:ok, %Message{} = msg} =
             Chat.post_message(%{
               space_id: room.id,
               participant_id: one_p.id,
               content_type: "text",
               content: "hey @#{two_p.display_name}"
             })

    assert Repo.get(Message, msg.id)
    assert {:ok, _dm} = Chat.find_or_create_dm(one.id, "user", two.id)
    assert Repo.aggregate(from(s in Signal, where: s.actor_user_id == ^one.id), :count) == 0
  end
end
