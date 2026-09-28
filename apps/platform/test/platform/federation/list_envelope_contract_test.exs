defmodule Platform.Federation.ListEnvelopeContractTest do
  @moduledoc """
  Every list-shaped tool response carries `total` and `has_more` (task
  01a04a7a). A silently short list is worse than an oversized one: a caller
  handed 50 rows cannot tell "that is all of them" from "that is the first
  page" unless the response says which.

  Three layers, each asserted in BOTH directions:

    * **Static guard** — every list-named tool is registered or exempt, with a
      positive control proving the guard can fire.
    * **Builders** — `ResultBound.paged/5` and `ResultBound.whole/3`.
    * **Runtime conformance** — per registered tool, through
      `ToolArguments.dispatch/3` (the door both transports use): a seeded
      corpus larger than the page shows truncation FIRST, then the flags.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.TenancyFixtures

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Canvas.Kinds
  alias Platform.Experiments.{Signals, Surfaces}
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Tasks.{CanvasAttachments, PhaseTransition, PhaseTransitions}
  alias Platform.Org.{Wiki, WikiJournalEntry, WikiPage}
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Goal
  alias Platform.Federation.ListContract
  alias Platform.Federation.ResultBound
  alias Platform.Federation.ToolArguments
  alias Platform.Federation.ToolSurface
  alias Platform.Files
  alias Platform.Orchestration.{ExecutionLease, RuntimeEvent}
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, ReviewRequests}

  defp u, do: System.unique_integer([:positive])

  # ── Static guard ─────────────────────────────────────────────────────────

  describe "static guard" do
    test "every list-shaped tool on the surface is registered or exempt" do
      assert ListContract.unclassified(ToolSurface.tool_definitions()) == []
    end

    test "POSITIVE CONTROL: an unregistered list-shaped name is reported" do
      defs = ToolSurface.tool_definitions() ++ [%{name: "zzz_widget_list"}]
      assert ListContract.unclassified(defs) == ["zzz_widget_list"]
    end

    test "POSITIVE CONTROL: each naming shape is caught, and a non-list name is not" do
      defs =
        Enum.map(
          ~w(zzz_list zzz.list zzz_list_things zzz_search zzz_get_messages zzz_listing zzz_get),
          &%{name: &1}
        )

      assert ListContract.unclassified(defs, %{}, %{}) ==
               Enum.sort(~w(zzz_list zzz.list zzz_list_things zzz_search zzz_get_messages))
    end

    test "every registered tool exists on the surface" do
      names = MapSet.new(ToolSurface.tool_definitions(), & &1.name)

      missing =
        ToolSurface.list_envelope_tools() |> Map.keys() |> Enum.reject(&(&1 in names))

      assert missing == []
    end

    # 25 audited by task 01a04a7a, plus task_delivery_candidate_list (01a044b0).
    test "the registry covers the 26 registered tools, each with an atom rows key" do
      tools = ToolSurface.list_envelope_tools()
      assert map_size(tools) == 26
      assert Enum.all?(tools, fn {_name, key} -> is_atom(key) and not is_nil(key) end)
    end

    test "every exempt reason is non-blank" do
      blank =
        ToolSurface.list_envelope_exempt()
        |> Enum.filter(fn {_name, reason} ->
          not is_binary(reason) or String.trim(reason) == ""
        end)

      assert blank == []
    end

    test "the registered and exempt maps are disjoint" do
      registered = ToolSurface.list_envelope_tools() |> Map.keys() |> MapSet.new()
      exempt = ToolSurface.list_envelope_exempt() |> Map.keys() |> MapSet.new()
      assert MapSet.intersection(registered, exempt) |> MapSet.to_list() == []
    end
  end

  # ── Builders ────────────────────────────────────────────────────────────

  describe "ResultBound.paged/5" do
    test "TRUNCATED: a 3-of-10 page reports has_more true and the corpus total" do
      env = ResultBound.paged(:rows, [1, 2, 3], 10, 0)
      assert length(env.rows) < 10
      assert env.has_more == true
      assert env.total == 10
      assert env.total > length(env.rows)
    end

    test "UNTRUNCATED: the last page (offset 7, 3 of 10) reports has_more false" do
      env = ResultBound.paged(:rows, [8, 9, 10], 10, 7)
      assert env.has_more == false
      assert env.total == 10
    end

    test "UNTRUNCATED: an exact multiple (10 of 10) reports has_more false" do
      rows = Enum.to_list(1..10)
      env = ResultBound.paged(:rows, rows, 10, 0)
      assert env.has_more == false
      assert env.total == length(env.rows)
    end

    test "UNTRUNCATED: an empty corpus reports has_more false and total 0" do
      env = ResultBound.paged(:rows, [], 0, 0)
      assert env.rows == []
      assert env.has_more == false
      assert env.total == 0
    end

    test "extra keys survive, and total/has_more win over same-named extras" do
      env = ResultBound.paged(:rows, [1], 5, 0, %{limit: 1, total: 999, has_more: false})
      assert env.limit == 1
      assert env.total == 5
      assert env.has_more == true
    end
  end

  describe "ResultBound.whole/3" do
    test "reports total == length(rows) and has_more false" do
      env = ResultBound.whole(:rows, [1, 2, 3])
      assert env.rows == [1, 2, 3]
      assert env.total == 3
      assert env.has_more == false
    end

    test "an empty list reports total 0 and has_more false" do
      env = ResultBound.whole(:rows, [])
      assert env.total == 0
      assert env.has_more == false
    end

    test "total/has_more win over same-named extras" do
      env = ResultBound.whole(:rows, [1], %{count: 1, total: 42, has_more: true})
      assert env.count == 1
      assert env.total == 1
      assert env.has_more == false
    end
  end

  # ── Runtime conformance, per registered tool ────────────────────────────
  #
  # Each case seeds 3 rows and calls with limit 2 (truncated) and limit 50
  # (whole). Truncation is SHOWN before the flag is asserted: a `has_more`
  # that is true on a page that was not actually short proves nothing.

  defp call(tool, args, context \\ %{}) do
    assert {:ok, env} = ToolArguments.dispatch(tool, args, context)
    env
  end

  # Registry-closure check (c): every conformance case goes through one of
  # the two helpers below, and both begin here.
  defp assert_envelope_keys(env) do
    assert is_map(env) and Map.has_key?(env, :total) and Map.has_key?(env, :has_more),
           "not a list envelope: #{inspect(env, limit: 5)}"
  end

  defp assert_truncated(tool, env, corpus) do
    assert_envelope_keys(env)
    key = Map.fetch!(ToolSurface.list_envelope_tools(), tool)
    rows = Map.fetch!(env, key)
    assert length(rows) < corpus, "#{tool}: the seeded corpus was not actually truncated"
    assert env.has_more == true
    assert env.total == corpus
    assert env.total > length(rows)
  end

  defp assert_whole(tool, env, corpus) do
    assert_envelope_keys(env)
    key = Map.fetch!(ToolSurface.list_envelope_tools(), tool)
    rows = Map.fetch!(env, key)
    assert length(rows) == corpus
    assert env.has_more == false
    assert env.total == length(rows)
  end

  describe "runtime conformance: task_delivery_candidate_list" do
    defmodule CandidateStubRunner do
      @moduledoc false
      @behaviour Platform.Tasks.DeliveryReference.Runner

      @impl true
      def commit(_slug, _sha), do: {:error, :not_found}

      @impl true
      def pull_request(_slug, _number), do: {:error, :not_found}

      @impl true
      def merged_pull_requests(_slug, _limit),
        do: {:ok, Application.get_env(:platform, :list_envelope_candidate_prs, [])}

      @impl true
      def code_search(_slug, _term), do: {:error, {:unavailable, "not stubbed"}}
    end

    setup do
      previous_runner = Application.get_env(:platform, :delivery_reference)
      Application.put_env(:platform, :delivery_reference, runner: CandidateStubRunner)

      {:ok, project} =
        Tasks.create_project(%{
          name: "Envelope Cand #{u()}",
          repo_url: "https://github.com/Envelope-Org/cand-#{u()}"
        })

      prs =
        for i <- 1..3 do
          {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Cand #{i}"})

          %{
            "number" => i,
            "title" => "Ships #{task.id}",
            "body" => "",
            "mergedAt" => "2999-01-01T00:00:00Z",
            "mergeCommit" => %{"oid" => "sha#{i}"},
            "url" => "https://github.com/Envelope-Org/cand/pull/#{i}"
          }
        end

      Application.put_env(:platform, :list_envelope_candidate_prs, prs)

      on_exit(fn ->
        Application.delete_env(:platform, :list_envelope_candidate_prs)

        case previous_runner do
          nil -> Application.delete_env(:platform, :delivery_reference)
          value -> Application.put_env(:platform, :delivery_reference, value)
        end
      end)

      %{project: project}
    end

    test "truncated: limit 2 over 3 rows", %{project: p} do
      env = call("task_delivery_candidate_list", %{"project_id" => p.id, "limit" => 2})
      assert_truncated("task_delivery_candidate_list", env, 3)
    end

    test "untruncated: limit 50 over 3 rows", %{project: p} do
      env = call("task_delivery_candidate_list", %{"project_id" => p.id, "limit" => 50})
      assert_whole("task_delivery_candidate_list", env, 3)
    end
  end

  describe "runtime conformance: task_list" do
    setup do
      {:ok, project} = Tasks.create_project(%{name: "Envelope Proj #{u()}"})

      for i <- 1..3 do
        {:ok, _} = Tasks.create_task(%{project_id: project.id, title: "Env #{i}"})
      end

      %{project: project}
    end

    test "truncated: limit 2 over 3 rows", %{project: p} do
      env = call("task_list", %{"project_id" => p.id, "limit" => 2})
      assert_truncated("task_list", env, 3)
    end

    test "untruncated: limit 50 over 3 rows", %{project: p} do
      env = call("task_list", %{"project_id" => p.id, "limit" => 50})
      assert_whole("task_list", env, 3)
    end
  end

  describe "runtime conformance: stack_list" do
    setup do
      {:ok, project} = Tasks.create_project(%{name: "Envelope Stacks #{u()}"})

      for i <- 1..3 do
        call("stack_create", %{
          "project_id" => project.id,
          "slug" => "env-stack-#{i}-#{u()}",
          "name" => "Env Stack #{i}"
        })
      end

      %{project: project}
    end

    test "truncated: limit 2 over 3 rows", %{project: p} do
      env = call("stack_list", %{"project_id" => p.id, "limit" => 2})
      assert_truncated("stack_list", env, 3)
    end

    test "untruncated: limit 50 over 3 rows", %{project: p} do
      env = call("stack_list", %{"project_id" => p.id, "limit" => 50})
      assert_whole("stack_list", env, 3)
    end
  end

  # ── stage 2: the record-limit-bounded heads ─────────────────────────────

  defp plan_with_stages(n) do
    {:ok, project} = Tasks.create_project(%{name: "Envelope Stages #{u()}"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Staged"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    stages =
      for i <- 1..n do
        {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: i, name: "S#{i}"})
        stage
      end

    %{task: task, plan: plan, stages: stages}
  end

  describe "runtime conformance: stage_list" do
    setup do: plan_with_stages(3)

    test "truncated: limit 2 over 3 rows", %{plan: plan} do
      env = call("stage_list", %{"plan_id" => plan.id, "limit" => 2})
      assert_truncated("stage_list", env, 3)
      assert env.limit == 2
      assert env.offset == 0
    end

    test "untruncated: limit 50 over 3 rows", %{plan: plan} do
      env = call("stage_list", %{"plan_id" => plan.id, "limit" => 50})
      assert_whole("stage_list", env, 3)
    end

    test "the last page (offset 2) is not truncated", %{plan: plan} do
      env = call("stage_list", %{"plan_id" => plan.id, "limit" => 2, "offset" => 2})
      assert length(env.stages) == 1
      assert env.total == 3
      assert env.has_more == false
    end
  end

  describe "runtime conformance: review_item_list" do
    setup do
      %{task: task, stages: [stage | _]} = plan_with_stages(1)
      {:ok, _} = PlanEngine.start_stage(stage.id)
      {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      {:ok, _request} =
        ReviewRequests.create_review_request(%{
          validation_id: validation.id,
          task_id: task.id,
          submitted_by: "envelope-agent",
          items: for(i <- 1..3, do: %{label: "Item #{i}", content: "c#{i}"})
        })

      %{task: task}
    end

    test "truncated: limit 2 over 3 rows; count keeps meaning ALL items", %{task: task} do
      env = call("review_item_list", %{"task_id" => task.id, "limit" => 2})
      assert_truncated("review_item_list", env, 3)
      assert env.count == 3
      assert env.returned_count == 2
      assert env.next_offset == 2
    end

    test "untruncated: limit 50 over 3 rows", %{task: task} do
      env = call("review_item_list", %{"task_id" => task.id, "limit" => 50})
      assert_whole("review_item_list", env, 3)
      assert env.count == 3
      assert env.next_offset == nil
    end
  end

  describe "runtime conformance: file_list" do
    setup do
      {:ok, project} = Tasks.create_project(%{name: "Envelope Files #{u()}"})

      for i <- 1..3 do
        name = "env-#{i}-#{u()}.txt"

        {:ok, _} =
          Files.create_file(%{
            project_id: project.id,
            org_id: project.org_id,
            name: name,
            original_filename: name,
            content_type: "text/plain",
            byte_size: 4,
            storage_key: "files/#{project.id}/#{Ecto.UUID.generate()}/#{name}",
            content_hash: :crypto.hash(:sha256, name) |> Base.encode16(case: :lower),
            ingest_status: "ingested",
            ingest_intent: "attempt"
          })
      end

      %{project: project}
    end

    test "truncated: limit 2 over 3 rows; count keeps meaning the page", %{project: p} do
      env = call("file_list", %{"project_id" => p.id, "limit" => 2})
      assert_truncated("file_list", env, 3)
      assert env.count == 2
    end

    test "untruncated: limit 50 over 3 rows", %{project: p} do
      env = call("file_list", %{"project_id" => p.id, "limit" => 50})
      assert_whole("file_list", env, 3)
      assert env.count == 3
    end

    test "total follows the content_type filter, not the whole project", %{project: p} do
      env = call("file_list", %{"project_id" => p.id, "content_type" => "application/pdf"})
      assert env.files == []
      assert env.total == 0
      assert env.has_more == false
    end
  end

  defp diag_task do
    {:ok, project} = Tasks.create_project(%{name: "Envelope Diag #{u()}"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Diag"})
    task
  end

  describe "runtime conformance: runtime_event_list" do
    setup do
      task = diag_task()

      for i <- 1..3 do
        {:ok, _} =
          %RuntimeEvent{}
          |> RuntimeEvent.changeset(%{
            task_id: task.id,
            phase: "execution",
            runtime_id: "runtime-env",
            event_type: "execution.heartbeat",
            occurred_at: DateTime.add(DateTime.utc_now(), -i, :second),
            idempotency_key: "env-#{i}-#{u()}",
            payload: %{}
          })
          |> Repo.insert()
      end

      %{task: task}
    end

    test "truncated: limit 2 over 3 rows; count keeps meaning the page", %{task: task} do
      env = call("runtime_event_list", %{"task_id" => task.id, "limit" => 2})
      assert_truncated("runtime_event_list", env, 3)
      assert env.count == 2
      assert env.limit == 2
    end

    test "untruncated: limit 50 over 3 rows", %{task: task} do
      env = call("runtime_event_list", %{"task_id" => task.id, "limit" => 50})
      assert_whole("runtime_event_list", env, 3)
    end

    test "total follows the event_type filter", %{task: task} do
      env = call("runtime_event_list", %{"task_id" => task.id, "event_type" => "nope"})
      assert env.events == []
      assert env.total == 0
      assert env.has_more == false
    end
  end

  describe "runtime conformance: execution_lease_list" do
    setup do
      task = diag_task()
      now = DateTime.utc_now()

      rows =
        for i <- 1..3 do
          %{
            id: Platform.Types.UUIDv7.generate(),
            task_id: task.id,
            stage_id: Ecto.UUID.generate(),
            phase: "execution",
            runtime_id: "runtime-env-#{i}",
            status: if(i == 3, do: "blocked", else: "active"),
            started_at: DateTime.add(now, i, :second),
            expires_at: DateTime.add(now, 1800, :second),
            metadata: %{},
            owner_attribution_status: "legacy_pre_migration",
            inserted_at: now,
            updated_at: now
          }
        end

      {3, _} = Repo.insert_all(ExecutionLease, rows)
      %{task: task}
    end

    test "truncated: limit 2 over 3 rows; count keeps meaning the page", %{task: task} do
      env = call("execution_lease_list", %{"task_id" => task.id, "limit" => 2})
      assert_truncated("execution_lease_list", env, 3)
      assert env.count == 2
    end

    test "untruncated: limit 50 over 3 rows", %{task: task} do
      env = call("execution_lease_list", %{"task_id" => task.id, "limit" => 50})
      assert_whole("execution_lease_list", env, 3)
    end

    test "total follows the status filter", %{task: task} do
      env = call("execution_lease_list", %{"task_id" => task.id, "status" => "blocked"})
      assert length(env.leases) == 1
      assert env.total == 1
      assert env.has_more == false
    end
  end

  defp tenant_agent!(org_id) do
    %Agent{}
    |> Agent.changeset(%{
      slug: "envelope-#{u()}",
      name: "Envelope #{u()}",
      status: "active",
      metadata: if(org_id, do: %{"org_id" => org_id}, else: %{})
    })
    |> Repo.insert!()
  end

  defp experiment!(org_id) do
    %Experiment{}
    |> Experiment.changeset(%{slug: "env-exp-#{u()}", name: "Env", org_id: org_id})
    |> Repo.insert!()
  end

  describe "runtime conformance: experiment_list" do
    setup do
      org = tenant_org_id("envelope-a-#{u()}")
      other = tenant_org_id("envelope-b-#{u()}")
      for _ <- 1..3, do: experiment!(org)
      hidden = experiment!(other)
      %{org: org, other: other, hidden: hidden, ctx: %{agent_id: tenant_agent!(org).id}}
    end

    test "truncated: limit 2 over 3 rows", %{org: org, ctx: ctx} do
      env = call("experiment_list", %{"org_id" => org, "limit" => 2}, ctx)
      assert_truncated("experiment_list", env, 3)
      assert env.count == 2
    end

    test "untruncated: limit 50 over 3 rows", %{org: org, ctx: ctx} do
      env = call("experiment_list", %{"org_id" => org, "limit" => 50}, ctx)
      assert_whole("experiment_list", env, 3)
    end

    test "total does NOT count a row the caller cannot see", ctx do
      # Filtering on the sibling org: the filter matches the hidden row, and
      # only the `visible/2` scope excludes it. A count taken outside that
      # scope reports 1 here and discloses the row.
      env = call("experiment_list", %{"org_id" => ctx.other}, ctx.ctx)
      assert env.experiments == []
      assert env.total == 0
      assert env.has_more == false

      unfiltered = call("experiment_list", %{"limit" => 200}, ctx.ctx)
      refute Enum.any?(unfiltered.experiments, &(&1.id == ctx.hidden.id))
      assert unfiltered.total == length(unfiltered.experiments)
      assert unfiltered.has_more == false
    end
  end

  defp seed_goals!(org_id, n) do
    now = DateTime.utc_now()

    rows =
      for i <- 1..n do
        %{
          id: Platform.Types.UUIDv7.generate(),
          org_id: org_id,
          statement: "Goal #{i}",
          metric_spec: %{},
          status: "active",
          inserted_at: DateTime.add(now, i, :microsecond),
          updated_at: now
        }
      end

    {^n, _} = Repo.insert_all(Goal, rows)
    :ok
  end

  describe "runtime conformance: experiment_goal_list" do
    # The tool takes no caller limit: its only bound is the hard 200 cap,
    # so the truncated case must seed 201. insert_all keeps that cheap.
    setup do
      org = tenant_org_id("envelope-g-#{u()}")
      %{org: org, ctx: %{agent_id: tenant_agent!(org).id}}
    end

    test "truncated: 201 goals against the 200 cap", %{org: org, ctx: ctx} do
      seed_goals!(org, 201)
      env = call("experiment_goal_list", %{"org_id" => org}, ctx)
      assert length(env.goals) == 200
      assert_truncated("experiment_goal_list", env, 201)
      assert env.count == 200
    end

    test "untruncated: 3 goals", %{org: org, ctx: ctx} do
      seed_goals!(org, 3)
      env = call("experiment_goal_list", %{"org_id" => org}, ctx)
      assert_whole("experiment_goal_list", env, 3)
    end

    test "total does NOT count a goal the caller cannot see", %{ctx: ctx} do
      other = tenant_org_id("envelope-gh-#{u()}")
      seed_goals!(other, 2)
      env = call("experiment_goal_list", %{"org_id" => other}, ctx)
      assert env.goals == []
      assert env.total == 0
      assert env.has_more == false
    end
  end

  # ── stage 3: the two readers bounded by something other than a record limit

  # memory_search. The byte bound restated, not read back from the module.
  @memory_search_max_payload_bytes 20_000

  defmodule CrashingProvider do
    @moduledoc false
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(_entries, _config), do: {:ok, 0}
    @impl true
    def search(_query, _opts, _config), do: exit(:boom)
    @impl true
    def delete(_ids, _config), do: {:ok, 0}
    @impl true
    def health(_c), do: :ok
  end

  defp use_memory_provider(provider) do
    prev = Application.get_env(:platform, :memory_service, [])
    Application.put_env(:platform, :memory_service, provider: provider)
    on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)
  end

  defp seed_wiki_pages(marker, n, body_chars) do
    for i <- 1..n do
      body =
        marker <> " " <> String.duplicate("lorem ipsum dolor sit amet ", div(body_chars, 27) + 1)

      {:ok, _} = Wiki.upsert_page("org/page/envelope-#{marker}-#{i}.md", %{content: body})
    end
  end

  defp memory_search(args) do
    call("memory_search", Map.merge(%{"source" => "page"}, args), %{
      agent_id: tenant_agent!(nil).id
    })
  end

  describe "runtime conformance: memory_search" do
    setup do
      use_memory_provider(Platform.Memory.Providers.Noop)
      Repo.delete_all(WikiPage)
      Repo.delete_all(WikiJournalEntry)
      :ok
    end

    test "truncated by the 20_000-byte payload bound" do
      # 40 snippeted hits (~800 bytes each) cannot fit 20_000 bytes.
      seed_wiki_pages("envzarq", 45, 8_000)
      env = memory_search(%{"query" => "envzarq", "limit" => 40})

      # Truncation FIRST: the byte bound fired and the payload fits it.
      assert env.payload_truncated == true
      assert byte_size(Jason.encode!(env)) <= @memory_search_max_payload_bytes

      assert env.has_more == true
      assert env.total > length(env.results)
    end

    test "untruncated: two small hits" do
      seed_wiki_pages("envsmol", 2, 40)
      env = memory_search(%{"query" => "envsmol"})

      assert env.payload_truncated == false
      assert env.truncated == false
      assert length(env.results) == 2
      assert env.has_more == false
      assert env.total == length(env.results)
    end

    test "over-limit: 25 small pages beat the default limit of 20" do
      # Regression for task 01a0e81b: total must be the true match count
      # (25), not the post-limit page length (20) — and has_more must
      # follow from that, not from the byte bound (bodies here are tiny).
      seed_wiki_pages("envmany", 25, 40)
      env = memory_search(%{"query" => "envmany"})

      assert env.total == 25
      assert env.has_more == true
      assert length(env.results) == 20
    end

    test "positive control: 5 small pages, all returned, no more to fetch" do
      seed_wiki_pages("envfew", 5, 40)
      env = memory_search(%{"query" => "envfew"})

      assert env.has_more == false
      assert env.total == 5
      assert env.total == length(env.results)
    end

    test "boundary: corpus size exactly equals the default limit (20)" do
      # The wrong-direction bug this guards against: a corpus of exactly
      # `limit` reporting has_more: true because something compared
      # length(results) == limit instead of the true count against total.
      # ResultBound.paged/5's sibling list tools already avoid that via
      # `offset + length(rows) < total`; this proves memory_search's
      # total/has_more matches that same correct comparison shape.
      seed_wiki_pages("envtwty", 20, 40)
      env = memory_search(%{"query" => "envtwty"})

      assert env.total == 20
      assert env.has_more == false
      assert length(env.results) == 20
    end

    test "EXCEPTION: channel cap hit — total is the true (lower-bound) match count above the page" do
      # limit 1 => channel cap 2; three matching pages trip it, so the
      # search itself reports `truncated`. The lexical channel returns 2
      # of the 3 matches before Search.do_search/2 takes just 1 for the
      # page — total (match_count) is 2, not 1, even though nothing was
      # dropped by the byte bound here. has_more is true both from
      # `length(results) < total` (1 < 2) and from `truncated`.
      seed_wiki_pages("envcapp", 3, 40)
      env = memory_search(%{"query" => "envcapp", "limit" => 1})

      assert env.truncated == true
      assert env.payload_truncated == false
      assert length(env.results) == 1
      assert env.total == 2
      assert env.has_more == true
    end

    test "degraded envelope carries total/has_more beside partial_results" do
      seed_wiki_pages("envdegr", 2, 40)
      use_memory_provider(CrashingProvider)
      env = memory_search(%{"query" => "envdegr"})

      assert env.retrieval_status == "degraded"
      refute Map.has_key?(env, :results)
      assert env.total == length(env.partial_results)
      # A dead channel forces `truncated`, so the same lower-bound exception.
      assert env.has_more == true
    end

    test "degraded envelope truncated by the byte bound" do
      # 40 snippeted hits (~800 bytes each) cannot fit 20_000 bytes.
      seed_wiki_pages("envdegb", 45, 8_000)
      use_memory_provider(CrashingProvider)
      env = memory_search(%{"query" => "envdegb", "limit" => 40})

      assert env.payload_truncated == true
      assert byte_size(Jason.encode!(env)) <= @memory_search_max_payload_bytes
      assert env.has_more == true
      assert env.total > length(env.partial_results)
    end
  end

  # space_get_messages.
  defp message_space! do
    agent = tenant_agent!(nil)

    {:ok, space} =
      Chat.create_space(%{name: "Envelope #{u()}", slug: "envelope-#{u()}", kind: "channel"})

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: agent.name,
        role: "member",
        joined_at: DateTime.utc_now()
      })

    %{space: space, participant: participant, ctx: %{agent_id: agent.id}}
  end

  defp post_messages!(space, participant, n) do
    for i <- 1..n do
      {:ok, m} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: participant.id,
          content_type: "text",
          content: "Envelope msg #{i}"
        })

      m
    end
  end

  describe "runtime conformance: space_get_messages" do
    setup do
      s = message_space!()
      Map.put(s, :posted, post_messages!(s.space, s.participant, 25))
    end

    test "truncated: the default call returns 20 of 25", %{space: space, ctx: ctx} do
      env = call("space_get_messages", %{"space_id" => space.id}, ctx)
      assert length(env.messages) == 20
      assert length(env.messages) < 25
      assert_truncated("space_get_messages", env, 25)
      assert env.limit == 20
    end

    test "untruncated: before_id at the 6th-oldest reaches exactly the 5 older", ctx do
      sixth_oldest = Enum.at(ctx.posted, 5)

      env =
        call(
          "space_get_messages",
          %{"space_id" => ctx.space.id, "before_id" => sixth_oldest.id},
          ctx.ctx
        )

      assert_whole("space_get_messages", env, 5)

      assert Enum.map(env.messages, & &1.id) ==
               ctx.posted |> Enum.take(5) |> Enum.reverse() |> Enum.map(& &1.id)
    end

    test "total excludes history before the participant's history_visible_from", ctx do
      boundary = DateTime.utc_now()
      Repo.update!(Ecto.Changeset.change(ctx.participant, history_visible_from: boundary))
      after_grant = post_messages!(ctx.space, ctx.participant, 3)

      env = call("space_get_messages", %{"space_id" => ctx.space.id}, ctx.ctx)

      # POSITIVE CONTROL: the 25 pre-grant messages exist and an unbounded
      # count sees them.
      assert Chat.count_messages(ctx.space.id, top_level_only: true) == 28

      assert env.total == 3
      assert env.has_more == false

      assert Enum.sort(Enum.map(env.messages, & &1.id)) ==
               Enum.sort(Enum.map(after_grant, & &1.id))
    end
  end

  # ── stage 4: the tools that cannot truncate at the handler ──────────────
  #
  # Each case seeds a known corpus and asserts the untruncated direction
  # (`has_more == false`, `total == length`). The truncated direction for
  # these tools is the transport backstop: `assert_backstop_shrinks/2`
  # pushes the SAME response through `ResultBound.fit/2` with a budget one
  # byte under its size and asserts the flag is raised and `total` survives
  # — which only works while the envelope has exactly one list-valued key.

  defp assert_backstop_shrinks(tool, env) do
    key = Map.fetch!(ToolSurface.list_envelope_tools(), tool) |> Atom.to_string()
    budget = byte_size(Jason.encode!(env)) - 1

    assert {:truncated, json, _note} = ResultBound.fit(env, budget),
           "#{tool}: the backstop could not shrink this envelope (a second list-valued key?)"

    shrunk = Jason.decode!(json)
    assert length(shrunk[key]) < env.total
    assert shrunk["total"] == env.total
    assert shrunk["has_more"] == true
  end

  defp assert_unbounded(tool, env, corpus) do
    assert_whole(tool, env, corpus)
    assert env.has_more == false
    assert_backstop_shrinks(tool, env)
  end

  describe "runtime conformance: space_list" do
    test "every space the agent is in, whole" do
      agent = tenant_agent!(nil)

      for i <- 1..3 do
        {:ok, space} =
          Chat.create_space(%{name: "Env SL #{i} #{u()}", slug: "env-sl-#{u()}", kind: "channel"})

        {:ok, _} =
          Chat.add_participant(space.id, %{
            participant_type: "agent",
            participant_id: agent.id,
            display_name: agent.name,
            role: "member",
            joined_at: DateTime.utc_now()
          })
      end

      env = call("space_list", %{}, %{agent_id: agent.id})
      assert_unbounded("space_list", env, 3)
    end
  end

  describe "runtime conformance: space_list_agents" do
    test "every agent participant, whole" do
      {:ok, space} =
        Chat.create_space(%{name: "Env SLA #{u()}", slug: "env-sla-#{u()}", kind: "channel"})

      for _ <- 1..3 do
        agent = tenant_agent!(nil)
        {:ok, _} = Chat.add_agent_participant(space.id, agent, display_name: agent.name)
      end

      env = call("space_list_agents", %{"space_id" => space.id})
      assert_unbounded("space_list_agents", env, 3)
    end
  end

  defp canvases!(space, participant, n) do
    for i <- 1..n do
      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => space.id,
          "created_by" => participant.id,
          "title" => "Env canvas #{i}"
        })

      canvas
    end
  end

  describe "runtime conformance: canvas_list" do
    test "every canvas in the space, whole" do
      %{space: space, participant: participant, ctx: ctx} = message_space!()
      canvases!(space, participant, 3)

      env = call("canvas_list", %{"space_id" => space.id}, ctx)
      assert_unbounded("canvas_list", env, 3)
    end
  end

  describe "runtime conformance: project_list" do
    test "every project in the org, whole" do
      org = tenant_org_id("envelope-p-#{u()}")

      for i <- 1..3 do
        {:ok, _} = Tasks.create_project(%{name: "Env Proj #{i} #{u()}", org_id: org})
      end

      env = call("project_list", %{"org_id" => org})
      assert_unbounded("project_list", env, 3)
    end
  end

  describe "runtime conformance: org_list_descendants" do
    test "every tenant of the root, whole; a leaf says zero explicitly" do
      corpus = length(Platform.Tenancy.list_tenants())
      assert corpus > 0

      env = call("org_list_descendants", %{"org_id" => fabrikam_org_id()})
      assert_unbounded("org_list_descendants", env, corpus)

      leaf = call("org_list_descendants", %{"org_id" => tenant_org_id("envelope-leaf-#{u()}")})
      assert_whole("org_list_descendants", leaf, 0)
    end
  end

  describe "runtime conformance: epic_list" do
    test "every epic in the project, whole" do
      {:ok, project} = Tasks.create_project(%{name: "Env Epics #{u()}"})

      for i <- 1..3 do
        {:ok, _} = Tasks.create_epic(%{project_id: project.id, name: "Env Epic #{i}"})
      end

      env = call("epic_list", %{"project_id" => project.id})
      assert_unbounded("epic_list", env, 3)
    end
  end

  describe "runtime conformance: validation_list" do
    test "every validation on the stage, whole" do
      %{stages: [stage]} = plan_with_stages(1)

      for kind <- ~w(test_pass lint_pass ci_check) do
        {:ok, _} = Tasks.create_validation(%{stage_id: stage.id, kind: kind})
      end

      env = call("validation_list", %{"stage_id" => stage.id})
      assert_unbounded("validation_list", env, 3)
    end
  end

  describe "runtime conformance: prompt_template_list" do
    test "every template, whole" do
      corpus = Repo.aggregate(PromptTemplate, :count)
      assert corpus > 0

      env = call("prompt_template_list", %{})
      assert_unbounded("prompt_template_list", env, corpus)
    end
  end

  describe "runtime conformance: task_transition_list" do
    test "every recorded transition, whole; count keeps its meaning" do
      task = diag_task()

      for to <- ~w(planning in_progress in_review) do
        {:ok, _} =
          PhaseTransitions.record(%{
            task_id: task.id,
            to_status: to,
            occurred_at: DateTime.utc_now(),
            actor_kind: "system"
          })
      end

      corpus =
        Repo.aggregate(from(t in PhaseTransition, where: t.task_id == ^task.id), :count)

      assert corpus >= 3

      env = call("task_transition_list", %{"task_id" => task.id})
      assert_unbounded("task_transition_list", env, corpus)
      assert env.count == corpus
    end
  end

  describe "runtime conformance: task_list_canvases" do
    test "every attachment on the task, whole" do
      %{space: space, participant: participant, ctx: ctx} = message_space!()
      {:ok, project} = Tasks.create_project(%{name: "Env TLC #{u()}"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Env TLC",
          assignee_type: "agent",
          assignee_id: ctx.agent_id
        })

      for canvas <- canvases!(space, participant, 3) do
        {:ok, _} =
          CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
            attached_by: %{kind: "user", id: Ecto.UUID.generate()}
          )
      end

      env = call("task_list_canvases", %{"task_id" => task.id}, ctx)
      assert_unbounded("task_list_canvases", env, 3)
    end
  end

  describe "runtime conformance: canvas.list_kinds" do
    test "every registered kind, whole" do
      corpus = length(Kinds.summaries())
      assert corpus > 0

      env = call("canvas.list_kinds", %{})
      assert_unbounded("canvas.list_kinds", env, corpus)
    end
  end

  describe "runtime conformance: skill.list" do
    test "every matching skill, whole; count keeps its meaning" do
      marker = "envskill#{u()}"

      for i <- 1..3 do
        {:ok, _} = Platform.Skills.create_skill(%{name: "#{marker} #{i}", content: "body"})
      end

      env = call("skill.list", %{"query" => marker})
      assert_unbounded("skill.list", env, 3)
      assert env.count == 3
    end
  end

  describe "runtime conformance: experiment_surface_list" do
    test "every registered surface, whole" do
      corpus = length(Surfaces.list())
      assert corpus > 0

      env = call("experiment_surface_list", %{})
      assert_unbounded("experiment_surface_list", env, corpus)
    end
  end

  describe "runtime conformance: experiment_signals_list" do
    test "every signal on the experiment, whole; count keeps its meaning" do
      org = tenant_org_id("envelope-sig-#{u()}")
      experiment = experiment!(org)

      for i <- 1..3 do
        {:ok, _} =
          Signals.record(%{
            experiment_id: experiment.id,
            subject_type: "task",
            subject_id: Ecto.UUID.generate(),
            source_type: "envelope_test",
            source_id: "src-#{i}",
            status: "unlabelled"
          })
      end

      env =
        call("experiment_signals_list", %{"experiment_id" => experiment.id}, %{
          agent_id: tenant_agent!(org).id
        })

      assert_unbounded("experiment_signals_list", env, 3)
      assert env.count == 3
    end
  end

  # ── Closing the registry ────────────────────────────────────────────────

  # The tool names this file has a runtime conformance case for, read from
  # its own `describe "runtime conformance: <tool>"` blocks — so a case is
  # counted only if it exists, never because a list says so.
  defp covered_tools do
    Regex.scan(~r/^  describe "runtime conformance: ([^"]+)" do$/m, File.read!(__ENV__.file))
    |> Enum.map(fn [_, name] -> name end)
    |> MapSet.new()
  end

  # Pure, so the positive control can inject a covered set with a hole.
  defp uncovered(registry, covered) do
    registered = registry |> Map.keys() |> MapSet.new()

    %{
      missing: registered |> MapSet.difference(covered) |> Enum.sort(),
      unregistered: covered |> MapSet.difference(registered) |> Enum.sort()
    }
  end

  describe "the registry is closed" do
    test "(a) the set of tools with a conformance case EQUALS the registry" do
      assert uncovered(ToolSurface.list_envelope_tools(), covered_tools()) ==
               %{missing: [], unregistered: []}
    end

    test "(a) POSITIVE CONTROL: a registered tool with no case is reported" do
      covered = MapSet.delete(covered_tools(), "epic_list")

      assert uncovered(ToolSurface.list_envelope_tools(), covered) ==
               %{missing: ["epic_list"], unregistered: []}
    end

    test "(b) every registered tool's `returns` names both total and has_more" do
      defs = Map.new(ToolSurface.tool_definitions(), &{&1.name, &1})

      silent =
        ToolSurface.list_envelope_tools()
        |> Map.keys()
        |> Enum.reject(fn name ->
          returns = defs |> Map.fetch!(name) |> Map.get(:returns, "")
          returns =~ "total" and returns =~ "has_more"
        end)
        |> Enum.sort()

      assert silent == []
    end

    test "(d) the stage-1 static guard is still green" do
      assert ListContract.unclassified(ToolSurface.tool_definitions()) == []
    end
  end

  describe "the helpers' output stays shrinkable by the transport backstop" do
    test "whole/3: fit/2 raises has_more and keeps total" do
      env = ResultBound.whole(:rows, Enum.map(1..20, &%{id: &1, pad: String.duplicate("x", 50)}))
      assert env.has_more == false
      assert {:truncated, json, _} = ResultBound.fit(env, 400)
      shrunk = Jason.decode!(json)
      assert length(shrunk["rows"]) < 20
      assert shrunk["has_more"] == true
      assert shrunk["total"] == 20
    end

    test "paged/5 on a last page: fit/2 raises has_more and keeps total" do
      rows = Enum.map(1..20, &%{id: &1, pad: String.duplicate("x", 50)})
      env = ResultBound.paged(:rows, rows, 20, 0, %{limit: 20, offset: 0})
      assert env.has_more == false
      assert {:truncated, json, _} = ResultBound.fit(env, 400)
      shrunk = Jason.decode!(json)
      assert length(shrunk["rows"]) < 20
      assert shrunk["has_more"] == true
      assert shrunk["total"] == 20
    end

    test "POSITIVE CONTROL: a second list-valued key disables the backstop's shrink" do
      env =
        ResultBound.whole(:rows, Enum.map(1..20, &%{id: &1, pad: String.duplicate("x", 50)}), %{
          other: [1]
        })

      assert {:truncated, json, _} = ResultBound.fit(env, 400)
      assert Jason.decode!(json)["has_more"] == false
    end
  end
end
