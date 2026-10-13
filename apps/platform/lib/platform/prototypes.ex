defmodule Platform.Prototypes do
  @moduledoc """
  Versioned, multi-file prototype bundles, served sealed behind org login
  (ADR 0057 Decision 1; task 01a1316b-4e46 stage 1).

    * A prototype belongs to exactly one org. Only that org's members can
      open it (`PlatformWeb.PrototypeController`).
    * Every publish creates version N+1 and never rewrites an older version.
      N is one more than the highest version EVER written for the prototype
      (removed ones included), so a number is never reused.
    * `rollback/3` repoints `latest_version`; nothing is copied.
    * Publishing is gated by `Platform.Prototypes.Settings`, read at call
      time, and fails closed: disabled, over a cap, or a caller the policy
      does not admit is refused before a byte is written.

  ## Publishers

  A publisher is `%{kind: :agent, agent_id: id, owner_user: user | nil}` (an
  MCP caller; `owner_user` is the human who owns the runtime the call arrived
  on) or `%{kind: :user, user: user}`. Org SCOPE for an agent (a tenant agent
  may only publish into its own org) is checked by the tool layer before it
  gets here; `authorize_publish/3` decides the install POLICY.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Prototypes.Bundle
  alias Platform.Prototypes.Prototype
  alias Platform.Prototypes.Settings
  alias Platform.Prototypes.Storage
  alias Platform.Prototypes.Version
  alias Platform.Repo
  alias Platform.Tenancy

  @type publisher ::
          %{kind: :agent, agent_id: binary(), owner_user: struct() | nil}
          | %{kind: :user, user: struct()}
  @type error :: {:error, {atom(), String.t()}}
  @type input :: {:zip, binary()} | {:files, map()}

  # ── Reads ──────────────────────────────────────────────────────────────

  @doc "A prototype by id, or nil (also nil for a non-UUID id)."
  @spec get_prototype(term()) :: Prototype.t() | nil
  def get_prototype(id) do
    if Platform.UUID.valid?(id), do: Repo.get(Prototype, id), else: nil
  end

  @doc "A version that has not been removed by retention, or nil."
  @spec get_live_version(binary(), integer()) :: Version.t() | nil
  def get_live_version(prototype_id, version) when is_integer(version) do
    Repo.one(
      from(v in Version,
        where: v.prototype_id == ^prototype_id and v.version == ^version and is_nil(v.removed_at)
      )
    )
  end

  @doc "Every version of a prototype, newest first, removed ones included."
  @spec list_versions(Prototype.t()) :: [Version.t()]
  def list_versions(%Prototype{id: id}) do
    Repo.all(from(v in Version, where: v.prototype_id == ^id, order_by: [desc: v.version]))
  end

  @doc "The path a version is opened at: `/proto/<id>/<version>/`."
  @spec url(binary(), integer()) :: String.t()
  def url(prototype_id, version), do: "/proto/#{prototype_id}/#{version}/"

  @doc """
  Everything the prototype canvas kind's bar needs, in one call (stage 2).

  `requested` is the node's `version` prop (nil = follow latest).
  `canvas_org_id` is the org of the space the canvas lives in: a prototype of
  any OTHER org is `:unavailable`, exactly like an unknown id, so a canvas in
  org X never frames, or reveals the existence of, a prototype of org Y. The
  serve route's 404 is the backstop; this check means the frame is never
  emitted at all. A nil `canvas_org_id` (the space could not be resolved) is
  also `:unavailable`: fail closed.

  Returns `{:ok, view}` where `view.state` is `:live` or `:removed` (the shown
  version was deleted by retention), or `{:error, :unavailable}`.
  """
  @spec frame_view(term(), integer() | nil, binary() | nil) ::
          {:ok, map()} | {:error, :unavailable}
  def frame_view(prototype_id, requested, canvas_org_id) do
    with %Prototype{org_id: org_id} = prototype when is_binary(org_id) <-
           get_prototype(prototype_id),
         true <- is_binary(canvas_org_id) and org_id == canvas_org_id,
         versions when versions != [] <- list_versions(prototype),
         shown = requested || prototype.latest_version,
         %Version{} = row <- Enum.find(versions, &(&1.version == shown)) do
      names = publisher_names(versions)

      {:ok,
       %{
         prototype: prototype,
         latest: prototype.latest_version,
         shown: shown,
         shown_at: row.inserted_at,
         pinned?: is_integer(requested) and requested < prototype.latest_version,
         state: if(row.removed_at, do: :removed, else: :live),
         versions:
           Enum.map(versions, fn v ->
             %{
               version: v.version,
               inserted_at: v.inserted_at,
               publisher: Map.get(names, publisher_key(v.published_by), "unknown"),
               removed?: not is_nil(v.removed_at)
             }
           end)
       }}
    else
      _ -> {:error, :unavailable}
    end
  end

  # Display names for every publisher of `versions`: one query for users and
  # one for agents, whatever the number of versions.
  defp publisher_names(versions) do
    keys = versions |> Enum.map(&publisher_key(&1.published_by)) |> Enum.uniq()
    ids = fn kind -> for {^kind, id} <- keys, Platform.UUID.valid?(id), do: id end

    users =
      case ids.("user") do
        [] ->
          []

        user_ids ->
          Repo.all(
            from(u in Platform.Accounts.User,
              where: u.id in ^user_ids,
              select: {u.id, u.name, u.email}
            )
          )
          |> Enum.map(fn {id, name, email} -> {{"user", id}, name || email} end)
      end

    agents =
      case ids.("agent") do
        [] ->
          []

        agent_ids ->
          Repo.all(
            from(a in Platform.Agents.Agent, where: a.id in ^agent_ids, select: {a.id, a.name})
          )
          |> Enum.map(fn {id, name} -> {{"agent", id}, name} end)
      end

    Map.new(users ++ agents)
  end

  defp publisher_key(%{"kind" => kind, "id" => id}), do: {kind, id}
  defp publisher_key(_), do: nil

  # ── Policy ─────────────────────────────────────────────────────────────

  @doc """
  Does the install policy let `publisher` publish (or roll back) in `org_id`?

    * disabled → `:prototypes_disabled`, for everyone.
    * `"agents_only"` → any agent; never a user.
    * `"members"` → any agent; a user who is a member of the org.
    * `"admins"` → a user, or an agent's runtime owner, who is an admin of the
      org (`Tenancy.org_admin?/2`) or a root admin. An agent whose runtime has
      no owner is refused.
  """
  @spec authorize_publish(Settings.t(), publisher(), binary()) :: :ok | error()
  def authorize_publish(%Settings{enabled: false}, _publisher, _org_id),
    do:
      {:error,
       {:prototypes_disabled,
        "prototype publishing is turned off on this install (an admin enables it in the admin panel)"}}

  def authorize_publish(%Settings{who_may_publish: policy}, publisher, org_id) do
    allowed? =
      case {policy, publisher} do
        {"agents_only", %{kind: :agent}} -> true
        {"agents_only", _} -> false
        {"members", %{kind: :agent}} -> true
        {"members", %{kind: :user, user: user}} -> Tenancy.member_of?(user, org_id)
        {"admins", %{kind: :agent, owner_user: owner}} -> admin?(owner, org_id)
        {"admins", %{kind: :user, user: user}} -> admin?(user, org_id)
        _ -> false
      end

    if allowed?,
      do: :ok,
      else:
        {:error,
         {:publish_not_allowed,
          "this install only lets #{policy_label(policy)} publish prototypes in this org"}}
  end

  defp admin?(nil, _org_id), do: false
  defp admin?(user, org_id), do: Tenancy.org_admin?(user, org_id) or Tenancy.root_admin?(user)

  defp policy_label("agents_only"), do: "agents"
  defp policy_label("admins"), do: "org admins (or agents they own)"
  defp policy_label(_), do: "org members and agents"

  # ── Publish ────────────────────────────────────────────────────────────

  @doc """
  Publish a new version.

  `attrs`: `:prototype` (an existing `%Prototype{}`, to add a version) OR
  `:org_id` + `:name` (+ optional `:space_id`) to create one; optional
  `:entry_path` (default `"index.html"`).

  Returns `{:ok, %{prototype: p, version: v}}` or a coded error. On any error
  nothing is left in storage.
  """
  @spec publish(publisher(), map(), input()) ::
          {:ok, %{prototype: Prototype.t(), version: Version.t()}} | error()
  def publish(publisher, attrs, input) do
    settings = Settings.get()
    limits = %{max_files: settings.max_files, max_bytes: settings.max_bundle_bytes}
    entry_path = Map.get(attrs, :entry_path) || "index.html"
    org_id = org_for(attrs)

    with :ok <- authorize_publish(settings, publisher, org_id),
         :ok <- Bundle.validate_path(entry_path),
         {:ok, files} <- ingest(input, limits),
         :ok <- require_entry(files, entry_path) do
      prototype_id =
        case attrs do
          %{prototype: %Prototype{id: id}} -> id
          _ -> Platform.Types.UUIDv7.generate()
        end

      write_version(publisher, attrs, prototype_id, entry_path, files)
    end
  end

  defp org_for(%{prototype: %Prototype{org_id: org_id}}), do: org_id
  defp org_for(%{org_id: org_id}), do: org_id

  defp ingest({:zip, bin}, limits), do: Bundle.from_zip(bin, limits)
  defp ingest({:files, map}, limits), do: Bundle.from_files(map, limits)

  defp require_entry(files, entry_path) do
    if Enum.any?(files, &(&1.path == entry_path)),
      do: :ok,
      else:
        {:error,
         {:missing_entry,
          "the bundle has no #{inspect(entry_path)}; add one or pass entry_path naming a file in the bundle"}}
  end

  # The version number is chosen under a row lock on the prototype, and the
  # bytes are written inside the same transaction, so two concurrent publishes
  # serialize instead of racing for one number. Every key this call could
  # have written is known up front, so a failure anywhere deletes all of them
  # (delete is idempotent); an earlier version's keys are never in that set.
  defp write_version(publisher, attrs, prototype_id, entry_path, files) do
    result =
      try do
        Repo.transaction(fn ->
          do_write_version(publisher, attrs, prototype_id, entry_path, files)
        end)
      rescue
        e ->
          cleanup_pending(prototype_id, files)
          reraise e, __STACKTRACE__
      end

    case result do
      {:ok, _} = ok ->
        Process.delete({__MODULE__, :pending_version})
        ok

      {:error, reason} ->
        cleanup_pending(prototype_id, files)

        case reason do
          {:storage_failed, why} -> {:error, {:storage_failed, "storage write failed: #{why}"}}
          {code, msg} when is_atom(code) and is_binary(msg) -> {:error, {code, msg}}
          other -> {:error, {:publish_failed, inspect(other)}}
        end
    end
  end

  defp cleanup_pending(prototype_id, files) do
    case Process.delete({__MODULE__, :pending_version}) do
      nil -> :ok
      version -> Enum.each(files, &Storage.delete(Storage.key(prototype_id, version, &1.path)))
    end
  end

  defp do_write_version(publisher, attrs, prototype_id, entry_path, files) do
    prototype = lock_or_create(attrs, prototype_id, publisher)
    version = next_version(prototype.id)
    Process.put({__MODULE__, :pending_version}, version)

    manifest =
      Enum.map(files, fn %{path: path, bytes: bytes} ->
        key = Storage.key(prototype.id, version, path)

        case Storage.put(key, bytes) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback({:storage_failed, inspect(reason)})
        end

        %{
          "path" => path,
          "content_type" => MIME.from_path(path),
          "byte_size" => byte_size(bytes),
          "storage_key" => key,
          "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
        }
      end)

    row =
      Repo.insert!(%Version{
        prototype_id: prototype.id,
        version: version,
        manifest: manifest,
        total_bytes: Enum.reduce(files, 0, &(byte_size(&1.bytes) + &2)),
        entry_path: entry_path,
        published_by: published_by(publisher)
      })

    {1, _} =
      Repo.update_all(
        from(p in Prototype, where: p.id == ^prototype.id),
        set: [latest_version: version, updated_at: DateTime.utc_now()]
      )

    %{prototype: %{prototype | latest_version: version}, version: row}
  end

  defp lock_or_create(%{prototype: %Prototype{id: id}}, _prototype_id, _publisher) do
    Repo.one!(from(p in Prototype, where: p.id == ^id, lock: "FOR UPDATE"))
  end

  defp lock_or_create(attrs, prototype_id, publisher) do
    changeset =
      attrs
      |> Map.take([:org_id, :space_id, :name])
      |> Map.merge(creator(publisher))
      |> Prototype.create_changeset()
      |> Ecto.Changeset.put_change(:id, prototype_id)

    case Repo.insert(changeset) do
      {:ok, prototype} ->
        prototype

      {:error, cs} ->
        Repo.rollback({:invalid_prototype, inspect(cs.errors)})
    end
  end

  defp next_version(prototype_id) do
    (Repo.one(from(v in Version, where: v.prototype_id == ^prototype_id, select: max(v.version))) ||
       0) + 1
  end

  defp creator(%{kind: :agent, agent_id: agent_id} = p),
    do: %{created_by_agent_id: agent_id, created_by_user_id: owner_id(p)}

  defp creator(%{kind: :user, user: user}), do: %{created_by_user_id: user.id}

  defp owner_id(%{owner_user: %{id: id}}), do: id
  defp owner_id(_), do: nil

  defp published_by(%{kind: :agent, agent_id: agent_id} = p),
    do: %{"kind" => "agent", "id" => agent_id, "owner_user_id" => owner_id(p)}

  defp published_by(%{kind: :user, user: user}), do: %{"kind" => "user", "id" => user.id}

  # ── Rollback ───────────────────────────────────────────────────────────

  @doc """
  Point `latest_version` at an existing, unremoved version. Same policy gate
  as publishing. No bytes move.
  """
  @spec rollback(publisher(), Prototype.t(), integer()) :: {:ok, Prototype.t()} | error()
  def rollback(publisher, %Prototype{} = prototype, version) when is_integer(version) do
    with :ok <- authorize_publish(Settings.get(), publisher, prototype.org_id) do
      case get_live_version(prototype.id, version) do
        nil ->
          {:error,
           {:version_not_found, "version #{version} does not exist or was removed by retention"}}

        %Version{} ->
          prototype
          |> Ecto.Changeset.change(latest_version: version)
          |> Repo.update()
          |> case do
            {:ok, p} -> {:ok, p}
            {:error, cs} -> {:error, {:rollback_failed, inspect(cs.errors)}}
          end
      end
    end
  end
end
