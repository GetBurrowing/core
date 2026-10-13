defmodule Platform.Prototypes.Tools do
  @moduledoc """
  Behaviour of the `prototype` bundle's MCP tools (definitions in
  `Platform.Federation.PrototypeTools`). Reached only through
  `Platform.Federation.ToolSurface.execute/3`, which adds
  `context.agent_home_org` (`:root` or `{:tenant, org_id}`) so org scope is
  decided by the same rule every other tenant-scoped tool uses.

  Scope: a tenant agent may only touch prototypes of its own org; a root
  agent may touch any. A prototype outside scope reads as not found.
  Policy (on/off, who may publish, caps) is `Platform.Prototypes`'.
  """

  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Chat.Attachments.ToolHandlers, as: AttachmentHandlers
  alias Platform.Prototypes
  alias Platform.Prototypes.Prototype
  alias Platform.Tenancy

  @spec execute(String.t(), map(), map()) :: {:ok, map()} | {:error, map()}
  def execute("prototype.publish", args, context) do
    with {:ok, agent_id} <- agent_id(context),
         {:ok, target} <- resolve_target(args, context),
         {:ok, input} <- read_input(args, context) do
      publisher = %{kind: :agent, agent_id: agent_id, owner_user: runtime_owner(context)}

      attrs =
        target
        |> Map.put(:entry_path, blank_to_nil(Map.get(args, "entry_path")))

      case Prototypes.publish(publisher, attrs, input) do
        {:ok, %{prototype: p, version: v}} ->
          {:ok,
           %{
             prototype_id: p.id,
             version: v.version,
             url: Prototypes.url(p.id, v.version),
             latest_url: "/proto/#{p.id}/latest/",
             entry_path: v.entry_path,
             file_count: length(v.manifest),
             total_bytes: v.total_bytes
           }}

        {:error, {code, message}} ->
          error(code, message)
      end
    end
  end

  def execute("prototype.versions", args, context) do
    with {:ok, prototype} <- fetch_in_scope(args, context) do
      versions =
        prototype
        |> Prototypes.list_versions()
        |> Enum.map(fn v ->
          %{
            version: v.version,
            url: Prototypes.url(prototype.id, v.version),
            entry_path: v.entry_path,
            file_count: length(v.manifest),
            total_bytes: v.total_bytes,
            published_by: v.published_by,
            inserted_at: v.inserted_at,
            removed_at: v.removed_at
          }
        end)

      {:ok,
       %{
         prototype_id: prototype.id,
         name: prototype.name,
         org_id: prototype.org_id,
         latest_version: prototype.latest_version,
         versions: versions,
         total: length(versions),
         has_more: false
       }}
    end
  end

  def execute("prototype.rollback", args, context) do
    with {:ok, agent_id} <- agent_id(context),
         {:ok, prototype} <- fetch_in_scope(args, context),
         {:ok, version} <- require_integer(args, "version") do
      publisher = %{kind: :agent, agent_id: agent_id, owner_user: runtime_owner(context)}

      case Prototypes.rollback(publisher, prototype, version) do
        {:ok, p} ->
          {:ok,
           %{
             prototype_id: p.id,
             latest_version: p.latest_version,
             url: Prototypes.url(p.id, p.latest_version)
           }}

        {:error, {code, message}} ->
          error(code, message)
      end
    end
  end

  def execute(tool, _args, _context),
    do: error(:unknown_tool, "unknown prototype tool #{inspect(tool)}")

  # ── Target resolution ──────────────────────────────────────────────────

  defp resolve_target(%{"prototype_id" => id} = args, context) when is_binary(id) and id != "" do
    with {:ok, prototype} <- fetch_in_scope(args, context) do
      case blank_to_nil(Map.get(args, "org_id")) do
        nil ->
          {:ok, %{prototype: prototype}}

        org_id when org_id == prototype.org_id ->
          {:ok, %{prototype: prototype}}

        _other ->
          error(
            :org_mismatch,
            "prototype #{id} belongs to a different org than the org_id you passed"
          )
      end
    end
  end

  defp resolve_target(args, context) do
    space_id = blank_to_nil(Map.get(args, "space_id"))
    org_id = blank_to_nil(Map.get(args, "org_id"))

    with {:ok, space} <- fetch_space(space_id, context),
         {:ok, org_id} <- pick_org(org_id, space),
         :ok <- in_scope(org_id, context),
         {:ok, name} <- require_string(args, "name") do
      {:ok, %{org_id: org_id, space_id: space && space.id, name: name}}
    end
  end

  defp fetch_space(nil, _context), do: {:ok, nil}

  defp fetch_space(space_id, context) do
    with %Chat.Space{} = space <- Platform.UUID.valid?(space_id) && Chat.get_space(space_id),
         %Chat.Participant{} <- Chat.get_agent_participant(space_id, Map.get(context, :agent_id)) do
      {:ok, space}
    else
      _ -> error(:space_not_found, "space #{space_id} not found, or you are not a participant")
    end
  end

  defp pick_org(nil, nil),
    do: error(:missing_org, "pass org_id (or space_id) to create a prototype")

  defp pick_org(nil, %Chat.Space{org_id: nil}),
    do: error(:missing_org, "the space has no org; pass org_id")

  defp pick_org(nil, %Chat.Space{org_id: org_id}), do: {:ok, org_id}

  defp pick_org(org_id, space) do
    cond do
      not match?(%Tenancy.Org{}, Tenancy.get_org(org_id)) ->
        error(:org_not_found, "org #{org_id} not found")

      space && space.org_id && space.org_id != org_id ->
        error(:org_mismatch, "space #{space.id} belongs to a different org than org_id")

      true ->
        {:ok, org_id}
    end
  end

  defp fetch_in_scope(args, context) do
    with {:ok, id} <- require_string(args, "prototype_id") do
      case Prototypes.get_prototype(id) do
        %Prototype{} = p ->
          case in_scope(p.org_id, context) do
            :ok -> {:ok, p}
            _ -> not_found(id)
          end

        nil ->
          not_found(id)
      end
    end
  end

  defp in_scope(org_id, context) do
    case Map.get(context, :agent_home_org, :root) do
      :root ->
        :ok

      {:tenant, ^org_id} ->
        :ok

      {:tenant, _other} ->
        error(:unauthorized, "unauthorized: not a member of org #{org_id}")
    end
  end

  # ── Input ──────────────────────────────────────────────────────────────

  defp read_input(args, context) do
    zip_id = blank_to_nil(Map.get(args, "zip_attachment_id"))
    files = Map.get(args, "files")

    case {zip_id, files} do
      {nil, nil} ->
        error(:missing_bundle, "pass zip_attachment_id or files")

      {id, nil} ->
        case AttachmentHandlers.get_inline(%{"attachment_id" => id}, context) do
          {:ok, %{data_base64: b64}} -> {:ok, {:zip, Base.decode64!(b64)}}
          {:error, %{} = envelope} -> {:error, Map.put_new(envelope, :code, :attachment_error)}
        end

      {nil, files} ->
        {:ok, {:files, files}}

      _ ->
        error(:ambiguous_bundle, "pass zip_attachment_id OR files, not both")
    end
  end

  # ── Principal ──────────────────────────────────────────────────────────

  defp agent_id(context) do
    case Map.get(context, :agent_id) do
      id when is_binary(id) -> {:ok, id}
      _ -> error(:agent_required, "prototype tools need an agent identity")
    end
  end

  # The human who owns the runtime the call arrived on, read off the runtime
  # row rather than trusted from the wire.
  defp runtime_owner(context) do
    with runtime_id when is_binary(runtime_id) <- Map.get(context, :runtime_id),
         %{owner_user_id: owner_id} when is_binary(owner_id) <-
           Platform.Federation.get_runtime_by_runtime_id(runtime_id) do
      Accounts.get_user(owner_id)
    else
      _ -> nil
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp require_string(args, key) do
    case Map.get(args, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> error(:invalid_argument, "missing or invalid #{inspect(key)} (string)")
    end
  end

  defp require_integer(args, key) do
    case Map.get(args, key) do
      v when is_integer(v) ->
        {:ok, v}

      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} -> {:ok, n}
          _ -> error(:invalid_argument, "#{inspect(key)} must be an integer")
        end

      _ ->
        error(:invalid_argument, "missing or invalid #{inspect(key)} (integer)")
    end
  end

  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp blank_to_nil(_), do: nil

  defp not_found(id), do: error(:not_found, "prototype #{id} not found")

  @recoverable ~w(invalid_argument missing_bundle ambiguous_bundle missing_org missing_entry
                  invalid_path too_many_files bundle_too_large symlink_entry invalid_zip
                  unsupported_zip duplicate_path path_conflict invalid_files
                  invalid_file_content empty_bundle version_not_found storage_failed)a

  defp error(code, message) do
    {:error,
     %{
       error: "prototype: #{message}",
       code: code,
       recoverable: code in @recoverable
     }}
  end
end
