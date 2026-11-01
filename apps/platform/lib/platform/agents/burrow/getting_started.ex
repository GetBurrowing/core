defmodule Platform.Agents.Burrow.GettingStarted do
  @moduledoc """
  The "Getting started" space the Burrow agent (`Platform.Agents.Burrow`)
  opens with the owner once it is connected on `/setup/connect-ai` (task
  01a10315 stage 5; owned by Burrow since task 01a19505).

  `ensure_getting_started/2` runs on the first observation of the agent
  `running`, and is idempotent, keyed on the agent id:

    * the space's slug is `getting-started-<last 12 hex of the agent id>`, so
      a second call finds it, and a concurrent insert loses on the slug's
      unique index;
    * the admin and the agent are added once each;
    * the kickoff message is posted once: the call that flips the space's
      `metadata["setup_kickoff"]` from absent to set, in one UPDATE, is the
      only one that posts.

  The metadata keys `"setup_agent_id"` and `"setup_kickoff"` and the slug are
  stored data on installs that already have a Getting started space; they keep
  their names so such an install is not sent a second kickoff.
  """

  import Ecto.Query

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{Participant, Space}
  alias Platform.Repo
  alias Platform.Tenancy

  @space_name "Getting started"

  @doc "The Getting started space's display name."
  def space_name, do: @space_name

  @doc "The Getting started space's slug for `agent`."
  @spec space_slug(Agent.t()) :: String.t()
  def space_slug(%Agent{id: id}), do: "getting-started-" <> String.slice(id, -12, 12)

  @doc "The Getting started space for `agent`, or nil."
  @spec getting_started_space(Agent.t()) :: Space.t() | nil
  def getting_started_space(%Agent{} = agent), do: Repo.get_by(Space, slug: space_slug(agent))

  @doc """
  Create the "Getting started" space for `agent` with `user` (the admin) and
  the agent, and post the kickoff once. Idempotent; see the moduledoc.
  Returns `{:ok, space}` or `{:error, reason}`.
  """
  @spec ensure_getting_started(Agent.t(), %{id: binary()}) :: {:ok, Space.t()} | {:error, term()}
  def ensure_getting_started(%Agent{} = agent, %{id: user_id} = user) when is_binary(user_id) do
    with {:ok, space} <- ensure_space(agent),
         :ok <- ensure_participant(space, "user", user_id, display_name(user)),
         :ok <- ensure_participant(space, "agent", agent.id, agent.name),
         :ok <- maybe_kickoff(space, agent) do
      {:ok, space}
    end
  end

  defp display_name(user), do: Map.get(user, :name) || Map.get(user, :email) || "Owner"

  defp ensure_space(agent) do
    case getting_started_space(agent) do
      %Space{} = space ->
        {:ok, space}

      nil ->
        attrs = %{
          name: @space_name,
          slug: space_slug(agent),
          kind: "channel",
          org_id: root_org_id(),
          description: "Where #{agent.name} helps you finish setting up Burrow.",
          metadata: %{"setup_agent_id" => agent.id}
        }

        case Chat.create_space(attrs) do
          {:ok, space} ->
            {:ok, space}

          {:error, reason} ->
            case getting_started_space(agent) do
              %Space{} = space -> {:ok, space}
              nil -> {:error, reason}
            end
        end
    end
  end

  defp root_org_id do
    case Tenancy.get_root_org() do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp ensure_participant(space, type, id, display_name) do
    if Repo.exists?(
         from(p in Participant,
           where:
             p.space_id == ^space.id and p.participant_type == ^type and p.participant_id == ^id
         )
       ) do
      :ok
    else
      case Chat.add_participant(space.id, %{
             participant_type: type,
             participant_id: id,
             display_name: display_name,
             joined_at: DateTime.utc_now()
           }) do
        {:ok, _} -> :ok
        # A concurrent call added it first.
        {:error, %Ecto.Changeset{}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The one call whose UPDATE flips the claim posts; every other call sees 0 rows.
  defp maybe_kickoff(space, agent) do
    claim =
      from(s in Space,
        where: s.id == ^space.id and not fragment("? \\? 'setup_kickoff'", s.metadata),
        update: [
          set: [
            metadata:
              fragment(
                "COALESCE(?, '{}'::jsonb) || jsonb_build_object('setup_kickoff', ?::text)",
                s.metadata,
                ^agent.id
              )
          ]
        ]
      )

    case Repo.update_all(claim, []) do
      {1, _} -> post_kickoff(space, agent)
      {0, _} -> :ok
    end
  end

  defp post_kickoff(space, agent) do
    with {:ok, participant} <- system_participant(space),
         {:ok, _message} <-
           Chat.post_message(%{
             space_id: space.id,
             participant_id: participant.id,
             content_type: "text",
             content: kickoff_text(agent.name),
             metadata: %{"source" => "setup_kickoff", "setup_agent_id" => agent.id}
           }) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "[Burrow.GettingStarted] kickoff not posted in space=#{space.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp system_participant(space) do
    id = Platform.UUID.deterministic("setup_kickoff:#{space.id}")

    case Repo.get_by(Participant,
           space_id: space.id,
           participant_type: "system",
           participant_id: id
         ) do
      %Participant{} = participant ->
        {:ok, participant}

      nil ->
        Chat.add_participant(space.id, %{
          participant_type: "system",
          participant_id: id,
          display_name: "Burrow",
          attention_mode: "mention",
          joined_at: DateTime.utc_now()
        })
    end
  end

  @doc "The kickoff message the space opens with."
  @spec kickoff_text(String.t()) :: String.t()
  def kickoff_text(name) do
    "@[#{name}] you're connected. Please walk the owner through finishing setup: " <>
      "which tools and accounts to connect (integrations), and creating a first space " <>
      "for their work. Keep it short and plain, one step at a time. When a step needs " <>
      "their consent, send them the link or button in Burrow and wait for them."
  end
end
