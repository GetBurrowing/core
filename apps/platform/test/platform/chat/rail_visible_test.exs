defmodule Platform.Chat.RailVisibleTest do
  @moduledoc """
  `Platform.Chat.rail_visible?/1` (task 01a1eab6 stage 3): a space whose
  metadata carries a non-empty `"surface"` belongs to another surface and is
  not a chat-rail conversation. The values below are arbitrary on purpose:
  core never compares the value, only whether it is set. The badge half
  proves the rail unread total leaves such a space out while still counting
  an ordinary conversation of the same viewer.
  """
  use Platform.DataCase, async: true

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.{Message, Space}

  describe "rail_visible?/1" do
    test "a space with no surface is on the rail" do
      assert Chat.rail_visible?(%Space{})
      assert Chat.rail_visible?(%Space{metadata: %{}})
      assert Chat.rail_visible?(%Space{metadata: %{"other" => "x"}})
      assert Chat.rail_visible?(%Space{metadata: %{"surface" => nil}})
    end

    test "any non-empty surface value takes it off the rail, never compared" do
      refute Chat.rail_visible?(%Space{metadata: %{"surface" => "x"}})
      refute Chat.rail_visible?(%Space{kind: "channel", metadata: %{"surface" => "anything"}})
    end

    test "an empty surface is not a surface" do
      assert Chat.rail_visible?(%Space{metadata: %{"surface" => ""}})
    end
  end

  describe "the rail unread badge" do
    test "counts an ordinary DM and leaves a surface-owned one out" do
      n = System.unique_integer([:positive])

      user =
        Repo.insert!(%User{
          email: "rail-visible-#{n}@example.com",
          name: "Rail Visible #{n}",
          oidc_sub: "oidc-rail-visible-#{n}"
        })

      plain = conversation!(user, %{})
      owned = conversation!(user, %{"surface" => "x"})

      for space <- [plain, owned], do: from_other!(space, user)

      assert Chat.unread_counts_for_user(user.id) |> Map.take([plain.id, owned.id]) ==
               %{plain.id => 1, owned.id => 1}

      assert Chat.total_unread_for_viewer(user) == 1
      assert {:ok, 1} = Chat.mark_all_chat_spaces_read(user)
    end
  end

  defp conversation!(user, metadata) do
    {:ok, space} = Chat.create_space(%{kind: "dm", is_direct: false, metadata: metadata})

    for {id, name} <- [{user.id, user.name}, {Ecto.UUID.generate(), "Other"}] do
      {:ok, _} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: id,
          display_name: name,
          joined_at: DateTime.utc_now()
        })
    end

    space
  end

  defp from_other!(space, user) do
    other = space.id |> Chat.list_participants() |> Enum.find(&(&1.participant_id != user.id))

    Repo.insert!(%Message{
      space_id: space.id,
      participant_id: other.id,
      content_type: "text",
      content: "hello"
    })
  end
end
