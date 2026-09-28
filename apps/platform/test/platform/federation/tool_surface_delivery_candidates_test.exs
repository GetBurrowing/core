defmodule Platform.Federation.ToolSurfaceDeliveryCandidatesTest do
  @moduledoc """
  Task 01a044b0 stage 4 — `task_delivery_candidate_list` on the MCP surface,
  driven through `ToolArguments.dispatch/3`.

  `async: false` because the `DeliveryReference` runner seam is pinned
  through application env, which is global. Every pin is restored in
  `on_exit`.
  """
  use Platform.DataCase, async: false

  alias Platform.Federation.ToolArguments
  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.PhaseTransition
  alias Platform.Tasks.Task

  @tool "task_delivery_candidate_list"
  @merged_at "2999-01-01T00:00:00Z"

  defmodule StubRunner do
    @moduledoc false
    @behaviour Platform.Tasks.DeliveryReference.Runner

    @impl true
    def commit(_slug, _sha), do: {:error, :not_found}

    @impl true
    def pull_request(_slug, _number), do: {:error, :not_found}

    @impl true
    def merged_pull_requests(slug, _limit),
      do: stub() |> Map.get(:prs, %{}) |> Map.get(slug, {:ok, []})

    @impl true
    def code_search(slug, term),
      do:
        stub()
        |> Map.get(:search, %{})
        |> Map.get({slug, term}, {:error, {:unavailable, "unstubbed"}})

    defp stub, do: Application.get_env(:platform, :delivery_candidates_stub, %{})
  end

  setup do
    previous_runner = Application.get_env(:platform, :delivery_reference)
    previous_stub = Application.get_env(:platform, :delivery_candidates_stub)
    Application.put_env(:platform, :delivery_reference, runner: StubRunner)

    on_exit(fn ->
      restore(:delivery_reference, previous_runner)
      restore(:delivery_candidates_stub, previous_stub)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:platform, key)
  defp restore(key, value), do: Application.put_env(:platform, key, value)

  defp stub!(map), do: Application.put_env(:platform, :delivery_candidates_stub, map)

  defp repo_project! do
    slug = "Cand-Org/repo-#{System.unique_integer([:positive])}"

    {:ok, project} =
      Tasks.create_project(%{name: "Cand #{slug}", repo_url: "https://github.com/#{slug}"})

    {project, slug}
  end

  defp task!(project, attrs \\ %{}) do
    Repo.insert!(
      struct(Task, Map.merge(%{project_id: project.id, title: "Open", status: "backlog"}, attrs))
    )
  end

  defp pr(number, title) do
    %{
      "number" => number,
      "title" => title,
      "body" => "",
      "mergedAt" => @merged_at,
      "mergeCommit" => %{"oid" => "sha#{number}"},
      "url" => "https://github.com/x/y/pull/#{number}"
    }
  end

  defp call(args \\ %{}) do
    assert {:ok, env} = ToolArguments.dispatch(@tool, args, %{})
    env
  end

  test "the tool is registered in the task bundle and bound by the list envelope" do
    assert Enum.any?(ToolSurface.list_tools(["task"]), &(&1.name == @tool))
    assert ToolSurface.list_envelope_tools()[@tool] == :candidates
  end

  test "a planted pair surfaces as id-named-in-commit" do
    {project, slug} = repo_project!()
    t1 = task!(project)
    stub!(%{prs: %{slug => {:ok, [pr(7, "Ship it (#{t1.id})")]}}})

    env = call()

    assert [candidate] = env.candidates
    assert candidate.task_id == t1.id
    assert candidate.confidence == "id-named-in-commit"
    assert candidate.pr_number == 7
    assert env.total == 1
    assert env.has_more == false
  end

  test "a no-repo project's task is returned under cannot_verify" do
    {:ok, no_repo} = Tasks.create_project(%{name: "No repo #{System.unique_integer()}"})
    t7 = task!(no_repo)
    {project, slug} = repo_project!()
    t1 = task!(project)
    stub!(%{prs: %{slug => {:ok, [pr(8, "Ship #{t1.id}")]}}})

    env = call()

    assert [%{task_id: id, reason: "project has no usable repo_url"}] = env.cannot_verify
    assert id == t7.id
    assert Enum.map(env.candidates, & &1.task_id) == [t1.id]
  end

  test "cannot_verify is returned whole even on an empty candidate page" do
    {:ok, no_repo} = Tasks.create_project(%{name: "No repo #{System.unique_integer()}"})
    t = task!(no_repo)
    stub!(%{})

    env = call(%{"limit" => 1, "offset" => 5})

    assert env.candidates == []
    assert env.total == 0
    assert [%{task_id: id}] = env.cannot_verify
    assert id == t.id
  end

  test "the prefix trap gives no candidate" do
    {project, slug} = repo_project!()
    base = Ecto.UUID.generate()
    prefix = binary_part(base, 0, 8)
    t4 = task!(project, %{id: base})
    t5 = task!(project, %{id: prefix <> binary_part(Ecto.UUID.generate(), 8, 28)})
    stub!(%{prs: %{slug => {:ok, [pr(9, "Fixes #{prefix}")]}}})

    env = call()

    assert env.candidates == []
    assert [%{prefix: ^prefix, task_ids: ids}] = env.ambiguous_prefixes
    assert Enum.sort(ids) == Enum.sort([t4.id, t5.id])
  end

  test "the call closes nothing: statuses, updated_at and transitions are unchanged" do
    {project, slug} = repo_project!()
    t1 = task!(project)
    t2 = task!(project)
    stub!(%{prs: %{slug => {:ok, [pr(10, "Ship #{t1.id} and #{t2.id}")]}}})

    snapshot = fn ->
      Task |> Repo.all() |> Enum.map(&{&1.id, &1.status, &1.updated_at}) |> Enum.sort()
    end

    before_rows = snapshot.()
    before_transitions = Repo.aggregate(PhaseTransition, :count)

    env = call()

    assert length(env.candidates) == 2
    assert snapshot.() == before_rows
    assert Repo.aggregate(PhaseTransition, :count) == before_transitions
  end

  test "an out-of-range pr_limit is refused, recoverably" do
    assert {:error, %{recoverable: true, error: error}} =
             ToolArguments.dispatch(@tool, %{"pr_limit" => 0}, %{})

    assert error =~ "pr_limit"
  end
end
