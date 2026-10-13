defmodule Platform.Prototypes.Purger do
  @moduledoc """
  Retention for prototype versions (ADR 0057 Decision 5). Mirrors
  `Platform.Files.Purger`: a daily `send_after` GenServer whose work is a
  synchronous `sweep/1` tests call directly.

  A sweep removes every version older than `Settings.retention_days` that is
  NOT its prototype's `latest_version` (the pointer, so a version a rollback
  pointed back at is kept however old it is). `retention_days: nil` keeps
  everything. Removing a version means setting `removed_at` (the row stays,
  so its number is never reused and the server answers 404 for it) and
  deleting its bytes.

  Each version is removed in its own transaction: the row update re-asserts
  "still unremoved, still not latest" in the query, then the bytes are
  deleted. A version a concurrent rollback just made latest matches 0 rows
  and is skipped with its bytes untouched. A raise on one version is logged
  and skipped so it cannot starve the rest.

  CANVAS-OWNED prototypes (a `scripts: true` embed, task 01a1316b-677a) are
  exempt while their canvas exists and is not soft-deleted: every version is
  kept, because the canvas's own version history and `canvas.restore` point
  at old ones. Growth is bounded by 256 KB (the embed `srcdoc` cap) per
  distinct HTML edit. Once the canvas is soft-deleted, or hard-deleted (the
  FK nilifies `canvas_id`), the ordinary rule above applies. That exemption
  is the one `retainable/0` clause both queries below share.

  Disabled in `config/test.exs` (`:start_prototype_purger false`).
  """

  use GenServer

  require Logger

  import Ecto.Query, only: [from: 2, dynamic: 2]

  alias Platform.Prototypes.Prototype
  alias Platform.Prototypes.Settings
  alias Platform.Prototypes.Storage
  alias Platform.Prototypes.Version
  alias Platform.Repo

  @tick_interval_ms 24 * 60 * 60 * 1000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Run one sweep synchronously. Returns `{:ok, removed_count}`.

  Options: `:now` (a `DateTime`, default now) for tests.
  """
  @spec sweep(keyword()) :: {:ok, non_neg_integer()}
  def sweep(opts \\ []) do
    case Settings.get().retention_days do
      nil ->
        {:ok, 0}

      days ->
        now = Keyword.get(opts, :now, DateTime.utc_now())
        cutoff = DateTime.add(now, -days, :day)

        removed =
          cutoff
          |> candidates()
          |> Enum.count(&(remove_one(&1, cutoff, now) == :removed))

        Logger.info("[prototype_purger] removed #{removed} prototype version(s) past retention")
        {:ok, removed}
    end
  end

  @impl true
  def init(_opts) do
    schedule_next_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    {:ok, _} = sweep()
    schedule_next_tick()
    {:noreply, state}
  end

  defp schedule_next_tick, do: Process.send_after(self(), :tick, @tick_interval_ms)

  defp candidates(cutoff) do
    Repo.all(
      from(v in Version,
        join: p in Prototype,
        on: p.id == v.prototype_id,
        where: is_nil(v.removed_at) and v.inserted_at < ^cutoff,
        where: v.version != p.latest_version,
        where: ^retainable(),
        order_by: [asc: v.inserted_at]
      )
    )
  end

  # Not owned by a live canvas. With `canvas_id` NULL the subquery matches no
  # row, so an ordinary prototype always passes. Raw table name on purpose:
  # this context does not depend on `Platform.Chat`'s schemas.
  defp retainable do
    dynamic(
      [_v, p],
      fragment(
        "NOT EXISTS (SELECT 1 FROM chat_canvases c WHERE c.id = ? AND c.deleted_at IS NULL)",
        p.canvas_id
      )
    )
  end

  defp remove_one(%Version{} = version, cutoff, now) do
    Repo.transaction(fn ->
      {count, _} =
        Repo.update_all(
          from(v in Version,
            join: p in Prototype,
            on: p.id == v.prototype_id,
            where: v.id == ^version.id and is_nil(v.removed_at) and v.inserted_at < ^cutoff,
            where: v.version != p.latest_version,
            where: ^retainable()
          ),
          set: [removed_at: now]
        )

      if count == 1 do
        Enum.each(version.manifest, fn %{"storage_key" => key} ->
          case Storage.delete(key) do
            :ok -> :ok
            other -> Repo.rollback({:storage_delete_failed, other})
          end
        end)
      else
        Repo.rollback(:stale)
      end
    end)
    |> case do
      {:ok, _} ->
        :removed

      {:error, reason} ->
        Logger.warning("[prototype_purger] version #{version.id} skipped: #{inspect(reason)}")

        :skipped
    end
  rescue
    error ->
      Logger.error(
        "[prototype_purger] removing version #{version.id} crashed, skipped: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :skipped
  end
end
