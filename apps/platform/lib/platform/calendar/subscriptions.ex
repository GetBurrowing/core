defmodule Platform.Calendar.Subscriptions do
  @moduledoc "Owner-scoped external snapshots. Failed/stale coverage cannot assert availability."
  import Ecto.Query
  alias Platform.{Access, Repo}
  alias Platform.Access.Scope
  alias Platform.Accounts.User
  alias Platform.Calendar.{Subscription, ExternalFetch, ICal, Recurrence}
  @fresh_seconds 3600

  def list(%Scope{actor: %User{id: id}} = scope) do
    if Access.can?(scope, "calendar.read"),
      do: Repo.all(from(s in Subscription, where: s.owner_id == ^id, order_by: s.inserted_at)),
      else: []
  end

  def list(_), do: []

  def create(%Scope{actor: %User{id: id}} = scope, attrs) do
    with :ok <- Access.authorize(scope, "calendar.write"),
         do: Repo.insert(Subscription.changeset(%Subscription{owner_id: id}, attrs))
  end

  def create(_, _), do: {:error, :forbidden}

  def delete(scope, id) do
    with {:ok, row} <- owned(scope, id),
         :ok <- Access.authorize(scope, "calendar.write"),
         do: Repo.delete(row)
  end

  def refresh(scope, id) do
    with {:ok, row} <- owned(scope, id),
         :ok <- Access.authorize(scope, "calendar.write"),
         do: refresh_row(row)
  end

  defp owned(scope, id) do
    case Enum.find(list(scope), &(&1.id == id)) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  def fresh?(row),
    do:
      is_nil(row.error) and not is_nil(row.refreshed_at) and
        DateTime.diff(DateTime.utc_now(), row.refreshed_at) < @fresh_seconds

  def refresh_row(%Subscription{} = row) do
    # Lock and re-read before fetching so an old job cannot overwrite newer state
    # or resurrect a deleted subscription. URL changes are intentionally unsupported.
    Repo.transaction(fn ->
      case Repo.one(from(s in Subscription, where: s.id == ^row.id, lock: "FOR UPDATE")) do
        nil ->
          Repo.rollback(:not_found)

        current ->
          now = DateTime.utc_now()

          changes =
            case ExternalFetch.fetch(current.url) do
              {:ok, body} ->
                case ICal.parse(body) do
                  {:ok, snapshot} ->
                    [snapshot: snapshot, refreshed_at: now, attempted_at: now, error: nil]

                  {:error, _} ->
                    [
                      attempted_at: now,
                      error: "Unsupported or malformed calendar; availability unknown"
                    ]
                end

              {:error, _} ->
                [attempted_at: now, error: "Refresh failed; availability unknown"]
            end

          updated = current |> Ecto.Changeset.change(changes) |> Repo.update!()

          Phoenix.PubSub.broadcast(
            Platform.PubSub,
            "calendar:#{updated.owner_id}",
            {:calendar_changed, updated.id}
          )

          updated
      end
    end)
  end

  def entries(scope, from, to) do
    list(scope)
    |> Enum.flat_map(fn sub ->
      Enum.flat_map(sub.snapshot, fn row ->
        ICal.event(row, sub.id)
        |> Recurrence.occurrences(from, to)
        |> Enum.map(fn event ->
          %{
            kind: :external,
            id: event.id,
            event: event,
            title: event.title,
            starts_at: event.starts_at,
            ends_at: event.ends_at,
            all_day: event.all_day,
            subscription: sub.name,
            stale: not fresh?(sub),
            transparent: row["transparent"]
          }
        end)
      end)
    end)
  end

  def availability(scope, from, to) do
    cond do
      not Access.can?(scope, "calendar.read") ->
        {:error, :forbidden}

      DateTime.compare(from, to) != :lt or DateTime.diff(to, from) > 366 * 86400 ->
        {:error, :invalid_window}

      Enum.any?(list(scope), &(not fresh?(&1))) ->
        {:error, :external_coverage_unknown}

      true ->
        native =
          Platform.Calendar.list_entries(scope, from, to)
          |> Enum.reject(fn
            %{kind: :external, transparent: true} ->
              true

            %{kind: :meeting, meeting: %{status: status}} when status in ["cancelled", "ended"] ->
              true

            _ ->
              false
          end)

        {:ok,
         Enum.map(
           native,
           &%{starts_at: &1.starts_at, ends_at: &1.ends_at || DateTime.add(&1.starts_at, 1800)}
         )}
    end
  end
end
