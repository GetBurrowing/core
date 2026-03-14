defmodule Platform.Chat.PresenceTest do
  use ExUnit.Case, async: false

  alias Platform.Chat.Presence, as: ChatPresence

  describe "track_in_space/4 and list_space/1" do
    test "tracked participant appears in list_space" do
      space_id = Ecto.UUID.generate()
      participant_id = Ecto.UUID.generate()

      {:ok, _ref} =
        ChatPresence.track_in_space(self(), space_id, participant_id, %{
          participant_type: "user",
          display_name: "Test User"
        })

      presences = ChatPresence.list_space(space_id)
      assert Map.has_key?(presences, participant_id)
      [meta] = presences[participant_id].metas
      assert meta.display_name == "Test User"
    end

    test "online_count reflects tracked participants" do
      space_id = Ecto.UUID.generate()
      assert ChatPresence.online_count(space_id) == 0

      p1 = Ecto.UUID.generate()
      p2 = Ecto.UUID.generate()

      parent = self()

      t1 =
        spawn(fn ->
          {:ok, _} = ChatPresence.track_in_space(self(), space_id, p1, %{})
          send(parent, :tracked)

          receive do
            :done -> :ok
          after
            2000 -> :ok
          end
        end)

      assert_receive :tracked, 500

      t2 =
        spawn(fn ->
          {:ok, _} = ChatPresence.track_in_space(self(), space_id, p2, %{})
          send(parent, :tracked)

          receive do
            :done -> :ok
          after
            2000 -> :ok
          end
        end)

      assert_receive :tracked, 500

      # Give presence time to settle
      :timer.sleep(100)
      assert ChatPresence.online_count(space_id) == 2

      Process.exit(t1, :kill)
      Process.exit(t2, :kill)
    end
  end

  describe "untrack_in_space/3" do
    test "untracked participant is removed from list_space" do
      space_id = Ecto.UUID.generate()
      participant_id = Ecto.UUID.generate()

      {:ok, _ref} = ChatPresence.track_in_space(self(), space_id, participant_id, %{})
      :ok = ChatPresence.untrack_in_space(self(), space_id, participant_id)

      # Give presence time to process
      :timer.sleep(50)
      presences = ChatPresence.list_space(space_id)
      refute Map.has_key?(presences, participant_id)
    end
  end
end
