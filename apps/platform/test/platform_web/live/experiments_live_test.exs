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

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Experiments
  alias Platform.Experiments.Assignments
  alias Platform.Experiments.Guardrail
  alias Platform.Experiments.Guardrails
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

  defp admin_conn(conn), do: init_test_session(conn, current_user_id: admin_user().id)

  defp admin_conn(conn, %User{} = user), do: init_test_session(conn, current_user_id: user.id)

  defp admin_user do
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

    user
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
    test "below the stop rule the cell prints words and its n, and no figure", %{conn: conn} do
      experiment = running_experiment("below-stop", stop_rule: %{"min_subjects" => 120})
      seed_arm(experiment, "control", 4, 3, "failed")

      {:ok, _view, html} = live(member_conn(conn), ~p"/control/experiments/below-stop")

      cell = q(html, ~s(#result-control [data-role="result-figure"]))

      # EQUALITY on the whole figure element, not `=~`: the only digits it
      # may hold are the n (12 resolved validations). A rate rendered beside
      # the words would make this string longer and fail it. (Task 01a0d415
      # stage 6 replaced "no effect yet" with the canvas's wording, which
      # carries n; the old "no digit at all" assertion cannot survive a
      # fused n, so it is replaced by this exact match.)
      assert cell |> LazyHTML.text() |> String.trim() == "not enough data · n=12"
      refute LazyHTML.text(cell) =~ "%"

      assert q(html, ~s(#result-control [data-role="result-cell"][data-state="insufficient"]))
             |> Enum.count() == 1
    end

    test "the basis is stated in the same cell, in both states", %{conn: conn} do
      experiment = running_experiment("basis-check", stop_rule: %{"min_subjects" => 120})
      seed_arm(experiment, "control", 4, 3, "failed")

      {:ok, _view, html} = live(member_conn(conn), ~p"/control/experiments/basis-check")

      basis = text(html, ~s(#result-control [data-role="result-basis"]))
      assert basis =~ "4 subjects"
      assert basis =~ "stop rule 120"
      # n travels in the figure, not in the basis caption.
      assert text(html, ~s(#result-control [data-role="result-figure"])) =~ "n=12"
    end

    test "above the stop rule the figure appears WITH its basis", %{conn: conn} do
      experiment = running_experiment("above-stop", stop_rule: %{"min_subjects" => 10})
      seed_arm(experiment, "control", 6, 2, "failed")

      {:ok, _view, html} = live(member_conn(conn), ~p"/control/experiments/above-stop")

      assert q(html, ~s(#result-control [data-role="result-cell"][data-state="measured"]))
             |> Enum.count() == 1

      # All twelve resolved validations failed, so the rate is 100.0%, and
      # the n is IN THE SAME ELEMENT as the figure, in one fused string.
      fused =
        text(html, ~s(#result-control [data-role="result-figure"] [data-role="result-fused"]))

      assert String.trim(fused) == "100.0% · n=12"

      basis = text(html, ~s(#result-control [data-role="result-basis"]))
      assert basis =~ "stop rule 10"
    end

    test "an absent stop rule earns no figure — it fails closed", %{conn: conn} do
      experiment = running_experiment("no-stop-rule", stop_rule: %{})
      seed_arm(experiment, "control", 6, 2, "failed")

      {:ok, _view, html} = live(member_conn(conn), ~p"/control/experiments/no-stop-rule")

      cell = q(html, ~s(#result-control [data-role="result-figure"]))
      assert cell |> LazyHTML.text() |> String.trim() == "not enough data · n=12"
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
      assert LazyHTML.text(row) =~ "not enough data · n=0"
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

    test "subjects assigned in one burst render as distinguishable ids", %{conn: conn} do
      experiment = running_experiment("burst-ids", [])
      # A burst is the normal case, and it is the case that breaks a
      # head-truncated UUIDv7: the leading hex digits are timestamp high bits
      # and are identical for every row inserted in the same ~65-second
      # bucket, so the table would list four rows under one string.
      seed_arm(experiment, "control", 4, 1, "passed")

      {:ok, view, _html} = live(member_conn(conn), ~p"/control/experiments/burst-ids")

      html =
        view
        |> element(~s([data-role="experiment-tab"][data-tab="assignments"]))
        |> render_click()

      shown =
        html
        |> q(~s([data-role="assignment-row"] td:first-child))
        |> Enum.map(&LazyHTML.text(LazyHTML.from_fragment(LazyHTML.to_html(&1))))

      assert length(shown) == 4
      assert length(Enum.uniq(shown)) == 4, "subject ids collapsed onto #{inspect(shown)}"
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
      for event <- ["stop", "promote", "activate", "create_experiment", "delete_experiment"] do
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

  # ── THE TECHNIQUE SPLIT IS THE POINT OF THIS FILE ───────────────────────
  #
  # CAPABILITY cases below DRIVE THE RENDERED UI: they locate the form by
  # its `data-role` and submit it with `form/3 |> render_submit/1`. They
  # never use `render_hook`. The prior admin positive control fired
  # `create_experiment` BY NAME and passed while the page had no button at
  # all — a capability test that can pass on a page with no control is
  # testing the wrong thing, and that defect is why this work exists.
  #
  # REFUSAL cases (the non-admin block above) do the opposite deliberately:
  # they fire by name, because hiding a button is not a gate and the gate
  # must hold against a client that never rendered one.
  describe "creating an experiment through the rendered form" do
    test "the empty state leads somewhere for an admin, and the member still sees the page",
         %{conn: conn} do
      {:ok, _view, html} = live(admin_conn(conn), ~p"/control/experiments")

      assert q(html, ~s([data-role="empty-list"])) |> Enum.count() == 1
      assert q(html, ~s([data-role="new-experiment-button"])) |> Enum.count() == 1
      assert q(html, ~s([data-role="empty-create-cta"])) |> Enum.count() == 1

      {:ok, _view, member_html} = live(member_conn(conn), ~p"/control/experiments")

      # The absence assertions are not vacuous: the member reached the page.
      assert q(member_html, ~s([data-role="empty-list"])) |> Enum.count() == 1
      assert q(member_html, ~s([data-role="new-experiment-button"])) |> Enum.count() == 0
      assert q(member_html, ~s([data-role="empty-create-cta"])) |> Enum.count() == 0
    end

    test "the metric picker's options are exactly the computable metrics", %{conn: conn} do
      {:ok, view, _html} = live(admin_conn(conn), ~p"/control/experiments")

      html = view |> element(~s([data-role="new-experiment-button"])) |> render_click()

      values =
        html
        |> q(~s([data-role="metric-option"]))
        |> LazyHTML.attribute("value")
        |> Enum.sort()

      # EQUALS, not "contains" — a hard-coded template list would satisfy a
      # mere "has options" check and ship an option nothing can compute.
      assert values == Enum.sort(Platform.Experiments.Metrics.known_metrics())

      neutral = q(html, ~s([data-role="metric-option"][value="stages_per_plan"]))
      assert LazyHTML.attribute(neutral, "data-direction") == ["neutral"]
      assert LazyHTML.text(neutral) =~ "neutral"
    end

    test "no option carries a metric description — a native option cannot wrap", %{conn: conn} do
      {:ok, view, _html} = live(admin_conn(conn), ~p"/control/experiments")

      html = view |> element(~s([data-role="new-experiment-button"])) |> render_click()

      option_text = html |> q(~s([data-role="metric-option"])) |> LazyHTML.text()

      # The overflow that got this rejected was description text inside
      # `<option>`: 708px of unwrappable content in a 302px control, and the
      # popup sized itself to the content. Assert against the catalog rather
      # than a copied string, so a new metric's description cannot creep back.
      for metric <- Platform.Experiments.Metrics.catalog() do
        refute option_text =~ metric.description
        assert option_text =~ metric.label
      end
    end

    test "the description and direction appear under the select once picked", %{conn: conn} do
      {:ok, view, _html} = live(admin_conn(conn), ~p"/control/experiments")

      html = view |> element(~s([data-role="new-experiment-button"])) |> render_click()

      # Nothing picked yet: no helper line to show, and nothing claiming one.
      assert q(html, ~s([data-role="metric-description"])) |> Enum.count() == 0

      html =
        view
        |> element(~s([data-role="create-experiment-form"]))
        |> render_change(%{"primary_metric" => "stages_per_plan", "name" => "", "slug" => ""})

      described = q(html, ~s([data-role="metric-description"]))
      assert Enum.count(described) == 1

      text = LazyHTML.text(described)
      metric = Enum.find(Platform.Experiments.Metrics.catalog(), &(&1.slug == "stages_per_plan"))

      assert text =~ metric.description
      assert text =~ "neither direction is a win"
    end

    test "an admin creates a draft by submitting the rendered form", %{conn: conn} do
      {:ok, view, _html} = live(admin_conn(conn), ~p"/control/experiments")

      view |> element(~s([data-role="new-experiment-button"])) |> render_click()

      view
      |> form(~s([data-role="create-experiment-form"]), %{
        "name" => "Terser planner briefs",
        "slug" => "planner-terser-briefs",
        "hypothesis" => "Shorter briefs reduce planning time.",
        "primary_metric" => "cycle_time",
        "min_subjects" => "40"
      })
      |> render_submit()

      experiment = Experiments.get_experiment_by_slug("planner-terser-briefs")
      assert experiment.status == "draft"
      assert experiment.primary_metric == "cycle_time"

      # The exact shape `min_subjects/1` reads: string key, INTEGER value.
      # The string "40" would fail that guard and read as no stop rule.
      assert experiment.stop_rule["min_subjects"] == 40
      assert is_integer(experiment.stop_rule["min_subjects"])
      assert PlatformWeb.ExperimentResults.min_subjects(experiment) == 40

      # A draft and nothing else — no snapshot, no traffic.
      assert Experiments.list_variants(experiment) == []
      assert Assignments.list_assignments(experiment) == []
    end

    test "the stop rule is pre-filled rather than blank", %{conn: conn} do
      {:ok, view, _html} = live(admin_conn(conn), ~p"/control/experiments")

      html = view |> element(~s([data-role="empty-create-cta"])) |> render_click()

      assert q(html, ~s([data-role="create-stop-rule"])) |> LazyHTML.attribute("value") == ["40"]
    end
  end

  describe "activating through the rendered control" do
    test "an admin activates and the control variant holds the template text at activation",
         %{conn: conn} do
      {:ok, _draft} =
        Experiments.create_experiment(%{
          slug: "activate-me",
          name: "Activate me",
          hypothesis: "h",
          primary_metric: "cycle_time",
          stop_rule: %{"min_subjects" => 40}
        })

      tmpl = template("tmpl-activate-me", "Original control text.")

      {:ok, view, _html} = live(admin_conn(conn), ~p"/control/experiments/activate-me")

      html =
        view |> element(~s([data-role="experiment-tab"][data-tab="design"])) |> render_click()

      # The consequence is stated BEFORE the button, not after it.
      panel = html |> q(~s([data-role="activate-panel"])) |> LazyHTML.to_html()
      assert panel =~ ~s(data-role="activate-consequence")

      consequence_at = :binary.match(panel, ~s(data-role="activate-consequence")) |> elem(0)
      button_at = :binary.match(panel, ~s(data-role="activate-button")) |> elem(0)
      assert consequence_at < button_at

      view
      |> form(~s([data-role="activate-form"]), %{"template_slug" => tmpl.slug})
      |> render_submit()

      experiment = Experiments.get_experiment_by_slug("activate-me")
      assert experiment.status == "running"
      assert experiment.target_template_slug == tmpl.slug

      control = Experiments.list_variants(experiment) |> Enum.find(&(&1.slug == "control"))
      assert control.content == "Original control text."
    end
  end

  describe "deleting a draft" do
    test "an admin deletes a draft through the rendered control", %{conn: conn} do
      {:ok, _draft} =
        Experiments.create_experiment(%{
          slug: "delete-me",
          name: "Delete me",
          hypothesis: "h",
          primary_metric: "cycle_time",
          stop_rule: %{"min_subjects" => 40}
        })

      {:ok, view, _html} = live(admin_conn(conn), ~p"/control/experiments/delete-me")

      view |> element(~s([data-role="experiment-tab"][data-tab="design"])) |> render_click()
      view |> element(~s([data-role="delete-draft-button"])) |> render_click()

      assert Experiments.get_experiment_by_slug("delete-me") == nil
    end

    test "an admin firing delete BY NAME against a running experiment leaves the row",
         %{conn: conn} do
      experiment = running_experiment("keep-me", [])

      {:ok, view, _html} = live(admin_conn(conn), ~p"/control/experiments/keep-me")

      # By name, bypassing the affordance — the draft-only rule is the
      # context's, not the template's.
      render_hook(view, "delete_experiment", %{"slug" => "keep-me"})

      reloaded = Experiments.get_experiment_by_slug("keep-me")
      # Existence, not just the flash: "refused" and "refused after
      # deleting" have the same return value from the caller's seat.
      assert reloaded.id == experiment.id
      assert reloaded.status == "running"
      assert Experiments.list_variants(reloaded) != []
    end

    test "no delete control is rendered on a running experiment", %{conn: conn} do
      running_experiment("no-delete-control", [])

      {:ok, view, _html} = live(admin_conn(conn), ~p"/control/experiments/no-delete-control")

      html =
        view |> element(~s([data-role="experiment-tab"][data-tab="design"])) |> render_click()

      assert q(html, ~s([data-role="delete-draft-button"])) |> Enum.count() == 0
      assert q(html, ~s([data-role="activate-panel"])) |> Enum.count() == 0
      # Not vacuous: the Design tab did render.
      assert q(html, ~s([data-role="design-metric"])) |> Enum.count() == 1
    end
  end

  # ── Task 01a0d415 stage 6: results, guardrails, approval, human controls ──

  @planner "planner.stage_budget"
  @planning "dispatch.planning"

  # A draft on a NON-prompt surface, with a `tight` arm, scoped as asked.
  defp planner_draft(slug, opts \\ []) do
    {:ok, experiment} =
      Experiments.create_experiment(%{
        slug: slug,
        name: Keyword.get(opts, :name, "Planner #{slug}"),
        hypothesis: "A stage budget shortens plans.",
        primary_metric: "validation_failure_rate",
        stop_rule: %{"min_subjects" => Keyword.get(opts, :min_subjects, 5)},
        surface_key: @planner,
        surface_target: @planning,
        org_id: Keyword.get(opts, :org_id),
        project_id: Keyword.get(opts, :project_id),
        proposed_by_agent_id: Keyword.get(opts, :proposed_by_agent_id),
        metric_spec: Keyword.get(opts, :metric_spec, %{})
      })

    {:ok, _} =
      Experiments.add_variant(experiment, %{
        "slug" => "tight",
        "payload" => %{"max_stages" => 3},
        "weight" => 1
      })

    experiment
  end

  defp planner_running(slug, user, opts \\ []) do
    experiment = planner_draft(slug, opts)
    {:ok, running} = Experiments.start(experiment, user)
    running
  end

  defp null_org_guardrail_count do
    Repo.aggregate(from(g in Guardrail, where: is_nil(g.org_id)), :count)
  end

  defp agent(name) do
    Repo.insert!(%Platform.Agents.Agent{
      slug: "exp-agent-#{System.unique_integer([:positive])}",
      name: name,
      status: "active"
    })
  end

  # An org that turned approval ON, and an agent-proposed experiment in it
  # that an agent start has parked at pending.
  defp pending_experiment(slug) do
    org = Tenancy.get_org_by_slug!("fabrikam")

    Repo.insert!(%Guardrail{
      org_id: org.id,
      max_live: 3,
      allowed_surfaces: [@planner],
      require_human_approval: true,
      allow_auto_promote: false
    })

    proposer = agent("Scientist Sage")
    experiment = planner_draft(slug, org_id: org.id, proposed_by_agent_id: proposer.id)
    assert {:ok, :pending_human_approval} = Experiments.start(experiment, :agent)
    {Experiments.get_experiment_by_slug(slug), proposer}
  end

  describe "the result row (canvas rules 1 and 2)" do
    test "an earned row draws an evidence bar; an insufficient row has NO bar element",
         %{conn: conn} do
      user = admin_user()
      experiment = planner_running("bars", user)
      seed_arm(experiment, "tight", 6, 1, "failed")
      seed_arm(experiment, "control", 2, 1, "failed")

      {:ok, _view, html} = live(admin_conn(conn, user), ~p"/control/experiments/bars")

      assert q(html, ~s(#result-tight [data-role="evidence-bar"])) |> Enum.count() == 1
      # Not a zero-width bar: no bar element, and no success fill, anywhere
      # in the unearned row's DOM.
      assert q(html, ~s(#result-control [data-role="evidence-bar"])) |> Enum.count() == 0
      assert q(html, ~s(#result-control .bg-success)) |> Enum.count() == 0

      assert text(html, ~s(#result-tight [data-role="result-fused"])) |> String.trim() ==
               "100.0% · n=6"

      assert text(html, ~s(#result-control [data-role="result-fused"])) |> String.trim() ==
               "not enough data · n=2"

      [control_class] = html |> q("#result-control") |> LazyHTML.attribute("class")
      assert control_class =~ "bg-base-300"

      # The fused string is one mono, full-ink, non-wrapping run.
      [figure_class] =
        html |> q(~s(#result-tight [data-role="result-figure"])) |> LazyHTML.attribute("class")

      assert figure_class =~ "font-mono"
      assert figure_class =~ "text-base-content"

      [fused_class] =
        html |> q(~s(#result-tight [data-role="result-fused"])) |> LazyHTML.attribute("class")

      assert fused_class =~ "whitespace-nowrap"
    end

    test "Promote is the only btn-primary, and only on the earned row", %{conn: conn} do
      user = admin_user()
      experiment = planner_running("one-primary", user)
      seed_arm(experiment, "tight", 6, 1, "failed")
      seed_arm(experiment, "control", 2, 1, "failed")

      {:ok, _view, html} = live(admin_conn(conn, user), ~p"/control/experiments/one-primary")

      primaries = q(html, ".btn-primary")
      assert Enum.count(primaries) == 1
      assert LazyHTML.attribute(primaries, "data-role") == ["promote-button"]
      assert q(html, ~s(#result-tight [data-role="promote-button"])) |> Enum.count() == 1

      # The index page, with the create form open, has none at all.
      {:ok, index, _} = live(admin_conn(conn, user), ~p"/control/experiments")
      index_html = index |> element(~s([data-role="new-experiment-button"])) |> render_click()
      assert q(index_html, ".btn-primary") |> Enum.count() == 0
      # Not vacuous: the form and the guardrails panel did render.
      assert q(index_html, ~s([data-role="create-submit"])) |> Enum.count() == 1
      assert q(index_html, ~s([data-role="guardrails-save"])) |> Enum.count() == 1
    end

    test "an admin promotes an earned arm through the rendered button", %{conn: conn} do
      user = admin_user()
      experiment = planner_running("promote-me", user)
      seed_arm(experiment, "tight", 6, 1, "failed")

      {:ok, view, _html} = live(admin_conn(conn, user), ~p"/control/experiments/promote-me")

      view |> element(~s(#result-tight [data-role="promote-button"])) |> render_click()

      assert Platform.Experiments.Surfaces.current_default(@planner, @planning, nil) ==
               %{"max_stages" => 3}

      # Promotion is not a status change: concluding is its own control.
      assert Experiments.get_experiment_by_slug("promote-me").status == "running"
    end

    test "exclusions sit on the row, and expand to their reasons", %{conn: conn} do
      experiment = running_experiment("row-exclusions", stop_rule: %{"min_subjects" => 1})
      [task | _] = seed_arm(experiment, "control", 3, 1, "passed")
      {:ok, _} = Assignments.exclude(experiment, {"task", task.id}, "cancelled before plan")

      {:ok, _view, html} = live(member_conn(conn), ~p"/control/experiments/row-exclusions")

      details = q(html, ~s(#result-control details[data-role="result-exclusions"]))
      assert Enum.count(details) == 1

      summary = details |> LazyHTML.query("summary") |> LazyHTML.text() |> String.trim()
      assert summary == "(1 excluded)"

      reason = text(html, ~s(#result-control [data-role="exclusion-reason"]))
      assert reason =~ "cancelled before plan"
      assert reason =~ "(1)"

      # Inside the figure element, beside the n it changed.
      assert text(html, ~s(#result-control [data-role="result-figure"])) =~ "(1 excluded)"
    end

    test "the observation window is stated in the header", %{conn: conn} do
      {:ok, experiment} =
        Experiments.create_experiment(%{
          slug: "windowed",
          name: "Windowed",
          primary_metric: "validation_failure_rate",
          stop_rule: %{"min_subjects" => 1},
          observation_window_days: 14
        })

      {:ok, _view, html} = live(member_conn(conn), ~p"/control/experiments/#{experiment.slug}")

      assert text(html, ~s([data-role="observation-window"])) |> String.trim() ==
               "Window: 14 days"
    end
  end

  describe "state chips differ in hue (canvas rule 3)" do
    test "running, stopped and concluded carry success, warning and info", %{conn: conn} do
      running_experiment("chip-running", [])
      stopped = running_experiment("chip-stopped", [])
      concluded = running_experiment("chip-concluded", [])
      {:ok, _} = Experiments.stop(stopped)
      {:ok, _} = Experiments.conclude(concluded)

      {:ok, _view, html} = live(member_conn(conn), ~p"/control/experiments")

      class_of = fn slug ->
        [class] =
          html
          |> q(~s(#experiment-row-#{slug} [data-role="status-badge"]))
          |> LazyHTML.attribute("class")

        class
      end

      assert class_of.("chip-running") =~ "badge-success"
      assert class_of.("chip-stopped") =~ "badge-warning"
      assert class_of.("chip-concluded") =~ "badge-info"
      refute class_of.("chip-concluded") =~ "badge-neutral"

      # Sentence case, not uppercase and not the raw lowercase status.
      assert text(html, ~s(#experiment-row-chip-stopped [data-role="status-badge"]))
             |> String.trim() == "Stopped"

      assert text(html, ~s(#experiment-row-chip-concluded [data-role="status-badge"]))
             |> String.trim() == "Concluded"
    end
  end

  describe "the guardrails panel" do
    test "the mail send path is a line of text with no input", %{conn: conn} do
      {:ok, _view, html} = live(admin_conn(conn), ~p"/control/experiments")

      row = q(html, ~s([data-role="mail-send-row"]))
      assert Enum.count(row) == 1
      assert LazyHTML.text(row) =~ "not available"
      assert q(html, ~s([data-role="mail-send-row"] input)) |> Enum.count() == 0

      # Not vacuous: the panel's real checkboxes ARE inputs, one per surface.
      assert q(html, ~s([data-role="guardrails-surface"])) |> Enum.count() ==
               length(Guardrails.default_allowed_surfaces())
    end

    test "approval is OFF by default and the panel says so", %{conn: conn} do
      {:ok, _view, html} = live(admin_conn(conn), ~p"/control/experiments")

      assert q(html, ~s([data-role="guardrails-approval"])) |> Enum.count() == 1
      assert q(html, ~s([data-role="guardrails-approval"][checked])) |> Enum.count() == 0
      assert text(html, ~s([data-role="guardrails-live"])) |> String.trim() == "0 of 3 used"
    end

    test "saving only max_live with no stored row keeps the effective surfaces",
         %{conn: conn} do
      before = Guardrails.for_org(nil)
      # The effective value is NOT the column default: an empty list here
      # would make the equality below pass against a broken pre-fill.
      assert before.allowed_surfaces != []
      assert Repo.aggregate(Guardrail, :count) == 0

      {:ok, view, _html} = live(admin_conn(conn), ~p"/control/experiments")

      # `form/3` submits what the RENDERED form holds, plus this one change:
      # the pre-filled checkboxes are the thing under test.
      view
      |> form(~s([data-role="guardrails-form"]), %{"max_live" => "5"})
      |> render_submit()

      [row] = Repo.all(from(g in Guardrail, where: is_nil(g.org_id)))
      assert row.max_live == 5
      assert Enum.sort(row.allowed_surfaces) == Enum.sort(before.allowed_surfaces)
      assert row.require_human_approval == false
      assert row.allow_auto_promote == false
    end

    test "a save that omits allowed_surfaces keeps it too (the server-side half)",
         %{conn: conn} do
      before = Guardrails.for_org(nil).allowed_surfaces
      {:ok, view, _html} = live(admin_conn(conn), ~p"/control/experiments")

      render_hook(view, "guardrails_save", %{"org_id" => "", "max_live" => "4"})

      [row] = Repo.all(from(g in Guardrail, where: is_nil(g.org_id)))
      assert row.max_live == 4
      assert Enum.sort(row.allowed_surfaces) == Enum.sort(before)
    end

    test "saving the install-wide guardrails twice leaves exactly one null-org row",
         %{conn: conn} do
      {:ok, view, _html} = live(admin_conn(conn), ~p"/control/experiments")

      view
      |> form(~s([data-role="guardrails-form"]), %{"max_live" => "2"})
      |> render_submit()

      view
      |> form(~s([data-role="guardrails-form"]), %{"max_live" => "7"})
      |> render_submit()

      assert null_org_guardrail_count() == 1
      assert Guardrails.for_org(nil).max_live == 7
    end

    test "unticking every surface stores an empty list — the ticked state is honoured",
         %{conn: conn} do
      {:ok, view, _html} = live(admin_conn(conn), ~p"/control/experiments")

      render_hook(view, "guardrails_save", %{
        "org_id" => "",
        "max_live" => "3",
        "allowed_surfaces" => [""]
      })

      assert Guardrails.for_org(nil).allowed_surfaces == []
    end

    test "an org's row is saved separately from the install-wide row", %{conn: conn} do
      org = Tenancy.get_org_by_slug!("fabrikam")
      {:ok, view, _html} = live(admin_conn(conn), ~p"/control/experiments")

      view
      |> form(~s([data-role="guardrails-scope-form"]), %{"org_id" => org.id})
      |> render_change()

      view
      |> form(~s([data-role="guardrails-form"]), %{"require_human_approval" => "true"})
      |> render_submit()

      assert Guardrails.stored_row(org.id).require_human_approval == true
      assert null_org_guardrail_count() == 0
    end
  end

  describe "pending approval (approval is opt-in per org)" do
    test "a started experiment in a default org shows no pending-approval UI", %{conn: conn} do
      user = admin_user()
      planner_running("no-approval", user)

      {:ok, _view, html} = live(admin_conn(conn, user), ~p"/control/experiments/no-approval")

      assert q(html, ~s([data-role="pending-approval"])) |> Enum.count() == 0
      assert q(html, ~s([data-role="approval-badge"])) |> Enum.count() == 0
    end

    test "an admin sees who proposed it and approves the launch through the button",
         %{conn: conn} do
      {pending, _proposer} = pending_experiment("needs-approval")
      assert pending.status == "draft"

      {:ok, _index, index_html} = live(admin_conn(conn), ~p"/control/experiments")

      assert text(index_html, ~s(#experiment-row-needs-approval [data-role="proposed-by"]))
             |> String.trim() == "Scientist Sage"

      {:ok, view, html} = live(admin_conn(conn), ~p"/control/experiments/needs-approval")

      assert text(html, ~s([data-role="pending-approval"])) =~ "Awaiting human approval"
      assert text(html, ~s([data-role="proposed-by"])) |> String.trim() == "Scientist Sage"

      view
      |> element(~s([data-role="pending-approval"] [data-role="approve-launch-button"]))
      |> render_click()

      approved = Experiments.get_experiment_by_slug("needs-approval")
      assert approved.status == "running"
      assert approved.approval_state == "approved"
    end
  end

  describe "stop with feedback" do
    test "the Stop button opens a form whose feedback, author and time are recorded and shown",
         %{conn: conn} do
      user = admin_user()
      planner_running("stop-feedback", user)

      {:ok, view, html} = live(admin_conn(conn, user), ~p"/control/experiments/stop-feedback")
      assert q(html, ~s([data-role="stop-form"])) |> Enum.count() == 0

      view |> element(~s([data-role="stop-button"])) |> render_click()

      html =
        view
        |> form(~s([data-role="stop-form"]), %{
          "feedback" => "Arms drifted; re-run with a cohort policy."
        })
        |> render_submit()

      stopped = Experiments.get_experiment_by_slug("stop-feedback")
      assert stopped.status == "stopped"
      assert stopped.stop_feedback == "Arms drifted; re-run with a cohort policy."
      assert stopped.stopped_by_user_id == user.id
      assert %DateTime{} = stopped.stopped_at

      assert text(html, ~s([data-role="stop-feedback"])) |> String.trim() ==
               "Arms drifted; re-run with a cohort policy."

      assert text(html, ~s([data-role="stopped-by"])) |> String.trim() == "Experiments Admin"
    end
  end

  describe "the human controls" do
    test "an admin creates a draft on a non-prompt surface through the rendered form",
         %{conn: conn} do
      org = Tenancy.get_org_by_slug!("fabrikam")
      {:ok, view, _html} = live(admin_conn(conn), ~p"/control/experiments")

      view |> element(~s([data-role="new-experiment-button"])) |> render_click()

      view
      |> form(~s([data-role="create-experiment-form"]), %{
        "name" => "Budget three",
        "slug" => "budget-three",
        "hypothesis" => "Three stages is enough.",
        "primary_metric" => "stages_per_plan",
        "min_subjects" => "10",
        "surface" => "#{@planner}::#{@planning}",
        "org_id" => org.id
      })
      |> render_submit()

      experiment = Experiments.get_experiment_by_slug("budget-three")
      assert experiment.status == "draft"
      assert experiment.surface_key == @planner
      assert experiment.surface_target == @planning
      assert experiment.org_id == org.id
    end

    test "an admin starts a draft through the rendered Start button", %{conn: conn} do
      planner_draft("start-me")

      {:ok, view, _html} = live(admin_conn(conn), ~p"/control/experiments/start-me")
      view |> element(~s([data-role="start-button"])) |> render_click()

      started = Experiments.get_experiment_by_slug("start-me")
      assert started.status == "running"
      assert Enum.map(Experiments.list_variants(started), & &1.slug) == ["control", "tight"]
    end

    test "an admin concludes through the rendered button", %{conn: conn} do
      user = admin_user()
      planner_running("conclude-me", user)

      {:ok, view, _html} = live(admin_conn(conn, user), ~p"/control/experiments/conclude-me")
      view |> element(~s([data-role="conclude-button"])) |> render_click()

      assert Experiments.get_experiment_by_slug("conclude-me").status == "concluded"
    end

    test "an admin adds a surface-validated variant to a draft; a bad payload is refused",
         %{conn: conn} do
      planner_draft("variant-me")

      {:ok, view, _html} = live(admin_conn(conn), ~p"/control/experiments/variant-me")
      view |> element(~s([data-role="experiment-tab"][data-tab="design"])) |> render_click()

      view
      |> form(~s([data-role="add-variant-form"]), %{
        "slug" => "loose",
        "payload" => ~s({"max_stages": 99})
      })
      |> render_submit()

      experiment = Experiments.get_experiment_by_slug("variant-me")
      refute Enum.any?(Experiments.list_variants(experiment), &(&1.slug == "loose"))

      view
      |> form(~s([data-role="add-variant-form"]), %{
        "slug" => "loose",
        "payload" => ~s({"max_stages": 8})
      })
      |> render_submit()

      loose = Enum.find(Experiments.list_variants(experiment), &(&1.slug == "loose"))
      assert loose.payload == %{"max_stages" => 8}
    end
  end

  describe "the Design tab" do
    test "shows the surface, target, org and project scope from the columns", %{conn: conn} do
      org = Tenancy.get_org_by_slug!("fabrikam")
      {:ok, project} = Tasks.create_project(%{name: "Scope Project", org_id: org.id})
      planner_draft("design-scope", project_id: project.id)

      {:ok, view, _html} = live(member_conn(conn), ~p"/control/experiments/design-scope")

      html =
        view |> element(~s([data-role="experiment-tab"][data-tab="design"])) |> render_click()

      assert text(html, ~s([data-role="design-surface"])) |> String.trim() == @planner
      assert text(html, ~s([data-role="design-target"])) |> String.trim() == @planning
      # The org is DERIVED from the project by the changeset.
      assert text(html, ~s([data-role="design-org"])) |> String.trim() == org.name
      assert text(html, ~s([data-role="design-project"])) |> String.trim() == "Scope Project"
    end
  end

  # Task 01a11706: the Design tab raised a CaseClauseError on a
  # `dispatch_usage` spec (prod, code-mode-2026-10). Every assertion is the
  # whole cell, trimmed, so a crash, a fallback string and a wording drift are
  # all red.
  defp design_metric(conn, slug) do
    {:ok, view, _html} = live(member_conn(conn), ~p"/control/experiments/#{slug}")

    html =
      view |> element(~s([data-role="experiment-tab"][data-tab="design"])) |> render_click()

    text(html, ~s([data-role="design-metric"])) |> String.trim()
  end

  describe "Design tab metric words" do
    test "a dispatch_usage spec reads as its agg, field and unit", %{conn: conn} do
      planner_draft("design-dispatch-usage",
        metric_spec: %{
          "kind" => "dispatch_usage",
          "agg" => "median",
          "field" => "suite_tool_calls"
        }
      )

      assert design_metric(conn, "design-dispatch-usage") ==
               "Median suite tool calls per dispatch"
    end

    test "a dispatch_usage spec with no agg reads as the default mean", %{conn: conn} do
      planner_draft("design-dispatch-wall",
        metric_spec: %{"kind" => "dispatch_usage", "field" => "wall_ms"}
      )

      assert design_metric(conn, "design-dispatch-wall") == "Mean wall time (ms) per dispatch"
    end

    test "an outcome_rate spec keeps its wording", %{conn: conn} do
      planner_draft("design-outcome-rate",
        metric_spec: %{"kind" => "outcome_rate", "labels" => ["positive"], "window_days" => 7}
      )

      assert design_metric(conn, "design-outcome-rate") ==
               "Share of subjects with a positive signal within 7 days of assignment"
    end

    test "a duration_between spec keeps its wording", %{conn: conn} do
      planner_draft("design-duration-between",
        metric_spec: %{
          "kind" => "duration_between",
          "from_status" => "planning",
          "to_status" => "in_progress"
        }
      )

      assert design_metric(conn, "design-duration-between") ==
               "Time from planning to in_progress"
    end
  end

  defmodule FakeKind do
    @moduledoc false
    def kind, do: "future_kind"
  end

  describe "spec_words/3 fallback" do
    test "a parsed kind with no words of its own renders, never raises" do
      assert PlatformWeb.ExperimentsLive.spec_words({:ok, FakeKind, %{"x" => 1}}, nil, []) ==
               "future_kind metric (no description for this kind yet)"
    end
  end

  describe "stage-6 writes are refused to a non-admin, server-side" do
    test "guardrails_save, approve_launch, start and promote by name change nothing",
         %{conn: conn} do
      {_pending, _proposer} = pending_experiment("member-approve")
      rows_before = Repo.aggregate(Guardrail, :count)

      {:ok, view, _html} = live(member_conn(conn), ~p"/control/experiments")

      render_hook(view, "guardrails_save", %{"org_id" => "", "max_live" => "9"})
      render_hook(view, "approve_launch", %{"slug" => "member-approve"})
      render_hook(view, "start", %{"slug" => "member-approve"})

      assert Repo.aggregate(Guardrail, :count) == rows_before
      assert null_org_guardrail_count() == 0

      still = Experiments.get_experiment_by_slug("member-approve")
      assert still.status == "draft"
      assert still.approval_state == "pending"

      # And the positive control: the same approve, as an admin, launches.
      {:ok, admin_view, _} = live(admin_conn(conn), ~p"/control/experiments")
      render_hook(admin_view, "approve_launch", %{"slug" => "member-approve"})
      assert Experiments.get_experiment_by_slug("member-approve").status == "running"
    end

    test "a member sees no editable guardrail control and no approve button", %{conn: conn} do
      pending_experiment("member-view")

      {:ok, _view, html} = live(member_conn(conn), ~p"/control/experiments")

      assert q(html, ~s([data-role="guardrails-panel"])) |> Enum.count() == 1
      assert q(html, ~s([data-role="guardrails-save"])) |> Enum.count() == 0
      assert q(html, ~s([data-role="guardrails-max-live"])) |> Enum.count() == 0
      assert q(html, ~s([data-role="approve-launch-button"])) |> Enum.count() == 0
      # Not vacuous: the pending row itself is visible to the member.
      assert q(html, ~s(#experiment-row-member-view [data-role="pending-approval"]))
             |> Enum.count() == 1
    end
  end
end
