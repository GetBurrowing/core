defmodule Platform.Agents.Agent do
  @moduledoc """
  Schema for the `agents` table.

  An Agent is a named, configurable AI agent within a workspace.
  Agents can be active, paused, or archived, and may have a parent agent.

  ## Kinds (M2)

  An Agent has a `kind` of either `"native"` (the default — runs in the
  built-in BEAM runtime) or `"external"` (delegates to an HTTP endpoint
  such as an OpenAI-compatible or native Ollama API).

  When `kind == "external"`, the fields `endpoint_kind`, `base_url`, and
  `model` are required, and `vault_key` may optionally name a credential
  stored elsewhere. When `kind != "external"`, none of those four fields
  may be set.

  Enforcement lives entirely in `changeset/2` — this module is the single
  source of truth for the kind/external-fields invariant. There is no DB
  CHECK constraint today; M3 may revisit that for the vault flow.

  ## Observability columns (M5)

  Four NULL-able fields capture probe + liveness state for external
  agents: `last_probe_at`, `last_probe_status`, `last_probe_latency_ms`
  (written by `Platform.ExternalAgents.probe/1` in stage 2), and
  `last_successful_fire_at` (written by the M6 dispatcher). These are
  cast through `changeset/2` for completeness, but writers in those
  stages route through `Ecto.Changeset.change/2` to avoid the
  `validate_required([:slug, :name, :status])` guard on minimal
  per-row observability updates.

  ## Avatar

  `avatar_url` is the servable URL; `avatar_storage_key` is the key the
  bytes live under in `Platform.Agents.AvatarStorage`. The second field is
  NOT provenance — it exists so replacing an avatar can delete the previous
  blob rather than leaking it.

  There is deliberately no `avatar_source` enum here, unlike
  `Platform.Accounts.User`. That column arbitrates between two competing
  writers (an OIDC refresh vs. a user upload); an agent has no OIDC and no
  login, so `avatar_url` has exactly one writer and nothing to arbitrate.

  Both fields are nullable and stay that way: an agent without an avatar
  falls back to `color` plus initials, which is the default state rather
  than a degraded one.

  ## Voice (01a03f4f)

  `voice_config` is a jsonb map shaped like `model_config`, holding the
  agent's per-agent voice selection — `provider`, `voice_id`, optional
  `model`. NO vendor appears in this schema: the provider is a value inside
  the map, validated by `Platform.Agents.Voice.validate_config/1` against a
  list that module owns, so adding a second TTS provider is one entry there
  rather than a migration here. See that module for why the personality
  markdown is a workspace file rather than a column alongside this one.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses ~w(active paused archived)
  @valid_kinds ~w(native external)
  @valid_endpoint_kinds ~w(openai_compat ollama_native)

  @external_only_fields [:endpoint_kind, :base_url, :model, :vault_key]

  schema "agents" do
    field(:workspace_id, :binary_id)
    field(:slug, :string)
    field(:name, :string)
    field(:status, :string, default: "active")
    field(:model_config, :map, default: %{})
    field(:tools_config, :map, default: %{})
    field(:thinking_default, :string)
    field(:heartbeat_config, :map, default: %{})
    field(:max_concurrent, :integer, default: 1)
    field(:sandbox_mode, :string, default: "off")
    field(:parent_agent_id, :binary_id)
    field(:metadata, :map, default: %{})
    field(:runtime_type, :string, default: "built_in")
    field(:runtime_id, :binary_id)
    field(:color, :string)
    field(:kind, :string, default: "native")
    field(:endpoint_kind, :string)
    field(:base_url, :string)
    field(:model, :string)
    field(:vault_key, :string)
    field(:last_probe_at, :utc_datetime_usec)
    field(:last_probe_status, :string)
    field(:last_probe_latency_ms, :integer)
    field(:last_successful_fire_at, :utc_datetime_usec)
    field(:avatar_url, :string)
    field(:avatar_storage_key, :string)
    field(:voice_config, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  def valid_kinds, do: @valid_kinds
  def valid_endpoint_kinds, do: @valid_endpoint_kinds

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :workspace_id,
      :slug,
      :name,
      :status,
      :model_config,
      :tools_config,
      :thinking_default,
      :heartbeat_config,
      :max_concurrent,
      :sandbox_mode,
      :parent_agent_id,
      :metadata,
      :runtime_type,
      :runtime_id,
      :color,
      :kind,
      :endpoint_kind,
      :base_url,
      :model,
      :vault_key,
      :last_probe_at,
      :last_probe_status,
      :last_probe_latency_ms,
      :last_successful_fire_at,
      :avatar_url,
      :avatar_storage_key,
      :voice_config
    ])
    |> validate_required([:slug, :name, :status])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:kind, @valid_kinds)
    |> validate_external_fields()
    |> Platform.Agents.Voice.validate_config()
    |> unique_constraint(:slug,
      name: :agents_unique_slug,
      message: "slug already taken in this workspace"
    )
  end

  defp validate_external_fields(changeset) do
    case get_field(changeset, :kind) do
      "external" ->
        changeset
        |> validate_required([:endpoint_kind, :base_url, :model])
        |> validate_inclusion(:endpoint_kind, @valid_endpoint_kinds)
        |> validate_base_url()

      _ ->
        Enum.reduce(@external_only_fields, changeset, fn field, acc ->
          case get_field(acc, field) do
            nil -> acc
            "" -> acc
            _ -> add_error(acc, field, "can only be set when kind is external")
          end
        end)
    end
  end

  defp validate_base_url(changeset) do
    case get_field(changeset, :base_url) do
      nil ->
        changeset

      url when is_binary(url) ->
        case URI.new(url) do
          {:ok, %URI{scheme: scheme, host: host}}
          when scheme in ["http", "https"] and is_binary(host) and host != "" ->
            changeset

          _ ->
            add_error(changeset, :base_url, "must be an http(s) URL")
        end

      _ ->
        add_error(changeset, :base_url, "must be an http(s) URL")
    end
  end
end
