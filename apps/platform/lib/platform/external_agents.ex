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

  ## Liveness state machine

  `liveness/2` resolves an external agent into one of three states
  based purely on the row's observability columns — no DB writes, no
  HTTP calls. The evaluation order is strict:

    1. **`:live`** — `last_successful_fire_at` is set and within
       `liveness_window_ms` of `now` (default 15 minutes). The agent
       has actually completed a dispatched turn recently.
    2. **`:stale`** — no fresh fire, but `last_probe_status == "ok"`
       and `last_probe_at` is within `probe_ok_window_ms` of `now`
       (default 1 hour). Reachable, not yet exercised.
    3. **`:dead`** — everything else: never probed, last probe failed,
       or last successful probe is older than `probe_ok_window_ms`.

  Both windows are configurable via
  `config :platform, :external_agents, liveness_window_ms: <ms>,
  probe_ok_window_ms: <ms>`. The `now` argument is injectable so
  callers can render deterministic snapshots and tests can pin a
  reference time.
  """

  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.ExternalAgents.EphemeralCredentials
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
    # `Repo.get_by(Agent, id: ...)` raises exactly like `Repo.get/2` does — the
    # `id:` keyword is pinned against the same strict UUIDv7 primary key. This
    # spelling is invisible to `git grep "Repo.get("`, which is why the sweep
    # missed it. Platform.UUID.valid?/1, not a bare cast: a bare cast accepts
    # any 16-byte binary and the raise lands inside Repo anyway.
    if Platform.UUID.valid?(id) do
      Repo.get_by(Agent, id: id, kind: @external_kind)
    else
      nil
    end
  end

  @doc """
  Fetch an external agent by id or raise. Raises `Ecto.NoResultsError`
  when no row matches or the row's `kind != "external"`.
  """
  @spec get_external_agent!(binary()) :: Agent.t()
  def get_external_agent!(id) when is_binary(id) do
    # The bang twin of get_external_agent/1, ten lines up. Its documented
    # contract is `Ecto.NoResultsError` on a miss, so a malformed id must raise
    # THAT, not `Ecto.Query.CastError` — a malformed id and an absent one are
    # the same outcome, and callers rescue/expect the documented exception.
    if Platform.UUID.valid?(id) do
      Repo.get_by!(Agent, id: id, kind: @external_kind)
    else
      raise Ecto.NoResultsError, queryable: Agent
    end
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

  @doc """
  Resolve the credential for an external agent.

  Dispatches on the agent's `vault_key` field (decision 6):

    * `vault_key` is `nil` → ephemeral path: look up the secret in the
      in-memory ETS store via `EphemeralCredentials.get/1`. Returns
      `{:error, :not_found}` when no row exists.
    * `vault_key` is a non-empty binary → vaulted path: read the
      Cloak-encrypted credential via
      `Platform.Vault.get/2` with `accessor: {:agent, agent.id}`. The
      ETS store is **not** consulted when `vault_key` is set — vault
      always wins so a stale ephemeral row can't shadow a freshly
      provisioned vault credential.

  Vault `{:error, :access_denied}` is normalized to
  `{:error, :not_found}` so the credentials-missing UX message stays
  uniform (M7 renders a single "credentials missing" error state and
  doesn't distinguish missing-row from no-access).

  Accepts a `Platform.Agents.Agent` struct or any bare map with `:id`
  and `:vault_key` keys — the latter keeps unit tests independent of
  the full schema struct.

  ## Telemetry

  Emits `[:platform, :external_agents, :credential_resolved]` on every
  call (success *or* `:not_found`), with metadata `:source` set to
  either `:vault` or `:ephemeral` to reflect the dispatch branch taken.
  Per decision 6, the ephemeral path leaves no DB trail — telemetry is
  the only observability signal on that branch.
  """
  @spec resolve_credential(map() | Agent.t()) :: {:ok, binary()} | {:error, :not_found}
  def resolve_credential(%{id: id, vault_key: nil}) when is_binary(id) do
    result = EphemeralCredentials.get(id)
    emit_resolved(:ephemeral, id)
    result
  end

  def resolve_credential(%{id: id, vault_key: vault_key})
      when is_binary(id) and is_binary(vault_key) and vault_key != "" do
    result =
      case Platform.Vault.get(vault_key, accessor: {:agent, id}) do
        {:ok, secret} -> {:ok, secret}
        {:error, :access_denied} -> {:error, :not_found}
        {:error, :not_found} -> {:error, :not_found}
        other -> other
      end

    emit_resolved(:vault, id)
    result
  end

  defp emit_resolved(source, agent_id) do
    :telemetry.execute(
      [:platform, :external_agents, :credential_resolved],
      %{system_time: System.system_time()},
      %{source: source, agent_id: agent_id}
    )
  end

  # ── Probe (M5 stage 2) ────────────────────────────────────────────────────

  @probe_receive_timeout_ms 5_000

  @doc """
  Issue an HTTP probe against an external agent's endpoint and persist
  the outcome onto the row (`last_probe_at`, `last_probe_status`,
  `last_probe_latency_ms`).

  Dispatches on `agent.endpoint_kind`:

    * `"openai_compat"` — `GET base_url/models` with a Bearer token
    * `"ollama_native"` — `GET base_url/api/tags` (no auth)

  Returns `{:ok, %{latency_ms: integer, model_count: integer}}` on a
  2xx response, or `{:error, reason}` for known failure classes
  (`:unauthorized`, `:http_error`, `:timeout`, `:network_error`).

  ## Credential resolution

  Bearer tokens for `openai_compat` are resolved by
  `resolve_credential/1` (now landed on main as part of M3). The
  legacy `agent.metadata["_probe_token"]` path is kept as a fallback
  for unit tests that don't want to set up an ETS or Vault row.

  ## Persistence

  Probe writes go through `Ecto.Changeset.change/2` (not
  `Agent.changeset/2`) to bypass `validate_required([:slug, :name,
  :status])` — these are observability-only updates and don't carry
  the rest of the row's data. See `Platform.Agents.Agent` moduledoc.

  ## Test seam

  The `Req` client is injectable via the
  `:external_agents_req_client` application env key. Mirrors the
  pattern in `Platform.Agents.Providers.Codex` and
  `Platform.Memory.Providers.MemoryService`. The Req.Test stubs and
  the full test suite land in M5 stage 4.
  """
  @spec probe(Agent.t()) ::
          {:ok, %{latency_ms: non_neg_integer(), model_count: non_neg_integer()}}
          | {:error, atom()}
  def probe(%Agent{kind: @external_kind} = agent) do
    url = probe_url(agent.endpoint_kind, agent.base_url)
    headers = probe_headers(agent)

    start_ms = System.monotonic_time(:millisecond)

    result =
      Req.get(req_client(),
        url: url,
        headers: headers,
        receive_timeout: @probe_receive_timeout_ms,
        retry: false
      )

    latency_ms = System.monotonic_time(:millisecond) - start_ms

    outcome = classify(agent.endpoint_kind, result)
    persist_probe(agent, outcome, latency_ms)

    case outcome do
      {:ok, model_count} -> {:ok, %{latency_ms: latency_ms, model_count: model_count}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Liveness (M5 stage 3) ────────────────────────────────────────────────

  @default_liveness_window_ms 15 * 60 * 1000
  @default_probe_ok_window_ms 60 * 60 * 1000

  @doc """
  Resolve an external agent's liveness state — `:live | :stale | :dead`.

  Pure function over the row's observability columns; no DB writes,
  no HTTP. The evaluation order is documented in the module's
  "Liveness state machine" section.

  The `now` argument defaults to `DateTime.utc_now/0` and is exposed
  for deterministic snapshots / tests.
  """
  @spec liveness(Agent.t(), DateTime.t()) :: :live | :stale | :dead
  def liveness(agent, now \\ DateTime.utc_now())

  def liveness(%Agent{} = agent, %DateTime{} = now) do
    cond do
      fired_within?(agent, now, liveness_window_ms()) -> :live
      probe_ok_within?(agent, now, probe_ok_window_ms()) -> :stale
      true -> :dead
    end
  end

  defp fired_within?(%Agent{last_successful_fire_at: nil}, _now, _window), do: false

  defp fired_within?(%Agent{last_successful_fire_at: t}, now, window) do
    DateTime.diff(now, t, :millisecond) <= window
  end

  defp probe_ok_within?(%Agent{last_probe_at: nil}, _now, _window), do: false

  defp probe_ok_within?(%Agent{last_probe_status: status}, _now, _window)
       when status != "ok",
       do: false

  defp probe_ok_within?(%Agent{last_probe_at: t}, now, window) do
    DateTime.diff(now, t, :millisecond) <= window
  end

  defp liveness_window_ms do
    config()
    |> Keyword.get(:liveness_window_ms, @default_liveness_window_ms)
  end

  defp probe_ok_window_ms do
    config()
    |> Keyword.get(:probe_ok_window_ms, @default_probe_ok_window_ms)
  end

  defp config, do: Application.get_env(:platform, :external_agents, [])

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

  # ── Probe helpers ─────────────────────────────────────────────────────────

  defp probe_url("openai_compat", base_url), do: "#{base_url}/models"
  defp probe_url("ollama_native", base_url), do: "#{base_url}/api/tags"

  defp probe_headers(%Agent{endpoint_kind: "openai_compat"} = agent) do
    [{"authorization", "Bearer #{resolve_token(agent)}"}]
  end

  defp probe_headers(%Agent{endpoint_kind: "ollama_native"}), do: []

  # M3 integration seam: prefer the credential vault once resolve_credential/1
  # exists; fall back to agent.metadata["_probe_token"] for tests today.
  defp resolve_token(%Agent{} = agent) do
    if function_exported?(__MODULE__, :resolve_credential, 1) do
      case apply(__MODULE__, :resolve_credential, [agent]) do
        {:ok, secret} when is_binary(secret) -> secret
        _ -> metadata_probe_token(agent)
      end
    else
      metadata_probe_token(agent)
    end
  end

  defp metadata_probe_token(%Agent{metadata: metadata}) do
    Map.get(metadata || %{}, "_probe_token", "")
  end

  defp classify(_kind, {:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    data =
      case body do
        %{"data" => list} when is_list(list) -> list
        %{"models" => list} when is_list(list) -> list
        _ -> []
      end

    {:ok, length(data)}
  end

  defp classify(_kind, {:ok, %Req.Response{status: status}}) when status in [401, 403],
    do: {:error, :unauthorized}

  defp classify(_kind, {:ok, %Req.Response{}}), do: {:error, :http_error}

  defp classify(_kind, {:error, %Req.TransportError{reason: :timeout}}),
    do: {:error, :timeout}

  defp classify(_kind, {:error, _other}), do: {:error, :network_error}

  defp persist_probe(%Agent{} = agent, outcome, latency_ms) do
    status_str =
      case outcome do
        {:ok, _} -> "ok"
        {:error, reason} -> Atom.to_string(reason)
      end

    agent
    |> Ecto.Changeset.change(%{
      last_probe_at: DateTime.utc_now(),
      last_probe_status: status_str,
      last_probe_latency_ms: latency_ms
    })
    |> Repo.update!()
  end

  defp req_client do
    Application.get_env(:platform, :external_agents_req_client, Req.new())
  end
end
