defmodule Platform.Agents.Burrow.Starter do
  @moduledoc """
  Burrow's starter allowance: a server-held Anthropic API key that lets
  Burrow speak on day one, before the owner has connected a plan of their own.

  Without it the first screen after a hand-over sign-in is
  `/setup/connect-ai` ("Which subscription do you use?"), a question a new
  owner cannot yet judge. With it the first screen is the Getting started
  conversation, and Burrow asks about the owner's own ChatGPT or Claude plan
  when it is useful and swaps over (`Platform.Agents.Burrow.ensure/2`).

  ## The key

  `STARTER_ANTHROPIC_API_KEY`, rendered by the installer from the manifest's
  `agents.starter_api_key_ref` into core's `secrets.env` and read once at boot
  into `:platform, :starter_anthropic_api_key`. It must look like an API key
  (`NativeLogin.api_key_shape/1`); anything else counts as not configured. It
  is never stored in the Vault, never rendered, never logged. It reaches the
  agent host only in the `agent.start` env (`NativeLogin.start_env/1`), for
  the one agent marked below, in either login mode.

  ## THE SPEND CAP IS NOT ENFORCED HERE

  Nothing in core counts or limits what this key spends. The cap is a spend
  limit set on the key at Anthropic's console, and that is the only cap. This
  module exposes no cap, balance or usage figure, on purpose: any such number
  would be a guess presented as a guarantee.

  ## Why creation happens at the first hand-over sign-in, not at boot

  `Burrow.ensure_starter/1` needs the owner: `NativeAgents.create/2` provisions
  the runtime through `Federation.provision_agent_runtime/3` under the owner's
  scope, and the Getting started space needs the owner as a participant. At
  boot on a fresh install no user exists yet (the owner row is created by the
  first OIDC callback), so a boot task could only create an ownerless Burrow.
  The hand-over callback is the first moment the owner exists and the first
  screen is about to be chosen, so `provision/1` runs there
  (`PlatformWeb.AuthController`). It is idempotent: it creates nothing when
  any Burrow exists, and the Getting started space and its kickoff are keyed
  on the agent.

  ## State and retirement

  The agent's `metadata["starter_key"]` is `"active"` while it runs on the
  starter key and `"retired"` after the owner connects their own plan or key.
  `Burrow.ensure/2` retires it before it stops and restarts the agent, and the
  mark lives in the database, so a restart of core, with the env var still
  set, never revives it. A retired mark is final for that install.
  """

  import Ecto.Query

  alias Platform.Agents.{Agent, Burrow, NativeLogin}
  alias Platform.Agents.Burrow.GettingStarted
  alias Platform.Repo
  alias Platform.Tenancy

  @marker "starter_key"

  @doc "The configured starter key, or nil. Never log or render it."
  @spec key() :: String.t() | nil
  def key do
    with key when is_binary(key) <- Application.get_env(:platform, :starter_anthropic_api_key),
         key = String.trim(key),
         :ok <- NativeLogin.api_key_shape(key) do
      key
    else
      _ -> nil
    end
  end

  @doc "True when this install has a usable starter key configured."
  @spec configured?() :: boolean()
  def configured?, do: key() != nil

  @doc "`\"active\"`, `\"retired\"` or nil: the mark on `agent`, read from the database."
  @spec state(Agent.t()) :: String.t() | nil
  def state(%Agent{id: id}) do
    query =
      from(a in Agent, where: a.id == ^id, select: fragment("?->>'starter_key'", a.metadata))

    Repo.one(query)
  end

  @doc "True when a key is configured and `agent` is marked as running on it."
  @spec active?(Agent.t() | nil) :: boolean()
  def active?(%Agent{} = agent), do: configured?() and state(agent) == "active"
  def active?(_), do: false

  @doc "The key to put in `agent`'s start env, or nil when it is not on the starter."
  @spec key_for(Agent.t()) :: String.t() | nil
  def key_for(%Agent{} = agent), do: if(active?(agent), do: key())

  @doc "Mark `agent` as running on the starter key."
  @spec activate(Agent.t()) :: {:ok, Agent.t()} | {:error, term()}
  def activate(%Agent{} = agent), do: put_state(agent, "active")

  @doc "Mark `agent` as off the starter key for good."
  @spec retire(Agent.t()) :: {:ok, Agent.t()} | {:error, term()}
  def retire(%Agent{} = agent), do: put_state(agent, "retired")

  defp put_state(%Agent{id: id}, value) do
    agent = Repo.get!(Agent, id)

    agent
    |> Ecto.Changeset.change(metadata: Map.put(agent.metadata || %{}, @marker, value))
    |> Repo.update()
  end

  @doc """
  The generated "allowance" section appended to Burrow's instructions file at
  every start: present only while `agent` is on the starter key, so the line
  is true when Burrow reads it and gone at the restart that retires it.
  """
  @spec instructions_section(Agent.t()) :: String.t()
  def instructions_section(%Agent{} = agent) do
    if active?(agent) do
      """

      ## Your allowance (generated at start)

      You are running on a starter allowance that Burrow provides, not on a plan
      your owner connected. It has a limit set outside Burrow, so do not promise
      it will last.
      """
    else
      ""
    end
  end

  @doc """
  Create Burrow on the starter key for `user` and open its Getting started
  space. Returns `{:ok, space}`, `:disabled` when there is no starter key or
  `user` is not an install admin, or `{:error, reason}`. Idempotent; see the
  moduledoc.
  """
  @spec provision(map()) :: {:ok, Platform.Chat.Space.t()} | :disabled | {:error, term()}
  def provision(%{id: owner_id} = user) when is_binary(owner_id) do
    if configured?() and Tenancy.root_admin?(user) do
      with {:ok, agent} <- Burrow.ensure_starter(owner_id) do
        GettingStarted.ensure_getting_started(agent, user)
      end
    else
      :disabled
    end
  end

  def provision(_), do: :disabled

  @doc """
  Where a hand-over sign-in lands `user`: the Getting started conversation
  when the starter provisioned it, else `/setup/connect-ai`. A failure falls
  back to the picker, so a broken starter never strands the owner.
  """
  @spec handover_landing(map()) :: String.t()
  def handover_landing(user) do
    case provision(user) do
      {:ok, %{slug: slug}} -> "/chat/" <> slug
      _ -> "/setup/connect-ai"
    end
  rescue
    _ -> "/setup/connect-ai"
  end
end
