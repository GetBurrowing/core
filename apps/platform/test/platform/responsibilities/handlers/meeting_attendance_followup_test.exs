defmodule Platform.Responsibilities.Handlers.MeetingAttendanceFollowupTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.MeetingAttendanceFollowup`
  — the Meeting Scribe key that task `019fa56b-c81f` stage 4 declares
  INERT rather than shipping.

  ## Why this file changed shape

  It used to `use ExUnit.Case` (no database) and its `handle_output/3`
  tests asserted only `assert :ok = handle_output(...)` — exactly what
  the registration-only stub returned. That is the same structural
  vacuity found in `meeting_action_items_test.exs` in stage 3: a file
  incapable of distinguishing "did the declared thing" from "did
  nothing". It now runs on `Platform.DataCase` so the metadata
  propagation claim — the load-bearing reason the placeholder lives in
  `metadata` and not in `enabled` — is proved against the real upsert
  rather than read off the attribute list.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Responsibilities
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
      metadata: %{"owner" => "platform.meetings", "status" => "placeholder"},
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

    test "metadata identifies the platform owner and DECLARES THE KEY A PLACEHOLDER" do
      [spec] = MeetingAttendanceFollowup.register()
      assert spec.metadata["owner"] == "platform.meetings"
      assert spec.metadata["status"] == "placeholder"
    end

    test "the row stays enabled — inertness is declared, not toggled off" do
      # Deliberate: `enabled: false` would ALSO strip the assignee's
      # meaning and, worse, would be a no-op against the production row
      # (see the propagation test below). The key keeps its role
      # resolution so nothing rots while it waits for the attendance
      # context chain.
      [spec] = MeetingAttendanceFollowup.register()
      refute Map.has_key?(spec, :enabled)

      {:ok, row} = Responsibilities.upsert_by_key(spec)
      assert row.enabled
    end

    test "the placeholder declaration PROPAGATES to a pre-existing row, where enabled would not" do
      # THE LOAD-BEARING PROOF. `@upsert_replace_fields` in
      # `Platform.Responsibilities` includes `metadata` and deliberately
      # EXCLUDES `enabled`. Simulate the production row as it exists
      # today — registered before this stage, so no `status` key — plus
      # an operator-flipped `enabled: false`, then re-run registration
      # the way boot does.
      [spec] = MeetingAttendanceFollowup.register()

      {:ok, existing} =
        Responsibilities.upsert_by_key(%{spec | metadata: %{"owner" => "platform.meetings"}})

      refute Map.has_key?(existing.metadata, "status")

      {:ok, _} =
        existing
        |> Ecto.Changeset.change(%{enabled: false})
        |> Platform.Repo.update()

      {:ok, reregistered} = Responsibilities.upsert_by_key(spec)

      # Same row — this is an UPDATE, not a fresh insert.
      assert reregistered.id == existing.id
      # metadata IS in @upsert_replace_fields — the declaration lands on
      # the existing row, which is the whole reason it was expressed here.
      assert reregistered.metadata["status"] == "placeholder"
      # enabled is NOT — the operator toggle survives, which is exactly
      # why a code-only `enabled: false` would have shipped a no-op.
      refute reregistered.enabled
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
    test "returns an empty map — no attendance slot is assembled anywhere" do
      # Pinned deliberately: this emptiness IS the argument for the
      # placeholder. `context_provided` promises org_identity +
      # meeting_transcript and nothing about who was expected versus who
      # joined, so a fire would ask a model about attendance with no
      # attendance data.
      assert {:ok, %{}} = MeetingAttendanceFollowup.gather_context(responsibility(), %{})

      [spec] = MeetingAttendanceFollowup.register()
      refute Enum.any?(spec.context_provided, &(&1 =~ "attend"))
    end
  end

  describe "handle_output/3 — records a FAILURE, not a success" do
    test "a well-shaped followups list still returns {:error, :not_implemented}" do
      payload = %{
        "followups" => [
          "Harper: We agreed X and Y — do you still want to own the vendor call?",
          "Alex: The RFP timeline shifted to Q3 — does that still work?"
        ]
      }

      log =
        capture_log(fn ->
          assert {:error, :not_implemented} =
                   MeetingAttendanceFollowup.handle_output(responsibility(), payload, %{
                     kind: :event_topic
                   })
        end)

      assert log =~ "fired while DECLARED INERT"
    end

    test "an atom-keyed followups list also returns {:error, :not_implemented}" do
      payload = %{followups: ["atom-keyed followup"]}

      assert {:error, :not_implemented} =
               MeetingAttendanceFollowup.handle_output(responsibility(), payload, %{
                 kind: :event_topic
               })
    end

    test "a malformed payload logs the shape warning and still returns the error" do
      log =
        capture_log(fn ->
          assert {:error, :not_implemented} =
                   MeetingAttendanceFollowup.handle_output(responsibility(), %{}, %{
                     kind: :event_topic
                   })

          assert {:error, :not_implemented} =
                   MeetingAttendanceFollowup.handle_output(
                     responsibility(),
                     "bare string",
                     %{kind: :event_topic}
                   )

          assert {:error, :not_implemented} =
                   MeetingAttendanceFollowup.handle_output(responsibility(), nil, %{
                     kind: :event_topic
                   })
        end)

      assert log =~ "[meetings.attendance_followup]"
      assert log =~ "unexpected output shape"
    end

    test "arity-2 delegates to arity-3 and inherits the error" do
      assert {:error, :not_implemented} =
               MeetingAttendanceFollowup.handle_output(responsibility(), %{"followups" => []})
    end

    test "ADR-0046 maps the outcome to :failed, not :complete" do
      # The point of returning an error rather than `:ok`: if this key
      # ever does fire, the step is recorded as broken rather than
      # quietly reported as a completed unit of work.
      assert Responsibilities.outcome({:error, :not_implemented}) == :failed
    end
  end
end
