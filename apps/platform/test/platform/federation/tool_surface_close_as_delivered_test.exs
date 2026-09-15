defmodule Platform.Federation.ToolSurfaceCloseAsDeliveredTest do
  @moduledoc """
  Task 01a0a552 stage 3 — `task_close_as_delivered` on the MCP surface.

  The tool exposes an ADMIN's authority through an agent, so every
  refusal here is a security assertion and every one of them is paired
  with a positive control of the same shape: a gate that refuses
  everything would satisfy a lone `assert {:error, _}` and protect
  nothing.

  `async: false` because the `DeliveryReference` runner seam is pinned
  through application env, which is global. Every pin is restored in
  `on_exit`.
  """
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures, only: [fabrikam_org_id: 0]

  alias Platform.Accounts.User
  alias Platform.Agents.AgentRuntime
  alias Platform.Federation.ToolArguments
  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.PhaseTransition
  alias Platform.Tasks.Task
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @repo_url "https://github.com/Startup-Suite/core"
  @sha "b85a4a96"

  defmodule StubRunner do
    @moduledoc false
    @behaviour Platform.Tasks.DeliveryReference.Runner

    @impl true
    def commit(_slug, sha), do: reply({:commit, sha})

    @impl true
    def pull_request(_slug, number), do: reply({:pr, number})

    defp reply(key) do
      responses = Application.get_env(:platform, :delivery_reference_stub, %{})
      Map.get(responses, key, {:error, :not_found})
    end
  end

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Delivered Project", repo_url: @repo_url})

    previous_runner = Application.get_env(:platform, :delivery_reference)
    previous_stub = Application.get_env(:platform, :delivery_reference_stub)

    Application.put_env(:platform, :delivery_reference, runner: StubRunner)

    Application.put_env(:platform, :delivery_reference_stub, %{
      {:commit, @sha} => {:ok, %{"sha" => @sha, "html_url" => "#{@repo_url}/commit/#{@sha}"}},
      {:pr, 1018} =>
        {:ok,
         %{
           "state" => "MERGED",
           "mergedAt" => "2026-09-01T00:00:00Z",
           "mergeCommit" => %{"oid" => @sha},
           "url" => "#{@repo_url}/pull/1018"
         }},
      {:pr, 999} => {:ok, %{"state" => "OPEN", "url" => "#{@repo_url}/pull/999"}}
    })

    on_exit(fn ->
      restore(:delivery_reference, previous_runner)
      restore(:delivery_reference_stub, previous_stub)
    end)

    %{project: project}
  end

  defp restore(key, nil), do: Application.delete_env(:platform, key)
  defp restore(key, value), do: Application.put_env(:platform, key, value)

  # ── fixtures ──────────────────────────────────────────────────────────

  defp user!(role) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        # Deliberately NOT an @example.com address — `Platform.Accounts`
        # derives `:admin` from that domain, and a kobo-ai email would
        # make the authorization tests pass for a reason unrelated to the
        # membership row under test.
        email: "delivered-#{n}@example.com",
        name: "Delivered #{n}",
        oidc_sub: "oidc-delivered-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: fabrikam_org_id(), role: role})
    |> Repo.insert!()

    user
  end

  defp runtime!(owner, agent_id \\ nil) do
    n = System.unique_integer([:positive])

    %AgentRuntime{}
    |> AgentRuntime.changeset(%{
      runtime_id: "runtime-#{n}",
      owner_user_id: owner.id,
      agent_id: agent_id,
      display_name: "Runtime #{n}",
      status: "active"
    })
    |> Repo.insert!()
  end

  defp admin_context(opts \\ []) do
    admin = user!("admin")
    assert Tenancy.fabrikam_admin?(admin)
    runtime = runtime!(admin)
    {admin, %{runtime_id: runtime.runtime_id, agent_id: Keyword.get(opts, :agent_id)}}
  end

  defp member_context do
    member = user!("member")
    refute Tenancy.fabrikam_admin?(member)
    runtime = runtime!(member)
    {member, %{runtime_id: runtime.runtime_id}}
  end

  defp task!(project, status) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Task #{System.unique_integer([:positive])}",
        deploy_target: "production"
      })

    {:ok, task} = task |> Task.changeset(%{status: status}) |> Repo.update()
    assert task.status == status
    task
  end

  defp reload(task), do: Tasks.get_task_record(task.id)

  # ── the required argument ─────────────────────────────────────────────

  describe "delivery_reference is required" do
    test "a call omitting it is refused BY THE ARGUMENT GATE and the task does not move",
         %{project: project} do
      backlog = task!(project, "backlog")
      {_admin, context} = admin_context()

      assert {:error, envelope} =
               ToolArguments.dispatch(
                 "task_close_as_delivered",
                 %{"task_id" => backlog.id},
                 context
               )

      # The per-parameter code from `ToolArguments`, proving the gate fired
      # BEFORE the handler — not a handler-side nil check downstream of it.
      assert envelope.code == :missing_delivery_reference
      assert reload(backlog).status == "backlog"

      # POSITIVE CONTROL: the same dispatch, same runtime, same task, with
      # the argument supplied, goes all the way through. So the refusal is
      # the argument gate answering and not a tool that refuses everything.
      assert {:ok, _} =
               ToolArguments.dispatch(
                 "task_close_as_delivered",
                 %{"task_id" => backlog.id, "delivery_reference" => @sha},
                 context
               )

      assert reload(backlog).status == "done"
    end

    test "a blank reference is refused and the task does not move", %{project: project} do
      backlog = task!(project, "backlog")
      {_admin, context} = admin_context()

      assert {:error, envelope} =
               ToolArguments.dispatch(
                 "task_close_as_delivered",
                 %{"task_id" => backlog.id, "delivery_reference" => "   "},
                 context
               )

      assert envelope.code == :missing_delivery_reference
      assert reload(backlog).status == "backlog"
    end
  end

  describe "the reference must name something real" do
    test "free text is refused as unparseable; a sha of the same length is not",
         %{project: project} do
      backlog = task!(project, "backlog")
      {_admin, context} = admin_context()

      for text <- ["shipped last week", "sha", "done in the PR", "it merged"] do
        assert {:error, envelope} =
                 ToolSurface.execute(
                   "task_close_as_delivered",
                   %{"task_id" => backlog.id, "delivery_reference" => text},
                   context
                 )

        assert envelope.error =~ "could not be read as a delivery reference"
        assert reload(backlog).status == "backlog"
      end

      # POSITIVE CONTROL in the same test.
      assert {:ok, _} =
               ToolSurface.execute(
                 "task_close_as_delivered",
                 %{"task_id" => backlog.id, "delivery_reference" => @sha},
                 context
               )
    end

    test "an unmerged PR and an unknown sha are refused with DISTINCT reasons",
         %{project: project} do
      {_admin, context} = admin_context()

      open_pr_task = task!(project, "backlog")

      assert {:error, not_merged} =
               ToolSurface.execute(
                 "task_close_as_delivered",
                 %{"task_id" => open_pr_task.id, "delivery_reference" => "#999"},
                 context
               )

      assert not_merged.error =~ "not merged"
      assert reload(open_pr_task).status == "backlog"

      unknown_task = task!(project, "backlog")

      assert {:error, not_found} =
               ToolSurface.execute(
                 "task_close_as_delivered",
                 %{"task_id" => unknown_task.id, "delivery_reference" => "deadbee"},
                 context
               )

      assert not_found.error =~ "does not exist"
      refute not_found.error =~ "not merged"
      assert reload(unknown_task).status == "backlog"

      # POSITIVE CONTROL: the merged PR on the same repo does close.
      merged_task = task!(project, "backlog")

      assert {:ok, _} =
               ToolSurface.execute(
                 "task_close_as_delivered",
                 %{"task_id" => merged_task.id, "delivery_reference" => "#1018"},
                 context
               )
    end

    test "an unavailable checker refuses RECOVERABLY and is NOT reported as not-found",
         %{project: project} do
      backlog = task!(project, "backlog")
      {_admin, context} = admin_context()

      Application.put_env(:platform, :delivery_reference_stub, %{
        {:commit, @sha} => {:error, {:unavailable, "`gh` (GitHub CLI) not found on PATH"}}
      })

      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_close_as_delivered",
                 %{"task_id" => backlog.id, "delivery_reference" => @sha},
                 context
               )

      assert envelope.recoverable
      assert envelope.error =~ "gh"
      # It must not ASSERT non-existence. The message may quote the
      # distinction ("... is not 'it does not exist'"), so the check is
      # against the not-found envelope's own claim, not the substring.
      refute envelope.error =~ "#{@sha} does not exist"
      # The whole point: nothing is recorded on a check that never ran.
      assert reload(backlog).status == "backlog"
    end

    test "a reference URL naming a DIFFERENT repository is refused, naming both slugs",
         %{project: project} do
      backlog = task!(project, "backlog")
      {_admin, context} = admin_context()

      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_close_as_delivered",
                 %{
                   "task_id" => backlog.id,
                   "delivery_reference" => "https://github.com/someone/else/pull/1018"
                 },
                 context
               )

      assert envelope.error =~ "someone/else"
      assert envelope.error =~ "Startup-Suite/core"
      assert reload(backlog).status == "backlog"

      # POSITIVE CONTROL: the SAME PR number, spelled with the project's
      # own slug, resolves and closes. So the refusal came from the slug
      # comparison and not from URL-form references being broken outright.
      assert {:ok, _} =
               ToolSurface.execute(
                 "task_close_as_delivered",
                 %{
                   "task_id" => backlog.id,
                   "delivery_reference" => "#{@repo_url}/pull/1018"
                 },
                 context
               )

      assert reload(backlog).status == "done"
    end
  end

  # ── the permission decision ───────────────────────────────────────────

  describe "the runtime owner must be a Fabrikam admin" do
    test "a non-admin-owned runtime is refused, and the refusal discloses no task state",
         %{project: project} do
      backlog = task!(project, "backlog")
      {_member, member_ctx} = member_context()

      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_close_as_delivered",
                 %{"task_id" => backlog.id, "delivery_reference" => @sha},
                 member_ctx
               )

      refute envelope.recoverable
      assert envelope.error =~ "not authorized"
      assert reload(backlog).status == "backlog"

      # The refusal must not be usable to probe the board: no status, no
      # title, no "task not found" — a non-admin learns nothing about
      # whether this id names a row at all.
      text = envelope.error <> to_string(Map.get(envelope, :suggestion, ""))
      refute text =~ "backlog"
      refute text =~ backlog.title
      refute text =~ "not found"

      # Same check with an id that names NOTHING is byte-identical, which
      # is what "discloses no task state" actually means.
      assert {:error, ^envelope} =
               ToolSurface.execute(
                 "task_close_as_delivered",
                 %{
                   "task_id" => "01a0a552-0000-7000-8000-000000000000",
                   "delivery_reference" => @sha
                 },
                 member_ctx
               )

      # POSITIVE CONTROL in the same test: an admin-owned runtime closes
      # THE SAME task, so the refusal came from the authorization gate.
      {_admin, admin_ctx} = admin_context()

      assert {:ok, _} =
               ToolSurface.execute(
                 "task_close_as_delivered",
                 %{"task_id" => backlog.id, "delivery_reference" => @sha},
                 admin_ctx
               )

      assert reload(backlog).status == "done"
    end

    test "a context with no runtime_id at all is refused", %{project: project} do
      backlog = task!(project, "backlog")

      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_close_as_delivered",
                 %{"task_id" => backlog.id, "delivery_reference" => @sha},
                 %{}
               )

      refute envelope.recoverable
      assert reload(backlog).status == "backlog"
    end
  end

  # ── what a closure records ────────────────────────────────────────────

  describe "the happy path" do
    test "the reference and the calling agent are READ BACK off a fresh row",
         %{project: project} do
      backlog = task!(project, "backlog")
      # `via_agent_id` is stamped into `task.metadata` verbatim — a JSONB
      # value, not an FK — so a generated id exercises the same path a
      # real agent id would without coupling this test to agent creation.
      agent_id = Ecto.UUID.generate()
      {admin, context} = admin_context(agent_id: agent_id)

      assert {:ok, result} =
               ToolSurface.execute(
                 "task_close_as_delivered",
                 %{"task_id" => backlog.id, "delivery_reference" => @sha},
                 context
               )

      assert result.status == "done"

      # ANTI-VACUITY: a tool that REQUIRES an argument and then discards
      # it passes every call-site assertion above. Only a re-read of the
      # persisted row can tell a write from a no-op.
      stamp = reload(backlog).metadata["closed_as_delivered"]

      assert stamp["reference"] == @sha
      assert stamp["via_agent_id"] == agent_id
      assert stamp["by_user_id"] == admin.id
      assert stamp["from_status"] == "backlog"
      assert stamp["resolution"]["kind"] == "sha"
      assert stamp["resolution"]["url"] =~ "Startup-Suite/core"
    end
  end

  # ── the table is NOT widened ──────────────────────────────────────────

  describe "the transition table is untouched" do
    test "an in_progress task is refused `not_correctable` and stays put",
         %{project: project} do
      running = task!(project, "in_progress")
      {_admin, context} = admin_context()

      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_close_as_delivered",
                 %{"task_id" => running.id, "delivery_reference" => @sha},
                 context
               )

      assert envelope.error =~ "not_correctable" or envelope.error =~ "already has"
      assert reload(running).status == "in_progress"

      # POSITIVE CONTROL: a `backlog` task — one with no legitimate route
      # to `done` — closes for the same runtime and the same reference.
      backlog = task!(project, "backlog")

      assert {:ok, _} =
               ToolSurface.execute(
                 "task_close_as_delivered",
                 %{"task_id" => backlog.id, "delivery_reference" => @sha},
                 context
               )
    end

    test "`done` is still ABSENT from backlog's outbound edges, derived from the table" do
      backlog_exits = Map.fetch!(Tasks.valid_task_transitions(), "backlog")

      # Derived, never transcribed: if someone widens the table this goes
      # red and makes them confront the decision rather than inherit it.
      refute "done" in backlog_exits
      # Anti-vacuity on the derivation itself — an empty or missing list
      # would satisfy the refute above for the wrong reason.
      assert "cancelled" in backlog_exits
    end
  end

  # ── stage 4: the adversarial cases, and what the edge inventory claims ──

  describe "what an agent-initiated closure records (task 01a0a552 stage 4)" do
    test "a `phase_transitions` row lands with actor_kind \"user\" — the AUTHORITY, not the instrument",
         %{project: project} do
      backlog = task!(project, "backlog")
      agent_id = Ecto.UUID.generate()
      {admin, context} = admin_context(agent_id: agent_id)

      assert {:ok, _} =
               ToolSurface.execute(
                 "task_close_as_delivered",
                 %{"task_id" => backlog.id, "delivery_reference" => @sha},
                 context
               )

      row =
        PhaseTransition
        |> where([t], t.task_id == ^backlog.id and t.to_status == "done")
        |> Repo.one!()

      # The admin's authority is what moved the row; the agent was the
      # instrument. Collapsing the two would lose the fact that matters
      # when something is closed wrongly, so they are stored separately:
      # actor here, agent id in the stamp.
      assert row.actor_kind == "user"
      assert row.actor_id == admin.id
      assert reload(backlog).metadata["closed_as_delivered"]["via_agent_id"] == agent_id
    end

    test "the persisted stamp's KEY SET is exactly these six — a raw list, not a subset check",
         %{project: project} do
      backlog = task!(project, "backlog")
      {_admin, context} = admin_context(agent_id: Ecto.UUID.generate())

      assert {:ok, _} =
               ToolSurface.execute(
                 "task_close_as_delivered",
                 %{"task_id" => backlog.id, "delivery_reference" => @sha},
                 context
               )

      # A per-key `assert stamp["x"]` sweep catches a key going MISSING and
      # is blind to one being ADDED. Only the full sorted list fails when a
      # later change starts writing something extra into an audit stamp.
      assert backlog
             |> reload()
             |> Map.fetch!(:metadata)
             |> Map.fetch!("closed_as_delivered")
             |> Map.keys()
             |> Enum.sort() ==
               ~w(at by_user_id from_status reference resolution via_agent_id)
    end

    test "`undeliverable_statuses/0` is EXACTLY the four, so cancelled stays absorbing here" do
      # The edge inventory asserts "`cancelled` stays absorbing for every
      # agent-reachable surface". This is the measurement behind that
      # sentence: the only agent-reachable writer to `done` outside the
      # pipeline accepts these four from-statuses and no others, and
      # `reinstate_cancelled_task/3` has no MCP tool at all. A raw list
      # equality, because a `refute "cancelled" in …` would stay green if
      # someone added `in_review` — widening is the direction a membership
      # check cannot see.
      assert Enum.sort(Tasks.undeliverable_statuses()) ==
               ~w(backlog blocked planning stack_pending)
    end

    test "a cancelled task is refused `not_correctable` through the tool and stays cancelled",
         %{project: project} do
      cancelled = task!(project, "cancelled")
      {_admin, context} = admin_context()

      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_close_as_delivered",
                 %{"task_id" => cancelled.id, "delivery_reference" => @sha},
                 context
               )

      assert envelope.error =~ "not_correctable" or envelope.error =~ "already has"
      # Absorbing means the row does not move, not merely that the call
      # returned an error tuple.
      assert reload(cancelled).status == "cancelled"
    end
  end
end
