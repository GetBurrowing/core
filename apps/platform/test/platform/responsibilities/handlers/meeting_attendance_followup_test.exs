defmodule Platform.Responsibilities.Handlers.MeetingAttendanceFollowupTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.MeetingAttendanceFollowup`
  — the Meeting Scribe bundle stage 3 registration-only handler.
  Downstream side-effects land in a follow-up ticket.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Platform.Responsibilities.Handlers.MeetingAttendanceFollowup
  alias Platform.Responsibilities.Responsibility

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: MeetingAttendanceFollowup.key(),
      feature: "meetings",
      trigger_kind: "event_topic",
      trigger_config: %{"topic" => "meeting:finished"},
      scope: "per_meeting",
      context_provided: ["org_identity", "meeting_transcript"],
      enabled: true
    }
  end

  describe "register/0" do
    test "returns exactly one spec with the canonical key + feature" do
      specs = MeetingAttendanceFollowup.register()

      assert length(specs) == 1
      [spec] = specs

      assert spec.key == "meetings.attendance_followup"
      assert spec.feature == "meetings"
      assert spec.trigger_kind == "event_topic"

      assert spec.trigger_config == %{
               "topic" => "meeting:finished",
               "topic_pattern" => "meeting:finished:*",
               "event_match" => "meeting_finished"
             }

      assert spec.scope == "per_meeting"
      assert spec.context_provided == ["org_identity", "meeting_transcript"]
      assert spec.default_prompt_template == "meetings.attendance_followup.v1"
      assert spec.cost_profile == "low_freq_capable"
    end

    test "output_contract satisfies the M1 schema invariant (map-of-strings)" do
      [spec] = MeetingAttendanceFollowup.register()

      Enum.each(spec.output_contract, fn {key, value} ->
        assert is_binary(key)
        assert is_binary(value), "#{inspect(key)}=#{inspect(value)} must be a string type name"
      end)

      assert spec.output_contract == %{"followups" => "list[string]"}
    end

    test "metadata identifies the platform owner" do
      [spec] = MeetingAttendanceFollowup.register()
      assert spec.metadata["owner"] == "platform.meetings"
    end
  end

  describe "key/0" do
    test "matches the registered spec key" do
      [spec] = MeetingAttendanceFollowup.register()
      assert MeetingAttendanceFollowup.key() == spec.key
      assert MeetingAttendanceFollowup.key() == "meetings.attendance_followup"
    end
  end

  describe "gather_context/2" do
    test "returns an empty map — the shim handles the shared meetings slots" do
      assert {:ok, %{}} = MeetingAttendanceFollowup.gather_context(responsibility(), %{})
    end
  end

  describe "handle_output/3" do
    test "returns :ok for a well-shaped followups list" do
      payload = %{
        "followups" => [
          "Harper: We agreed X and Y — do you still want to own the vendor call?",
          "Alex: The RFP timeline shifted to Q3 — does that still work?"
        ]
      }

      assert :ok =
               MeetingAttendanceFollowup.handle_output(responsibility(), payload, %{
                 kind: :event_topic
               })
    end

    test "returns :ok for an atom-keyed followups list" do
      payload = %{followups: ["atom-keyed followup"]}

      assert :ok =
               MeetingAttendanceFollowup.handle_output(responsibility(), payload, %{
                 kind: :event_topic
               })
    end

    test "returns :ok for a malformed payload (log-and-move-on)" do
      log =
        capture_log(fn ->
          assert :ok =
                   MeetingAttendanceFollowup.handle_output(responsibility(), %{}, %{
                     kind: :event_topic
                   })

          assert :ok =
                   MeetingAttendanceFollowup.handle_output(
                     responsibility(),
                     "bare string",
                     %{kind: :event_topic}
                   )

          assert :ok =
                   MeetingAttendanceFollowup.handle_output(responsibility(), nil, %{
                     kind: :event_topic
                   })
        end)

      assert log =~ "[meetings.attendance_followup]"
      assert log =~ "unexpected output shape"
    end

    test "arity-2 delegates to arity-3 with default meta" do
      assert :ok =
               MeetingAttendanceFollowup.handle_output(responsibility(), %{"followups" => []})
    end
  end
end
