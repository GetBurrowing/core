defmodule Platform.Responsibilities.ExperimentsScientistTest do
  @moduledoc """
  The `experiments.scientist` responsibility (task 01a0d415 stage 5, the
  experimentation-layer ADR-0052).

  The load-bearing test is the ABSENCE check: an inbound mail whose body,
  subject and sender each carry a distinctive string is ingested through the
  real path and labelled into a signal, and that string must appear nowhere
  in the gathered context or the rendered prompt. Its positive controls are
  that the string IS in the stored inbound row, and that the signal derived
  from that very mail IS in the context — so the check cannot pass by the
  signal never reaching the Scientist. It was shown to fail by adding the
  inbound `text_body` to the signal projection (stage notes carry the
  output).

  Every figure is a LITERAL (ADR-0048 addendum's anti-vacuity rule).

  async: false — the labeler stub and the native dispatcher are installed
  through Application env.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog
  import Platform.Test.ExperimentsMailFixtures

  alias Platform.Agents.Agent
  alias Platform.Experiments
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Goal
  alias Platform.Experiments.Signals
  alias Platform.Experiments.Signals.MailSource
  alias Platform.Mail.InboundMessage
  alias Platform.Responsibilities
  alias Platform.Responsibilities.BuiltIns
  alias Platform.Responsibilities.Handlers.ExperimentsScientist, as: Handler
  alias Platform.Responsibilities.Providers
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Roles.RoleResponsibility
  alias Platform.Test.ExperimentsLabelerStub, as: Stub
  alias Platform.Tenancy

  @key "experiments.scientist"
  @goal "More job responses"
  @feedback "Stopped: the directive leaked the company name into the subject line."

  @outcome_spec %{
    "kind" => "outcome_rate",
    "labels" => ["screen"],
    "window_days" => 7,
    "anchor" => "assigned_at"
  }

  defmodule CaptureDispatcher do
    @moduledoc false
    def maybe_dispatch(signal) do
      pid = Application.get_env(:platform, :scientist_capture_pid)
      if is_pid(pid), do: send(pid, {:captured_signal, signal})
      :ok
    end
  end

  setup do
    org_id = Tenancy.get_org_by_slug!("soylent").id
    %{org_id: org_id}
  end

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

  defp goal!(org_id) do
    %Goal{}
    |> Goal.changeset(%{statement: @goal, org_id: org_id, status: "active"})
    |> Repo.insert!()
  end

  defp assign_at!(experiment, variant_slug, assigned_at) do
    subject_id = Ecto.UUID.generate()

    Repo.insert!(%Assignment{
      experiment_id: experiment.id,
      subject_type: "task",
      subject_id: subject_id,
      variant_slug: variant_slug,
      assigned_at: assigned_at
    })

    subject_id
  end

  # A running mail-signal experiment on the goal, with a control arm that has
  # nothing eligible and a treatment arm whose figure is earned:
  #   treatment: 2 subjects past the 7-day window (1 screened), 1 inside it
  #   -> value 0.5, n 2, pending 1; stop rule 2 -> measured.
  defp running_experiment!(goal, org_id) do
    experiment =
      mail_experiment!(%{
        name: "Voice model vs default",
        org_id: org_id,
        goal_id: goal.id,
        metric_spec: @outcome_spec,
        stop_rule: %{"min_subjects" => 2}
      })

    {:ok, _} = Experiments.add_variant(experiment, %{slug: "treatment", content: "t", weight: 1})

    screened = assign_at!(experiment, "treatment", days_ago(10))
    _silent = assign_at!(experiment, "treatment", days_ago(10))
    _young = assign_at!(experiment, "treatment", days_ago(1))

    {:ok, _} =
      Signals.record(%{
        experiment_id: experiment.id,
        subject_type: "task",
        subject_id: screened,
        label: "screen",
        status: "labelled",
        source_type: "test",
        source_id: "src-#{unique()}",
        reason: "Invites a phone screen.",
        inserted_at: days_ago(8)
      })

    experiment
  end

  defp stopped_experiment!(goal, org_id) do
    {:ok, experiment} =
      Experiments.create_experiment(%{
        slug: "stopped-#{unique()}",
        name: "Stopped arm",
        org_id: org_id,
        goal_id: goal.id
      })

    {:ok, stopped} = Experiments.stop(experiment, %{stop_feedback: @feedback})
    stopped
  end

  # Ingests a mail whose body, subject and sender carry `secret`, and labels
  # it into a signal on `experiment` through the real MailSource path.
  defp secret_signal!(experiment, org_id, secret) do
    agent = scientist!()
    :ok = Stub.install!(fn _c, _m, _o -> {:error, :no_reply_planted} end)

    Stub.reply!(
      Stub.json(%{
        "label" => "rejection",
        "subject_id" => nil,
        "confidence" => 0.7,
        "reason" => "The email declines the application."
      })
    )

    {1, inbound} =
      ingest!(account!(org_id),
        body: "Unfortunately we will not proceed. #{secret}",
        subject: "Re: application #{secret}",
        from: "Recruiter <#{String.downcase(secret)}@corp.test>"
      )

    [{:ok, signal}] = MailSource.on_inbound(inbound.id)
    {agent, inbound, signal}
  end

  defp row(entry, slug), do: Enum.find(entry.results, &(&1.variant_slug == slug))

  describe "register/0" do
    test "a cron row every six hours, in the scientist role, owning its template" do
      assert [spec] = Handler.register()

      assert spec.key == @key
      assert spec.feature == "experiments"
      assert spec.trigger_kind == "cron"
      assert spec.trigger_config == %{"expression" => "0 */6 * * *"}
      assert spec.scope == "global"
      assert spec.default_prompt_template == "experiments.scientist.v1"
      assert spec.metadata["role"] == "scientist"

      assert {:ok, _row} = Responsibilities.upsert_by_key(spec)
    end

    test "the handler is a built-in and the experiments provider routes the key to it" do
      assert Handler in BuiltIns.providers()
      assert Providers.Experiments.handler_for(@key) == Handler
      assert Enum.any?(Providers.Experiments.register(), &(&1.key == @key))
    end

    test "handle_output/3 is a logged no-op" do
      # The test env's primary level is above :info; raise it for this module.
      Logger.put_module_level(Handler, :info)
      on_exit(fn -> Logger.delete_module_level(Handler) end)

      log =
        capture_log([level: :info], fn ->
          assert :ok = Handler.handle_output(%{}, %{"summary" => "x"}, %{})
        end)

      assert log =~ "[experiments.scientist] output ignored by design"
    end
  end

  describe "gather_context/1" do
    test "figures travel with n; insufficient data is words; stop feedback is carried", ctx do
      goal = goal!(ctx.org_id)
      running = running_experiment!(goal, ctx.org_id)
      stopped = stopped_experiment!(goal, ctx.org_id)

      context = Handler.gather_context(%{})

      assert [entry] = context.goals
      assert entry.goal.statement == @goal
      assert entry.goal.org_id == ctx.org_id

      assert entry.guardrails.require_human_approval == false
      assert entry.guardrails.max_live == 3
      assert entry.guardrails.live == 1

      running_entry = Enum.find(entry.experiments, &(&1.id == running.id))
      assert running_entry.status == "running"

      treatment = row(running_entry, "treatment")
      assert treatment.value == 0.5
      assert treatment.n == 2
      assert treatment.pending == 1
      assert treatment.excluded == 0
      assert treatment.reason == "measured"
      assert treatment.reading == "50.0% · n=2 (0 excluded, 1 pending)"

      control = row(running_entry, "control")
      assert control.value == nil
      refute control.value == 0.0
      assert control.n == 0
      assert control.reason == "insufficient_data"
      assert control.reading =~ "insufficient data — not yet, not no effect"

      stopped_entry = Enum.find(entry.experiments, &(&1.id == stopped.id))
      assert stopped_entry.status == "stopped"
      assert stopped_entry.stop_feedback == @feedback

      assert [stop] = context.recent_stops
      assert stop.id == stopped.id
      assert stop.stop_feedback == @feedback
      assert stop.stopped_by_human == false

      assert Enum.map(context.surfaces, & &1.key) |> Enum.sort() ==
               [
                 "chat.context_summary",
                 "dispatch.code_mode",
                 "dispatch.product_docs_preamble",
                 "dispatch.prompt",
                 "mail.draft.generator",
                 "meetings.open_question_classifier",
                 "planner.stage_budget"
               ]
    end

    test "a mail body, subject or sender string is ABSENT from the whole context", ctx do
      secret = "ZX-SECRET-BODY-#{Ecto.UUID.generate()}"
      goal = goal!(ctx.org_id)
      experiment = running_experiment!(goal, ctx.org_id)
      {_agent, inbound, signal} = secret_signal!(experiment, ctx.org_id, secret)

      # POSITIVE CONTROL 1: the string really is in the stored mail.
      stored = Repo.get!(InboundMessage, inbound.id)
      assert stored.text_body =~ secret
      assert stored.subject =~ secret

      context = Handler.gather_context(%{})

      # POSITIVE CONTROL 2: the signal derived from THAT mail reached the
      # Scientist, so the absence below is not the absence of the signal.
      [entry] = context.goals
      scientist_view = Enum.find(entry.experiments, &(&1.id == experiment.id)).signals

      assert %{label: "rejection", subject_id: nil, reason: reason} =
               Enum.find(scientist_view.recent, &(&1.label == "rejection"))

      assert reason == signal.reason
      assert scientist_view.by_label["rejection"] == 1
      assert scientist_view.by_label["screen"] == 1
      assert scientist_view.by_status["labelled"] == 2

      # The signal tuple is these four keys and nothing else.
      for tuple <- scientist_view.recent do
        assert tuple |> Map.keys() |> Enum.sort() == [:confidence, :label, :reason, :subject_id]
      end

      # THE ABSENCE CHECK, over the whole map and the rendered prompt.
      refute inspect(context, limit: :infinity, printable_limit: :infinity) =~ secret

      {:ok, %{system: system, user: user}} = Handler.build_prompt(context)
      refute system =~ secret
      refute user =~ secret
      refute user =~ String.downcase(secret)
    end

    test "the prompt carries the goal, the figures with n, and opt-in approval", ctx do
      goal = goal!(ctx.org_id)
      running_experiment!(goal, ctx.org_id)
      stopped_experiment!(goal, ctx.org_id)

      {:ok, %{user: user}} = Handler.build_prompt(Handler.gather_context(%{}))

      assert user =~ @goal
      assert user =~ "50.0% · n=2 (0 excluded, 1 pending)"
      assert user =~ @feedback
      # Rowan, 2026-09-24: approval is opt-in per org.
      assert user =~ "By default a start goes straight to `running`"
      assert user =~ "`pending_human_approval`: that is success, not a failure to retry"
      refute user =~ "{{state}}"
    end
  end

  describe "gather_context/1 tenancy" do
    # Review finding at 66af0259: one cron dispatch carried goals, figures
    # and label reasons from three orgs. The context is now scoped to the
    # scientist assignee's home org, by the stage-2 tools' own check.
    @goal_b "ORG-B-GOAL-do-not-leak"
    @reason_b "ORG-B-REASON-names-a-company"

    defp pinned_scientist!(org_id) do
      agent =
        %Agent{}
        |> Agent.changeset(%{
          slug: "scientist-pinned-#{unique()}",
          name: "Pinned Scientist",
          status: "active",
          kind: "native",
          runtime_type: "external",
          metadata: %{"org_id" => org_id}
        })
        |> Repo.insert!()

      :ok = Roles.unassign_role("scientist")
      {:ok, _} = Roles.assign_role("scientist", agent.id)
      agent
    end

    defp org_b_world!(org_b) do
      goal_b =
        %Goal{}
        |> Goal.changeset(%{statement: @goal_b, org_id: org_b, status: "active"})
        |> Repo.insert!()

      experiment_b = running_experiment!(goal_b, org_b)
      subject = assign_at!(experiment_b, "treatment", days_ago(10))

      {:ok, _} =
        Signals.record(%{
          experiment_id: experiment_b.id,
          subject_type: "task",
          subject_id: subject,
          label: "screen",
          status: "labelled",
          source_type: "test",
          source_id: "src-#{unique()}",
          reason: @reason_b,
          inserted_at: days_ago(8)
        })

      {:ok, stopped_b} =
        Experiments.create_experiment(%{
          slug: "stopped-b-#{unique()}",
          name: "ORG-B-STOPPED",
          org_id: org_b,
          goal_id: goal_b.id
        })

      {:ok, _} = Experiments.stop(stopped_b, %{stop_feedback: "ORG-B-FEEDBACK"})
      experiment_b
    end

    test "a tenant-pinned scientist sees its own org and install-wide rows, never another org",
         ctx do
      org_a = ctx.org_id
      org_b = Tenancy.get_org_by_slug!("paragon").id

      goal_a = goal!(org_a)
      experiment_a = running_experiment!(goal_a, org_a)

      install_goal =
        %Goal{}
        |> Goal.changeset(%{statement: "INSTALL-WIDE-GOAL", org_id: nil, status: "active"})
        |> Repo.insert!()

      experiment_b = org_b_world!(org_b)
      pinned_scientist!(org_a)

      context = Handler.gather_context(%{})
      dump = inspect(context, limit: :infinity, printable_limit: :infinity)

      # POSITIVE CONTROLS: org A's goal and figures, and the install-wide goal.
      assert dump =~ @goal
      assert dump =~ experiment_a.id
      assert dump =~ "INSTALL-WIDE-GOAL"

      assert Enum.map(context.goals, & &1.goal.id) |> Enum.sort() ==
               Enum.sort([goal_a.id, install_goal.id])

      # Org B's goal, experiment, figures, label reasons and stop feedback.
      refute dump =~ @goal_b
      refute dump =~ experiment_b.id
      refute dump =~ @reason_b
      refute dump =~ "ORG-B-FEEDBACK"
      refute dump =~ "ORG-B-STOPPED"
      refute dump =~ org_b
    end

    test "an unpinned scientist is install-wide and sees both orgs (the same data can leak)",
         ctx do
      org_b = Tenancy.get_org_by_slug!("paragon").id
      goal!(ctx.org_id)
      experiment_b = org_b_world!(org_b)
      scientist!()

      dump = inspect(Handler.gather_context(%{}), limit: :infinity, printable_limit: :infinity)

      # Shows the refutes above are not vacuous: the instrument sees org B's
      # strings when the assignee is allowed to.
      assert dump =~ @goal
      assert dump =~ @goal_b
      assert dump =~ experiment_b.id
      assert dump =~ @reason_b
      assert dump =~ "ORG-B-FEEDBACK"
    end
  end

  describe "Router.fire/2" do
    setup do
      Logger.put_module_level(Platform.Responsibilities.Router, :info)
      on_exit(fn -> Logger.delete_module_level(Platform.Responsibilities.Router) end)

      Application.put_env(:platform, :scientist_capture_pid, self())
      on_exit(fn -> Application.delete_env(:platform, :scientist_capture_pid) end)

      Application.put_env(
        :platform,
        :responsibility_router_native_dispatcher,
        {CaptureDispatcher, :maybe_dispatch}
      )

      on_exit(fn ->
        Application.delete_env(:platform, :responsibility_router_native_dispatcher)
      end)

      [spec] = Handler.register()
      {:ok, _row} = Responsibilities.upsert_by_key(spec)
      :ok
    end

    defp fire! do
      {result, _log} =
        with_log([level: :info], fn ->
          Router.fire(@key, %{kind: :cron, fired_at: DateTime.utc_now()})
        end)

      result
    end

    test "with no scientist pinned it is unfilled and dispatches nothing", ctx do
      goal!(ctx.org_id)
      :ok = Roles.unassign_role("scientist")

      assert {:ok, :unfilled} = fire!()
      refute_receive {:captured_signal, _}, 200
    end

    test "with a scientist pinned the dispatch carries the goal and no mail text", ctx do
      secret = "ZX-SECRET-BODY-#{Ecto.UUID.generate()}"
      goal = goal!(ctx.org_id)
      experiment = running_experiment!(goal, ctx.org_id)
      secret_signal!(experiment, ctx.org_id, secret)

      agent =
        %Agent{}
        |> Agent.changeset(%{
          slug: "scientist-native-#{unique()}",
          name: "Scientist Fire Test",
          status: "active",
          kind: "native",
          runtime_type: "external",
          workspace_id: nil
        })
        |> Repo.insert!()

      :ok = Roles.unassign_role("scientist")
      {:ok, _} = Roles.assign_role("scientist", agent.id)

      assert {:ok, :dispatched} = fire!()
      assert_receive {:captured_signal, signal}
      assert signal.metadata.responsibility_key == @key
      assert signal.metadata.agent_id == agent.id
      assert signal.metadata.prompt =~ @goal
      assert signal.metadata.prompt =~ "n=2"
      refute signal.metadata.prompt =~ secret
    end
  end

  describe "the scientist role bundle" do
    test "holds both experiments keys, and re-seeding adds nothing" do
      :ok = Roles.Seeds.seed_defaults()
      :ok = Roles.Seeds.seed_defaults()

      assert Roles.bundle_for("scientist") == [
               "experiments.label_signal",
               "experiments.scientist"
             ]

      assert Repo.aggregate(
               from(rr in RoleResponsibility, where: rr.role_key == "scientist"),
               :count
             ) == 2
    end
  end
end
