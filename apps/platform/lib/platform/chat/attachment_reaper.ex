defmodule Platform.Chat.AttachmentReaper do
  @moduledoc """
  Sweeps expired pending attachment rows (ADR 0039 phase 4+5).

  Agents calling `attachment.upload_start` reserve a row in `state: :pending`
  with an `upload_expires_at` timestamp. If the agent never POSTs the bytes,
  the row lingers and the storage key (if any) takes up space. This GenServer
  ticks every 5 minutes and deletes any `:pending` row whose expiry is in the
  past, plus its storage key.
  """

  use GenServer

  require Logger

  alias Platform.Chat.Attachment
  alias Platform.Chat.AttachmentStorage
  alias Platform.Repo

  import Ecto.Query, only: [from: 2]

  @tick_interval_ms 5 * 60 * 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Run one sweep synchronously. Returns the number of rows deleted."
  @spec sweep() :: non_neg_integer()
  def sweep, do: do_sweep()

  @impl true
  def init(_opts) do
    schedule_next_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    count = do_sweep()

    if count > 0 do
      Logger.info("[attachment_reaper] swept #{count} expired pending row(s)")
    end

    schedule_next_tick()
    {:noreply, state}
  end

  defp schedule_next_tick, do: Process.send_after(self(), :tick, @tick_interval_ms)

  defp do_sweep do
    now = DateTime.utc_now()

    expired =
      Repo.all(
        from(a in Attachment,
          where:
            a.state == "pending" and not is_nil(a.upload_expires_at) and
              a.upload_expires_at < ^now,
          select: %{id: a.id, storage_key: a.storage_key}
        )
      )

    Enum.each(expired, fn %{id: id, storage_key: key} ->
      AttachmentStorage.delete(key)
      Repo.delete(Repo.get(Attachment, id))
    end)

    length(expired)
  end
end
