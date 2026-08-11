defmodule Platform.Agents.AgentRuntime do
  @moduledoc """
  Schema for the `agent_runtimes` table.

  Represents an external agent runtime (e.g. an OpenClaw instance) that
  connects to the Suite collaboration plane via WebSocket.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses ~w(pending active suspended revoked)
  @valid_trust_levels ~w(viewer participant collaborator admin)
  @valid_transports ~w(websocket)
  # Must equal `ToolSurface.all_bundles/0` as a set — a bundle the surface
  # registers but this list rejects cannot be persisted at all, so the full
  # surface could not be granted even deliberately (019ff110). Guarded by
  # `test/platform/agents/agent_runtime_test.exs`.
  #
  # Being GRANTABLE is not being GRANTED: adding a bundle here does not add it
  # to `@default_allowed_bundles` below, and must not.
  @valid_bundles ~w(federation space context_read messaging review canvas task plan memory skill attachment files)

  @default_allowed_bundles ~w(federation space context_read messaging attachment skill)

  schema "agent_runtimes" do
    field(:runtime_id, :string)
    field(:owner_user_id, :binary_id)
    field(:agent_id, :binary_id)
    field(:display_name, :string)
    field(:transport, :string, default: "websocket")
    field(:status, :string, default: "pending")
    field(:trust_level, :string, default: "participant")
    field(:allowed_bundles, {:array, :string}, default: @default_allowed_bundles)
    field(:auth_token_hash, :string)
    field(:last_connected_at, :utc_datetime_usec)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  def valid_bundles, do: @valid_bundles
  def default_allowed_bundles, do: @default_allowed_bundles

  def changeset(runtime, attrs) do
    runtime
    |> cast(attrs, [
      :runtime_id,
      :owner_user_id,
      :agent_id,
      :display_name,
      :transport,
      :status,
      :trust_level,
      :allowed_bundles,
      :auth_token_hash,
      :last_connected_at,
      :metadata
    ])
    |> validate_required([:runtime_id, :owner_user_id])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:trust_level, @valid_trust_levels)
    |> validate_inclusion(:transport, @valid_transports)
    |> validate_subset(:allowed_bundles, @valid_bundles)
    |> unique_constraint(:runtime_id)
  end

  @doc "Hash a raw token for storage."
  def hash_token(raw_token) when is_binary(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
  end

  @doc "Generate a cryptographically random token."
  def generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  @doc "Verify a raw token against a stored hash."
  def verify_token(raw_token, stored_hash) do
    hash_token(raw_token) == stored_hash
  end

  @valid_client_products ~w(openclaw claude_channel)

  @doc """
  Reads `metadata["client_info"]["product"]` from a runtime (or any map
  with a `:metadata` key) and returns one of `"openclaw"`,
  `"claude_channel"`, or `"unknown"`.

  The `"unknown"` case covers:

    * no `client_info` ever set,
    * missing `product` key inside `client_info`,
    * a value not in the allowlist (defensive — blocks accidental drift).

  Pure function, no DB access. Works on freshly-loaded structs whose
  `metadata` map has string keys (jsonb round-trip).
  """
  @spec client_product(%__MODULE__{} | %{metadata: map()}) :: String.t()
  def client_product(%{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("client_info", %{})
    |> case do
      m when is_map(m) -> Map.get(m, "product")
      _ -> nil
    end
    |> classify_product()
  end

  def client_product(_), do: "unknown"

  defp classify_product(product) when product in @valid_client_products, do: product
  defp classify_product(_), do: "unknown"

  @system_event_prompt_feature "system_event_prompt"

  @doc """
  The capability a `claude_channel` bridge declares when its build renders
  `signal.prompt` on `system_event` attentions (the envelope that carries no
  `message` key).

  Exposed as an accessor so callers reference the constant rather than a bare
  string literal — the declaration in the client and the check on the server
  have to stay the same word or the verdict is meaningless.
  """
  @spec system_event_prompt_feature() :: String.t()
  def system_event_prompt_feature, do: @system_event_prompt_feature

  @doc """
  Reads `metadata["client_info"]["features"]` from a runtime (or any map with
  a `:metadata` key) and returns the declared capability list.

  Returns `[]` — never `nil`, never raises — for:

    * no metadata at all (or `nil` metadata on a legacy row),
    * no `client_info`, or a `client_info` that is not a map,
    * no `features` key,
    * a `features` value that is not a list (map, string, integer, `nil`).

  Entries that are not binaries are filtered out of an otherwise valid list,
  so a partially-garbage payload degrades to its usable subset instead of
  poisoning the whole read.

  There is deliberately NO allowlist of valid feature names (contrast
  `@valid_client_products` above). Products are a closed set the server
  switches behavior on; capabilities are an open set that grows every time a
  client ships something, and an allowlist would mean every new client
  capability needed a server deploy before it could be reported. The bound
  enforced at the handshake (`PlatformWeb.RuntimeChannel.resolve_client_info/1`
  caps the list at 32 entries of 64 bytes) already caps the abuse surface.

  Pure function, no DB access. Works on freshly-loaded structs whose
  `metadata` map has string keys (jsonb round-trip).
  """
  @spec client_features(%__MODULE__{} | %{metadata: map()}) :: [String.t()]
  def client_features(%{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("client_info", %{})
    |> case do
      m when is_map(m) -> Map.get(m, "features")
      _ -> nil
    end
    |> case do
      features when is_list(features) -> Enum.filter(features, &is_binary/1)
      _ -> []
    end
  end

  def client_features(_), do: []

  @doc """
  Whether a runtime has declared `feature` on its most recent join.

  FAILS CLOSED: a runtime we have heard nothing from — no metadata, no
  `client_info`, no `features` — is `false`, never `true`. Absence of a
  declaration means "not proven", which is the honest state for both an old
  build and a new build that has not reconnected yet; it is never read as a
  positive.

  Matching is exact. A near-miss (`"SYSTEM_EVENT_PROMPT"`, a `_v2` suffix, a
  space-padded variant) is not the capability — a fuzzy match would hand out
  the one verdict this predicate exists to make trustworthy.
  """
  @spec client_supports?(%__MODULE__{} | %{metadata: map()}, String.t()) :: boolean()
  def client_supports?(runtime, feature) when is_binary(feature) do
    feature in client_features(runtime)
  end
end
