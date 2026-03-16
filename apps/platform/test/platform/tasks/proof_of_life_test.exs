defmodule Platform.Tasks.ProofOfLifeTest do
  use ExUnit.Case, async: false

  alias Platform.{Artifacts, Context, Execution}
  alias Platform.Tasks.ProofOfLife

  setup do
    config = Application.get_env(:platform, :proof_of_life, [])
    on_exit(fn -> Application.put_env(:platform, :proof_of_life, config) end)
    :ok
  end

  test "bootstrap + approve + launch completes a local proof flow and records the result" do
    root = temp_dir("proof-flow")
    {repo_path, remote} = setup_temp_repo_with_remote(root)

    Application.put_env(:platform, :proof_of_life,
      repo_path: repo_path,
      remote: "origin",
      base_ref: "main",
      run_root: Path.join(root, "runs")
    )

    assert {:ok, task_id} = ProofOfLife.bootstrap_task(task_id: "proof-task")
    assert {:ok, _version} = ProofOfLife.approve_plan(task_id)
    assert {:ok, run} = ProofOfLife.launch(task_id)

    assert_eventually(
      fn ->
        case Execution.get_run(run.id) do
          {:ok, run} -> run.status == :completed
          _ -> false
        end
      end,
      5_000
    )

    assert_eventually(
      fn ->
        Artifacts.list_artifacts(task_id: task_id) != []
      end,
      5_000
    )

    assert %{"state" => "pushed", "branch" => branch} =
             current_task_item(task_id, "proof_of_life:status")

    assert %{"status" => "passed"} = current_task_item(task_id, "proof_of_life:verification")

    {output, 0} = System.cmd("git", ["ls-remote", remote, "refs/heads/#{branch}"], cd: repo_path)
    assert String.contains?(output, branch)
  end

  defp current_task_item(task_id, key) do
    {:ok, snapshot} = Context.snapshot(%{task_id: task_id})

    snapshot.items
    |> Enum.find(&(&1.key == key))
    |> Map.fetch!(:value)
  end

  defp temp_dir(prefix) do
    path =
      Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(path)
    path
  end

  defp assert_eventually(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assert_eventually(fun, deadline)
  end

  defp do_assert_eventually(fun, deadline) do
    if fun.() do
      assert true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(50)
        do_assert_eventually(fun, deadline)
      else
        flunk("condition was not met before timeout")
      end
    end
  end

  defp setup_temp_repo_with_remote(root) do
    bare = Path.join(root, "bare.git")
    clone = Path.join(root, "clone")

    System.cmd("git", ["init", "--bare", "--initial-branch=main", bare], stderr_to_stdout: true)

    seed = Path.join(root, "seed")
    File.mkdir_p!(seed)
    System.cmd("git", ["init", "--initial-branch=main"], cd: seed, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@suite.local"], cd: seed)
    System.cmd("git", ["config", "user.name", "Test"], cd: seed)
    File.write!(Path.join(seed, "README.md"), "# proof flow\n")
    System.cmd("git", ["add", "."], cd: seed)
    System.cmd("git", ["commit", "-m", "init"], cd: seed, stderr_to_stdout: true)
    System.cmd("git", ["remote", "add", "origin", bare], cd: seed)
    System.cmd("git", ["push", "origin", "main"], cd: seed, stderr_to_stdout: true)

    System.cmd("git", ["clone", bare, clone], stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@suite.local"], cd: clone)
    System.cmd("git", ["config", "user.name", "Suite Bot"], cd: clone)

    {clone, bare}
  end
end
