defmodule Platform.Chat.PresenceCanvasTest do
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Presence

  defp setup_space do
    {:ok, space} =
      Chat.create_space(%{
        name: "Presence Test",
        slug: "pres-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp tracker do
    # Wrap presence tracking in a long-lived process so we can inspect the list.
    test = self()

    pid =
      spawn_link(fn ->
        receive do
          :stop -> :ok
        end

        send(test, :done)
      end)

    pid
  end

  describe "set_canvas_engagement/4" do
    test "adds a canvas bag to the participant's meta" do
      space = setup_space()
      pid = tracker()
      participant_id = Ecto.UUID.generate()

      {:ok, _} =
        Presence.track_in_space(pid, space.id, participant_id, %{display_name: "Alice"})

      {:ok, _} =
        Presence.set_canvas_engagement(pid, space.id, participant_id, %{
          canvas_id: "canvas-1",
          engagement: :viewing
        })

      engagement = Presence.list_canvas_engagement(space.id, "canvas-1")
      assert length(engagement.viewing) == 1
      assert hd(engagement.viewing).display_name == "Alice"

      send(pid, :stop)
      assert_receive :done, 1_000
    end

    test "routes editing engagement into the editing bucket" do
      space = setup_space()
      pid = tracker()
      participant_id = Ecto.UUID.generate()

      {:ok, _} =
        Presence.track_in_space(pid, space.id, participant_id, %{display_name: "Bob"})

      {:ok, _} =
        Presence.set_canvas_engagement(pid, space.id, participant_id, %{
          canvas_id: "canvas-1",
          engagement: :editing,
          focus_node_id: "n1"
        })

      engagement = Presence.list_canvas_engagement(space.id, "canvas-1")
      assert length(engagement.editing) == 1
      assert hd(engagement.editing).focus_node_id == "n1"
      assert engagement.viewing == []

      send(pid, :stop)
      assert_receive :done, 1_000
    end

    test "clear removes the canvas bag" do
      space = setup_space()
      pid = tracker()
      participant_id = Ecto.UUID.generate()

      {:ok, _} =
        Presence.track_in_space(pid, space.id, participant_id, %{display_name: "Carol"})

      {:ok, _} =
        Presence.set_canvas_engagement(pid, space.id, participant_id, %{
          canvas_id: "canvas-1",
          engagement: :viewing
        })

      {:ok, _} = Presence.clear_canvas_engagement(pid, space.id, participant_id)

      engagement = Presence.list_canvas_engagement(space.id, "canvas-1")
      assert engagement == %{viewing: [], editing: []}

      send(pid, :stop)
      assert_receive :done, 1_000
    end
  end
end
