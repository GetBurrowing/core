defmodule Platform.Chat.AttachmentStorage.Root do
  @moduledoc """
  Process-scoped override for the attachment storage root.

  ## Why this exists

  `:chat_attachments_root` is read at call time by
  `Platform.Chat.AttachmentStorage.Adapter.LocalDisk.storage_root/0` and by
  `Platform.Files.Extractor`. Tests used to point those reads at a scratch
  directory with `Application.put_env/3`, which writes a **VM-global** key.
  Three `async: true` modules did that concurrently, so one test's `on_exit`
  restore repointed the root out from under another test that was mid-flight.

  Uniqueness of the *value* does not fix that — every one of those tests
  already had a unique directory (`Platform.TestTemp`) and still failed. The
  missing property is ownership of the *read*: a root no sibling can repoint.

  Restoring made it worse rather than better. `config/runtime.exs` sets the
  same key unguarded by env and loads after `config/test.exs`, so the value in
  scope during the whole test run is the deployment path
  (`/data/platform/chat_uploads` by default), which does not exist locally and
  whose parent is read-only. A sibling's restore therefore aimed the global
  root at an unwritable path, which is where the `{:error, :erofs}` failures
  came from — a shared-tmp-directory account cannot explain those at all.

  ## Mechanism

  An override lives in the **process dictionary** of the process that claims
  it, and is visible to that process and to processes it spawned, resolved
  through `$callers` (set by `Task`) and `$ancestors` (set by supervisors and
  `GenServer`). One OS-level VM, many independent roots; a concurrently
  running process cannot reach into another's dictionary to change it, so the
  race is structurally impossible rather than merely less likely.

  ## Production is unchanged

  No production code path calls `put_override/1`, so `get/1` always returns the
  fallback it is handed. Each call site passes exactly the expression it used
  before this module existed — see `LocalDisk.storage_root/0` and
  `Platform.Files.Extractor` — so with no override in scope the resolved root
  is byte-identical to the previous behaviour, including each site's own
  distinct default.
  """

  @dict_key {__MODULE__, :override}

  @doc """
  Claims `root` as the attachment storage root for the calling process and its
  descendants.

  The override outlives nothing: it dies with the process that set it, so a
  test does not need to (and should not) restore anything on exit.
  """
  @spec put_override(binary()) :: :ok
  def put_override(root) when is_binary(root) do
    Process.put(@dict_key, root)
    :ok
  end

  @doc """
  Drops the calling process's override, if any.
  """
  @spec delete_override() :: :ok
  def delete_override do
    Process.delete(@dict_key)
    :ok
  end

  @doc """
  Returns the process-scoped override if one is in scope, otherwise `fallback`.

  `fallback` is the caller's own app-env resolution, evaluated by the caller,
  so this function cannot change what production reads.
  """
  @spec get(binary()) :: binary()
  def get(fallback) do
    case lookup([self() | related_pids()]) do
      {:ok, root} -> root
      :error -> fallback
    end
  end

  defp related_pids do
    Process.get(:"$callers", []) ++ Process.get(:"$ancestors", [])
  end

  defp lookup([]), do: :error

  defp lookup([pid | rest]) when is_pid(pid) do
    case dictionary_override(pid) do
      {:ok, root} -> {:ok, root}
      :error -> lookup(rest)
    end
  end

  # `$ancestors` can carry a registered name rather than a pid.
  defp lookup([name | rest]) do
    case Process.whereis(name) do
      nil -> lookup(rest)
      pid -> lookup([pid | rest])
    end
  rescue
    ArgumentError -> lookup(rest)
  end

  defp dictionary_override(pid) when pid == self() do
    case Process.get(@dict_key) do
      nil -> :error
      root -> {:ok, root}
    end
  end

  defp dictionary_override(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, entries} ->
        case List.keyfind(entries, @dict_key, 0) do
          {_key, root} -> {:ok, root}
          nil -> :error
        end

      # The owner has exited; nothing to inherit.
      nil ->
        :error
    end
  end
end
