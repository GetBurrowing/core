defmodule Mix.Tasks.Platform.BackfillAgentRoster do
  @moduledoc """
  Backfills the per-space agent roster (`chat_space_agents`) for every
  active federated agent, so each appears in every non-archived channel
  space of its workspace.

  This mirrors the auto-roster behavior that `Platform.Federation.link_agent/2`
  now applies on new federated-agent creation, and is intended as a
  one-shot catch-up for federated agents that were created before the
  auto-roster feature shipped.

  Idempotent — delegates to `Chat.ensure_space_agent/3`, which no-ops when
  the `chat_space_agents` row already exists.

  ## Usage

      # Apply to every active external agent in the database
      mix platform.backfill_agent_roster

      # Print what would change without writing
      mix platform.backfill_agent_roster --dry-run

      # Limit the scan to a specific workspace
      mix platform.backfill_agent_roster --workspace-id <uuid>
  """

  use Mix.Task

  require Logger
  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Repo

  @shortdoc "Ensure every federated agent is on every channel-space roster in its workspace"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          "dry-run": :boolean,
          "workspace-id": :string
        ]
      )

    Mix.Task.run("app.start")

    dry_run? = Keyword.get(opts, :"dry-run", false)
    workspace_id = Keyword.get(opts, :"workspace-id")

    agents = list_federated_agents(workspace_id)

    IO.puts(
      "Scanning #{length(agents)} federated agent(s)#{if dry_run?, do: " (dry-run)", else: ""}"
    )

    {added, skipped, errors} =
      Enum.reduce(agents, {0, 0, 0}, fn agent, {added, skipped, errors} ->
        spaces = Chat.list_spaces(workspace_id: agent.workspace_id, kind: "channel")

        Enum.reduce(spaces, {added, skipped, errors}, fn %Space{} = space, {a, s, e} ->
          case ensure_or_preview(agent, space, dry_run?) do
            :added -> {a + 1, s, e}
            :exists -> {a, s + 1, e}
            :error -> {a, s, e + 1}
          end
        end)
      end)

    IO.puts("Done. added=#{added} already-present=#{skipped} errors=#{errors}")
  end

  defp list_federated_agents(nil) do
    Repo.all(
      from(a in Agent,
        where: a.runtime_type == "external" and a.status != "archived",
        order_by: [asc: a.inserted_at]
      )
    )
  end

  defp list_federated_agents(workspace_id) when is_binary(workspace_id) do
    Repo.all(
      from(a in Agent,
        where:
          a.runtime_type == "external" and a.status != "archived" and
            a.workspace_id == ^workspace_id,
        order_by: [asc: a.inserted_at]
      )
    )
  end

  defp ensure_or_preview(agent, space, true) do
    # Dry-run: read-only check
    import Ecto.Query

    case Repo.one(
           from(sa in Platform.Chat.SpaceAgent,
             where: sa.space_id == ^space.id and sa.agent_id == ^agent.id,
             limit: 1
           )
         ) do
      nil ->
        IO.puts("  would add: agent=#{agent.slug} space=#{space.name} (#{space.id})")
        :added

      _ ->
        :exists
    end
  end

  defp ensure_or_preview(agent, space, false) do
    case Chat.ensure_space_agent(space.id, agent.id, role: "member") do
      {:ok, sa} ->
        # ensure_space_agent returns the existing row when no insert happened.
        # Distinguish by comparing inserted_at to updated_at or by peeking.
        if recent?(sa) do
          IO.puts("  added: agent=#{agent.slug} space=#{space.name}")
          :added
        else
          :exists
        end

      {:error, reason} ->
        IO.puts("  ERROR: agent=#{agent.slug} space=#{space.name} reason=#{inspect(reason)}")
        :error
    end
  end

  # Treat a row whose inserted_at is within the last 5 seconds as "just added".
  # ensure_space_agent returns {:ok, existing} for pre-existing rows, which we
  # want to count as `:exists` not `:added`.
  defp recent?(%{inserted_at: inserted_at}) when not is_nil(inserted_at) do
    DateTime.diff(DateTime.utc_now(), inserted_at, :second) < 5
  end

  defp recent?(_), do: false
end
