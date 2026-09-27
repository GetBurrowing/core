defmodule Platform.Tasks.PayloadAmendmentNoticeTest do
  @moduledoc """
  Task 01a0e266 stage 2 — every committed `Tasks.amend_validation_payload/4`
  posts ONE log-only notice into the task's execution space, built by the
  pure `PayloadAmendmentNotice.compose_message/4` and carrying no bracketed
  mention token even when the caller's reason does.

  Mutations this file is meant to turn red: M5 (delete the notice call in
  `amend_validation_payload/4`) fails the count tests here and in
  `tool_surface_payload_amend_test.exs`; M6 (skip neutralisation) fails the
  token test, whose positive control shows the detector fires on the raw
  reason.

  No test here types a literal mention token: every adversarial reason is
  concatenated at runtime from an at-sign, an open bracket, a slug and a
  close bracket.
  """
  use Platform.DataCase, async: true

  import Ecto.Query
  import Platform.TenancyFixtures

  alias Platform.Agents.Agent
  alias Platform.Chat.{AttentionRouter, Message, Participant}
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Plan, PayloadAmendmentNotice, Validation}

  @payload %{
    "setup" => "A task with a merged PR",
    "actions" => "curl the endpoint with X-Forwarded-Host set",
    "expected" => "The endpoint answers 200"
  }

  @reason "actions sent a header the pipeline refuses"

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp seed(opts \\ []) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{name: "Amend Notice Project #{n}", org_id: fabrikam_org_id()})

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Amend Notice Task #{n}"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    {:ok, gate} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Task-level review"})

    {:ok, a} =
      Tasks.create_validation(%{
        stage_id: gate.id,
        kind: "e2e_behavior",
        evaluation_payload: @payload
      })

    plan = plan |> Plan.changeset(%{status: "approved"}) |> Repo.update!()

    space =
      if Keyword.get(opts, :space, true) do
        {:ok, space} = ExecutionSpace.find_or_create(task.id)
        # The system participant is what every router log in a live space has
        # already created; creating it up front makes "participants unchanged"
        # measure the amendment, not the first-ever post.
        {:ok, _} = ExecutionSpace.ensure_system_participant(space.id)
        space
      end

    %{task: task, plan: plan, a: a, space: space}
  end

  defp create_agent(prefix, name) do
    Repo.insert!(
      Agent.changeset(%Agent{}, %{
        slug: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}",
        name: name,
        status: "active"
      })
    )
  end

  defp notices(%{id: space_id}) do
    from(m in Message,
      where:
        m.space_id == ^space_id and
          fragment("?->>'reason' = ?", m.metadata, "validation_payload_amended"),
      order_by: [asc: m.inserted_at, asc: m.id]
    )
    |> Repo.all()
  end

  defp participant_count(%{id: space_id}) do
    Repo.aggregate(from(p in Participant, where: p.space_id == ^space_id), :count)
  end

  defp tokens(content) do
    {tokens, _legacy_zone} = AttentionRouter.extract_bracketed_tokens(String.downcase(content))
    tokens
  end

  # An at-sign-bracket token built at runtime, never typed.
  defp mention_token(slug), do: "@" <> "[" <> slug <> "]"

  # ── compose_message/4 ───────────────────────────────────────────────────

  describe "compose_message/4" do
    test "is exactly the contracted string" do
      validation = %Validation{
        id: "01a0e28d-0000-7000-8000-000000000001",
        evaluation_payload: Map.put(@payload, "actions", "curl without the header")
      }

      entry = %{"prior_payload" => @payload, "reason" => @reason}

      assert PayloadAmendmentNotice.compose_message(validation, entry, 1, "Planner") ==
               "E2E case amended: 01a0e28d-0000-7000-8000-000000000001 " <>
                 "(amendment 1, changed: actions). Amended by Planner. " <>
                 "Reason: actions sent a header the pipeline refuses"
    end

    test "lists changed fields comma-separated in setup, actions, expected order" do
      current = %{"setup" => "s2", "actions" => "a1", "expected" => "e2"}
      prior = %{"setup" => "s1", "actions" => "a1", "expected" => "e1"}

      assert PayloadAmendmentNotice.changed_fields(prior, current) == ["setup", "expected"]

      assert PayloadAmendmentNotice.compose_message(
               %Validation{id: "v", evaluation_payload: current},
               %{"prior_payload" => prior, "reason" => "r"},
               3,
               "x"
             ) ==
               "E2E case amended: v (amendment 3, changed: setup, expected). Amended by x. Reason: r"
    end

    test "amender: agent name, else the amended_by label, and system (no agent) for system" do
      agent = create_agent("notice-namer", "Namer")

      assert PayloadAmendmentNotice.amender_display(
               %{"amended_by" => agent.slug, "actor_type" => "agent"},
               agent.id
             ) == "Namer"

      assert PayloadAmendmentNotice.amender_display(
               %{"amended_by" => "some-slug", "actor_type" => "agent"},
               nil
             ) == "some-slug"

      # A malformed or unknown agent id folds to the label; it never raises.
      assert PayloadAmendmentNotice.amender_display(
               %{"amended_by" => "some-slug", "actor_type" => "agent"},
               "not-a-uuid"
             ) == "some-slug"

      assert PayloadAmendmentNotice.amender_display(
               %{"amended_by" => "operator:test", "actor_type" => "system"},
               nil
             ) == "system (no agent)"
    end
  end

  # ── Posting through amend_validation_payload/4 ──────────────────────────

  describe "amend_validation_payload/4 posts the notice" do
    test "one log-only message per amendment; the second says amendment 2" do
      amender = create_agent("notice-amender", "Amender Agent")
      s = seed()
      actor = {amender.slug, "agent", amender.id}

      assert notices(s.space) == []

      first = Map.put(@payload, "actions", "curl without the header")
      assert {:ok, v1} = Tasks.amend_validation_payload(s.a.id, first, @reason, actor)

      assert [m1] = notices(s.space)
      assert m1.log_only == true
      assert m1.content_type == "system"
      assert m1.metadata["validation_id"] == s.a.id
      assert m1.metadata["amendment_number"] == 1
      assert m1.metadata["source"] == "task_router"
      assert m1.metadata["kind"] == "log"

      assert m1.content ==
               "E2E case amended: #{s.a.id} (amendment 1, changed: actions). " <>
                 "Amended by Amender Agent. Reason: #{@reason}"

      second = Map.put(first, "expected", "The endpoint answers 204")

      assert {:ok, v2} =
               Tasks.amend_validation_payload(s.a.id, second, "expected the wrong code", actor)

      assert length(v2.payload_amendments) == 2
      assert v1.id == v2.id

      assert [^m1, m2] = notices(s.space)
      assert m2.metadata["amendment_number"] == 2

      assert m2.content ==
               "E2E case amended: #{s.a.id} (amendment 2, changed: expected). " <>
                 "Amended by Amender Agent. Reason: expected the wrong code"
    end

    test "the operator path is named system (no agent)" do
      s = seed()

      assert {:ok, _} =
               Tasks.amend_validation_payload(
                 s.a.id,
                 Map.put(@payload, "setup", "A task with two merged PRs"),
                 @reason,
                 {"operator:test", "system"}
               )

      assert [m] = notices(s.space)
      assert m.content =~ "(amendment 1, changed: setup). Amended by system (no agent). Reason:"
    end

    test "a refusal posts nothing" do
      s = seed()

      assert {:error, :unchanged} =
               Tasks.amend_validation_payload(s.a.id, @payload, @reason, {"p", "agent"})

      assert {:error, :reason_required} =
               Tasks.amend_validation_payload(
                 s.a.id,
                 Map.put(@payload, "setup", "x"),
                 "  ",
                 {"p", "agent"}
               )

      assert notices(s.space) == []
    end

    test "a task with no execution space still amends ok and posts nothing" do
      s = seed(space: false)
      assert ExecutionSpace.find_by_task_id(s.task.id) == nil

      # The skip is logged at :info, below the test env's :warning level, so
      # the log line itself is not observable here; the outcome is.
      assert {:ok, updated} =
               Tasks.amend_validation_payload(
                 s.a.id,
                 Map.put(@payload, "actions", "curl without the header"),
                 @reason,
                 {"p", "agent"}
               )

      assert [_] = updated.payload_amendments
      assert ExecutionSpace.find_by_task_id(s.task.id) == nil
    end
  end

  # ── Mention neutralisation ──────────────────────────────────────────────

  describe "a mention token in the reason" do
    test "is neutralised: no token in the body, nobody added to the space" do
      bystander = create_agent("notice-bystander", "Bystander")
      s = seed()
      reason = "probe points at the wrong port, cc " <> mention_token(bystander.slug)

      # POSITIVE CONTROL: the detector fires on the raw reason, so an empty
      # result on the body below is a measurement and not a blind spot.
      assert tokens(reason) == [String.downcase(bystander.slug)]

      participants_before = participant_count(s.space)
      refute Repo.get_by(Participant, space_id: s.space.id, participant_id: bystander.id)

      assert {:ok, _} =
               Tasks.amend_validation_payload(
                 s.a.id,
                 Map.put(@payload, "actions", "curl the right port"),
                 reason,
                 {"p", "agent"}
               )

      assert [m] = notices(s.space)
      assert tokens(m.content) == []
      # The reason is still quoted, readably, with the slug intact.
      assert m.content =~ "Reason: probe points at the wrong port, cc @ [#{bystander.slug}]"

      assert participant_count(s.space) == participants_before
      refute Repo.get_by(Participant, space_id: s.space.id, participant_id: bystander.id)
    end
  end
end
