defmodule Platform.InstructionPacks.Owner do
  @moduledoc "Owner-facing read model. Authorization is checked on every request, never cached from mount."
  import Ecto.Query
  alias Platform.{Access, Repo, Sharing}
  alias Platform.InstructionPacks.{Entry, Installer, RetainedRelease, State}

  def snapshot(actor) do
    with :ok <- authorize(actor) do
      packs = Repo.all(from s in State, order_by: s.pack_id)
      rows = Enum.map(packs, fn state ->
        releases = Repo.all(from r in RetainedRelease, where: r.pack_id == ^state.pack_id, order_by: [desc: r.version])
        {:ok, conflicts} = Installer.conflicts(state.pack_id, actor)
        entries = Repo.all(from e in Entry, where: e.pack_id == ^state.pack_id)
        versions = entries |> Enum.map(& &1.effective_version) |> Enum.uniq() |> Enum.sort()
        previous = state.history |> Enum.reverse() |> Enum.find(fn h -> h["version"] != state.version and Enum.any?(releases, &(&1.version == h["version"])) end)
        current = Enum.find(releases, &(&1.version == state.version))
        manifest = if current, do: Jason.decode!(current.envelope)["manifest"], else: %{}
        %{state: state, versions: versions, conflicts: conflicts, releases: releases, previous: previous && previous["version"], manifest: manifest}
      end)
      events = Repo.all(from e in Platform.Audit.Event, where: e.resource_type in ["instruction_pack", "install_sharing"], order_by: [desc: e.inserted_at], limit: 100)
      {:ok, %{sharing: Sharing.get(), packs: rows, events: events}}
    end
  end

  def set_sharing(key, enabled, actor) when is_binary(key) and is_boolean(enabled) do
    with :ok <- authorize(actor),
         entry when not is_nil(entry) <- Enum.find(Sharing.registry(), &(Atom.to_string(&1.key) == key)) do
      case entry.key do
        :instruction_updates -> Installer.set_updates(enabled, actor)
        key -> Sharing.set(key, enabled, {:user, actor.id})
      end
    else
      _ -> {:error, :unauthorized}
    end
  end

  def pin(pack, version, actor) do
    with :ok <- authorize(actor), %State{} = state <- Repo.get(State, pack) do
      if version == state.version, do: Installer.pin(pack, version, actor), else: Installer.rollback(pack, version, roots(), actor)
    else
      _ -> {:error, :not_installed}
    end
  end

  def roots, do: Application.get_env(:platform, :instruction_packs, []) |> Keyword.get(:trust_roots, %{})
  def authorize(%Platform.Accounts.User{} = actor), do: Access.authorize_install(actor)
  def authorize(_), do: {:error, :unauthorized}
end
