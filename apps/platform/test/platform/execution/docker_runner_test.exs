defmodule Platform.Execution.DockerRunnerTest do
  use ExUnit.Case, async: false

  alias Platform.Execution.{CredentialLease, DockerRunner, Run}

  # ---------------------------------------------------------------------------
  # Deterministic fake client
  # ---------------------------------------------------------------------------

  defmodule FakeSuiteRunnerdClient do
    @behaviour Platform.Execution.SuiteRunnerdClient

    alias Platform.Execution.Run

    @impl true
    def spawn_run(%Run{} = run, payload, opts) do
      send(opts[:test_pid], {:spawn_run, run, payload})

      {:ok,
       %{
         container_id: "ctr-#{run.id}",
         status: :starting,
         image: "suite-runner:dev"
       }}
    end

    @impl true
    def describe_run(%Run{} = run, provider_ref, opts) do
      send(opts[:test_pid], {:describe_run, run, provider_ref})

      {:ok,
       %{
         status: :running,
         exit_code: nil,
         stop_mode: nil,
         image: provider_ref[:image] || "suite-runner:dev",
         health: :healthy,
         started_at: nil,
         finished_at: nil,
         exit_message: nil
       }}
    end

    @impl true
    def request_stop(%Run{} = run, provider_ref, opts) do
      send(opts[:test_pid], {:request_stop, run, provider_ref})
      :ok
    end

    @impl true
    def force_stop(%Run{} = run, provider_ref, opts) do
      send(opts[:test_pid], {:force_stop, run, provider_ref})
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Fake client that returns an already-stopped container immediately
  # ---------------------------------------------------------------------------

  defmodule FakeStoppedClient do
    @behaviour Platform.Execution.SuiteRunnerdClient

    alias Platform.Execution.Run

    @impl true
    def spawn_run(%Run{} = run, _payload, opts) do
      send(opts[:test_pid], {:spawn_run, run})
      {:ok, %{container_id: "ctr-#{run.id}", status: :starting, image: "suite-runner:dev"}}
    end

    @impl true
    def describe_run(%Run{} = run, _provider_ref, opts) do
      send(opts[:test_pid], {:describe_run, run})
      {:ok, %{status: :exited, exit_code: 0, stop_mode: :graceful, image: "suite-runner:dev"}}
    end

    @impl true
    def request_stop(%Run{} = run, _provider_ref, opts) do
      send(opts[:test_pid], {:request_stop, run})
      :ok
    end

    @impl true
    def force_stop(%Run{} = run, _provider_ref, opts) do
      send(opts[:test_pid], {:force_stop, run})
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Fake client that never stops (forces escalation)
  # ---------------------------------------------------------------------------

  defmodule FakeStuckClient do
    @behaviour Platform.Execution.SuiteRunnerdClient

    alias Platform.Execution.Run

    @impl true
    def spawn_run(%Run{} = run, _payload, opts) do
      send(opts[:test_pid], {:spawn_run, run})
      {:ok, %{container_id: "ctr-#{run.id}", status: :starting, image: "suite-runner:dev"}}
    end

    @impl true
    def describe_run(%Run{} = run, _provider_ref, opts) do
      send(opts[:test_pid], {:describe_run, run})
      # Always reports :running — container is stuck
      {:ok, %{status: :running, exit_code: nil, stop_mode: nil, image: "suite-runner:dev"}}
    end

    @impl true
    def request_stop(%Run{} = run, _provider_ref, opts) do
      send(opts[:test_pid], {:request_stop, run})
      :ok
    end

    @impl true
    def force_stop(%Run{} = run, _provider_ref, opts) do
      send(opts[:test_pid], {:force_stop, run})
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Fake client that fails the stop request
  # ---------------------------------------------------------------------------

  defmodule FakeStopFailClient do
    @behaviour Platform.Execution.SuiteRunnerdClient

    alias Platform.Execution.Run

    @impl true
    def spawn_run(%Run{} = run, _payload, _opts),
      do: {:ok, %{container_id: "ctr-#{run.id}", status: :starting, image: "suite-runner:dev"}}

    @impl true
    def describe_run(%Run{} = _run, _provider_ref, _opts),
      do: {:ok, %{status: :running, exit_code: nil}}

    @impl true
    def request_stop(%Run{} = _run, _provider_ref, _opts),
      do: {:error, {:suite_runnerd_http_error, 503, "service unavailable"}}

    @impl true
    def force_stop(%Run{} = _run, _provider_ref, _opts), do: :ok
  end

  # ---------------------------------------------------------------------------
  # Fake client that returns error on describe
  # ---------------------------------------------------------------------------

  defmodule FakeDescribeErrorClient do
    @behaviour Platform.Execution.SuiteRunnerdClient

    alias Platform.Execution.Run

    @impl true
    def spawn_run(%Run{} = run, _payload, _opts),
      do: {:ok, %{container_id: "ctr-#{run.id}", status: :starting, image: "suite-runner:dev"}}

    @impl true
    def describe_run(%Run{} = _run, _provider_ref, opts) do
      send(opts[:test_pid], :describe_error)
      {:error, {:suite_runnerd_request_failed, :econnrefused}}
    end

    @impl true
    def request_stop(%Run{} = run, _provider_ref, opts) do
      send(opts[:test_pid], {:request_stop, run})
      :ok
    end

    @impl true
    def force_stop(%Run{} = run, _provider_ref, opts) do
      send(opts[:test_pid], {:force_stop, run})
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # spawn_run/2
  # ---------------------------------------------------------------------------

  describe "spawn_run/2" do
    test "delegates to suite-runnerd with workspace + leased env payload" do
      run = run_fixture("docker-run")
      root = temp_dir("docker-root")

      {:ok, lease} =
        CredentialLease.lease(:github,
          run_id: run.id,
          github_token: "gh-test-token",
          author_name: "Zip",
          author_email: "zip@test.local"
        )

      assert {:ok, ref} =
               DockerRunner.spawn_run(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()],
                 run_root: root,
                 command: "/bin/sh",
                 args: ["-c", "echo hello"],
                 credential_lease: lease,
                 meta_overrides: [runner_image: "suite-runner:dev"]
               )

      assert_receive {:spawn_run, ^run, payload}
      assert payload.workspace_root == Path.expand(root)
      assert payload.workspace_path == Path.join(Path.expand(root), run.id)
      assert payload.command == "/bin/sh"
      assert payload.args == ["-c", "echo hello"]
      assert payload.env["GITHUB_TOKEN"] == "gh-test-token"

      # meta_overrides merged into meta
      assert payload.meta[:runner_image] == "suite-runner:dev"

      assert ref.provider == :docker
      assert ref.run_id == run.id
      assert ref.workspace_root == Path.expand(root)
      assert ref.workspace_path == Path.join(Path.expand(root), run.id)
      assert ref.container_id == "ctr-#{run.id}"
      assert ref.image == "suite-runner:dev"
      assert ref.command == "/bin/sh"
      assert ref.args == ["-c", "echo hello"]
    end

    test "spawn payload carries security posture" do
      run = run_fixture("docker-security-run")
      root = temp_dir("docker-root")

      assert {:ok, _ref} =
               DockerRunner.spawn_run(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()],
                 run_root: root,
                 command: "/bin/sh",
                 args: []
               )

      assert_receive {:spawn_run, ^run, payload}

      security = payload.security
      assert security.no_new_privileges == true
      assert security.capability_drop == ["ALL"]
      assert security.no_docker_socket == true
      assert security.user == "node"
      assert security.capability_add == []
    end

    test "spawn payload carries host worktree bind mount" do
      run = run_fixture("docker-mount-run")
      root = temp_dir("docker-root")

      assert {:ok, _ref} =
               DockerRunner.spawn_run(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()],
                 run_root: root,
                 command: "/bin/sh",
                 args: []
               )

      assert_receive {:spawn_run, ^run, payload}

      mount = payload.mount
      assert mount.type == "bind"
      assert mount.host_source == Path.join(Path.expand(root), run.id)
      assert mount.container_target == "/workspace"
      assert mount.read_only == false
    end

    test "custom runner_user option is forwarded in security payload" do
      run = run_fixture("docker-custom-user")
      root = temp_dir("docker-root")

      assert {:ok, _ref} =
               DockerRunner.spawn_run(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()],
                 run_root: root,
                 command: "/bin/sh",
                 args: [],
                 runner_user: "agent"
               )

      assert_receive {:spawn_run, ^run, payload}
      assert payload.security.user == "agent"
    end

    test "custom container_workspace_path is forwarded in mount payload" do
      run = run_fixture("docker-custom-mount")
      root = temp_dir("docker-root")

      assert {:ok, _ref} =
               DockerRunner.spawn_run(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()],
                 run_root: root,
                 command: "/bin/sh",
                 args: [],
                 container_workspace_path: "/runs"
               )

      assert_receive {:spawn_run, ^run, payload}
      assert payload.mount.container_target == "/runs"
    end

    test "returns error when command is missing" do
      run = run_fixture("docker-run-no-command")

      assert {:error, :missing_command} =
               DockerRunner.spawn_run(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()],
                 run_root: temp_dir("docker-root")
               )
    end

    test "resolves command from run meta (atom key)" do
      run = run_fixture("docker-meta-cmd") |> Map.put(:meta, %{command: "/bin/true", args: []})
      root = temp_dir("docker-root")

      assert {:ok, ref} =
               DockerRunner.spawn_run(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()],
                 run_root: root
               )

      assert ref.command == "/bin/true"
    end

    test "resolves command from run meta (string key)" do
      run =
        run_fixture("docker-meta-cmd-str") |> Map.put(:meta, %{"command" => "/bin/true"})

      root = temp_dir("docker-root")

      assert {:ok, ref} =
               DockerRunner.spawn_run(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()],
                 run_root: root
               )

      assert ref.command == "/bin/true"
    end

    test "spawns without credential lease — env is empty map" do
      run = run_fixture("docker-no-lease")
      root = temp_dir("docker-root")

      assert {:ok, _ref} =
               DockerRunner.spawn_run(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()],
                 run_root: root,
                 command: "/bin/sh",
                 args: []
               )

      assert_receive {:spawn_run, ^run, payload}
      assert payload.env == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # request_stop/2 and force_stop/2
  # ---------------------------------------------------------------------------

  describe "request_stop/2 and force_stop/2" do
    test "delegates stop using the existing provider ref on the run" do
      run =
        run_fixture("docker-run-stop")
        |> Map.put(:runner_ref, %{
          provider: :docker,
          run_id: "docker-run-stop",
          workspace_root: "/tmp/root",
          workspace_path: "/tmp/root/docker-run-stop",
          container_id: "ctr-docker-run-stop"
        })

      assert :ok =
               DockerRunner.request_stop(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()]
               )

      assert_receive {:request_stop, ^run, %{container_id: "ctr-docker-run-stop"}}
    end

    test "delegates force_stop (kill) using the existing provider ref" do
      run =
        run_fixture("docker-run-kill")
        |> Map.put(:runner_ref, %{
          provider: :docker,
          run_id: "docker-run-kill",
          container_id: "ctr-docker-run-kill"
        })

      assert :ok =
               DockerRunner.force_stop(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()]
               )

      assert_receive {:force_stop, ^run, %{container_id: "ctr-docker-run-kill"}}
    end

    test "returns error when provider ref is missing on stop" do
      run = run_fixture("docker-run-no-ref")

      assert {:error, :missing_provider_ref} =
               DockerRunner.request_stop(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()]
               )
    end

    test "returns error when provider ref is missing on force_stop" do
      run = run_fixture("docker-run-no-ref-kill")

      assert {:error, :missing_provider_ref} =
               DockerRunner.force_stop(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()]
               )
    end

    test "stop request failure is propagated" do
      run =
        run_fixture("docker-stop-fail")
        |> Map.put(:runner_ref, %{container_id: "ctr-stop-fail"})

      assert {:error, {:suite_runnerd_http_error, 503, _}} =
               DockerRunner.request_stop(run, client: FakeStopFailClient)
    end
  end

  # ---------------------------------------------------------------------------
  # describe_run/2
  # ---------------------------------------------------------------------------

  describe "describe_run/2" do
    test "merges suite-runnerd status with the stored provider ref" do
      run =
        run_fixture("docker-run-describe")
        |> Map.put(:runner_ref, %{
          provider: :docker,
          run_id: "docker-run-describe",
          workspace_root: "/tmp/root",
          workspace_path: "/tmp/root/docker-run-describe",
          container_id: "ctr-docker-run-describe",
          image: "suite-runner:dev"
        })

      assert {:ok, description} =
               DockerRunner.describe_run(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()]
               )

      assert_receive {:describe_run, ^run, %{container_id: "ctr-docker-run-describe"}}

      assert description.provider == :docker
      assert description.status == :running
      assert description.container_id == "ctr-docker-run-describe"
      assert description.image == "suite-runner:dev"
      assert Map.has_key?(description, :workspace_path)
      assert description.health == :healthy
    end

    test "returns error when provider ref is missing" do
      run = run_fixture("docker-run-missing-ref")

      assert {:error, :missing_provider_ref} =
               DockerRunner.describe_run(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()]
               )
    end

    test "propagates suite-runnerd describe errors" do
      run =
        run_fixture("docker-describe-error")
        |> Map.put(:runner_ref, %{container_id: "ctr-error"})

      assert {:error, {:suite_runnerd_request_failed, :econnrefused}} =
               DockerRunner.describe_run(run,
                 client: FakeDescribeErrorClient,
                 client_opts: [test_pid: self()]
               )

      assert_receive :describe_error
    end

    test "normalizes string-keyed provider ref to atom keys" do
      run =
        run_fixture("docker-run-string-ref")
        |> Map.put(:runner_ref, %{
          "provider" => "docker",
          "container_id" => "ctr-strkey",
          "image" => "suite-runner:dev",
          "workspace_root" => "/tmp/root",
          "workspace_path" => "/tmp/root/docker-run-string-ref"
        })

      assert {:ok, desc} =
               DockerRunner.describe_run(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()]
               )

      assert desc.container_id == "ctr-strkey"
      assert desc.provider == :docker
    end
  end

  # ---------------------------------------------------------------------------
  # stop_with_escalation/2 — fast kill semantics
  # ---------------------------------------------------------------------------

  describe "stop_with_escalation/2" do
    test "returns :ok immediately when container stops after graceful request" do
      run =
        run_fixture("docker-escalation-stop")
        |> Map.put(:runner_ref, %{container_id: "ctr-stop"})

      assert :ok =
               DockerRunner.stop_with_escalation(run,
                 client: FakeStoppedClient,
                 client_opts: [test_pid: self()],
                 escalation_timeout_ms: 2_000
               )

      assert_receive {:request_stop, _}
      assert_receive {:describe_run, _}
      # force_stop should NOT be called
      refute_receive {:force_stop, _}
    end

    test "escalates to force_stop when container does not exit before timeout" do
      run =
        run_fixture("docker-escalation-kill")
        |> Map.put(:runner_ref, %{container_id: "ctr-stuck"})

      assert :ok =
               DockerRunner.stop_with_escalation(run,
                 client: FakeStuckClient,
                 client_opts: [test_pid: self()],
                 # Very short timeout so the test is fast
                 escalation_timeout_ms: 10
               )

      assert_receive {:request_stop, _}
      assert_receive {:force_stop, _}
    end

    test "escalates to force_stop when describe returns error" do
      run =
        run_fixture("docker-describe-error-escalation")
        |> Map.put(:runner_ref, %{container_id: "ctr-err"})

      assert :ok =
               DockerRunner.stop_with_escalation(run,
                 client: FakeDescribeErrorClient,
                 client_opts: [test_pid: self()],
                 escalation_timeout_ms: 5_000
               )

      assert_receive {:request_stop, _}
      assert_receive {:force_stop, _}
    end

    test "returns error when the initial stop request fails" do
      run =
        run_fixture("docker-stop-fail-esc")
        |> Map.put(:runner_ref, %{container_id: "ctr-fail"})

      assert {:error, {:suite_runnerd_http_error, 503, _}} =
               DockerRunner.stop_with_escalation(run, client: FakeStopFailClient)
    end

    test "returns error when provider ref is missing" do
      run = run_fixture("docker-escalation-no-ref")

      assert {:error, :missing_provider_ref} =
               DockerRunner.stop_with_escalation(run, client: FakeStuckClient)
    end
  end

  # ---------------------------------------------------------------------------
  # push_context/3
  # ---------------------------------------------------------------------------

  describe "push_context/3" do
    test "returns :ok (no-op for docker provider in MVP)" do
      run = run_fixture("docker-push-ctx")
      assert :ok = DockerRunner.push_context(run, %{}, [])
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp run_fixture(run_id) do
    %Run{
      id: run_id,
      task_id: "task-#{run_id}",
      runner_type: :docker,
      meta: %{}
    }
  end

  defp temp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
