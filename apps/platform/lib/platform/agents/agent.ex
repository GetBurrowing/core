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
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses ~w(active paused archived)
  @valid_system_events ~w(historian)
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
    field(:system_events, {:array, :string}, default: [])
    field(:kind, :string, default: "native")
    field(:endpoint_kind, :string)
    field(:base_url, :string)
    field(:model, :string)
    field(:vault_key, :string)

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
      :system_events,
      :kind,
      :endpoint_kind,
      :base_url,
      :model,
      :vault_key
    ])
    |> validate_required([:slug, :name, :status])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_subset(:system_events, @valid_system_events)
    |> validate_inclusion(:kind, @valid_kinds)
    |> validate_external_fields()
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
