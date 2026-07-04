defmodule Platform.Responsibilities.Handlers.MeetingActionItemsTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.MeetingActionItems` — the
  Meeting Scribe bundle stage 3 registration-only handler. Downstream
  side-effects land in a follow-up ticket; this handler just declares
  the spec and no-ops with a log line so we can smoke-check that
  spurious dispatches don't crash the router.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Platform.Responsibilities.Handlers.MeetingActionItems
  alias Platform.Responsibilities.Responsibility

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: MeetingActionItems.key(),
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
      specs = MeetingActionItems.register()

      assert length(specs) == 1
      [spec] = specs

      assert spec.key == "meetings.action_items"
      assert spec.feature == "meetings"
      assert spec.trigger_kind == "event_topic"

      assert spec.trigger_config == %{
               "topic" => "meeting:finished",
               "topic_pattern" => "meeting:finished:*",
               "event_match" => "meeting_finished"
             }

      assert spec.scope == "per_meeting"
      assert spec.context_provided == ["org_identity", "meeting_transcript"]
      assert spec.default_prompt_template == "meetings.action_items.v1"
      assert spec.cost_profile == "low_freq_capable"
    end

    test "output_contract satisfies the M1 schema invariant (map-of-strings)" do
      [spec] = MeetingActionItems.register()

      Enum.each(spec.output_contract, fn {key, value} ->
        assert is_binary(key)
        assert is_binary(value), "#{inspect(key)}=#{inspect(value)} must be a string type name"
      end)

      assert spec.output_contract == %{"action_items" => "list[string]"}
    end

    test "metadata identifies the platform owner" do
      [spec] = MeetingActionItems.register()
      assert spec.metadata["owner"] == "platform.meetings"
    end
  end

  describe "key/0" do
    test "matches the registered spec key" do
      [spec] = MeetingActionItems.register()
      assert MeetingActionItems.key() == spec.key
      assert MeetingActionItems.key() == "meetings.action_items"
    end
  end

  describe "gather_context/2" do
    test "returns an empty map — the shim handles the shared meetings slots" do
      assert {:ok, %{}} = MeetingActionItems.gather_context(responsibility(), %{})
    end
  end

  describe "handle_output/3" do
    test "returns :ok for a well-shaped action_items list" do
      payload = %{
        "action_items" => [
          "Harper: schedule the vendor call (this week)",
          "Alex: draft the RFP"
        ]
      }

      assert :ok =
               MeetingActionItems.handle_output(responsibility(), payload, %{
                 kind: :event_topic
               })
    end

    test "returns :ok for an atom-keyed action_items list" do
      payload = %{action_items: ["atom-keyed item"]}

      assert :ok =
               MeetingActionItems.handle_output(responsibility(), payload, %{
                 kind: :event_topic
               })
    end

    test "returns :ok for a malformed payload (log-and-move-on)" do
      # Registration-only handler is intentionally lenient — a follow-up
      # ticket wires the real persistence. Malformed payloads log a
      # warning and return :ok so the router doesn't crash on drift.
      log =
        capture_log(fn ->
          assert :ok =
                   MeetingActionItems.handle_output(responsibility(), %{}, %{
                     kind: :event_topic
                   })

          assert :ok =
                   MeetingActionItems.handle_output(responsibility(), "bare string", %{
                     kind: :event_topic
                   })

          assert :ok =
                   MeetingActionItems.handle_output(responsibility(), nil, %{
                     kind: :event_topic
                   })
        end)

      assert log =~ "[meetings.action_items]"
      assert log =~ "unexpected output shape"
    end

    test "arity-2 delegates to arity-3 with default meta" do
      assert :ok = MeetingActionItems.handle_output(responsibility(), %{"action_items" => []})
    end
  end
end
