defmodule Mix.Tasks.Platform.TerminalFixture do
  @shortdoc "Dev/test only: create an agent and an active runtime for the terminal review"

  @moduledoc """
  Creates, in the dev database, an agent plus an ACTIVE `AgentRuntime` owned
  by the user `/dev/login?as=<slug>` creates, and prints the ids a fake CLI
  needs:

      mix platform.terminal_fixture --owner alice
      RUNTIME_ID=...
      TOKEN=...

  The token goes to stdout only and is never written to a file. Lives in
  `dev_support/`, which is compiled in dev and test and never in a release.
  """
  use Mix.Task

  alias Platform.Accounts.ExternalAdmission
  alias Platform.Agents.Agent
  alias Platform.Federation
  alias Platform.Repo

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [owner: :string])
    slug = opts[:owner] || Mix.raise("usage: mix platform.terminal_fixture --owner <slug>")

    Mix.Task.run("app.start")

    # The same identity `AuthController.dev_admit/3` derives from `?as=<slug>`.
    slug = String.downcase(slug)

    admitted =
      ExternalAdmission.admit(
        %{sub: "dev-#{slug}", email: "#{slug}@localhost", name: "Dev #{String.capitalize(slug)}"},
        surface: :app
      )

    user =
      case admitted do
        %ExternalAdmission.Result{user: user} -> user
        other -> Mix.raise("could not resolve the dev user: #{inspect(other)}")
      end

    n = System.unique_integer([:positive])

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "terminal-fixture-#{n}",
        name: "Terminal Fixture #{n}",
        status: "active"
      })
      |> Repo.insert()

    {:ok, runtime} = Federation.register_runtime(user.id, %{runtime_id: "terminal-fixture-#{n}"})
    {:ok, active, raw_token} = Federation.activate_runtime(runtime)
    {:ok, _} = Federation.link_agent(active, agent)

    Mix.shell().info("RUNTIME_ID=#{active.runtime_id}")
    Mix.shell().info("TOKEN=#{raw_token}")
  end
end
