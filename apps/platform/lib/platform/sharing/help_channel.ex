defmodule Platform.Sharing.HelpChannel do
  @moduledoc """
  The "Help & feedback" channel (task 01a1b678 stage 3): a new install's
  third default space, after General and the per-agent Getting started.

  ## Created with General, on new installs only

  `Platform.Chat.DefaultSpace.ensure/0` calls `create/1` in the same branch
  that creates `#general`: only when the install has no channel at all. An
  existing install, which always has a channel, never gets one.

  The channel's agent attention policy is `directed`, so a person's
  un-addressed post reaches the channel's principal agent.

  ## The Burrow agent watches it

  `ensure_agent/1` seats the install's Burrow agent (`Platform.Agents.Burrow`)
  in the channel: as principal when the channel has none (promoting the
  member row a historian join may already have made), otherwise as a member. It is called when the agent is first observed running on
  `/setup/connect-ai`, next to the Getting started space, and is a no-op when
  the channel does not exist or the agent is already in it. The agent's
  instructions for the channel live in `Burrow.identity_template/2`.

  ## Reports from the channel

  A `feedback_submit` call made from this channel (`help_space?/1` on the
  call's `space_id`) also needs `Platform.Sharing.enabled?(:help_channel_reports)`;
  see `Platform.Federation.ToolSurface`.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{Participant, Space}
  alias Platform.Repo

  @name "Help & feedback"
  @slug "help-and-feedback"
  @origin "help_channel"

  @doc "The channel's display name."
  def name, do: @name

  @doc "The channel's slug."
  def slug, do: @slug

  @doc """
  Create the channel in `root` (the root org). Called by
  `Platform.Chat.DefaultSpace` only, after it created `#general`. Returns
  `{:ok, space}` or `{:error, reason}`.
  """
  @spec create(%{id: binary()}) :: {:ok, Space.t()} | {:error, term()}
  def create(%{id: org_id}) do
    attrs = %{
      name: @name,
      slug: @slug,
      kind: "channel",
      org_id: org_id,
      description: "Ask Burrow for help, report a bug or suggest a change.",
      metadata: %{"origin" => @origin}
    }

    with {:ok, space} <- Chat.create_space(attrs) do
      space
      |> Space.agent_attention_changeset(%{agent_attention_policy: "directed"})
      |> Repo.update()
    end
  end

  @doc "The channel, or nil."
  @spec space() :: Space.t() | nil
  def space do
    Repo.one(
      from(s in Space,
        where: s.slug == @slug and s.kind == "channel" and is_nil(s.archived_at),
        limit: 1
      )
    )
  end

  @doc "True when `space_id` is the Help & feedback channel."
  @spec help_space?(term()) :: boolean()
  def help_space?(space_id) when is_binary(space_id) do
    case Platform.UUID.cast(space_id) do
      {:ok, id} ->
        Repo.exists?(
          from(s in Space, where: s.id == ^id and s.slug == @slug and s.kind == "channel")
        )

      :error ->
        false
    end
  end

  def help_space?(_), do: false

  @doc """
  Seat `agent` in the channel (principal when the channel has none, else
  member). Returns `:ok`, also when there is no channel or the agent is
  already in it, or `{:error, reason}`.
  """
  @spec ensure_agent(Agent.t()) :: :ok | {:error, term()}
  def ensure_agent(%Agent{id: agent_id}) do
    case space() do
      nil ->
        :ok

      %Space{id: space_id} ->
        cond do
          # Also promotes a row the historian join already made as member.
          not principal?(space_id) ->
            seated(Chat.set_principal_agent(space_id, agent_id))

          match?(%Participant{}, Chat.get_agent_participant(space_id, agent_id)) ->
            :ok

          true ->
            seated(Chat.add_space_agent(space_id, agent_id, role: "member"))
        end
    end
  end

  defp principal?(space_id) do
    Repo.exists?(
      from(p in Participant,
        where: p.space_id == ^space_id and p.participant_type == "agent" and p.role == "principal"
      )
    )
  end

  defp seated({:ok, _entry}), do: :ok

  defp seated({:error, reason}) do
    Logger.warning("[HelpChannel] agent not seated: #{inspect(reason)}")
    {:error, reason}
  end
end
