defmodule Platform.Agents.WorkspaceBootstrapTest do
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Agents.{AgentServer, WorkspaceBootstrap}
  alias Platform.Repo

  defp tmp_workspace!(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "platform-agent-workspace-#{label}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)

    on_exit(fn ->
      File.rm_rf(path)
    end)

    path
  end

  defp write_workspace!(path, slug, soul) do
    openclaw = %{
      "agents" => %{
        "list" => [
          %{
            "id" => slug,
            "name" => "Zip",
            "model" => %{"primary" => "anthropic/claude-sonnet-4-6"},
            "tools" => %{"profile" => "minimal"}
          }
        ]
      }
    }

    File.write!(Path.join(path, "openclaw.json"), Jason.encode!(openclaw))
    File.write!(Path.join(path, "SOUL.md"), soul)
  end

  describe "boot/1" do
    test "upserts the mounted workspace agent and starts its runtime" do
      workspace = tmp_workspace!("boot")
      slug = "zip-#{System.unique_integer([:positive, :monotonic])}"
      write_workspace!(workspace, slug, "steady")

      assert {:ok, status} = WorkspaceBootstrap.boot(workspace_path: workspace)
      assert status.configured?
      assert status.reachable?
      assert status.agent.slug == slug

      Sandbox.allow(Repo, self(), status.pid)

      assert {:ok, state} = AgentServer.state(status.agent.id)
      assert state.workspace == %{"SOUL.md" => "steady"}

      File.write!(Path.join(workspace, "SOUL.md"), "updated")

      assert {:ok, refreshed} = WorkspaceBootstrap.boot(workspace_path: workspace)
      assert refreshed.agent.id == status.agent.id
      assert refreshed.pid == status.pid

      Sandbox.allow(Repo, self(), refreshed.pid)

      assert {:ok, refreshed_state} = AgentServer.state(refreshed.agent.id)
      assert refreshed_state.workspace == %{"SOUL.md" => "updated"}

      on_exit(fn ->
        AgentServer.stop_agent(refreshed.pid)
      end)
    end
  end

  describe "status/1" do
    test "reports unconfigured when the mounted workspace is missing" do
      status = WorkspaceBootstrap.status(workspace_path: "/tmp/does-not-exist/platform-agent")

      refute status.configured?
      refute status.reachable?
      assert status.error
    end
  end
end
