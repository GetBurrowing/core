defmodule Platform.InstructionPacks.Installer do
  @moduledoc """
  Signed content installation. Network IO happens outside the transaction;
  consent is read again under the singleton row lock before any content write.
  All target writes, retained signed bytes, provenance and history commit together.
  """
  import Ecto.Query
  alias Platform.{Access, Audit, Repo, Sharing}

  alias Platform.InstructionPacks.{
    Download,
    Entry,
    Manifest,
    RetainedRelease,
    Signature,
    State,
    Targets
  }

  alias Platform.Sharing.InstallSharing

  def set_updates(value, actor) when is_boolean(value) do
    with :ok <- authorize_owner(actor),
         do: Sharing.set(:instruction_updates, value, {:user, actor.id})
  end

  def stop_updates(value, actor) when is_boolean(value) do
    with :ok <- authorize_owner(actor),
         do: Sharing.set(:instruction_updates_stopped, value, {:user, actor.id})
  end

  def pull(pack_id, version, roots, options \\ []) do
    result =
      with {:ok, consent} <- consent_snapshot(),
           true <- Keyword.get(options, :consent_snapshot, consent) == consent,
           {:ok, envelope} <- Download.fetch_envelope(pack_id, version, roots, options) do
        install(envelope, roots, consent)
      else
        false -> {:error, :sharing_changed}
        error -> error
      end

    record_check(pack_id, result)
    result
  end

  defp record_check(pack_id, result) do
    # Fixed labels only: transport errors and pack text must never become UI HTML.
    if is_binary(pack_id) and Regex.match?(~r/\A[a-z0-9][a-z0-9_.-]{0,127}\z/, pack_id) do
      Repo.transaction(fn ->
        state = locked_state(pack_id)
        now = DateTime.utc_now()

        attrs =
          case result do
            {:ok, _} -> %{checked_at: now, last_successful_check_at: now, check_error: nil}
            {:error, reason} -> %{checked_at: now, check_error: check_error(reason)}
          end

        Repo.update!(Ecto.Changeset.change(state, attrs))
      end)
    end
  end

  defp check_error(reason) when reason in [:sharing_disabled, :sharing_changed], do: "disabled"
  defp check_error(:pinned), do: "pinned"
  defp check_error(reason) when reason in [:download_failed, :invalid_pack_source], do: "network"
  defp check_error(_), do: "verification"

  def consent_snapshot do
    row = Sharing.get()
    if allowed?(row), do: {:ok, row.updated_at}, else: {:error, :sharing_disabled}
  end

  def install(envelope, roots, consent) do
    with {:ok, manifest} <- Signature.verify(envelope, roots),
         :ok <- compatible(manifest) do
      Repo.transaction(fn ->
        lock_and_check_consent!(consent)
        state = locked_state(manifest["pack_id"])
        if state.pinned_version, do: Repo.rollback(:pinned)
        apply_release!(state, envelope, manifest, :advance, nil)
      end)
    end
  end

  def pin(pack_id, version, actor) do
    with :ok <- authorize_owner(actor) do
      Repo.transaction(fn ->
        state = locked_state(pack_id)
        if version != nil and version != state.version, do: Repo.rollback(:not_installed)
        changed = Repo.update!(Ecto.Changeset.change(state, pinned_version: version))
        audit!(pack_id, "pin", actor, %{"version" => version})
        changed
      end)
    end
  end

  def rollback(pack_id, version, roots, actor) do
    with :ok <- authorize_owner(actor), {:ok, consent} <- consent_snapshot() do
      Repo.transaction(fn ->
        lock_and_check_consent!(consent)
        state = locked_state(pack_id)

        unless Enum.any?(state.history, &(&1["version"] == version)),
          do: Repo.rollback(:not_previously_applied)

        release =
          Repo.get_by(RetainedRelease, pack_id: pack_id, version: version) ||
            Repo.rollback(:not_retained)

        with {:ok, envelope} <- Jason.decode(release.envelope),
             {:ok, manifest} <- Signature.verify(envelope, roots),
             :ok <- compatible(manifest) do
          result = apply_release!(state, envelope, manifest, :rollback, actor)
          Repo.update!(Ecto.Changeset.change(result, pinned_version: version))
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc "Owner review snapshots bind current physical rows and text to each conflict token."
  def conflicts(pack_id, actor) do
    with :ok <- authorize_owner(actor) do
      Repo.transaction(fn ->
        _state = locked_state(pack_id)

        Repo.all(from(e in Entry, where: e.pack_id == ^pack_id and not is_nil(e.conflict)))
        |> Enum.map(fn entry ->
          mapped = conflict_target!(entry)
          conflict_snapshot(entry, mapped)
        end)
      end)
    end
  end

  def resolve_conflict(pack_id, type, target, choice, expected_token, actor)
      when choice in [:local, :incoming] do
    with :ok <- authorize_owner(actor), {:ok, consent} <- consent_snapshot() do
      Repo.transaction(fn ->
        lock_and_check_consent!(consent)
        _state = locked_state(pack_id)

        entry =
          Repo.get_by(Entry, pack_id: pack_id, type: type, target: target) ||
            Repo.rollback(:not_found)

        unless entry.conflict, do: Repo.rollback(:no_conflict)
        mapped = conflict_target!(entry)
        snapshot = conflict_snapshot(entry, mapped)

        unless expected_token == Entry.conflict_token(snapshot),
          do: Repo.rollback(:stale_conflict)

        attrs =
          if choice == :incoming do
            value = entry.conflict["incoming"] || ""
            write!(mapped, value)

            %{
              applied_hash: Entry.hash(value),
              effective_version: entry.conflict["incoming_version"],
              conflict: nil
            }
          else
            %{applied_hash: nil, effective_version: nil, conflict: nil}
          end

        attrs = Map.put(attrs, :record_id, Targets.record_id(mapped))
        updated = Repo.update!(Ecto.Changeset.change(entry, attrs))

        audit!(pack_id, "resolve_conflict", actor, %{
          "type" => type,
          "target" => target,
          "choice" => to_string(choice)
        })

        updated
      end)
    end
  end

  defp apply_release!(state, envelope, manifest, mode, actor) do
    version = manifest["version"]
    digest = Manifest.digest(manifest)

    if mode == :advance do
      cond do
        state.version == version and state.digest == digest ->
          :ok

        state.version && version <= state.version ->
          Repo.rollback(:stale_release)

        state.version &&
            (version != state.version + 1 or manifest["previous_digest"] != state.digest) ->
          Repo.rollback(:invalid_release_chain)

        is_nil(state.version) and version != 1 ->
          Repo.rollback(:invalid_release_chain)

        true ->
          :ok
      end
    end

    case Repo.get_by(RetainedRelease, pack_id: state.pack_id, version: version) do
      nil ->
        Repo.insert!(%RetainedRelease{
          pack_id: state.pack_id,
          version: version,
          digest: digest,
          envelope: Jason.encode!(envelope)
        })

      %{digest: ^digest} ->
        :ok

      _ ->
        Repo.rollback(:release_collision)
    end

    # Replays must not turn previously resolved local ownership into conflicts.
    if mode == :advance and state.version == version and state.digest == digest do
      state
    else
      previous = Repo.all(from(e in Entry, where: e.pack_id == ^state.pack_id))
      incoming = Map.new(manifest["entries"], &{{&1["type"], &1["target"]}, &1["content"]})

      keys =
        (Map.keys(incoming) ++ Enum.map(previous, &{&1.type, &1.target}))
        |> Enum.uniq()
        |> Enum.sort()

      mappings =
        Enum.map(keys, fn {type, target} ->
          old = Enum.find(previous, &(&1.type == type and &1.target == target))

          mapped =
            case Targets.resolve(type, target) do
              {:ok, mapped} -> mapped
              {:error, :missing_target} when not is_nil(old) -> {:deleted, type, target}
              {:error, reason} -> Repo.rollback(reason)
            end

          {{type, target}, mapped}
        end)

      identities = Enum.map(mappings, fn {_, mapped} -> Targets.identity(mapped) end)
      if length(Enum.uniq(identities)) != length(identities), do: Repo.rollback(:ambiguous_target)

      for {{type, target} = key, mapped} <- mappings do
        old = Enum.find(previous, &(&1.type == type and &1.target == target))
        foreign = Repo.get_by(Entry, type: type, target: target)

        if foreign && foreign.pack_id != state.pack_id,
          do: Repo.rollback(:target_owned_by_another_pack)

        # A replacement row is local even when its bytes equal the old vendor value.
        comparison =
          if old && old.record_id != Targets.record_id(mapped),
            do: %{old | applied_hash: nil, effective_version: nil},
            else: old

        {decision, value, attrs} =
          Entry.reconcile(comparison, Targets.content(mapped), Map.get(incoming, key), version)

        attrs = Map.put(attrs, :record_id, Targets.record_id(mapped))

        if decision == :write, do: write!(mapped, value)
        row = old || %Entry{pack_id: state.pack_id, type: type, target: target}
        Repo.insert_or_update!(Ecto.Changeset.change(row, attrs))
      end

      now = DateTime.utc_now()

      history =
        state.history ++
          [
            %{
              "version" => version,
              "digest" => digest,
              "action" => to_string(mode),
              "at" => DateTime.to_iso8601(now)
            }
          ]

      result =
        Repo.update!(
          Ecto.Changeset.change(state, %{
            version: version,
            highest_version: max(version, state.highest_version),
            digest: digest,
            history: history,
            applied_at: now,
            checked_at: now
          })
        )

      audit!(state.pack_id, to_string(mode), actor, %{"version" => version})
      result
    end
  end

  defp allowed?(row),
    do: row.instruction_updates == true and row.instruction_updates_stopped == false

  defp lock_and_check_consent!(snapshot) do
    row = Repo.one!(from(s in InstallSharing, lock: "FOR UPDATE"))
    unless allowed?(row) and row.updated_at == snapshot, do: Repo.rollback(:sharing_changed)
  end

  defp locked_state(pack_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "instruction_pack_install"
    ])

    Repo.insert!(%State{pack_id: pack_id}, on_conflict: :nothing, conflict_target: :pack_id)
    Repo.get!(State, pack_id)
  end

  defp compatible(manifest) do
    current = Application.spec(:platform, :vsn) |> to_string()

    if Version.compare(current, manifest["minimum_client_version"]) in [:eq, :gt],
      do: :ok,
      else: {:error, :incompatible_client}
  end

  defp conflict_target!(entry) do
    case Targets.resolve(entry.type, entry.target) do
      {:ok, mapped} -> mapped
      {:error, :missing_target} -> {:deleted, entry.type, entry.target}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp conflict_snapshot(entry, mapped) do
    %{
      entry
      | record_id: Targets.record_id(mapped),
        conflict: Map.put(entry.conflict, "local", Targets.content(mapped))
    }
  end

  defp write!({:deleted, _, _}, _value), do: Repo.rollback(:missing_target)

  defp write!(mapped, value) do
    case Targets.write(mapped, value) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp audit!(pack_id, action, actor, metadata) do
    {kind, id} =
      case actor do
        nil -> {"system", nil}
        %{id: id} -> {"user", id}
      end

    case Audit.record(%{
           event_type: "platform.instruction_packs." <> action,
           actor_type: kind,
           actor_id: id,
           resource_type: "instruction_pack",
           action: action,
           metadata: Map.put(metadata, "pack_id", pack_id)
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # An agent/system scope is not an owner's conflict-resolution decision.
  defp authorize_owner(%Platform.Accounts.User{} = actor), do: Access.authorize_install(actor)
  defp authorize_owner(_), do: {:error, :unauthorized}
end
