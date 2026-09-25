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
  @valid_bundles ~w(federation space context_read messaging review canvas task plan memory skill attachment files meetings mail experiments)

  # `meetings` is a DEFAULT, not merely grantable (task 01a066af stage 4).
  # `meeting_say` is the only way an invited agent can speak in a room, and it
  # is guarded independently by `Platform.Meetings`' own room check — an agent no
  # human invited still gets `:not_in_room`, so the bundle grant on its own
  # buys nothing. Withholding it by default, though, meant every voice-capable
  # runtime on the defaults was refused before that guard ever ran.
  #
  # `mail` is a DEFAULT for the same reason it exists at all (task 01a0d4a0
  # stage 4 round 2): before `mail` was split out of `messaging`, every
  # default runtime already got `mail_draft_create`/`mail_draft_update`
  # implicitly by holding `messaging`. Keeping `mail` off the defaults would
  # have silently narrowed every existing default runtime's capability —
  # this bundle split is about letting a runtime be granted `messaging`
  # WITHOUT `mail` (as `mix platform.seed_meeting_voice_agent` now does by
  # simply not listing `mail`), not about narrowing what the defaults get.
  @default_allowed_bundles ~w(federation space context_read messaging attachment skill meetings mail)

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

  @valid_client_products ~w(openclaw claude_channel hermes_channel)

  @doc """
  Reads `metadata["client_info"]["product"]` from a runtime (or any map
  with a `:metadata` key) and returns one of `"openclaw"`,
  `"claude_channel"`, `"hermes_channel"`, or `"unknown"`.

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

  # Shared absent-safe read of one key out of `metadata["client_info"]`.
  # Returns nil for a missing `client_info`, a `client_info` that is not a
  # map, or a missing key — so callers only have to validate the value.
  defp client_info_field(metadata, key) do
    metadata
    |> Map.get("client_info", %{})
    |> case do
      m when is_map(m) -> Map.get(m, key)
      _ -> nil
    end
  end

  @doc """
  Reads `metadata["client_info"]["build"]` — the build identifier (a plugin
  commit sha, or a release string) the client declared on its most recent
  declaring join.

  Returns `nil` — never raises — for:

    * no metadata at all (or `nil` metadata on a legacy row),
    * no `client_info`, or a `client_info` that is not a map,
    * no `build` key,
    * a `build` value that is not a non-empty binary.

  `nil` means "this runtime has not told us", which is the honest state for
  a client whose build predates the handshake carrying this key. It is never
  read as "no build".

  This is the LOAD-BEARING field for "is the capability we shipped actually
  loaded here?". `version` cannot answer it (two plugin builds either side of
  the capability boundary that motivated this ticket both declare "0.3.0" and
  the identical feature list), and `client_started_at/1` cannot answer it
  alone either — see the one-way-test warning on that function.

  Pure function, no DB access. Works on freshly-loaded structs whose
  `metadata` map has string keys (jsonb round-trip).
  """
  @spec client_build(%__MODULE__{} | %{metadata: map()}) :: String.t() | nil
  def client_build(%{metadata: metadata}) when is_map(metadata) do
    case client_info_field(metadata, "build") do
      build when is_binary(build) and build != "" -> build
      _ -> nil
    end
  end

  def client_build(_), do: nil

  @doc """
  Reads `metadata["client_info"]["started_at"]` — when the client PROCESS
  started — and parses it back from its stored ISO8601 form into a UTC
  `DateTime`.

  Returns `nil` — never raises — for:

    * no metadata at all (or `nil` metadata on a legacy row),
    * no `client_info`, or a `client_info` that is not a map,
    * no `started_at` key,
    * a `started_at` that is not a binary, or that does not parse.

  This is a PROCESS age and is deliberately distinct from `last_connected_at`
  and from presence `connected_at`, which are CONNECTION ages: those reset
  whenever a socket drops and re-establishes, even though nothing restarted.
  A shipped client build only takes effect on a process restart, so the
  process age is the only one of the three that can answer whether a runtime
  has actually picked the build up.

  There is no `DateTime.utc_now()` fallback anywhere on this path — an
  invented start time would render as "just restarted", which is the exact
  false reassurance the field exists to prevent.

  ## Do not render this value on its own

  This is a ONE-WAY test. It can REFUTE freshness and cannot establish it:

    * started before a known fix landed => the process cannot be running
      that fix. Sound.
    * started after a known fix landed  => proves nothing at all. Unsound.

  Measured counterexample (2026-09-04): a runtime process started six hours
  after the relevant plugin commit merged upstream, and still lacked the
  capability — its local checkout was behind, so the restart loaded months-old
  code. A recent restart is not evidence of current code.

  So pair it with `client_build/1`, which names the code actually loaded and
  is the load-bearing field. A surface that shows "started 20 minutes ago"
  without the build it started ON re-creates the false-confidence bug this
  field was added to expose. `client_started_at/1` earns its place only by
  catching the opposite case — a process too OLD to have picked up a build
  that its checkout may since have received.

  Pure function, no DB access.
  """
  @spec client_started_at(%__MODULE__{} | %{metadata: map()}) :: DateTime.t() | nil
  def client_started_at(%{metadata: metadata}) when is_map(metadata) do
    with value when is_binary(value) <- client_info_field(metadata, "started_at"),
         {:ok, %DateTime{} = started_at, _utc_offset} <- DateTime.from_iso8601(value) do
      started_at
    else
      _ -> nil
    end
  end

  def client_started_at(_), do: nil

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
