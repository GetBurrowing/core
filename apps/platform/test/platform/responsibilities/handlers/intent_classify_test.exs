defmodule Platform.Responsibilities.Handlers.IntentClassifyTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.IntentClassify` — the
  registration-only placeholder that gives the Meeting Producer role
  (task 019f2451) a real responsibility row to bind to. Runtime lands
  in the follow-up ticket `019f2452-0210`; this handler just declares
  the spec and no-ops with a placeholder log line so operators can
  spot rogue fires before the classifier code is wired.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Platform.Responsibilities.Handlers.IntentClassify
  alias Platform.Responsibilities.Responsibility

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: IntentClassify.key(),
      feature: "meetings",
      trigger_kind: "event_topic",
      trigger_config: %{"topic" => "meeting:transcript_chunk"},
      scope: "per_meeting",
      context_provided: ["meeting_transcript_chunk"],
      enabled: true
    }
  end

  describe "register/0" do
    test "returns exactly one spec with the canonical key + feature" do
      specs = IntentClassify.register()

      assert length(specs) == 1
      [spec] = specs

      assert spec.key == "meetings.intent_classify"
      assert spec.feature == "meetings"
      assert spec.trigger_kind == "event_topic"

      assert spec.trigger_config == %{
               "topic" => "meeting:transcript_chunk",
               "event_match" => "transcript_chunk"
             }

      assert spec.scope == "per_meeting"
      assert spec.context_provided == ["meeting_transcript_chunk"]
      assert spec.default_prompt_template == "meetings.intent_classify.v1"
      assert spec.cost_profile == "high_freq_low_cost"
    end

    test "output_contract is a map of string names — satisfies the M1 schema invariant" do
      [spec] = IntentClassify.register()

      # M1's Responsibility.changeset/2 rejects non-string values in the
      # JSONB output_contract column. Every value here must be a bare
      # string type name so upsert succeeds at boot.
      Enum.each(spec.output_contract, fn {key, value} ->
        assert is_binary(key)
        assert is_binary(value), "#{inspect(key)}=#{inspect(value)} must be a string type name"
      end)

      # Explicit shape assertion so the runtime ticket's parser has a
      # named contract to code against.
      assert spec.output_contract == %{
               "intent" => "string",
               "target_role" => "string",
               "confidence" => "float",
               "dedupe_key" => "string"
             }
    end

    test "metadata flags this as a placeholder + points at the runtime task" do
      [spec] = IntentClassify.register()

      assert spec.metadata["owner"] == "platform.meetings"
      assert spec.metadata["status"] == "placeholder"
      assert spec.metadata["runtime_task"] == "019f2452-0210"
    end
  end

  describe "gather_context/2" do
    test "returns a missing? meeting_transcript_chunk slot" do
      assert {:ok, ctx} = IntentClassify.gather_context(responsibility(), %{})
      assert Map.has_key?(ctx, :meeting_transcript_chunk)

      slot = ctx.meeting_transcript_chunk
      assert slot.missing? == true
      assert slot.note =~ "019f2452-0210"
    end

    test "ignores the trigger payload — runtime not implemented yet" do
      payload = %{payload: %{transcript_id: "abc", chunk_id: "xyz"}}
      assert {:ok, ctx} = IntentClassify.gather_context(responsibility(), payload)
      assert ctx.meeting_transcript_chunk.missing? == true
    end
  end

  describe "handle_output/3" do
    # Returns an ERROR, not `:ok`. The row is declared
    # `dispatch: "inert"` because the real runtime is the
    # `Platform.Meetings.IntentClassifier` GenServer, so a call landing
    # here means the Router fired something it should not have. ADR-0046's
    # `outcome/1` maps the error to `:failed`, which records that rather
    # than counting a discarded output as a completed step.
    #
    # `:ok` was the old return, and it is exactly why the Router
    # double-classifying every transcript chunk stayed invisible: the
    # handler threw the answer away and reported success.
    test "returns {:error, :not_implemented} so a stray fire records as a failure" do
      log =
        capture_log(fn ->
          assert {:error, :not_implemented} =
                   IntentClassify.handle_output(
                     responsibility(),
                     %{"intent" => "assign_task", "confidence" => 0.9},
                     %{kind: :event_topic}
                   )
        end)

      assert log =~ "[meetings.intent_classify]"
      assert log =~ "inert row"
      assert log =~ "Platform.Meetings.IntentClassifier"
    end

    # The declaration and the return value have to agree. A handler that
    # errors while its row still dispatches is a broken key; a row that
    # is inert while its handler returns :ok hides the fires.
    test "the row it registers declares itself inert, naming its real executor" do
      [spec] = IntentClassify.register()

      assert spec.metadata["dispatch"] == "inert"
      assert spec.metadata["executor"] == "platform.meetings.intent_classifier"

      # Still enabled and still registered: the row is the ON SWITCH for
      # the GenServer. `IntentClassifier`'s guard 2 is
      # `Roles.assignee_for("meetings.intent_classify")` and its doc says
      # "Assignment IS the enable signal", so deleting or disabling this
      # row drops every chunk before any model is consulted.
      refute Map.get(spec, :enabled) == false
      assert spec.key == "meetings.intent_classify"
    end
  end

  describe "handle_output/2" do
    test "arity-2 delegates to arity-3 with the same error" do
      log =
        capture_log(fn ->
          assert {:error, :not_implemented} =
                   IntentClassify.handle_output(responsibility(), %{"intent" => "x"})
        end)

      assert log =~ "[meetings.intent_classify]"
      assert log =~ "inert row"
    end
  end

  describe "key/0" do
    test "matches the registered spec key" do
      [spec] = IntentClassify.register()
      assert IntentClassify.key() == spec.key
      assert IntentClassify.key() == "meetings.intent_classify"
    end
  end

  describe "template_slug/0" do
    test "returns the canonical prompt template slug" do
      assert IntentClassify.template_slug() == "meetings.intent_classify.v1"
    end

    test "matches the registered spec's default_prompt_template — drift guard" do
      # Load-bearing invariant: the handler's declared template slug MUST
      # match the value it advertises via register/0.default_prompt_template.
      # If someone renames one without the other, the router would 404 at
      # render time. Same protection pattern as Designer handlers.
      [spec] = IntentClassify.register()
      assert spec.default_prompt_template == IntentClassify.template_slug()
    end
  end
end
