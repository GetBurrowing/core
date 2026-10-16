defmodule Platform.Experiments.GuardrailsTest do
  @moduledoc """
  `Platform.Experiments.Guardrails` (task 01a0d415 stage 2). Refusals are
  asserted as literal struct fields; the tenancy cases run on the
  `org_id` / `project_id` columns.

  `async: false`: registers test surfaces through app env, and inserts
  install-wide (null org) guardrail rows, which block concurrent sandboxes on
  the NULLS NOT DISTINCT index.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Experiments
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Guardrail
  alias Platform.Experiments.Guardrails
  alias Platform.Experiments.Guardrails.Refusal
  alias Platform.Experiments.TestSurfaces
  alias Platform.Tasks

  @budget "test.budget"

  setup do
    TestSurfaces.register()
    %{org_a: tenant_org_id("soylent"), org_b: tenant_org_id("sxi")}
  end

  defp guardrail!(attrs) do
    %Guardrail{}
    |> Guardrail.changeset(Map.merge(%{max_live: 3, allowed_surfaces: [@budget]}, attrs))
    |> Repo.insert!()
  end

  defp experiment!(attrs) do
    {:ok, experiment} =
      Experiments.create_experiment(
        Map.merge(
          %{
            slug: "g-#{System.unique_integer([:positive])}",
            name: "Guardrails",
            surface_key: @budget,
            surface_target: "planner"
          },
          attrs
        )
      )

    experiment
  end

  # Launched by a human (no approval step, not bound by allowed_surfaces), so
  # each test sets up exactly the live set it is about.
  defp running!(attrs) do
    experiment = experiment!(attrs)
    {:ok, running} = Experiments.start(experiment, root_admin!())
    running
  end

  defp project!(org_id) do
    {:ok, project} =
      Tasks.create_project(%{name: "G #{System.unique_integer([:positive])}", org_id: org_id})

    project
  end

  describe "for_org/1 built-in default (no guardrail row anywhere)" do
    test "approval is OFF, max_live 3, auto-promote off" do
      rails = Guardrails.for_org(Ecto.UUID.generate())

      assert rails.id == nil
      assert rails.require_human_approval == false
      assert rails.max_live == 3
      assert rails.allow_auto_promote == false
    end

    test "allowed_surfaces is every registered surface except a mail send path" do
      rails = Guardrails.for_org(nil)

      assert Enum.sort(rails.allowed_surfaces) ==
               [
                 "agents.tool_profile",
                 "chat.context_summary",
                 "dispatch.code_mode",
                 "dispatch.product_docs_preamble",
                 "dispatch.prompt",
                 "mail.draft.generator",
                 "mail.test.generator",
                 "meetings.open_question_classifier",
                 "planner.stage_budget",
                 "test.budget"
               ]

      assert Guardrails.default_allowed_surfaces() == rails.allowed_surfaces
      refute Enum.any?(rails.allowed_surfaces, &String.starts_with?(&1, "mail.send"))
    end

    test "an agent start under the default launches (no pending step)" do
      experiment = experiment!(%{org_id: tenant_org_id("soylent")})

      assert {:ok, %Experiment{status: "running", approval_state: "not_required"}} =
               Experiments.start(experiment, :agent)
    end
  end

  describe "for_org/1 row precedence" do
    test "the org's row wins, then THE install-wide row", %{org_a: a, org_b: b} do
      guardrail!(%{org_id: nil, max_live: 7})
      guardrail!(%{org_id: a, max_live: 1})

      assert Guardrails.for_org(a).max_live == 1
      assert Guardrails.for_org(b).max_live == 7
      assert Guardrails.for_org(nil).max_live == 7
    end

    test "a stored row NARROWS allowed_surfaces: [] allows no surface to an agent", %{org_a: a} do
      guardrail!(%{org_id: a, allowed_surfaces: []})
      experiment = experiment!(%{org_id: a})

      assert {:error,
              %Refusal{
                code: :surface_not_allowed,
                surface: "test.budget",
                limit: nil,
                current: nil
              }} =
               Guardrails.check(:create, experiment, :agent)

      # A human is not bound by allowed_surfaces.
      assert :ok = Guardrails.check(:create, experiment, %User{})
    end

    test "allowed_surfaces refuses a key that is not registered, including mail.send" do
      changeset =
        Guardrail.changeset(%Guardrail{}, %{
          max_live: 3,
          allowed_surfaces: ["test.budget", "mail.send", "nope"]
        })

      refute changeset.valid?

      assert {~s("mail.send" is not a registered surface), []} in Keyword.get_values(
               changeset.errors,
               :allowed_surfaces
             )

      assert {~s("nope" is not a registered surface), []} in Keyword.get_values(
               changeset.errors,
               :allowed_surfaces
             )
    end
  end

  describe "approval, when an org turns it on" do
    test "an agent start returns pending and leaves the experiment a draft", %{org_a: a} do
      guardrail!(%{org_id: a, require_human_approval: true})
      experiment = experiment!(%{org_id: a})

      assert {:ok, :pending_human_approval} = Experiments.start(experiment, :agent)

      reloaded = Repo.get!(Experiment, experiment.id)
      assert reloaded.status == "draft"
      assert reloaded.approval_state == "pending"

      # Idempotent: asking again is still pending, not an error and not running.
      assert {:ok, :pending_human_approval} = Experiments.start(reloaded, :agent)
    end

    test "approve_launch by a user runs it and records who approved", %{org_a: a} do
      guardrail!(%{org_id: a, require_human_approval: true})
      experiment = experiment!(%{org_id: a})
      {:ok, :pending_human_approval} = Experiments.start(experiment, :agent)

      %User{id: user_id} = admin = root_admin!()

      assert {:ok, %Experiment{status: "running", approval_state: "approved"}} =
               Experiments.approve_launch(experiment, admin)

      [event] = Platform.Audit.list(event_type: "platform.experiments.launch_approved")
      assert event.actor_id == user_id
      assert event.resource_id == experiment.id
    end

    test "approve_launch refuses an experiment that is not pending", %{org_a: a} do
      experiment = experiment!(%{org_id: a})

      assert {:error, :not_pending} = Experiments.approve_launch(experiment, root_admin!())
    end

    test "approve_launch still honours max_live: a human bypasses only the approval", %{
      org_a: a
    } do
      guardrail!(%{org_id: a, require_human_approval: true, max_live: 1})
      pending = experiment!(%{org_id: a, surface_target: "t1"})
      {:ok, :pending_human_approval} = Experiments.start(pending, :agent)
      _live = running!(%{org_id: a, surface_target: "t2"})

      assert {:error, %Refusal{code: :max_live_reached, limit: 1, current: 1}} =
               Experiments.approve_launch(pending, root_admin!())
    end
  end

  describe "max_live, counted per org on the org_id column" do
    test "limit 1 with one running in org A refuses a second in A and allows one in B", %{
      org_a: a,
      org_b: b
    } do
      guardrail!(%{org_id: a, max_live: 1})
      _live = running!(%{org_id: a, surface_target: "one"})

      second_a = experiment!(%{org_id: a, surface_target: "two"})

      assert {:error, %Refusal{code: :max_live_reached, limit: 1, current: 1, surface: nil}} =
               Experiments.start(second_a, :agent)

      assert Repo.get!(Experiment, second_a.id).status == "draft"

      in_b = experiment!(%{org_id: b, surface_target: "two"})
      assert {:ok, %Experiment{status: "running"}} = Experiments.start(in_b, :agent)
    end

    test "install-wide experiments count against the install-wide limit only", %{org_a: a} do
      guardrail!(%{org_id: nil, max_live: 1})
      _live = running!(%{org_id: nil, surface_target: "iw"})

      assert Guardrails.live_count(nil) == 1
      assert Guardrails.live_count(a) == 0
    end
  end

  describe "surface_busy, overlap computed on the columns" do
    test "an install-wide experiment and an org-A experiment on one target overlap", %{
      org_a: a
    } do
      _install_wide = running!(%{org_id: nil, surface_target: "shared"})
      org_scoped = experiment!(%{org_id: a, surface_target: "shared"})

      assert {:error, %Refusal{code: :surface_busy, surface: "test.budget", current: 1}} =
               Experiments.start(org_scoped, :agent)
    end

    test "projects P and Q in the same org do not overlap", %{org_a: a} do
      p = project!(a)
      q = project!(a)

      _in_p = running!(%{project_id: p.id, surface_target: "per-project"})
      in_q = experiment!(%{project_id: q.id, surface_target: "per-project"})

      assert {:ok, %Experiment{status: "running", org_id: ^a}} = Experiments.start(in_q, :agent)
    end

    test "an org-wide experiment overlaps a project inside it", %{org_a: a} do
      p = project!(a)
      _org_wide = running!(%{org_id: a, surface_target: "wide"})
      in_p = experiment!(%{project_id: p.id, surface_target: "wide"})

      assert {:error, %Refusal{code: :surface_busy}} = Experiments.start(in_p, :agent)
    end

    test "a different target on the same surface does not overlap", %{org_a: a} do
      _one = running!(%{org_id: a, surface_target: "x"})
      other = experiment!(%{org_id: a, surface_target: "y"})

      assert {:ok, %Experiment{status: "running"}} = Experiments.start(other, :agent)
    end
  end

  describe "promote" do
    test "an agent is refused while allow_auto_promote is off (the default)", %{org_a: a} do
      experiment = experiment!(%{org_id: a})

      assert {:error, %Refusal{code: :auto_promote_disabled, surface: "test.budget"}} =
               Guardrails.check(:promote, experiment, :agent)
    end

    test "allowed when the org's row allows it", %{org_a: a} do
      guardrail!(%{org_id: a, allow_auto_promote: true})
      assert :ok = Guardrails.check(:promote, experiment!(%{org_id: a}), :agent)
    end

    test "any mail.* surface is refused for an agent whatever the row says", %{org_a: a} do
      guardrail!(%{
        org_id: a,
        allow_auto_promote: true,
        allowed_surfaces: ["test.budget", "mail.test.generator"]
      })

      experiment = experiment!(%{org_id: a, surface_key: "mail.test.generator"})

      assert {:error, %Refusal{code: :surface_not_promotable, surface: "mail.test.generator"}} =
               Guardrails.check(:promote, experiment, :agent)
    end
  end

  describe "the start lock" do
    test "with_start_lock takes transaction-scoped advisory locks" do
      experiment = experiment!(%{org_id: nil})

      assert {:ok, locks} =
               Guardrails.with_start_lock(experiment, fn ->
                 Repo.query!(
                   "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()"
                 ).rows
               end)

      # One org lock and one surface lock.
      assert locks == [[2]]
    end
  end

  describe "source" do
    test "guardrails.ex reads tenancy from columns only: no ->> and no scope" do
      source = File.read!("lib/platform/experiments/guardrails.ex")

      refute source =~ "->>"
      refute source =~ ~r/scope/i
    end
  end
end
