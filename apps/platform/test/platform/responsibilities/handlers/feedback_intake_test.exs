defmodule Platform.Responsibilities.Handlers.FeedbackIntakeTest do
  @moduledoc """
  The dedicated `feedback.intake` responsibility (task 01a11ec3 stage 3):
  registration, provider wiring, role bundle, prompt seed, and the refusal of
  any Router-built dispatch.

  Failing-first: against the stage-2 tip (ffdc1cbc5) every test here fails —
  the handler and provider modules do not exist, `feedback` has no provider,
  `triage_officer`'s bundle lacks the key, and `feedback.intake.v1` is not
  seeded.
  """
  use Platform.DataCase, async: false

  alias Platform.Feedback.Intake
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities
  alias Platform.Responsibilities.BuiltIns
  alias Platform.Responsibilities.Handlers.FeedbackIntake
  alias Platform.Responsibilities.Providers
  alias Platform.Roles
  alias Platform.Test.FeedbackIntakeStub, as: Stub

  test "registers one feedback.intake row on a null topic with the intake template" do
    assert [row] = FeedbackIntake.register()
    assert row.key == "feedback.intake"
    assert row.feature == "feedback"
    assert row.trigger_kind == "event_topic"
    assert row.trigger_config == %{"topic" => "platform.feedback.intake_only"}
    assert row.default_prompt_template == "feedback.intake.v1"
    assert row.metadata["capabilities"] == Intake.capabilities()
  end

  test "it is a built-in distinct from every other responsibility, including any janitor" do
    assert FeedbackIntake in BuiltIns.providers()

    owners =
      BuiltIns.providers()
      |> Enum.flat_map(fn mod -> Enum.map(mod.register(), &{&1.key, mod}) end)
      |> Enum.filter(fn {key, _mod} -> key == "feedback.intake" end)

    assert owners == [{"feedback.intake", FeedbackIntake}]

    # Any janitor responsibility is owned by some other module.
    janitor_owners =
      BuiltIns.providers()
      |> Enum.filter(fn mod -> Enum.any?(mod.register(), &(&1.key =~ "janitor")) end)

    refute FeedbackIntake in janitor_owners
    refute FeedbackIntake.key() =~ "janitor"
  end

  test "the capability set is disjoint from the denied set and names no execution authority" do
    [row] = FeedbackIntake.register()
    granted = MapSet.new(row.metadata["capabilities"])
    denied = MapSet.new(row.metadata["denied"])

    assert MapSet.disjoint?(granted, denied)

    for capability <-
          ~w(repository_checkout repository_write planning execution shell deploy secret_read github_broad promote_from_quarantine) do
      assert capability in denied
    end
  end

  test "the feedback feature resolves to its provider, which routes the key to the handler" do
    assert {:ok, Providers.Feedback} = Providers.feature_provider("feedback")
    assert Providers.Feedback.handler_for("feedback.intake") == FeedbackIntake
    assert Providers.Feedback.handler_for("feedback.other") == nil
  end

  test "a Router-built prompt is refused with an error the Router propagates, not :no_build_prompt" do
    assert {:error, :feedback_intake_not_router_dispatched} =
             Providers.Feedback.build_prompt(%{__responsibility__: %{key: "feedback.intake"}})

    {:ok, [responsibility]} = Responsibilities.register(Providers.Feedback)

    assert {:error, :feedback_intake_not_router_dispatched} =
             Providers.Feedback.handle_output(responsibility, %{"verdict" => "accept_bug"}, %{})
  end

  test "triage_officer's migrated bundle carries the key, so the pinned agent classifies" do
    agent = Stub.classifier_agent!()
    assert %{id: id} = Roles.assignee_for("feedback.intake")
    assert id == agent.id
  end

  test "feedback.intake.v1 is seeded and renders with no placeholder left" do
    assert %{content: content} = PromptTemplates.get_template_by_slug("feedback.intake.v1")
    assert content =~ "{{verdicts}}"

    prompt = Platform.Feedback.Classifier.system_prompt()
    refute prompt =~ "{{"
    assert prompt =~ "accept_positive_change"
    assert prompt =~ "instruction_injection"
  end
end
