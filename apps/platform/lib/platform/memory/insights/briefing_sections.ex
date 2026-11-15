defmodule Platform.Memory.Insights.BriefingSections do
  @moduledoc """
  Runs optional extension sections without coupling the briefing to an extension.
  Sections may deliver even when insights are disabled or have no dreaming agent.
  """
  require Logger
  alias Platform.Access.Scope
  alias Platform.Memory.Insights.Briefings

  def summaries(user_id, date) do
    Enum.flat_map(Platform.Extensions.briefing_sections(), fn section ->
      safely(section.key, [], fn ->
        case section.summary.(user_id, date) do
          nil ->
            []

          %{total: 0} ->
            []

          %{total: total, open: open, calls: calls}
          when is_integer(total) and total > 0 and is_integer(open) and open >= 0 and
                 open <= total and is_integer(calls) and calls >= 0 and calls <= open ->
            [
              %{
                key: section.key,
                component: section.component,
                total: total,
                open: open,
                calls: calls
              }
            ]

          other ->
            raise ArgumentError, "invalid section summary: #{inspect(other)}"
        end
      end)
    end)
  end

  def for_view(%{user_id: id, digest_date: date}, %Scope{actor: %{id: id}} = scope) do
    if Scope.guest?(scope), do: [], else: summaries(id, date)
  end

  def for_view(_, _), do: []

  def prepare(user_id, date) do
    Platform.Extensions.briefing_sections()
    |> Enum.map(fn section ->
      safely(section.key, 0, fn ->
        case section.prepare.(user_id, date) do
          n when is_integer(n) and n >= 0 -> n
          other -> raise ArgumentError, "invalid section prepare result: #{inspect(other)}"
        end
      end)
    end)
    |> Enum.sum()
  end

  def changed(user_id, date) do
    case Briefings.for_user_on(user_id, date) do
      nil ->
        :ok

      briefing ->
        user = Platform.Accounts.get_user(user_id)
        counts = Briefings.view(briefing, Scope.for_user(user)).counts

        Platform.Inbox.upsert_briefing_item(briefing, %{
          total: counts.total,
          calls: counts.calls,
          body: Platform.Inbox.briefing_summary(counts),
          new_items?: false
        })

        :ok
    end
  end

  defp safely(key, fallback, fun) do
    fun.()
  rescue
    error ->
      Logger.warning("briefing section #{key} failed: #{Exception.message(error)}")
      fallback
  catch
    kind, _reason ->
      Logger.warning("briefing section #{key} failed: #{kind}")
      fallback
  end
end

