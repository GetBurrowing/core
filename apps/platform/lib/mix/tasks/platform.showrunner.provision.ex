defmodule Mix.Tasks.Platform.Showrunner.Provision do
  @moduledoc """
  Switch the How to Computer showrunner on for one agent and one show space
  (task 01a1eaf6 stage 4). A thin wrapper over `Platform.Showrunner.provision/1`.

      mix platform.showrunner.provision \\
        --agent-id <agent uuid> --space-id <space uuid> \\
        --project-id <project uuid> --escalate-user-id <user uuid> \\
        [--host-user-id <user uuid> ...] [--reassign]

  Idempotent: a second run leaves one role assignment and six responsibility
  rows, and keeps any cadence an operator set. It prints whether the agent's
  runtime can reach the `social` tool bundle, and a warning when it cannot
  (post and retro then park on a Needs-you item until it is added).

  Ids are given here, at run time, and never committed.
  """

  use Mix.Task

  @shortdoc "Provision the showrunner role, its six responsibilities and their config"

  @switches [
    agent_id: :string,
    space_id: :string,
    project_id: :string,
    escalate_user_id: :string,
    host_user_id: :keep,
    reassign: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {parsed, _rest, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("unknown options: #{inspect(invalid)}")

    hosts = Keyword.get_values(parsed, :host_user_id)

    attrs =
      %{
        agent_id: parsed[:agent_id] || Mix.raise("--agent-id is required"),
        space_id: parsed[:space_id] || Mix.raise("--space-id is required"),
        escalate_user_id:
          parsed[:escalate_user_id] || Mix.raise("--escalate-user-id is required"),
        project_id: parsed[:project_id],
        host_user_ids: if(hosts == [], do: nil, else: hosts),
        reassign: parsed[:reassign] || false
      }

    case Platform.Showrunner.provision(attrs) do
      {:ok, report} -> report |> lines() |> Enum.each(fn line -> Mix.shell().info(line) end)
      {:error, reason} -> Mix.raise("showrunner provisioning failed: #{inspect(reason)}")
    end
  end

  @doc false
  def lines(report) do
    [
      "showrunner role: #{report.role} (agent #{report.agent_id})",
      "responsibilities (#{length(report.responsibilities)}):"
    ] ++
      Enum.map(report.responsibilities, fn %{key: key, trigger_config: config} ->
        cadence = config["expression"] || config["topic"] || "-"
        "  #{key}  #{cadence}"
      end) ++
      ["social bundle: #{social(report.social_bundle)}"] ++
      Enum.map(report.warnings, &("WARNING: " <> &1))
  end

  defp social(:present), do: "present"
  defp social({:absent, reason}), do: "ABSENT (#{reason})"
end
