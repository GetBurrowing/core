defmodule Platform.Mail.Imap.FakeClient do
  @moduledoc """
  In-memory `Platform.Mail.Imap.Client` for the Email module's tests (task
  01a0cf21 stage 3). No sockets.

  A fake server is an Agent registered globally under the account's
  `imap_host`, so the poller (in whatever process) reaches the same state the
  test seeded:

      FakeClient.start_server!("imap.acme.test")
      FakeClient.put_folder("imap.acme.test", "INBOX", uidvalidity: 7)
      FakeClient.deliver("imap.acme.test", "INBOX", raw)   # => uid

  Every call is recorded (`calls/1`) so a test can assert the client was
  never asked to do anything but read. Folders created with
  `flags: ["\\\\Noselect"]` are listed but carry no messages.
  """
  @behaviour Platform.Mail.Imap.Client

  # ── Test API ────────────────────────────────────────────────────────────

  def start_server!(host) do
    {:ok, pid} =
      Agent.start(fn -> %{folders: %{}, order: [], calls: []} end,
        name: name(host)
      )

    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
    pid
  end

  def put_folder(host, folder, opts \\ []) do
    update(host, fn state ->
      entry = %{
        uidvalidity: Keyword.get(opts, :uidvalidity, 1),
        flags: Keyword.get(opts, :flags, []),
        next_uid: 1,
        messages: %{}
      }

      order = if folder in state.order, do: state.order, else: state.order ++ [folder]
      %{state | folders: Map.put(state.folders, folder, entry), order: order}
    end)
  end

  @doc "Append `raw` to `folder` and return its UID."
  def deliver(host, folder, raw) do
    Agent.get_and_update(name(host), fn state ->
      entry = Map.fetch!(state.folders, folder)
      uid = entry.next_uid

      entry = %{entry | next_uid: uid + 1, messages: Map.put(entry.messages, uid, raw)}
      {uid, %{state | folders: Map.put(state.folders, folder, entry)}}
    end)
  end

  @doc "Simulate the server renumbering a folder: new UIDVALIDITY, UIDs restart."
  def renumber(host, folder, uidvalidity) do
    update(host, fn state ->
      entry = Map.fetch!(state.folders, folder)

      messages =
        entry.messages
        |> Enum.sort()
        |> Enum.with_index(1)
        |> Map.new(fn {{_old_uid, raw}, new_uid} -> {new_uid, raw} end)

      entry = %{
        entry
        | uidvalidity: uidvalidity,
          messages: messages,
          next_uid: map_size(messages) + 1
      }

      %{state | folders: Map.put(state.folders, folder, entry)}
    end)
  end

  def calls(host), do: Agent.get(name(host), &Enum.reverse(&1.calls))

  # ── Behaviour ───────────────────────────────────────────────────────────

  @impl true
  def connect(%{host: host} = params) do
    case GenServer.whereis(name(host)) do
      nil ->
        {:error, :unable_to_connect}

      _pid ->
        record(host, {:connect, Map.delete(params, :password)})
        {:ok, %{host: host, folder: make_ref_folder()}}
    end
  end

  @impl true
  def list_folders(%{host: host}) do
    record(host, :list)

    {:ok,
     Agent.get(name(host), fn state ->
       Enum.map(state.order, fn folder -> {folder, state.folders[folder].flags} end)
     end)}
  end

  @impl true
  def examine(%{host: host} = conn, folder) do
    record(host, {:examine, folder})

    case Agent.get(name(host), &Map.get(&1.folders, folder)) do
      nil ->
        {:error, :no_such_folder}

      entry ->
        Process.put({__MODULE__, conn.folder}, folder)
        max_uid = entry.messages |> Map.keys() |> Enum.max(fn -> 0 end)
        {:ok, entry.uidvalidity, max_uid}
    end
  end

  @impl true
  def uids_after(%{host: host} = conn, uid) do
    folder = Process.get({__MODULE__, conn.folder})
    record(host, {:uids_after, folder, uid})

    uids =
      Agent.get(name(host), fn state ->
        state.folders[folder].messages |> Map.keys() |> Enum.filter(&(&1 > uid)) |> Enum.sort()
      end)

    {:ok, uids}
  end

  @impl true
  def fetch_raw(%{host: host} = conn, uid) do
    folder = Process.get({__MODULE__, conn.folder})
    record(host, {:fetch_raw, folder, uid})

    case Agent.get(name(host), &get_in(&1, [:folders, folder, :messages, uid])) do
      nil -> {:error, :no_such_uid}
      raw -> {:ok, raw}
    end
  end

  @impl true
  def logout(%{host: host}) do
    record(host, :logout)
    :ok
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp name(host), do: {:global, {__MODULE__, host}}

  defp update(host, fun), do: Agent.update(name(host), fun)

  defp record(host, call), do: update(host, &%{&1 | calls: [call | &1.calls]})

  defp make_ref_folder, do: make_ref()
end
