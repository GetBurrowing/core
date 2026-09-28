defmodule Mix.Tasks.Platform.VoiceRuntime do
  @moduledoc """
  Mint a voice runtime row for an existing agent — the "mouth" that joins
  meetings — and print its credentials once.

  Wraps `Platform.Federation.register_voice_runtime/3`. The new row is a
  second `agent_runtimes` entry bound to the agent by `agent_id`; the
  agent's `runtime_id` (its brain) is NOT touched, so dispatches keep going
  where they went before. See task 01a06686 for why brain and mouth are
  separate rows.

  ## Usage

      mix platform.voice_runtime --agent <slug|uuid> --owner <email> [--name <display>]

  Prints `runtime_id`, `display_name`, and the raw auth token. The token is
  shown ONCE — only its hash is stored — so copy it into the voice worker's
  configuration before closing the terminal.

  ## In dev this boots the real app

  `Mix.Task.run("app.start")` starts the full application against the
  database of the current `MIX_ENV`. In dev that is the dev database and the
  routers/supervisors that come up with it, exactly as `mix phx.server`
  would. Run it against the database you actually mean.
  """

  use Mix.Task

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation
  alias Platform.Repo

  @shortdoc "Mint a voice runtime row (and token) for an existing agent"

  @usage "Usage: mix platform.voice_runtime --agent <slug|uuid> --owner <email> [--name <display>]"

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [agent: :string, owner: :string, name: :string]
      )

    abort_on_bad_args!(rest, invalid)

    agent_ref = opts[:agent] || Mix.raise("--agent is required\n\n#{@usage}")
    owner_email = opts[:owner] || Mix.raise("--owner is required\n\n#{@usage}")

    Mix.Task.run("app.start")

    agent = resolve_agent!(agent_ref)
    owner = resolve_owner!(owner_email)

    attrs = if opts[:name], do: %{display_name: opts[:name]}, else: %{}

    case Federation.register_voice_runtime(owner.id, agent, attrs) do
      {:ok, runtime, raw_token} ->
        Mix.shell().info("""
        Voice runtime registered for agent #{agent.slug} (#{agent.id})
          runtime_id:   #{runtime.runtime_id}
          display_name: #{runtime.display_name}
          token:        #{raw_token}
        WARNING: the token is shown once and will not be shown again; only its hash is stored.\
        """)

        :ok

      {:error, %Ecto.Changeset{} = changeset} ->
        Mix.raise("Could not register the voice runtime: #{inspect(changeset.errors)}")
    end
  end

  # Slug first, then primary key. A slug that happens to look like a UUID is
  # still resolved as a slug before we try it as an id.
  #
  # A slug shared by agents in different workspaces is refused, never picked
  # (task 01a0e77c): the operator passes the UUID instead.
  defp resolve_agent!(ref) do
    case Platform.Agents.SlugLookup.resolve(ref) do
      {:ok, agent} ->
        agent

      {:error, :ambiguous_slug} ->
        Mix.raise(
          "Ambiguous agent #{inspect(ref)} — more than one agent has that slug " <>
            "(in different workspaces); pass the agent's UUID instead"
        )

      {:error, :not_found} ->
        get_agent_by_id(ref) ||
          Mix.raise("Unknown agent #{inspect(ref)} — no agent has that slug or id")
    end
  end

  # `Platform.UUID.cast/1`, not a bare `Ecto.UUID.cast/1`: the bare cast
  # accepts any 16-byte binary, so a 16-character slug would clear it and
  # `Repo.get/2` would raise `Ecto.Query.CastError` against the UUIDv7 PK.
  defp get_agent_by_id(ref) do
    case Platform.UUID.cast(ref) do
      {:ok, id} -> Repo.get(Agent, id)
      :error -> nil
    end
  end

  defp resolve_owner!(email) do
    Repo.get_by(User, email: email) ||
      Mix.raise("Unknown owner #{inspect(email)} — no user has that email")
  end

  defp abort_on_bad_args!([], []), do: :ok

  defp abort_on_bad_args!(rest, invalid) do
    Mix.raise(
      "unrecognised arguments: " <>
        Enum.map_join(rest ++ Enum.map(invalid, &elem(&1, 0)), " ", &inspect/1) <>
        "\n\n#{@usage}"
    )
  end
end
