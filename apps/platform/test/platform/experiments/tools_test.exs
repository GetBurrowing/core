defmodule Platform.Experiments.ToolsTest do
  @moduledoc """
  The `experiments` MCP tools end to end through `ToolSurface.execute/3`
  (task 01a0d415 stage 2): every step is a tool call, with no code change
  between steps.

  Launch approval is OPT-IN (Rowan, 2026-09-24): both the default (an agent's
  start runs) and the approval-on path (pending, then a human approves) are
  driven here. Stop feedback round-trips through experiment_get and
  experiment_list, and stopped is never concluded.

  `async: false`: registers test surfaces through app env.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Experiments
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Guardrail
  alias Platform.Experiments.Signals
  alias Platform.Experiments.TestSurfaces
  alias Platform.Experiments.Variant
  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration.PromptTemplate

  defp unique, do: System.unique_integer([:positive])

  defp agent!(metadata) do
    %Agent{}
    |> Agent.changeset(%{
      slug: "scientist-#{unique()}",
      name: "Scientist #{unique()}",
      status: "active",
      metadata: metadata
    })
    |> Repo.insert!()
  end

  defp user! do
    n = unique()

    %User{}
    |> User.changeset(%{
      email: "exp-#{n}@example.com",
      name: "Exp #{n}",
      oidc_sub: "oidc-exp-tools-#{n}"
    })
    |> Repo.insert!()
  end

  defp template! do
    %PromptTemplate{}
    |> PromptTemplate.changeset(%{
      slug: "tools.test.v#{unique()}",
      name: "Tools test",
      content: "LIVE BODY"
    })
    |> Repo.insert!()
  end

  defp guardrail!(attrs) do
    %Guardrail{}
    |> Guardrail.changeset(Map.merge(%{max_live: 3}, attrs))
    |> Repo.insert!()
  end

  defp call(tool, args, agent), do: ToolSurface.execute(tool, args, %{agent_id: agent.id})

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

  setup do
    TestSurfaces.register()
    org = tenant_org_id("soylent")

    %{
      org: org,
      other_org: tenant_org_id("sxi"),
      agent: agent!(%{"org_id" => org}),
      root_agent: agent!(%{}),
      sibling: agent!(%{"org_id" => tenant_org_id("sxi")})
    }
  end

  defp create!(ctx, overrides \\ %{}) do
    template = template!()

    args =
      Map.merge(
        %{
          "surface_key" => "dispatch.prompt",
          "surface_target" => template.slug,
          "name" => "Shorter preamble",
          "hypothesis" => "A shorter preamble keeps plans smaller.",
          "org_id" => ctx.org,
          "metric_spec" => %{
            "kind" => "outcome_rate",
            "labels" => ["screen"],
            "window_days" => 14
          },
          "stop_rule" => %{"min_subjects" => 2},
          # Refused and ignored: the status is never taken from args.
          "status" => "running"
        },
        overrides
      )

    assert {:ok, %{experiment: experiment}} = call("experiment_create", args, ctx.agent)
    experiment
  end

  defp add_arms!(ctx, id) do
    for {slug, body} <- [{"short", "SHORT BODY"}, {"long", "LONG BODY"}] do
      assert {:ok, %{variant: %{slug: ^slug, payload: %{"content" => ^body}}}} =
               call(
                 "experiment_variant_add",
                 %{"experiment_id" => id, "slug" => slug, "payload" => %{"content" => body}},
                 ctx.agent
               )
    end
  end

  describe "end to end with approval ON for the org" do
    test "create, add 2 arms, start (pending), approve as a user, running, results with n, stop",
         ctx do
      guardrail!(%{
        org_id: ctx.org,
        require_human_approval: true,
        allowed_surfaces: ["dispatch.prompt"]
      })

      experiment = create!(ctx)
      assert experiment.status == "draft"
      assert experiment.org_id == ctx.org
      assert experiment.proposed_by_agent_id == ctx.agent.id
      id = experiment.id

      add_arms!(ctx, id)

      assert {:ok, %{result: "pending_human_approval", experiment: pending}} =
               call("experiment_start", %{"experiment_id" => id}, ctx.agent)

      assert pending.status == "draft"
      assert pending.approval_state == "pending"

      # No tool approves a launch; a person does.
      refute Enum.any?(ToolSurface.list_tools(["experiments"]), &(&1.name =~ "approve"))

      assert {:ok, %Experiment{status: "running", approval_state: "approved"}} =
               Experiments.approve_launch(Repo.get!(Experiment, id), user!())

      assert {:ok, %{experiment: %{status: "running", variants: variants}}} =
               call("experiment_get", %{"experiment_id" => id}, ctx.agent)

      assert Enum.map(variants, & &1.slug) == ["control", "long", "short"]

      assert %{payload: %{"content" => "LIVE BODY"}} =
               Enum.find(variants, &(&1.slug == "control"))

      # Two eligible subjects on `short` (one positive), one still pending.
      running = Repo.get!(Experiment, id)
      [s1, s2, young] = for _ <- 1..3, do: Ecto.UUID.generate()

      for {subject, at} <- [{s1, days_ago(20)}, {s2, days_ago(20)}, {young, days_ago(1)}] do
        Repo.insert!(%Assignment{
          experiment_id: id,
          subject_type: "task",
          subject_id: subject,
          variant_slug: "short",
          assigned_at: at
        })
      end

      {:ok, _} =
        Signals.record(%{
          experiment_id: id,
          subject_type: "task",
          subject_id: s1,
          label: "screen",
          confidence: 0.9,
          reason: "invited to a screen",
          status: "labelled",
          source_type: "test",
          source_id: "src-#{unique()}",
          inserted_at: days_ago(15)
        })

      assert {:ok, %{experiment_id: ^id, rows: rows}} =
               call("experiment_results", %{"experiment_id" => id}, ctx.agent)

      short = Enum.find(rows, &(&1.variant_slug == "short"))
      assert short.value == 0.5
      assert short.n == 2
      assert short.pending == 1
      assert short.excluded == 0
      assert short.reason == "measured"

      control = Enum.find(rows, &(&1.variant_slug == "control"))
      assert control.value == nil
      assert control.n == 0
      assert control.reason == "insufficient_data"

      assert {:ok, %{count: 1, signals: [signal]}} =
               call("experiment_signals_list", %{"experiment_id" => id}, ctx.agent)

      assert signal == %{
               label: "screen",
               subject_id: s1,
               confidence: 0.9,
               reason: "invited to a screen",
               status: "labelled"
             }

      assert {:ok, %{experiment: stopped}} =
               call(
                 "experiment_stop",
                 %{"experiment_id" => id, "feedback" => "Confounded by a template edit."},
                 ctx.agent
               )

      assert stopped.status == "stopped"
      refute stopped.status == "concluded"
      assert stopped.stop_feedback == "Confounded by a template edit."
      assert stopped.stopped_by_user_id == nil
      assert %DateTime{} = stopped.stopped_at
      assert running.status == "running"

      # stopped cannot be turned into concluded.
      assert {:error, %{code: :invalid_status}} =
               call("experiment_conclude", %{"experiment_id" => id}, ctx.agent)

      assert Repo.get!(Experiment, id).status == "stopped"
    end
  end

  describe "default guardrails (no row): approval is off" do
    test "an agent's experiment_start goes straight to running", ctx do
      experiment = create!(ctx)
      add_arms!(ctx, experiment.id)

      assert {:ok,
              %{
                result: "running",
                experiment: %{status: "running", approval_state: "not_required"}
              }} =
               call("experiment_start", %{"experiment_id" => experiment.id}, ctx.agent)
    end

    test "a non-prompt surface starts with the control from control_payload/2", ctx do
      assert {:ok, %{experiment: %{id: id}}} =
               call(
                 "experiment_create",
                 %{
                   "surface_key" => "test.budget",
                   "surface_target" => "planner",
                   "name" => "Budget",
                   "org_id" => ctx.org
                 },
                 ctx.agent
               )

      assert {:ok, %{variant: %{slug: "tight", payload: %{"max_stages" => 3}}}} =
               call(
                 "experiment_variant_add",
                 %{"experiment_id" => id, "slug" => "tight", "payload" => %{"max_stages" => 3}},
                 ctx.agent
               )

      assert {:ok, %{result: "running"}} =
               call("experiment_start", %{"experiment_id" => id}, ctx.agent)

      assert %Variant{payload: %{}} =
               Repo.get_by!(Variant, experiment_id: id, slug: "control")
    end
  end

  describe "guardrail refusals over MCP carry discrete fields" do
    test "max_live_reached with limit 1 and current 1", ctx do
      guardrail!(%{org_id: ctx.org, max_live: 1, allowed_surfaces: ["dispatch.prompt"]})

      first = create!(ctx)

      {:ok, %{result: "running"}} =
        call("experiment_start", %{"experiment_id" => first.id}, ctx.agent)

      second = create!(ctx)

      assert {:error, envelope} =
               call("experiment_start", %{"experiment_id" => second.id}, ctx.agent)

      assert envelope.code == :max_live_reached
      assert envelope.refusal == %{code: :max_live_reached, limit: 1, current: 1, surface: nil}
      assert envelope.recoverable == false
      assert Repo.get!(Experiment, second.id).status == "draft"
    end

    test "surface_not_allowed at create, and nothing is written", ctx do
      guardrail!(%{org_id: ctx.org, allowed_surfaces: ["test.budget"]})
      before = Repo.aggregate(Experiment, :count)

      template = template!()

      assert {:error, envelope} =
               call(
                 "experiment_create",
                 %{
                   "surface_key" => "dispatch.prompt",
                   "surface_target" => template.slug,
                   "name" => "Nope",
                   "org_id" => ctx.org
                 },
                 ctx.agent
               )

      assert envelope.refusal == %{
               code: :surface_not_allowed,
               limit: nil,
               current: nil,
               surface: "dispatch.prompt"
             }

      assert Repo.aggregate(Experiment, :count) == before
    end

    test "an unknown surface such as mail.send is refused, and nothing is written", ctx do
      before = Repo.aggregate(Experiment, :count)

      assert {:error, %{code: :unknown_surface}} =
               call(
                 "experiment_create",
                 %{"surface_key" => "mail.send", "surface_target" => "x", "name" => "Send"},
                 ctx.agent
               )

      assert Repo.aggregate(Experiment, :count) == before
    end

    test "promote is refused while auto-promote is off", ctx do
      experiment = create!(ctx)
      add_arms!(ctx, experiment.id)
      {:ok, _} = call("experiment_start", %{"experiment_id" => experiment.id}, ctx.agent)

      assert {:error, %{code: :auto_promote_disabled}} =
               call(
                 "experiment_promote",
                 %{"experiment_id" => experiment.id, "variant" => "short"},
                 ctx.agent
               )
    end

    test "an invalid payload returns the surface's error list verbatim", ctx do
      {:ok, %{experiment: %{id: id}}} =
        call(
          "experiment_create",
          %{
            "surface_key" => "test.budget",
            "surface_target" => "planner",
            "name" => "Budget",
            "org_id" => ctx.org
          },
          ctx.agent
        )

      assert {:error,
              %{code: :invalid_payload, errors: ["max_stages must be an integer in 1..10"]}} =
               call(
                 "experiment_variant_add",
                 %{"experiment_id" => id, "slug" => "huge", "payload" => %{"max_stages" => 99}},
                 ctx.agent
               )

      assert {:error, %{code: :reserved_slug}} =
               call(
                 "experiment_variant_add",
                 %{"experiment_id" => id, "slug" => "control", "payload" => %{"max_stages" => 2}},
                 ctx.agent
               )
    end

    test "an unknown metric kind is refused with a specific error, and nothing is written", ctx do
      before = Repo.aggregate(Experiment, :count)
      template = template!()

      assert {:error, %{code: :invalid, errors: %{metric_spec: [_ | _]}}} =
               call(
                 "experiment_create",
                 %{
                   "surface_key" => "dispatch.prompt",
                   "surface_target" => template.slug,
                   "name" => "Bad metric",
                   "org_id" => ctx.org,
                   "metric_spec" => %{"kind" => "no_such_kind"}
                 },
                 ctx.agent
               )

      assert Repo.aggregate(Experiment, :count) == before
    end
  end

  describe "a human stop with feedback" do
    test "records who and why, round-trips through get and list, and is not concluded", ctx do
      experiment = create!(ctx)
      add_arms!(ctx, experiment.id)
      {:ok, _} = call("experiment_start", %{"experiment_id" => experiment.id}, ctx.agent)

      user = user!()

      assert {:ok, %Experiment{status: "stopped"} = stopped} =
               Experiments.stop(
                 Repo.get!(Experiment, experiment.id),
                 user,
                 "Candidates complained about the tone."
               )

      assert stopped.stopped_by_user_id == user.id
      assert stopped.stop_feedback == "Candidates complained about the tone."
      assert %DateTime{} = stopped.stopped_at

      assert {:ok, %{experiment: got}} =
               call("experiment_get", %{"experiment_id" => experiment.id}, ctx.agent)

      assert got.status == "stopped"
      assert got.stop_feedback == "Candidates complained about the tone."
      assert got.stopped_by_user_id == user.id

      assert {:ok, %{experiments: listed}} =
               call("experiment_list", %{"status" => "stopped"}, ctx.agent)

      assert %{stop_feedback: "Candidates complained about the tone.", status: "stopped"} =
               Enum.find(listed, &(&1.id == experiment.id))

      assert {:ok, %{experiments: concluded}} =
               call("experiment_list", %{"status" => "concluded"}, ctx.agent)

      refute Enum.any?(concluded, &(&1.id == experiment.id))
    end

    test "feedback cannot be written onto a running experiment without stopping it", ctx do
      experiment = create!(ctx)
      add_arms!(ctx, experiment.id)
      {:ok, _} = call("experiment_start", %{"experiment_id" => experiment.id}, ctx.agent)

      changeset =
        Repo.get!(Experiment, experiment.id)
        |> Experiment.changeset(%{stop_feedback: "sneaky"})

      refute changeset.valid?
    end
  end

  describe "tenancy" do
    test "a tenant-pinned agent cannot create in a sibling org or install-wide", ctx do
      template = template!()

      base = %{
        "surface_key" => "dispatch.prompt",
        "surface_target" => template.slug,
        "name" => "x"
      }

      assert {:error, %{code: :unauthorized}} =
               call("experiment_create", Map.put(base, "org_id", ctx.other_org), ctx.agent)

      assert {:error, %{code: :unauthorized}} = call("experiment_create", base, ctx.agent)

      assert {:ok, %{experiment: %{org_id: nil}}} =
               call("experiment_create", base, ctx.root_agent)
    end

    test "org_id is derived from project_id", ctx do
      {:ok, project} = Platform.Tasks.create_project(%{name: "P #{unique()}", org_id: ctx.org})
      template = template!()

      assert {:ok, %{experiment: %{org_id: org, project_id: pid}}} =
               call(
                 "experiment_create",
                 %{
                   "surface_key" => "dispatch.prompt",
                   "surface_target" => template.slug,
                   "name" => "Scoped",
                   "project_id" => project.id
                 },
                 ctx.agent
               )

      assert org == ctx.org
      assert pid == project.id
    end

    test "a sibling org's experiment is not found, not disclosed", ctx do
      experiment = create!(ctx)

      assert {:error, %{code: :not_found}} =
               call("experiment_get", %{"experiment_id" => experiment.id}, ctx.sibling)

      assert {:ok, %{experiments: listed}} = call("experiment_list", %{}, ctx.sibling)
      refute Enum.any?(listed, &(&1.id == experiment.id))
    end
  end

  describe "exclusion and goals" do
    test "experiment_exclude needs a reason and keeps the row", ctx do
      experiment = create!(ctx)
      add_arms!(ctx, experiment.id)
      {:ok, _} = call("experiment_start", %{"experiment_id" => experiment.id}, ctx.agent)
      subject = Ecto.UUID.generate()

      Repo.insert!(%Assignment{
        experiment_id: experiment.id,
        subject_type: "task",
        subject_id: subject,
        variant_slug: "short",
        assigned_at: DateTime.utc_now()
      })

      assert {:error, %{code: :missing_reason}} =
               call(
                 "experiment_exclude",
                 %{"experiment_id" => experiment.id, "subject_id" => subject},
                 ctx.agent
               )

      assert {:ok, %{assignment: %{variant_slug: "short", excluded_reason: "duplicate task"}}} =
               call(
                 "experiment_exclude",
                 %{
                   "experiment_id" => experiment.id,
                   "subject_id" => subject,
                   "reason" => "duplicate task"
                 },
                 ctx.agent
               )

      assert Repo.get_by!(Assignment, experiment_id: experiment.id, subject_id: subject)
    end

    test "goal_set creates and updates; goal_list sees it", ctx do
      assert {:ok, %{goal: %{id: id, statement: "More job responses", org_id: org}}} =
               call(
                 "experiment_goal_set",
                 %{"statement" => "More job responses", "org_id" => ctx.org},
                 ctx.agent
               )

      assert org == ctx.org

      assert {:ok, %{goal: %{status: "paused"}}} =
               call("experiment_goal_set", %{"goal_id" => id, "status" => "paused"}, ctx.agent)

      assert {:ok, %{goals: goals}} = call("experiment_goal_list", %{}, ctx.agent)
      assert Enum.any?(goals, &(&1.id == id))

      assert {:error, %{code: :not_found}} =
               call("experiment_goal_set", %{"goal_id" => id, "status" => "active"}, ctx.sibling)
    end
  end

  test "experiment_surface_list lists each surface's key, subject_type, path and schema", ctx do
    assert {:ok, %{surfaces: surfaces}} = call("experiment_surface_list", %{}, ctx.agent)

    assert %{subject_type: "task", path: "dispatch", payload_schema: %{"required" => ["content"]}} =
             Enum.find(surfaces, &(&1.key == "dispatch.prompt"))

    assert Enum.all?(surfaces, &(&1.path in ["dispatch", "draft"]))
  end
end
