defmodule Platform.MeetingsTranscriberPredicateTest do
  # async: false — the config-override case mutates the
  # `:transcriber_identity_markers` app env, which is global. It must not
  # live in meetings_test.exs, which runs `async: true`.
  use ExUnit.Case, async: false

  alias Platform.Meetings
  alias Platform.Meetings.Participant

  @user_id "019f0000-0000-7000-8000-000000000001"
  @agent_id "019f0000-0000-7000-8000-000000000002"

  defp row(attrs), do: struct!(Participant, attrs)

  # Shape recorded from production in the org journal on 2026-08-05.
  defp prod_transcriber_row do
    row(
      display_name: "Transcription",
      metadata: %{"identity" => "transcriber:space-#{Ecto.UUID.generate()}"}
    )
  end

  describe "transcriber_participant?/1 with the default markers" do
    test "the production-shaped transcriber row is a transcriber" do
      assert Meetings.transcriber_participant?(prod_transcriber_row())
    end

    test "a meeting-transcriber display name is a transcriber" do
      assert Meetings.transcriber_participant?(row(display_name: "meeting-transcriber"))
    end

    test "the match is case-insensitive on the haystack" do
      assert Meetings.transcriber_participant?(
               row(display_name: "x", metadata: %{"identity" => "TRANSCRIBER:space-1"})
             )
    end

    test "a human row with a user FK is not a transcriber" do
      refute Meetings.transcriber_participant?(
               row(user_id: @user_id, display_name: "Marlowe", metadata: %{"identity" => "user:1"})
             )
    end

    test "a guest row is not a transcriber" do
      refute Meetings.transcriber_participant?(
               row(display_name: "Ada (guest)", metadata: %{"identity" => "guest:abc"})
             )
    end

    test "an agent row is not a transcriber" do
      refute Meetings.transcriber_participant?(
               row(
                 agent_id: @agent_id,
                 display_name: "Higgins",
                 metadata: %{"identity" => "agent:slug"}
               )
             )

      # Also without the FK: the agent: identity alone does not match.
      refute Meetings.transcriber_participant?(
               row(display_name: "Higgins", metadata: %{"identity" => "agent:slug"})
             )
    end

    test "an orphaned nil-FK row named Bob is not a transcriber" do
      refute Meetings.transcriber_participant?(row(display_name: "Bob", metadata: %{}))
    end

    test "FK guard: a user-FK row whose strings carry a marker is not a transcriber" do
      refute Meetings.transcriber_participant?(
               row(
                 user_id: @user_id,
                 display_name: "transcriber: Marlowe",
                 metadata: %{"identity" => "transcriber:space-1"}
               )
             )
    end

    test "FK guard: an agent-FK row whose strings carry a marker is not a transcriber" do
      refute Meetings.transcriber_participant?(
               row(agent_id: @agent_id, display_name: "meeting-transcriber")
             )
    end

    test "a LiveKit-participant shaped map is matched on identity and name" do
      assert Meetings.transcriber_participant?(%{
               identity: "transcriber:space-1",
               name: "Transcription"
             })

      assert Meetings.transcriber_participant?(%{name: "meeting-transcriber"})
      assert Meetings.transcriber_participant?(%{display_name: "meeting-transcriber"})
      refute Meetings.transcriber_participant?(%{identity: "user:1", name: "Marlowe"})
    end

    test "anything else is not a transcriber" do
      refute Meetings.transcriber_participant?(nil)
      refute Meetings.transcriber_participant?("transcriber:space-1")
      refute Meetings.transcriber_participant?(%{kind: "AGENT"})
    end
  end

  describe "config changes what is hidden" do
    setup do
      previous = Application.fetch_env(:platform, :transcriber_identity_markers)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:platform, :transcriber_identity_markers, value)
          :error -> Application.delete_env(:platform, :transcriber_identity_markers)
        end
      end)

      Application.put_env(:platform, :transcriber_identity_markers, ["custom-scribe:"])
      :ok
    end

    test "transcriber_identity_markers/0 returns the overridden list" do
      assert Meetings.transcriber_identity_markers() == ["custom-scribe:"]
    end

    test "a transcriber: row is un-hidden and a custom-scribe row is hidden" do
      refute Meetings.transcriber_participant?(
               row(
                 display_name: "Transcription",
                 metadata: %{"identity" => "transcriber:space-x"}
               )
             )

      assert Meetings.transcriber_participant?(
               row(display_name: "Scribe", metadata: %{"identity" => "custom-scribe:1"})
             )
    end
  end

  test "default markers are the two historical entries when unconfigured" do
    case Application.fetch_env(:platform, :transcriber_identity_markers) do
      :error ->
        assert Meetings.transcriber_identity_markers() == ["meeting-transcriber", "transcriber:"]

      {:ok, configured} ->
        assert Meetings.transcriber_identity_markers() == configured
    end
  end
end
