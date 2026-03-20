defmodule Platform.Chat.ContextPlaneTest do
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.ContextPlane

  setup do
    # Ensure ContextPlane is running
    if pid = Process.whereis(ContextPlane) do
      Ecto.Adapters.SQL.Sandbox.allow(Platform.Repo, self(), pid)
    end

    :ok
  end

  defp create_space(attrs \\ %{}) do
    default = %{name: "Test", slug: unique_slug(), kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp create_participant(space_id, attrs \\ %{}) do
    default = %{
      participant_type: "user",
      participant_id: Ecto.UUID.generate(),
      display_name: "Alice",
      joined_at: DateTime.utc_now()
    }

    {:ok, participant} = Chat.add_participant(space_id, Map.merge(default, attrs))
    participant
  end

  defp unique_slug, do: "test-#{System.unique_integer([:positive])}"

  test "starts and creates ETS table" do
    assert Process.whereis(ContextPlane) != nil
    assert :ets.info(:suite_context_plane) != :undefined
  end

  test "message posted telemetry updates recent_activity" do
    space = create_space()
    participant = create_participant(space.id)

    {:ok, _msg} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: "Hello context plane!"
      })

    # Give telemetry handler time to process
    Process.sleep(50)

    activity = ContextPlane.get_recent_activity(space.id)
    assert length(activity) >= 1
    assert hd(activity).preview =~ "Hello context plane"
  end

  test "canvas created telemetry updates canvas_summaries" do
    space = create_space()
    participant = create_participant(space.id)

    {:ok, canvas, _msg} =
      Chat.create_canvas_with_message(space.id, participant.id, %{
        "canvas_type" => "table",
        "title" => "Test Canvas"
      })

    # Give telemetry handler time to process
    Process.sleep(50)

    summaries = ContextPlane.get_canvas_summaries(space.id)
    assert length(summaries) >= 1
    assert Enum.any?(summaries, fn c -> c.id == canvas.id end)
  end

  test "build_context_bundle returns complete context for a space" do
    space = create_space()
    participant = create_participant(space.id)

    {:ok, _msg} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: "Setup message"
      })

    # Give telemetry handler time to process
    Process.sleep(50)

    bundle = ContextPlane.build_context_bundle(space.id)

    assert is_map(bundle)
    assert Map.has_key?(bundle, :space)
    assert Map.has_key?(bundle, :active_canvases)
    assert Map.has_key?(bundle, :active_tasks)
    assert Map.has_key?(bundle, :other_agents)
    assert Map.has_key?(bundle, :recent_activity_summary)
    assert is_binary(bundle.recent_activity_summary)
  end
end
