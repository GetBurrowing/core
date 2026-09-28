defmodule Platform.Tasks.DeliverySweepTest do
  # Task 01a044b0 stage 3. The runner is injected through `:runner`; its
  # answers come from the test process's dictionary, so there is no app env
  # and no network.
  use Platform.DataCase, async: true

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.DeliverySweep
  alias Platform.Tasks.DeliverySweep.Matcher
  alias Platform.Tasks.PhaseTransition
  alias Platform.Tasks.Task

  defmodule StubRunner do
    @moduledoc false
    @behaviour Platform.Tasks.DeliveryReference.Runner

    @impl true
    def commit(_slug, _sha), do: {:error, :not_found}

    @impl true
    def pull_request(_slug, _number), do: {:error, :not_found}

    @impl true
    def merged_pull_requests(slug, _limit) do
      stub() |> Map.get(:prs, %{}) |> Map.get(slug, {:ok, []})
    end

    @impl true
    def code_search(slug, term) do
      send(self(), {:code_search, slug, term})

      stub()
      |> Map.get(:search, %{})
      |> Map.get({slug, term}, {:error, {:unavailable, "unstubbed search #{term}"}})
    end

    defp stub, do: Process.get(:delivery_sweep_stub, %{})
  end

  defmodule VerifyOnlyRunner do
    @moduledoc false
    @behaviour Platform.Tasks.DeliveryReference.Runner

    @impl true
    def commit(_slug, _sha), do: {:error, :not_found}

    @impl true
    def pull_request(_slug, _number), do: {:error, :not_found}
  end

  @merged_at "2999-01-01T00:00:00Z"

  defp stub!(map), do: Process.put(:delivery_sweep_stub, map)

  defp project!(repo_url) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Sweep #{System.unique_integer([:positive])}",
        repo_url: repo_url
      })

    project
  end

  defp repo_project! do
    slug = "Sweep-Org/repo-#{System.unique_integer([:positive])}"
    {project!("https://github.com/#{slug}"), slug}
  end

  defp task!(project, attrs \\ %{}) do
    base = %{project_id: project.id, title: "Open ticket", status: "backlog"}
    Repo.insert!(struct(Task, Map.merge(base, attrs)))
  end

  defp pr(number, title, body \\ "") do
    %{
      "number" => number,
      "title" => title,
      "body" => body,
      "mergedAt" => @merged_at,
      "mergeCommit" => %{"oid" => "sha#{number}"},
      "url" => "https://github.com/x/y/pull/#{number}"
    }
  end

  defp sweep!(opts \\ []) do
    assert {:ok, report} = DeliverySweep.run(Keyword.put_new(opts, :runner, StubRunner))
    report
  end

  defp candidate_ids(report), do: report.candidates |> Enum.map(& &1.task_id) |> Enum.uniq()

  # Every scanned task is a candidate, cannot_verify, or no finding — and
  # candidates and cannot_verify never overlap.
  defp assert_accounted!(report, tasks) do
    cand = MapSet.new(candidate_ids(report))
    cv = MapSet.new(report.cannot_verify, & &1.task_id)
    assert MapSet.disjoint?(cand, cv)

    all = MapSet.new(tasks, & &1.id)
    assert MapSet.subset?(cand, all)
    assert MapSet.subset?(cv, all)
    no_finding = MapSet.difference(all, MapSet.union(cand, cv))

    assert MapSet.size(cand) + MapSet.size(cv) + MapSet.size(no_finding) == report.scanned.tasks
    assert report.scanned.tasks == length(tasks)
  end

  test "PLANTED PAIR: a merged PR naming a task's full id surfaces it" do
    {project, slug} = repo_project!()
    t1 = task!(project)
    stub!(%{prs: %{slug => {:ok, [pr(41, "Close the record (#{t1.id})", "details")]}}})

    report = sweep!()

    assert [candidate] = report.candidates
    assert candidate.task_id == t1.id
    assert candidate.confidence == "id-named-in-commit"
    assert candidate.pr_number == 41
    assert candidate.pr_url == "https://github.com/x/y/pull/41"
    assert candidate.merge_commit == "sha41"
    assert candidate.merged_at == @merged_at
    assert candidate.evidence == "Close the record (#{t1.id})"
    assert report.scanned.prs_by_slug == %{slug => 1}
    assert_accounted!(report, [t1])
  end

  test "DEFECT PRESENT (negative) and ABSENT (positive control) in one run" do
    {project, slug} = repo_project!()
    t2 = task!(project, %{description: "Crashes in `Foo.still_here/2`."})
    t3 = task!(project, %{description: "Crashes in `Foo.now_gone/1`."})

    stub!(%{
      prs: %{
        slug =>
          {:ok, [pr(50, "Refactor", "Rewrote Foo.still_here and removed Foo.now_gone entirely")]}
      },
      search: %{
        {slug, "Foo.still_here"} => {:ok, [%{"path" => "lib/foo.ex"}]},
        {slug, "Foo.now_gone"} => {:ok, []}
      }
    })

    report = sweep!()

    assert [candidate] = report.candidates
    assert candidate.task_id == t3.id
    assert candidate.confidence == "defect-string-absent"
    assert candidate.pr_number == 50

    assert candidate.evidence ==
             "`Foo.now_gone` not found by code search on #{slug}; named by #50: " <>
               "Rewrote Foo.still_here and removed Foo.now_gone entirely"

    assert report.cannot_verify == []
    assert_accounted!(report, [t2, t3])
  end

  test "a token named only by a PR merged before the task existed is not searched" do
    {project, slug} = repo_project!()
    t = task!(project, %{description: "`Foo.old_name`"})
    old = %{pr(51, "Removed Foo.old_name") | "mergedAt" => "2000-01-01T00:00:00Z"}
    stub!(%{prs: %{slug => {:ok, [old]}}, search: %{{slug, "Foo.old_name"} => {:ok, []}}})

    report = sweep!()

    assert report.candidates == []
    refute_received {:code_search, _, _}
    assert_accounted!(report, [t])
  end

  test "PREFIX TRAP: an ambiguous prefix yields no candidate; a unique prefix does" do
    {project, slug} = repo_project!()
    base = Ecto.UUID.generate()
    prefix = binary_part(base, 0, 8)
    twin = prefix <> binary_part(Ecto.UUID.generate(), 8, 28)
    t4 = task!(project, %{id: base})
    t5 = task!(project, %{id: twin})
    t6 = task!(project)
    refute binary_part(t6.id, 0, 8) == prefix

    stub!(%{
      prs: %{
        slug =>
          {:ok,
           [
             pr(60, "Fixes #{prefix} for real"),
             pr(61, "Also closes #{binary_part(t6.id, 0, 8)}")
           ]}
      }
    })

    report = sweep!()

    assert [candidate] = report.candidates
    assert candidate.task_id == t6.id
    assert candidate.pr_number == 61

    assert [%{prefix: ^prefix, task_ids: ids, pr: %{number: 60}}] = report.ambiguous_prefixes
    assert Enum.sort(ids) == Enum.sort([t4.id, t5.id])
    assert_accounted!(report, [t4, t5, t6])
  end

  test "a unique prefix that resolves to a soft-deleted backlog task gives no candidate" do
    {project, slug} = repo_project!()
    # Explicit v4 ids: two UUIDv7 ids minted in the same minute share
    # their first 8 hex, which would make this an ambiguity test instead.
    deleted = task!(project, %{id: Ecto.UUID.generate(), deleted_at: DateTime.utc_now()})
    live = task!(project, %{id: Ecto.UUID.generate()})
    refute binary_part(deleted.id, 0, 8) == binary_part(live.id, 0, 8)
    assert Matcher.resolve_prefix(binary_part(deleted.id, 0, 8)) == {:unique, deleted.id}

    stub!(%{
      prs: %{
        slug =>
          {:ok,
           [
             pr(70, "Closes #{binary_part(deleted.id, 0, 8)}"),
             pr(71, "Closes #{binary_part(live.id, 0, 8)}")
           ]}
      }
    })

    report = sweep!()

    assert Enum.map(report.candidates, & &1.task_id) == [live.id]
    assert report.scanned.tasks == 1
  end

  test "NO REPO: a project without repo_url lands in cannot_verify; a repo project still surfaces" do
    no_repo = project!(nil)
    t7 = task!(no_repo)
    {project, slug} = repo_project!()
    t1 = task!(project)
    stub!(%{prs: %{slug => {:ok, [pr(80, "Ship #{t1.id}")]}}})

    report = sweep!()

    assert [%{task_id: id, project_id: pid, reason: "project has no usable repo_url"}] =
             report.cannot_verify

    assert id == t7.id
    assert pid == no_repo.id
    assert candidate_ids(report) == [t1.id]
    assert_accounted!(report, [t7, t1])
  end

  test "a non-GitHub repo_url is cannot_verify too" do
    t = task!(project!("https://gitlab.com/a/b"))
    report = sweep!()
    assert [%{task_id: id, reason: "project has no usable repo_url"}] = report.cannot_verify
    assert id == t.id
  end

  test "UNAVAILABLE: a merged-PR listing failure puts the project's tasks in cannot_verify" do
    {project, slug} = repo_project!()
    t1 = task!(project)
    t2 = task!(project, %{description: "`Foo.bar_baz`"})
    stub!(%{prs: %{slug => {:error, {:unavailable, "HTTP 502"}}}})

    report = sweep!()

    assert report.candidates == []
    assert Enum.sort(Enum.map(report.cannot_verify, & &1.task_id)) == Enum.sort([t1.id, t2.id])
    assert Enum.all?(report.cannot_verify, &(&1.reason == "HTTP 502"))
    assert_accounted!(report, [t1, t2])
  end

  test "UNAVAILABLE: a code-search failure is cannot_verify, never a candidate" do
    {project, slug} = repo_project!()
    t = task!(project, %{description: "`Foo.flaky_one`"})

    stub!(%{
      prs: %{slug => {:ok, [pr(90, "Touches Foo.flaky_one")]}},
      search: %{{slug, "Foo.flaky_one"} => {:error, {:unavailable, "rate limited"}}}
    })

    report = sweep!()

    assert report.candidates == []
    assert [%{task_id: id, reason: "rate limited"}] = report.cannot_verify
    assert id == t.id
    assert_accounted!(report, [t])
  end

  test "a runner without the listing callbacks sends every task to cannot_verify" do
    {project, _slug} = repo_project!()
    t = task!(project)

    report = sweep!(runner: VerifyOnlyRunner)

    assert report.candidates == []
    assert [%{task_id: id, reason: reason}] = report.cannot_verify
    assert id == t.id
    assert reason =~ "VerifyOnlyRunner"
    assert_accounted!(report, [t])
  end

  test "CAP: max_code_searches: 1 with two eligible tokens puts one task in not_checked" do
    {project, slug} = repo_project!()
    ta = task!(project, %{description: "`Foo.first_token`"})
    tb = task!(project, %{description: "`Foo.second_token`"})

    stub!(%{
      prs: %{slug => {:ok, [pr(100, "Removed Foo.first_token and Foo.second_token")]}},
      search: %{
        {slug, "Foo.first_token"} => {:ok, []},
        {slug, "Foo.second_token"} => {:ok, []}
      }
    })

    report = sweep!(max_code_searches: 1)

    assert [%{task_id: skipped, reason: "max_code_searches reached"}] = report.not_checked
    assert length(report.candidates) == 1
    assert Enum.sort([skipped | candidate_ids(report)]) == Enum.sort([ta.id, tb.id])
    assert_accounted!(report, [ta, tb])
  end

  test "project_id limits the scan" do
    {p1, s1} = repo_project!()
    {p2, s2} = repo_project!()
    t1 = task!(p1)
    t2 = task!(p2)
    stub!(%{prs: %{s1 => {:ok, [pr(1, "#{t1.id}")]}, s2 => {:ok, [pr(2, "#{t2.id}")]}}})

    report = sweep!(project_id: p1.id)

    assert candidate_ids(report) == [t1.id]
    assert report.scanned.tasks == 1
  end

  test "closed tasks are not scanned" do
    {project, slug} = repo_project!()
    done = task!(project, %{status: "done"})
    stub!(%{prs: %{slug => {:ok, [pr(3, "#{done.id}")]}}})

    report = sweep!()

    assert report.candidates == []
    assert report.scanned.tasks == 0
  end

  test "CLOSES NOTHING: task rows and phase transitions are unchanged by a run with candidates" do
    {project, slug} = repo_project!()
    t1 = task!(project)
    t3 = task!(project, %{description: "`Foo.now_gone`"})

    stub!(%{
      prs: %{slug => {:ok, [pr(110, "Ship #{t1.id}", "drops Foo.now_gone")]}},
      search: %{{slug, "Foo.now_gone"} => {:ok, []}}
    })

    snapshot = fn ->
      Task |> Repo.all() |> Enum.map(&{&1.id, &1.status, &1.updated_at}) |> Enum.sort()
    end

    before_rows = snapshot.()
    before_transitions = Repo.aggregate(PhaseTransition, :count)

    report = sweep!()

    assert Enum.sort(candidate_ids(report)) == Enum.sort([t1.id, t3.id])
    assert snapshot.() == before_rows
    assert Repo.aggregate(PhaseTransition, :count) == before_transitions
  end

  test "source guard: the sweep and the matcher contain no write call" do
    forbidden = [
      ~r/close_as_delivered\s*\(/,
      ~r/update_task\s*\(/,
      ~r/transition_task_status\s*\(/,
      ~r/Repo\.(insert|update|delete|update_all|insert_all|delete_all|insert_or_update)\b/
    ]

    for path <- [
          "lib/platform/tasks/delivery_sweep.ex",
          "lib/platform/tasks/delivery_sweep/matcher.ex"
        ] do
      source = File.read!(path)

      for pattern <- forbidden do
        refute source =~ pattern, "#{path} matches forbidden write pattern #{inspect(pattern)}"
      end
    end
  end
end
