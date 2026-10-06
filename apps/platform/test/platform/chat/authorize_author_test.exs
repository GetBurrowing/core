defmodule Platform.Chat.AuthorizeAuthorTest do
  @moduledoc """
  Task 01a111bb stage 2: the one author rule (`Chat.authorize_author/2`) and
  the freeze held by `Chat.edit_message/2` itself.
  """
  use Platform.DataCase, async: false

  import Platform.ExternalUserFixtures

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Chat.Participant

  describe "authorize_author/2" do
    test "the author's own participant is :ok" do
      pid = Ecto.UUID.generate()
      assert Chat.authorize_author(%Message{participant_id: pid}, %Participant{id: pid}) == :ok
    end

    test "another participant is forbidden" do
      message = %Message{participant_id: Ecto.UUID.generate()}

      assert Chat.authorize_author(message, %Participant{id: Ecto.UUID.generate()}) ==
               {:error, :forbidden}
    end

    test "no participant (not in the space) is forbidden" do
      assert Chat.authorize_author(%Message{participant_id: Ecto.UUID.generate()}, nil) ==
               {:error, :forbidden}
    end

    test "a message with no author is never matched by a participant without an id" do
      assert Chat.authorize_author(%Message{participant_id: nil}, %Participant{id: nil}) ==
               {:error, :forbidden}
    end
  end

  describe "edit_message/2 and the freeze" do
    setup do
      user = create_user!(%{name: "Freeze Author"})
      space = channel!()

      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: "Freeze Author",
          joined_at: DateTime.utc_now()
        })

      message = post!(space.id, participant.id, "original")
      %{message: message, participant: participant}
    end

    test "an unfrozen message is edited (control)", %{message: message} do
      assert {:ok, %Message{content: "changed"}} = Chat.edit_message(message, "changed")
    end

    test "a frozen message is refused, naming who froze it, and is not changed", %{
      message: message,
      participant: participant
    } do
      {:ok, frozen} =
        message
        |> Message.freeze_changeset(%{
          frozen_at: DateTime.utc_now(),
          frozen_by_participant_id: participant.id
        })
        |> Repo.update()

      assert {:error, :frozen, %{participant_display_name: name}} =
               Chat.edit_message(frozen, "changed anyway")

      assert name == "Freeze Author"
      assert Repo.get!(Message, message.id).content == "original"
    end
  end
end
