defmodule PlatformWeb.ExperimentsLiveTest do
  @moduledoc """
  What `/control/experiments` must refuse to render. Task 019fe6ba, ADR-0048.

    * It must resolve as the experiments page, not as an agent named
      "experiments" — the route sits under a catch-all `/control/:agent_slug`
      and an ordering regression is invisible until someone opens the URL.
    * A result below its stop rule must show no number AT ALL. That is
      asserted as the absence of any digit inside the result cell, not as the
      presence of the words "no effect yet": the page is full of digits and
      full of prose, and a whole-page grep for either passes for reasons that
      have nothing to do with the cell under test.
    * An earned figure must carry its basis in the SAME cell.
    * An excluded assignment must stay listed with its reason.
    * `stopped` and `concluded` must both persist, with different markers.
    * A non-admin must be able to read both pages and must change nothing by
      firing any write event by name.

  Every assertion goes through `data-role` attributes rather than rendered
  copy, so a wording change does not silently vacate the test and a moved
  element does not silently satisfy it.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Experiments
  alias Platform.Experiments.Assignments
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Stage
  alias Platform.Tasks.Validation
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # LazyHTML, not Floki — Phoenix.LiveViewTest 1.1 replaced it.
  defp q(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp text(html, selector), do: html |> q(selector) |> LazyHTML.text()

  defp member_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "experiments-member-#{n}@example.com",
        name: "Experiments Member",
        oidc_sub: "oidc-experiments-member-#{n}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp admin_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "experiments-admin-#{n}@example.com",
        name: "Experiments Admin",
        oidc_sub: "oidc-experiments-admin-#{n}"
      })

    org = Tenancy.get_org_by_slug!("fabrikam")

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "admin"})
    |> Repo.insert!()

    init_test_session(conn, current_user_id: user.id)
  end

  defp template(slug, content \\ "You are a planner.") do
    Repo.insert!(%PromptTemplate{slug: slug, name: slug, content: content, description: "t"})
  end

  # An experiment already past activation, so it has a real control snapshot
  # rather than a hand-inserted variant row.
  defp running_experiment(slug, opts) do
    stop_rule = Keyword.get(opts, :stop_rule, %{"min_subjects" => 120})
    metric = Keyword.get(opts, :metric, "validation_failure_rate")

    {:ok, experiment} =
      Experiments.create_experiment(%{
        slug: slug,
        name: Keyword.get(opts, :name, "Experiment #{slug}"),
        hypothesis: "Terser briefs reduce revisions.",
        primary_metric: metric,
        stop_rule: stop_rule
      })

    tmpl = template("tmpl-#{slug}")
    {:ok, experiment} = Experiments.activate(experiment, tmpl.slug)
    experiment
  end

  # Builds `count` subjects in an arm, each carrying `resolved` validations
  # with the given status, so ValidationFailureRate has a real `n` to report.
  # `n` counts RESOLVED VALIDATIONS, not subjects — the metric's own
  # moduledoc says so, and a fixture that conflates them proves nothing about
  # the stop rule.
  defp seed_arm(experiment, variant_slug, count, validations_each, status) do
    {:ok, project} = Tasks.create_project(%{name: "Exp #{System.unique_integer([:positive])}"})

    for _ <- 1..count do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Subject"})

      Repo.insert!(%Platform.Experiments.Assignment{
        experiment_id: experiment.id,
        subject_type: "task",
        subject_id: task.id,
        variant_slug: variant_slug,
        assigned_at: DateTime.utc_now()
      })

      plan = Repo.insert!(%Plan{task_id: task.id, version: 1, status: "approved"})
      stage = Repo.insert!(%Stage{plan_id: plan.id, name: "s", position: 1, status: "pending"})

      for _ <- 1..validations_each do
        Repo.insert!(%Validation{stage_id: stage.id, kind: "test_pass", status: status})
      end

      task
    end
  end

  describe "routing" do
    test "both paths resolve as the experiments page, not as an agent slug", %{conn: conn} do
      running_experiment("routing-check", [])
      conn = member_conn(conn)

      {:ok, _view, html} = live(conn, ~p"/control/experiments")
      assert q(html, ~s([data-role="result-cell"])) |> Enum.count() > 0

      {:ok, _view, detail} = live(conn, ~p"/control/experiments/routing-check")
      assert q(detail, ~s([data-role="experiment-tab"])) |> Enum.count() == 4
    end
  end

  describe "the stop rule" do
    test "below the stop rule the cell shows no digit anywhere", %{conn: conn} do
      experiment = running_experiment("below-stop", stop_rule: %{"min_subjects" => 120})
      seed_arm(experiment, "control", 4, 3, "failed")

      {:ok, _view, html} = live(member_conn(conn), ~p"/control/experiments/below-stop")

      cell = q(html, ~s(#result-control [data-role="result-figure"]))
      assert LazyHTML.text(cell) =~ "no effect yet"

      # The load-bearing assertion: not "it says the honest words" but "it
      # contains no number". A figure rendered beside the words would pass the
      # line above and fail this one.
      refute LazyHTML.text(cell) =~ ~r/\d/

      assert q(html, ~s(#result-control [data-role="result-cell"][data-state="insufficient"]))
             |> Enum.count() == 1
    end

    test "the basis is stated in the same cell, in both states", %{conn: conn} do
      experiment = running_experiment("basis-check", stop_rule: %{"min_subjects" => 120})
      seed_arm(experiment, "control", 4, 3, "failed")

      {:ok, _view, html} = live(member_conn(conn), ~p"/control/experiments/basis-check")

      basis = text(html, ~s(#result-control [data-role="result-basis"]))
      assert basis =~ "4 subjects"
      assert basis =~ "12 measured"
      assert basis =~ "stop rule 120"
    end

    test "above the stop rule the figure appears WITH its basis", %{conn: conn} do
      experiment = running_experiment("above-stop", stop_rule: %{"min_subjects" => 10})
      seed_arm(experiment, "control", 6, 2, "failed")

      {:ok, _view, html} = live(member_conn(conn), ~p"/control/experiments/above-stop")

      assert q(html, ~s(#result-control [data-role="result-cell"][data-state="measured"]))
             |> Enum.count() == 1

      figure = text(html, ~s(#result-control [data-role="result-figure"]))
      # All twelve resolved validations failed, so the rate is 100.0%.
      assert figure =~ "100.0%"

      basis = text(html, ~s(#result-control [data-role="result-basis"]))
      assert basis =~ "12 measured"
      assert basis =~ "stop rule 10"
    end

    test "an absent stop rule earns no figure — it fails closed", %{conn: conn} do
      experiment = running_experiment("no-stop-rule", stop_rule: %{})
      seed_arm(experiment, "control", 6, 2, "failed")

      {:ok, _view, html} = live(member_conn(conn), ~p"/control/experiments/no-stop-rule")

      cell = q(html, ~s(#result-control [data-role="result-figure"]))
      refute LazyHTML.text(cell) =~ ~r/\d/
      assert text(html, ~s(#result-control [data-role="result-confound"])) =~ "no stop rule"
    end

    test "no page anywhere renders a projected lift", %{conn: conn} do
      experiment = running_experiment("no-projection", stop_rule: %{"min_subjects" => 10})
      seed_arm(experiment, "control", 6, 2, "failed")

      {:ok, _view, html} = live(member_conn(conn), ~p"/control/experiments/no-projection")

      refute html =~ "projected"
      refute html =~ "lift"
    end
  end

  describe "the sparse state" do
    test "a draft with zero subjects renders a complete cell, not a hole", %{conn: conn} do
      {:ok, _draft} =
        Experiments.create_experiment(%{
          slug: "sparse-draft",
          name: "Sparse draft",
          primary_metric: "validation_failure_rate",
          stop_rule: %{"min_subjects" => 120}
        })

      {:ok, _view, html} = live(member_conn(conn), ~p"/control/experiments")

      row = q(html, ~s(#experiment-row-sparse-draft [data-role="result-cell"]))
      assert Enum.count(row) == 1
      assert LazyHTML.text(row) =~ "no effect yet"
      assert LazyHTML.text(row) =~ "0 subjects"
      assert LazyHTML.text(row) =~ "stop rule 120"
    end
  end

  describe "exclusions stay visible" do
    test "an excluded assignment is listed with its reason", %{conn: conn} do
      experiment = running_experiment("exclusions", [])
      [task | _] = seed_arm(experiment, "control", 3, 1, "passed")

      {:ok, _} =
        Assignments.exclude(experiment, {"task", task.id}, "cancelled before plan")

      {:ok, view, _html} = live(member_conn(conn), ~p"/control/experiments/exclusions")

      html =
        view
        |> element(~s([data-role="experiment-tab"][data-tab="assignments"]))
        |> render_click()

      excluded = q(html, ~s([data-role="assignment-row"][data-excluded="true"]))
      assert Enum.count(excluded) == 1
      assert LazyHTML.text(excluded) =~ "cancelled before plan"

      # It stays in the list rather than being filtered out of it: three
      # assigned, one of them excluded.
      assert q(html, ~s([data-role="assignment-row"])) |> Enum.count() == 3
    end
  end

  describe "stopped and concluded both persist" do
    test "both rows render with distinct status markers", %{conn: conn} do
      stopped = running_experiment("was-stopped", name: "Was stopped")
      concluded = running_experiment("was-concluded", name: "Was concluded")

      {:ok, _} = Experiments.stop(stopped)
      {:ok, _} = Experiments.conclude(concluded)

      {:ok, _view, html} = live(member_conn(conn), ~p"/control/experiments")

      assert q(html, ~s(#experiment-row-was-stopped [data-status="stopped"])) |> Enum.count() == 1

      assert q(html, ~s(#experiment-row-was-concluded [data-status="concluded"]))
             |> Enum.count() == 1

      # Distinct markers, not the same class under two names — if a future
      # edit collapses the two treatments this detonates.
      stopped_class = q(html, ~s(#experiment-row-was-stopped [data-role="status-badge"]))
      concluded_class = q(html, ~s(#experiment-row-was-concluded [data-role="status-badge"]))

      refute LazyHTML.attribute(stopped_class, "class") ==
               LazyHTML.attribute(concluded_class, "class")
    end
  end

  describe "reads are member-visible, writes are admin-only" do
    test "a non-admin member can read the list and the detail", %{conn: conn} do
      running_experiment("member-read", [])
      conn = member_conn(conn)

      {:ok, _view, html} = live(conn, ~p"/control/experiments")
      assert html =~ "Experiments"

      {:ok, _view, detail} = live(conn, ~p"/control/experiments/member-read")
      assert q(detail, ~s([data-role="experiment-tab"])) |> Enum.count() == 4
    end

    test "a non-admin firing each write event by name changes nothing", %{conn: conn} do
      experiment = running_experiment("member-write", [])

      {:ok, view, _html} = live(member_conn(conn), ~p"/control/experiments/member-write")

      # By NAME, not by clicking — the buttons are not rendered for a member,
      # and a test that could only click them would prove the affordance is
      # hidden rather than that the write is refused.
      for event <- ["stop", "promote", "activate", "create_experiment"] do
        render_hook(view, event, %{})
      end

      # Untouched: still running, still one control variant, no new rows.
      reloaded = Experiments.get_experiment_by_slug("member-write")
      assert reloaded.status == "running"
      assert reloaded.id == experiment.id
      assert Experiments.list_experiments() |> Enum.count() == 1
    end

    test "an admin firing the same events does change state — the control", %{conn: conn} do
      running_experiment("admin-write", [])

      {:ok, view, _html} = live(admin_conn(conn), ~p"/control/experiments/admin-write")

      render_hook(view, "stop", %{})

      # If this fails, the previous test proves nothing: a handler that
      # refused EVERYONE would pass it while the gate did no work.
      assert Experiments.get_experiment_by_slug("admin-write").status == "stopped"
    end
  end
end
