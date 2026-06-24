defmodule Platform.ExternalAgents do
  @moduledoc """
  Context for external (HTTP-delegated) agents.

  An "external" agent is an `agents` table row with `kind == "external"`.
  External agents delegate inference to an HTTP endpoint (OpenAI-compatible
  or native Ollama) rather than running in the built-in BEAM runtime that
  backs `kind == "native"` agents.

  ## Kind-gating invariant

  This context is the *only* sanctioned surface for managing external
  agents. To make that boundary load-bearing:

    * `create_external_agent/1` **forces** `kind: "external"` into attrs,
      overriding any caller value — the context cannot be used to mint
      native agents.
    * `update_external_agent/2` raises `ArgumentError` when handed an
      agent whose `kind != "external"` (programmer error, not a runtime
      condition) and **strips** `:kind` from attrs to prevent
      kind-flipping. An external agent stays external.
    * `get_external_agent/1`, `get_external_agent!/1`, and
      `list_external_agents/1` all filter on `kind == "external"`; rows
      with any other kind are invisible through this context.

  The underlying `Platform.Agents.Agent` changeset is the schema-level
  source of truth for the kind / external-fields invariant — see its
  `@moduledoc` for the field-level rules. This module sits on top of that
  and provides the kind-scoped CRUD surface.

  ## Credential semantics — ephemeral vs vaulted

  External agents may need a bearer token or API key to talk to their
  endpoint. The `vault_key` field on the schema is a *reference* to a
  credential stored elsewhere — never the credential itself.

    * **Ephemeral** — when `vault_key` is `nil`, callers supply the
      credential at request time (e.g. from a session, env, or per-call
      override). Nothing sensitive is persisted on the `agents` row.
    * **Vaulted** — when `vault_key` is set, the named credential is
      resolved from the credential vault at request time. M3
      (external-agent credential vault) owns the write/read API for
      vaulted credentials and the resolution flow at dispatch.

  This context never reads, writes, or echoes credential material — it
  only persists the `vault_key` reference. Provisioning of the vault row
  itself is M3's responsibility.

  ## Notifications

  No PubSub broadcasts here. M7 wires UI subscriptions for the external
  agents admin surface; introducing topics now would be premature.
  """

  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.Repo

  @external_kind "external"

  @doc """
  Create an external agent.

  `kind` is forced to `"external"` regardless of the caller-supplied
  value — this context cannot be used to mint native agents. All other
  fields are validated by `Platform.Agents.Agent.changeset/2`, including
  the `endpoint_kind` / `base_url` / `model` requirements that kick in
  for external agents.
  """
  @spec create_external_agent(map()) :: {:ok, Agent.t()} | {:error, Ecto.Changeset.t()}
  def create_external_agent(attrs) when is_map(attrs) do
    %Agent{}
    |> Agent.changeset(force_external_kind(attrs))
    |> Repo.insert()
  end

  @doc """
  Update an external agent.

  Raises `ArgumentError` if `agent.kind != "external"` — using this
  context on a native agent is a programmer error, not a runtime
  condition. The `:kind` key is stripped from `attrs` before the
  changeset runs, so an external agent stays external.
  """
  @spec update_external_agent(Agent.t(), map()) ::
          {:ok, Agent.t()} | {:error, Ecto.Changeset.t()}
  def update_external_agent(%Agent{kind: @external_kind} = agent, attrs) when is_map(attrs) do
    agent
    |> Agent.changeset(strip_kind(attrs))
    |> Repo.update()
  end

  def update_external_agent(%Agent{kind: kind}, _attrs) do
    raise ArgumentError,
          "Platform.ExternalAgents.update_external_agent/2 called on agent with kind=#{inspect(kind)}; " <>
            "this context only manages kind=\"external\" agents"
  end

  @doc """
  Fetch an external agent by id. Returns `nil` when no row matches or
  the row's `kind != "external"`.
  """
  @spec get_external_agent(binary()) :: Agent.t() | nil
  def get_external_agent(id) when is_binary(id) do
    Repo.get_by(Agent, id: id, kind: @external_kind)
  end

  @doc """
  Fetch an external agent by id or raise. Raises `Ecto.NoResultsError`
  when no row matches or the row's `kind != "external"`.
  """
  @spec get_external_agent!(binary()) :: Agent.t()
  def get_external_agent!(id) when is_binary(id) do
    Repo.get_by!(Agent, id: id, kind: @external_kind)
  end

  @doc """
  List external agents, newest-first by `inserted_at`.

  ## Options

    * `:workspace_id` — filter to a specific workspace
    * `:endpoint_kind` — filter to `"openai_compat"` or `"ollama_native"`

  Unknown options are ignored.
  """
  @spec list_external_agents(keyword()) :: [Agent.t()]
  def list_external_agents(opts \\ []) when is_list(opts) do
    Agent
    |> where([a], a.kind == ^@external_kind)
    |> maybe_filter(:workspace_id, opts[:workspace_id])
    |> maybe_filter(:endpoint_kind, opts[:endpoint_kind])
    |> order_by([a], desc: a.inserted_at)
    |> Repo.all()
  end

  @doc """
  Delete an external agent. Hard delete — the `agents` schema has no
  `archived_at` column today, so this context follows suit.
  """
  @spec delete_external_agent(Agent.t()) :: {:ok, Agent.t()} | {:error, Ecto.Changeset.t()}
  def delete_external_agent(%Agent{kind: @external_kind} = agent) do
    Repo.delete(agent)
  end

  # ── Internal helpers ─────────────────────────────────────────────────────

  defp force_external_kind(attrs) do
    attrs
    |> strip_kind()
    |> Map.put(:kind, @external_kind)
  end

  defp strip_kind(attrs) do
    attrs
    |> Map.delete(:kind)
    |> Map.delete("kind")
  end

  defp maybe_filter(query, _field, nil), do: query

  defp maybe_filter(query, field, value) do
    where(query, [a], field(a, ^field) == ^value)
  end
end
