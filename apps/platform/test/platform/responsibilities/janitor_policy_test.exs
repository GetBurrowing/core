defmodule Platform.Responsibilities.JanitorPolicyTest do
  @moduledoc """
  Eligibility, ordering, the per-run cap, the exclusion policy, audit
  metadata, and overlap safety of `Platform.Responsibilities.Janitor`
  (task `019fa1ac-6685` stage 2).

  Every test here fails against unfixed code. Measured on moon: this file
  run on the stage-1 tip 65129051 fails 14/14, because
  `Platform.Responsibilities.Janitor` does not exist there.

  ## Mutation probes (measured on moon, this file only)

    * `lock("FOR UPDATE SKIP LOCKED")` deleted: the overlap test fails and
      nothing else does. Claim B blocks on the row locks A's writes hold;
      once A commits, B re-claims all three of A's tasks (the failure
      message lists them). Plain `FOR UPDATE`: the overlap test fails, B
      blocks.
    * cap 3 -> 4: six tests fail. Architect-first ordering removed: two.
      The policy short-circuited to "always safe": two. The claim's
      assignment write skipped: one.
    * SURVIVORS, by design: deleting the `handled_by` filter from the query
      alone, or the `eligible?/1` re-check alone, fails nothing, because
      each covers the other. Deleting both fails three tests. Likewise
      dropping `origin == "internal"` from `eligible?/1` alone survives;
      from the base query alone fails one test (the candidate query is
      asserted directly); from both fails three.

  "Unchanged" is measured on the WHOLE row: `row_to_json` over the `tasks`
  row read straight from Postgres, compared as text before and after the
  run, so a column the schema does not declare is covered too.

  ## The overlap test runs two claims concurrently, outside the sandbox

  Inside the SQL sandbox every process shares ONE connection and ONE
  transaction. Row locks never conflict within a transaction, and
  DBConnection serialises the two callers on the connection anyway, so a
  sandboxed "overlap" test runs the claims one after the other and passes
  without any lock. The overlap test therefore commits its fixture through
  `Sandbox.unboxed_run/2`, runs claim A on its own connection and HOLDS
  its transaction open (the `:before_commit` seam) while claim B runs on a
  second connection, and deletes everything it committed in `on_exit`.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.JanitorCronDrain
  alias Platform.Responsibilities.Janitor
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Roles.Seeds
  alias Platform.Tasks
  alias Platform.Tasks.Project
  alias Platform.Tasks.Task, as: TaskSchema

  @safe_description "Rename the private helper format_line/1 in lib/platform/chat/formatter.ex " <>
                      "to render_line/1 so the name matches what it returns."

  setup do
    {:ok, project} =
      Tasks.create_project(%{name: "Janitor policy #{System.unique_integer([:positive])}"})

    %{project: project, agent_id: native_agent!().id}
  end

  # ── fixtures ─────────────────────────────────────────────────────────────

  defp native_agent! do
    %Agent{}
    |> Agent.changeset(%{
      slug: "janitor-policy-#{System.unique_integer([:positive])}",
      name: "Janitor Policy Agent",
      status: "active",
      kind: "native",
      workspace_id: nil
    })
    |> Repo.insert!()
  end

  defp chore!(project, attrs) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{
            project_id: project.id,
            title: "Tidy #{System.unique_integer([:positive])}",
            description: @safe_description,
            kind: "chore"
          },
          attrs
        )
      )

    task
  end

  defp architect_chore!(project, attrs \\ %{}) do
    architect = %{"filed_by" => "architect_cron_sweep", "adr" => "0044", "refs" => []}

    chore!(
      project,
      Map.put(attrs, :metadata, Map.merge(architect, Map.get(attrs, :metadata, %{})))
    )
  end

  defp external_chore!(project, trust, issue) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "External chore #{issue}",
        description: @safe_description,
        kind: "chore",
        origin: "external_feedback",
        trust: trust,
        external_repository_identity: "Startup-Suite/feedback",
        external_issue_number: issue
      })

    task
  end

  # The full persisted row, as Postgres renders it.
  defp row_json(id) do
    {:ok, uuid} = Ecto.UUID.dump(id)

    %{rows: [[json]]} =
      Repo.query!("SELECT row_to_json(t)::text FROM tasks t WHERE t.id = $1", [uuid])

    json
  end

  defp reload(id), do: Repo.one!(from(t in TaskSchema, where: t.id == ^id))

  defp claim!(agent_id, opts \\ []) do
    {result, _log} =
      with_log(fn -> Janitor.claim(Keyword.put(opts, :agent_id, agent_id)) end)

    assert {:ok, result} = result
    result
  end

  defp ids(tasks), do: Enum.map(tasks, & &1.id)

  # Runs `fun` on a REAL connection, outside the sandbox transaction, in a
  # fresh process. It must be a fresh process: the test process is already
  # `:allowed` on the sandbox owner, so `Sandbox.unboxed_run/2` called from
  # it gets `{:already, :allowed}` from the ownership manager and silently
  # runs INSIDE the sandbox (measured: the first version of the overlap test
  # seeded six rows that neither claimer could see).
  defp unboxed(fun) do
    Elixir.Task.async(fn -> Sandbox.unboxed_run(Repo, fun) end)
    |> Elixir.Task.await(30_000)
  end

  # ── cap, order, determinism ──────────────────────────────────────────────

  describe "cap and order" do
    test "five eligible architect chores: exactly the three oldest are claimed, the other two are byte-for-byte unchanged",
         %{project: project, agent_id: agent_id} do
      chores = for _ <- 1..5, do: architect_chore!(project)
      [c1, c2, c3, c4, c5] = chores
      before = Map.new(chores, &{&1.id, row_json(&1.id)})

      result = claim!(agent_id)

      assert ids(result.claimed) == [c1.id, c2.id, c3.id]
      assert result.refused == []

      for untouched <- [c4, c5] do
        assert row_json(untouched.id) == before[untouched.id],
               "eligible task past the cap was modified"
      end

      for claimed <- [c1, c2, c3] do
        row = reload(claimed.id)
        assert row.status == "backlog"
        assert row.auto_approve_plan == true
        assert row.metadata["filed_by"] == "architect_cron_sweep"
        assert row.metadata["adr"] == "0044"
        assert row.metadata["handled_by"] == "janitor"
        assert row.metadata["janitor_disposition"] == "claimed"
        assert row.metadata["janitor_run_id"] == result.run_id
        assert {:ok, _, _} = DateTime.from_iso8601(row.metadata["janitor_at"])

        slot = %{"assignee_id" => agent_id, "assignee_type" => "agent"}
        assert row.phase_assignees["planning"] == slot
        assert row.phase_assignees["execution"] == slot
        assert row.assignee_id == agent_id
        assert row.assignee_type == "agent"
      end
    end

    test "a second run takes the next oldest and never re-claims", %{
      project: project,
      agent_id: agent_id
    } do
      [c1, c2, c3, c4, c5] = for _ <- 1..5, do: architect_chore!(project)

      first = claim!(agent_id)
      second = claim!(agent_id)
      third = claim!(agent_id)

      assert ids(first.claimed) == [c1.id, c2.id, c3.id]
      assert ids(second.claimed) == [c4.id, c5.id]
      assert third.claimed == []
      assert reload(c1.id).metadata["janitor_run_id"] == first.run_id
    end

    test "ordinary internal trusted chores are taken after architect chores, even when older",
         %{project: project, agent_id: agent_id} do
      ordinary_old = chore!(project, %{})
      ordinary_new = chore!(project, %{})
      a1 = architect_chore!(project)
      a2 = architect_chore!(project)

      result = claim!(agent_id)

      assert ids(result.claimed) == [a1.id, a2.id, ordinary_old.id]
      assert reload(ordinary_new.id).metadata["handled_by"] == nil
    end

    test "the candidate order is architect first, then oldest", %{project: project} do
      o = chore!(project, %{})
      a1 = architect_chore!(project)
      a2 = architect_chore!(project)

      ordered =
        Janitor.candidate_query()
        |> where([t], t.project_id == ^project.id)
        |> select([t], t.id)
        |> Repo.all()

      assert ordered == [a1.id, a2.id, o.id]
    end
  end

  # ── eligibility ──────────────────────────────────────────────────────────

  describe "eligibility is conjunctive" do
    test "other kinds, quarantined, external-feedback, non-backlog and ambiguous tasks are not claimed",
         %{project: project, agent_id: agent_id} do
      excluded =
        for(
          kind <- ~w(bug feature research ops),
          do: chore!(project, %{kind: kind, metadata: %{"filed_by" => "architect_cron_sweep"}})
        ) ++
          [
            chore!(project, %{trust: "quarantined"}),
            external_chore!(project, "quarantined", 701),
            external_chore!(project, "trusted", 702),
            chore!(project, %{status: "done"}),
            chore!(project, %{status: "blocked"}),
            chore!(project, %{status: "cancelled"})
          ]

      deleted = chore!(project, %{})
      {:ok, _} = Tasks.update_task(deleted, %{deleted_at: DateTime.utc_now()})
      excluded = excluded ++ [reload(deleted.id)]

      ambiguous = chore!(project, %{description: "fix it"})
      no_description = chore!(project, %{description: nil})
      bad_paths = chore!(project, %{metadata: %{"paths" => "lib/x.ex"}})
      safe = chore!(project, %{})

      before = Map.new(excluded, &{&1.id, row_json(&1.id)})

      result = claim!(agent_id)

      assert ids(result.claimed) == [safe.id]

      for task <- excluded do
        assert row_json(task.id) == before[task.id],
               "ineligible task #{task.kind}/#{task.status}/#{task.origin}/#{task.trust} was modified"
      end

      refused = Map.new(result.refused, fn {t, code} -> {t.id, code} end)

      for task <- [ambiguous, no_description, bad_paths] do
        assert refused[task.id] == "ambiguous_scope"
        row = reload(task.id)
        assert row.status == "backlog"
        assert row.auto_approve_plan == false
        assert row.metadata["janitor_disposition"] == "refused"
        assert row.metadata["janitor_reason"] == "ambiguous_scope"
      end
    end

    test "no external_feedback task is ever returned or mutated, even one whose text a refusal would match",
         %{project: project, agent_id: agent_id} do
      # Extends the parent quarantine contract
      # (`external_feedback_trust_test.exs`, `trusted_internal_chore_query/0`):
      # not only is such a row never CLAIMED, it is never STAMPED either,
      # not even as refused.
      dangerous =
        for {trust, issue} <- [{"trusted", 801}, {"quarantined", 802}] do
          {:ok, t} =
            Tasks.create_task(%{
              project_id: project.id,
              title: "Rotate the vault.ex signing key",
              description: "Update secrets handling in lib/platform/vault.ex for auth.",
              kind: "chore",
              origin: "external_feedback",
              trust: trust,
              external_repository_identity: "Startup-Suite/feedback",
              external_issue_number: issue
            })

          t
        end

      plain = [external_chore!(project, "trusted", 803)]
      externals = dangerous ++ plain
      before = Map.new(externals, &{&1.id, row_json(&1.id)})

      refute Enum.any?(
               Repo.all(Janitor.candidate_query()),
               &(&1.origin == "external_feedback")
             )

      result = claim!(agent_id)
      touched = ids(result.claimed) ++ Enum.map(result.refused, fn {t, _} -> t.id end)

      for task <- externals do
        refute task.id in touched
        assert row_json(task.id) == before[task.id]
      end

      refute Enum.any?(result.claimed, &(&1.origin == "external_feedback"))
      refute Enum.any?(result.refused, fn {t, _} -> t.origin == "external_feedback" end)
    end

    test "eligible?/1 needs every conjunct" do
      base = %TaskSchema{
        status: "backlog",
        kind: "chore",
        origin: "internal",
        trust: "trusted",
        metadata: %{}
      }

      assert Janitor.eligible?(base)
      refute Janitor.eligible?(%{base | status: "planning"})
      refute Janitor.eligible?(%{base | kind: "bug"})
      refute Janitor.eligible?(%{base | origin: "external_feedback"})
      refute Janitor.eligible?(%{base | trust: "quarantined"})
      refute Janitor.eligible?(%{base | deleted_at: DateTime.utc_now()})
      refute Janitor.eligible?(%{base | metadata: %{"handled_by" => "janitor"}})
    end
  end

  # ── exclusion policy ─────────────────────────────────────────────────────

  describe "dangerous scope is refused with attributable metadata and no auto-approval" do
    @dangerous [
      {"auth text", "auth_or_secrets",
       %{description: "Tighten the authorization check on the admin route."}},
      {"auth path", "auth_or_secrets",
       %{metadata: %{"paths" => ["apps/platform/lib/platform_web/plugs/require_auth.ex"]}}},
      {"secrets text", "auth_or_secrets",
       %{description: "Move the hard-coded API key into the secrets store, nothing else."}},
      {"tenancy text", "tenancy_boundary",
       %{description: "Share the cache across tenants to cut duplicate fetches."}},
      {"tenancy path", "tenancy_boundary",
       %{metadata: %{"files" => ["lib/platform/tenancy/lifecycle.ex"]}}},
      {"migration path", "database_migration",
       %{
         metadata: %{
           "paths" => ["apps/platform/priv/repo/migrations/20261009000000_tidy_index.exs"]
         }
       }},
      {"migration text", "database_migration",
       %{description: "Drop the column legacy_flag from the tasks table to tidy up."}},
      {"deploy workflow path", "deploy_runtime_config",
       %{metadata: %{"paths" => [".github/workflows/ci.yml"]}}},
      {"runtime config path", "deploy_runtime_config",
       %{description: "Inline the default in config/runtime.exs so the value is visible."}},
      {"container text", "deploy_runtime_config",
       %{description: "Pin the base image in the Dockerfile to a digest for reproducibility."}},
      {"vault path", "vault",
       %{metadata: %{"refs" => ["apps/platform/lib/platform/vault.ex:42"]}}},
      {"vault text", "vault",
       %{description: "Simplify the fallback branch in lib/platform/vault.ex for readability."}}
    ]

    test "each category, by text and by path, is refused and never claimed", %{
      project: project,
      agent_id: agent_id
    } do
      # Start every dangerous chore with auto_approve_plan already true: the
      # refusal must clear it, not merely leave it.
      dangerous =
        for {{label, code, attrs}, n} <- Enum.with_index(@dangerous, 1) do
          # A neutral title, so each category is detected by the attribute
          # under test (description or declared path), not by its label.
          task =
            architect_chore!(
              project,
              Map.merge(%{title: "Tidy item #{n}", auto_approve_plan: true}, attrs, fn
                :metadata, a, b -> Map.merge(a, b)
                _k, _a, b -> b
              end)
            )

          {label, code, task}
        end

      safe = chore!(project, %{})

      assert length(dangerous) < Janitor.scan_limit()
      result = claim!(agent_id)

      assert ids(result.claimed) == [safe.id]
      refused = Map.new(result.refused, fn {t, code} -> {t.id, code} end)

      for {label, code, task} <- dangerous do
        assert refused[task.id] == code,
               "#{label}: expected #{code}, got #{inspect(refused[task.id])}"

        row = reload(task.id)
        assert row.status == "backlog", label
        assert row.auto_approve_plan == false, label
        assert row.metadata["handled_by"] == "janitor", label
        assert row.metadata["janitor_disposition"] == "refused", label
        assert row.metadata["janitor_reason"] == code, label
        assert is_binary(row.metadata["janitor_reason_detail"]), label
        assert row.metadata["janitor_run_id"] == result.run_id, label
        assert row.metadata["filed_by"] == "architect_cron_sweep", label
        assert row.phase_assignees in [nil, %{}], label
      end

      # Refused rows are handled: a later run neither re-refuses nor claims them.
      again = claim!(agent_id)
      assert again.claimed == [] and again.refused == []
    end

    test "evaluate/1 names vault.ex wherever it sits" do
      for path <- ["vault.ex", "lib/platform/vault.ex", "apps/platform/lib/platform/vault.ex"] do
        task = %TaskSchema{
          title: "Tidy",
          description: @safe_description,
          metadata: %{"paths" => [path]}
        }

        assert {:refuse, "vault", _} = Janitor.evaluate(task)
      end
    end

    test "the declared globs cover the categories the policy names" do
      globs = Janitor.path_globs()
      assert "**/vault.ex" in globs["vault"]
      assert "**/priv/repo/migrations/**" in globs["database_migration"]
      assert "**/.github/workflows/**" in globs["deploy_runtime_config"]
      assert "**/tenancy/**" in globs["tenancy_boundary"]
      assert "**/auth/**" in globs["auth_or_secrets"]

      assert Janitor.glob_match?("priv/repo/migrations/1_x.exs", "**/priv/repo/migrations/**")
      assert Janitor.glob_match?("a/b/vault.ex", "**/vault.ex")
      refute Janitor.glob_match?("lib/platform/chat/formatter.ex", "**/vault.ex")
    end

    test "a plainly safe chore passes the policy" do
      task = %TaskSchema{title: "Rename helper", description: @safe_description, metadata: %{}}
      assert Janitor.evaluate(task) == :ok
    end
  end

  # ── handler wiring ───────────────────────────────────────────────────────

  describe "the cron handler claims only after the assignment gate" do
    setup %{project: project} do
      :ok = Seeds.seed_defaults(only_keys: ["janitor"])
      [spec] = JanitorCronDrain.register()
      {:ok, row} = Responsibilities.upsert_by_key(spec)

      previous = Application.get_env(:platform, :responsibility_router_native_dispatcher)

      Application.put_env(
        :platform,
        :responsibility_router_native_dispatcher,
        {__MODULE__.NullDispatcher, :maybe_dispatch}
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:platform, :responsibility_router_native_dispatcher, previous),
          else: Application.delete_env(:platform, :responsibility_router_native_dispatcher)
      end)

      %{row: row, chores: for(_ <- 1..4, do: architect_chore!(project))}
    end

    # Paired: the unassigned fire writes nothing; the assigned fire over the
    # same fixture claims the three oldest.
    test "unassigned fire claims nothing; assigned fire claims three", %{
      row: row,
      chores: chores,
      agent_id: agent_id
    } do
      before = Map.new(chores, &{&1.id, row_json(&1.id)})

      capture_log(fn ->
        assert {:ok, :unfilled} = Router.fire_trigger(row, %{kind: :cron}, %{})
      end)

      for c <- chores, do: assert(row_json(c.id) == before[c.id])

      {:ok, _} = Roles.assign_role("janitor", agent_id)

      capture_log(fn ->
        assert {:ok, :dispatched} = Router.fire_trigger(row, %{kind: :cron}, %{})
      end)

      [c1, c2, c3, c4] = chores

      for c <- [c1, c2, c3] do
        assert reload(c.id).metadata["janitor_disposition"] == "claimed"
        assert reload(c.id).auto_approve_plan
      end

      assert row_json(c4.id) == before[c4.id]
    end

    test "gather_context renders exactly the claimed ids", %{
      chores: chores,
      agent_id: agent_id,
      row: row
    } do
      {:ok, _} = Roles.assign_role("janitor", agent_id)
      {{:ok, ctx}, _} = with_log(fn -> JanitorCronDrain.gather_context(row, %{}) end)

      expected = chores |> Enum.take(3) |> ids()
      assert ctx.claimed_task_ids == expected
      for id <- expected, do: assert(ctx.claimed_tasks =~ id)
      refute ctx.claimed_tasks =~ List.last(chores).id
    end
  end

  defmodule NullDispatcher do
    @moduledoc false
    def maybe_dispatch(_signal), do: :ok
  end

  # ── overlap ──────────────────────────────────────────────────────────────

  describe "overlapping claims" do
    setup %{agent_id: agent_id} do
      # Committed fixture: the two claims run on separate connections and
      # must see the same rows. The agent row only has to exist for the
      # assignee to be meaningful; phase_assignees does not reference it.
      test_tag = "janitor-overlap-#{System.unique_integer([:positive])}"

      {project_id, chore_ids} =
        unboxed(fn ->
          %Platform.Tenancy.Org{id: org_id} = Platform.Tenancy.get_root_org()

          project =
            %Project{}
            |> Project.changeset(%{name: test_tag, org_id: org_id})
            |> Repo.insert!()

          ids =
            for n <- 1..6 do
              %TaskSchema{}
              |> TaskSchema.changeset(%{
                project_id: project.id,
                title: "#{test_tag} chore #{n}",
                description: @safe_description,
                kind: "chore",
                metadata: %{"filed_by" => "architect_cron_sweep"}
              })
              |> Repo.insert!()
              |> Map.fetch!(:id)
            end

          {project.id, ids}
        end)

      on_exit(fn ->
        unboxed(fn ->
          Repo.delete_all(from(t in TaskSchema, where: t.project_id == ^project_id))
          Repo.delete_all(from(p in Project, where: p.id == ^project_id))
        end)
      end)

      %{chore_ids: chore_ids, agent_id: agent_id}
    end

    test "a run that overlaps an open claim skips its locked rows instead of double-claiming",
         %{chore_ids: chore_ids, agent_id: agent_id} do
      test_pid = self()

      claim_a =
        Elixir.Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Janitor.claim(
              agent_id: agent_id,
              run_id: "run-a",
              before_commit: fn result ->
                send(test_pid, {:a_holding, ids(result.claimed)})

                receive do
                  :release -> :ok
                after
                  15_000 -> :ok
                end
              end
            )
          end)
        end)

      assert_receive {:a_holding, a_ids}, 10_000

      claim_b =
        Elixir.Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Janitor.claim(agent_id: agent_id, run_id: "run-b")
          end)
        end)

      # B must finish WHILE A still holds its transaction open. Without
      # SKIP LOCKED, B either waits on A's locks (plain FOR UPDATE, or the
      # row locks A's writes took) and this yield times out, or it reads
      # A's uncommitted rows as still eligible.
      b_result = Elixir.Task.yield(claim_b, 5_000)
      send(claim_a.pid, :release)
      a_result = Elixir.Task.await(claim_a, 15_000)

      if is_nil(b_result) do
        # A has committed now. Let B finish so the message can say what the
        # blocked run went on to do once the locks were gone.
        late =
          case Elixir.Task.yield(claim_b, 10_000) || Elixir.Task.shutdown(claim_b, :brutal_kill) do
            {:ok, {:ok, late_b}} ->
              a_claimed = with({:ok, a} <- a_result, do: ids(a.claimed), else: (_ -> []))
              overlap = Enum.filter(ids(late_b.claimed), &(&1 in a_claimed))

              "after A committed, B claimed #{inspect(ids(late_b.claimed))}; " <>
                "re-claimed from A: #{inspect(overlap)}"

            other ->
              "B never finished: #{inspect(other)}"
          end

        flunk(
          "claim B did not complete while claim A held its transaction open: it blocked on " <>
            "A's locks instead of skipping them (#{late})"
        )
      end

      assert {:ok, {:ok, b}} = b_result
      assert {:ok, a} = a_result

      b_ids = ids(b.claimed)
      assert ids(a.claimed) == a_ids
      assert length(a_ids) == 3
      assert length(b_ids) == 3
      assert MapSet.disjoint?(MapSet.new(a_ids), MapSet.new(b_ids))
      assert Enum.sort(a_ids ++ b_ids) == Enum.sort(chore_ids)

      # The committed rows agree: each task carries exactly one run.
      runs =
        unboxed(fn ->
          Repo.all(
            from(t in TaskSchema,
              where: t.id in ^chore_ids,
              select: {t.id, fragment("?->>'janitor_run_id'", t.metadata)}
            )
          )
        end)
        |> Map.new()

      for id <- a_ids, do: assert(runs[id] == "run-a")
      for id <- b_ids, do: assert(runs[id] == "run-b")
    end
  end
end
