defmodule PlatformWeb.TasksLiveMergeControlTest do
  @moduledoc """
  The `Merge` / `Open PR` cluster on the task detail panel (task 019ff182
  stage 1).

  The thing under test is not "does a button render". GitHub reports
  `mergeable: MERGEABLE` when ZERO checks ran, character-for-character
  identically to when every check passed, so the assertions that matter
  are:

    * the no-checks state renders the WARNING treatment and NOT the
      success one (`renders the warning treatment…`), and
    * activating the RENDERED Merge control actually reaches the merge
      implementation (`reaches AutoMerger…`).

  Every absence assertion here is paired with a positive control in the
  SAME setup. An absence assertion whose fixture never rendered the
  control in the first place passes for the wrong reason.

  `async: false` because the runner/merger seams are read from
  application env — the same reason
  `DeployMergeReconciler.merge_runner/0` exists.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks}
  alias Platform.Tasks.MergeControl

  @merge_button ~s([data-role="task-merge-button"])
  @cluster ~s([data-role="task-merge-controls"])
  @band ~s([data-role="merge-check-state"])

  # ── Seams ───────────────────────────────────────────────────────────────

  defmodule StubRunner do
    @moduledoc false
    @behaviour Platform.Tasks.MergeControl.Runner

    @impl true
    def pr_state(%{repo: _, branch: _}) do
      Application.get_env(:platform, :merge_control_stub_pr_state)
    end
  end

  # The ref seam the reconciler reads. Application env rather than the
  # process dictionary because `reconcile/3` runs inside the LiveView
  # process, not the test one.
  defmodule StubRefRunner do
    @moduledoc false
    @behaviour Platform.Tasks.BranchProvisioner.Runner

    @impl true
    def branch_head_sha(_args), do: {:error, :not_stubbed}

    @impl true
    def default_branch_sha(_), do: {:error, :not_used}

    @impl true
    def create_ref(_), do: {:error, :not_used}

    @impl true
    def list_matching_refs(%{repo: _, ref: _}) do
      Application.get_env(:platform, :merge_control_stub_refs, {:ok, []})
    end
  end

  defmodule StubMerger do
    @moduledoc false

    # Mirrors `AutoMerger.execute_merge/4`'s arity and argument order.
    # `MergeControl.default_merger/0` is asserted separately to be
    # `AutoMerger` itself, so this stub observes the call without
    # letting the production path drift away from it unobserved.
    def execute_merge(task, repo_url, pr_number, method) do
      send(
        Application.get_env(:platform, :merge_control_test_pid),
        {:execute_merge, task.id, repo_url, pr_number, method}
      )

      {:ok, "deadbeefcafe"}
    end
  end

  setup do
    prev = Application.get_env(:platform, :merge_control, [])
    prev_provisioner = Application.get_env(:platform, :branch_provisioner, [])

    Application.put_env(:platform, :merge_control, runner: StubRunner, merger: StubMerger)
    Application.put_env(:platform, :branch_provisioner, runner: StubRefRunner)
    Application.put_env(:platform, :merge_control_test_pid, self())
    put_pr_state({:ok, pr(checks: [])})

    on_exit(fn ->
      Application.put_env(:platform, :merge_control, prev)
      Application.put_env(:platform, :branch_provisioner, prev_provisioner)
      Application.delete_env(:platform, :merge_control_stub_pr_state)
      Application.delete_env(:platform, :merge_control_stub_refs)
      Application.delete_env(:platform, :merge_control_test_pid)
    end)

    :ok
  end

  defp put_pr_state(state),
    do: Application.put_env(:platform, :merge_control_stub_pr_state, state)

  defp put_refs(answer),
    do: Application.put_env(:platform, :merge_control_stub_refs, answer)

  defp pr(opts) do
    %{
      number: Keyword.get(opts, :number, 707),
      url: "https://github.com/Startup-Suite/core/pull/707",
      base_ref: "main",
      checks: Keyword.fetch!(opts, :checks)
    }
  end

  defp check(passed?), do: %{name: "ci", passed?: passed?}

  # ── Fixtures ────────────────────────────────────────────────────────────

  @pr_merge_manual %{"type" => "pr_merge", "config" => %{"auto_merge" => false}}
  @pr_merge_auto %{
    "type" => "pr_merge",
    "config" => %{"auto_merge" => true},
    "repos" => [%{"repo_url" => "https://github.com/Startup-Suite/core", "ci" => "required"}]
  }

  defp authenticated_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "merge-control-#{n}@example.com",
        name: "Merge Control User",
        oidc_sub: "oidc-merge-control-#{n}"
      })

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp task_with_live_deploy_gate!(opts \\ []) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{
        name: "Merge Control #{n}",
        repo_url: "https://github.com/Startup-Suite/core"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Merge control task #{n}",
        status: "deploying",
        deploy_strategy: Keyword.get(opts, :strategy, @pr_merge_manual)
      })

    task =
      if Keyword.get(opts, :stacked, false) do
        task
        |> Ecto.Changeset.change(stack_id: stack!(project, n).id, stack_position: 1)
        |> Repo.update!()
      else
        task
      end

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Deploy: PR merge"})
    {:ok, stage} = Tasks.transition_stage(stage, "running")

    {:ok, _validation} =
      Tasks.create_validation(%{
        stage_id: stage.id,
        kind: "pr_merged",
        evaluation_payload: %{
          "repo" => "Startup-Suite/core",
          "repo_url" => "https://github.com/Startup-Suite/core",
          "branch" => "task/019ff182-cd38",
          "ci" => "required",
          "auto_merge" => false,
          "merge_method" => "squash"
        }
      })

    task
  end

  defp stack!(project, n) do
    {:ok, stack} =
      Platform.Tasks.Stacks.create_stack(%{
        project_id: project.id,
        name: "Stack #{n}",
        slug: "stack-#{n}",
        rollup_branch: "stack/#{n}"
      })

    stack
  end

  defp open_panel(conn, task) do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    view
  end

  # Text of ONE element, whitespace-normalised. Scoped — never a grep of
  # the whole template, which would pass on the string appearing anywhere
  # (a comment, another panel, an unrelated badge).
  defp text_of(html, selector) do
    nodes = html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

    # `LazyHTML.query/2` returns a STRUCT: `== []` and `!= []` are both
    # wrong for emptiness. Count.
    assert Enum.count(nodes) == 1,
           "expected exactly 1 #{selector}, got #{Enum.count(nodes)}"

    nodes
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp count(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
  end

  # ── Test 1: auto_merge ──────────────────────────────────────────────────

  describe "auto_merge" do
    test "absent when auto_merge is true, present when it is false", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)

      auto = task_with_live_deploy_gate!(strategy: @pr_merge_auto)
      refute has_element?(open_panel(conn, auto), @cluster)

      # Positive control, same setup, one flag flipped. Without it the
      # refutation above passes on any fixture that never renders.
      manual = task_with_live_deploy_gate!(strategy: @pr_merge_manual)
      assert has_element?(open_panel(conn, manual), @cluster)
    end
  end

  # ── Test 2: deploy strategy ─────────────────────────────────────────────

  describe "deploy strategy" do
    test "absent unless the strategy is pr_merge", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)

      docker = task_with_live_deploy_gate!(strategy: %{"type" => "docker_deploy"})
      refute has_element?(open_panel(conn, docker), @cluster)

      pr_merge = task_with_live_deploy_gate!(strategy: @pr_merge_manual)
      assert has_element?(open_panel(conn, pr_merge), @cluster)
    end
  end

  # ── Test 3: stacked tasks ───────────────────────────────────────────────

  describe "stacked tasks" do
    test "absent on a stack member, present on a standalone task", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)

      member = task_with_live_deploy_gate!(stacked: true)
      refute has_element?(open_panel(conn, member), @cluster)

      standalone = task_with_live_deploy_gate!()
      assert has_element?(open_panel(conn, standalone), @cluster)
    end
  end

  # ── Test 4: gh unavailable ──────────────────────────────────────────────

  describe "gh unavailable" do
    test "names the cause and keeps the Merge button visible and enabled", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      put_pr_state({:error, :gh_unavailable, "`gh` not found on PATH"})

      html = open_panel(conn, task_with_live_deploy_gate!()) |> render()

      assert text_of(html, @band) =~
               "Cannot merge from Burrow: the GitHub CLI is unavailable on the server."

      # Not a vanishing control and not a greyed-out one with no reason.
      assert count(html, @merge_button) == 1
      assert count(html, "#{@merge_button}[disabled]") == 0
    end
  end

  # ── Test 5: the case most likely to ship as a reassuring green ──────────

  describe "no status checks configured" do
    test "renders the warning treatment and NOT the success treatment", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      put_pr_state({:ok, pr(checks: [])})

      html = open_panel(conn, task_with_live_deploy_gate!()) |> render()

      assert count(html, ~s(#{@band}[data-tone="warning"])) == 1

      # BOTH halves. A band that renders warning AND success classes
      # would pass the first assertion alone.
      assert count(html, ~s(#{@band}[data-tone="success"])) == 0
      assert count(html, ~s(#{@band}.border-success)) == 0
      assert count(html, ~s(#{@band}.bg-success\\/10)) == 0
      assert count(html, ~s(#{@band}.border-warning)) == 1

      # Anti-vacuity: the success treatment IS reachable from this same
      # band, so its absence above is a fact about this state and not
      # about a selector that never matches anything.
      put_pr_state({:ok, pr(checks: [check(true)])})
      green = open_panel(conn, task_with_live_deploy_gate!()) |> render()
      assert count(green, ~s(#{@band}[data-tone="success"])) == 1
      assert count(green, ~s(#{@band}.border-success)) == 1
    end
  end

  # ── Test 6: the whole state line ────────────────────────────────────────

  describe "the state line" do
    test "is a full sentence, asserted whole", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      put_pr_state({:ok, pr(checks: [])})

      html = open_panel(conn, task_with_live_deploy_gate!()) |> render()

      assert text_of(html, @band) ==
               "No status checks configured Nothing has verified this branch."
    end

    test "renders source -> target with only the source truncating", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      html = open_panel(conn, task_with_live_deploy_gate!()) |> render()

      assert count(html, ~s([data-role="merge-source-ref"].truncate)) == 1
      assert count(html, ~s([data-role="merge-target-ref"].shrink-0)) == 1
      assert count(html, ~s([data-role="merge-target-ref"].truncate)) == 0
      assert text_of(html, ~s([data-role="merge-target-ref"])) == "main"
    end
  end

  # ── The capability assertion ────────────────────────────────────────────

  describe "activating the rendered Merge control" do
    test "reaches AutoMerger's merge entry point with this task, branch and PR", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      put_pr_state({:ok, pr(number: 4242, checks: [])})
      task = task_with_live_deploy_gate!()

      view = open_panel(conn, task)

      # Driven through the RENDERED control. `element/2` raises if no
      # element matches the selector, so a Merge button wired to nothing
      # — or absent from the markup — fails here. Firing the event by
      # name would prove the handler works, not that a person can reach
      # it.
      view |> element(@merge_button) |> render_click()

      assert_receive {:execute_merge, task_id, repo_url, pr_number, method}
      assert task_id == task.id
      assert repo_url == "https://github.com/Startup-Suite/core"
      assert pr_number == 4242
      assert method == "squash"
    end

    test "the production merger is AutoMerger, which exports that arity", %{conn: _conn} do
      # The stub above observes the call; this pins WHAT the unstubbed
      # path calls, so the two together mean "the click reaches
      # AutoMerger". Without it the capability test could pass against a
      # seam whose default had drifted to anything at all.
      prev = Application.get_env(:platform, :merge_control, [])
      Application.put_env(:platform, :merge_control, Keyword.delete(prev, :merger))
      on_exit(fn -> Application.put_env(:platform, :merge_control, prev) end)

      assert MergeControl.merger() == Platform.Tasks.AutoMerger
      Code.ensure_loaded!(Platform.Tasks.AutoMerger)
      assert function_exported?(Platform.Tasks.AutoMerger, :execute_merge, 4)
    end

    test "records who merged, on which task, stage and branch", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      put_pr_state({:ok, pr(number: 4242, checks: [])})
      task = task_with_live_deploy_gate!()

      open_panel(conn, task) |> element(@merge_button) |> render_click()

      [event] =
        Platform.Audit.list(event_type: "platform.tasks.merge_control", resource_id: task.id)

      assert event.action == "merged"
      assert event.actor_id == user.id
      assert event.actor_type == "user"
      assert event.metadata["branch"] == "task/019ff182-cd38"
      assert is_binary(event.metadata["stage_id"])

      # A Suite-performed merge must not be indistinguishable from an
      # auto-merger one.
      assert event.metadata["performed_by"] == "merge_control"
    end
  end

  # ── The two states that used to be one sentence ──────────────────────────

  describe "no open PR, recorded branch missing from the remote" do
    @recorded "task/019ff182-cd38"

    test "names BOTH the recorded and the found branch", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      put_pr_state({:ok, nil})
      put_refs({:ok, ["refs/heads/task/ext-app-badge"]})

      html = open_panel(conn, task_with_live_deploy_gate!()) |> render()
      band = text_of(html, @band)

      # The distinguishing text, not merely the tone: a red band whose
      # sentence still read "This branch has no open pull request to
      # merge." would leave the defect exactly where it was.
      assert band =~ "Recorded branch not found"
      assert band =~ @recorded
      assert band =~ "task/ext-app-badge"
      refute band =~ "This branch has no open pull request to merge."
      assert count(html, ~s(#{@band}[data-tone="error"])) == 1
    end

    test "positive control: a matching ref with no PR keeps the ordinary sentence", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      put_pr_state({:ok, nil})
      put_refs({:ok, ["refs/heads/" <> @recorded]})

      band = open_panel(conn, task_with_live_deploy_gate!()) |> render() |> text_of(@band)

      assert band == "No open pull request This branch has no open pull request to merge."
    end

    test "a failed ref probe is never reported as a mismatch", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      put_pr_state({:ok, nil})
      put_refs({:error, :gh_unavailable, "`gh` not found on PATH"})

      band = open_panel(conn, task_with_live_deploy_gate!()) |> render() |> text_of(@band)

      assert band == "No open pull request This branch has no open pull request to merge."
    end

    test "clicking Merge on a mismatch refuses with the mismatch headline in the audit row", %{
      conn: conn
    } do
      {conn, user} = authenticated_conn(conn)
      put_pr_state({:ok, nil})
      put_refs({:ok, ["refs/heads/task/ext-app-badge"]})
      task = task_with_live_deploy_gate!()

      open_panel(conn, task) |> element(@merge_button) |> render_click()

      [event] =
        Platform.Audit.list(event_type: "platform.tasks.merge_control", resource_id: task.id)

      assert event.action == "refused"
      assert event.actor_id == user.id
      assert event.metadata["detail"] == "Recorded branch not found"

      # The merge implementation was never reached.
      refute_received {:execute_merge, _, _, _, _}
    end
  end
end
