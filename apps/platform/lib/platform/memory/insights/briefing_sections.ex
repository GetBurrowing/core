defmodule Platform.Memory.Insights.BriefingSections do
  @moduledoc """
  Runs optional extension sections without coupling the briefing to an extension.
  Sections may deliver even when insights are disabled or have no dreaming agent.

  ## Core providers (task 01a1ea5b stage 5)

  A core context that is not a build-time module contributes sections through
  the same contract (`t:Platform.Extension.briefing_section/0`) by being
  listed under

      config :platform, Platform.Memory.Insights.BriefingSections, providers: [...]

  Each provider implements `briefing_sections/0`, read per call, exactly as an
  extension's. The briefing never names a provider: Email's called-out email
  section (`Platform.Mail.Triage.BriefingSection`) is the core provider,
  configured in `config/config.exs`.
  Core providers run before extensions, and an extension section whose key a
  core provider already uses is dropped (logged), so keys stay unique.
  """
  require Logger
  alias Platform.Access.Scope
  alias Platform.Memory.Insights.Briefings

  @doc """
  Every section on the briefing: core providers' first, then extensions'.
  Read per call; an empty provider list and no extensions is `[]` with no
  query.
  """
  @spec all() :: [Platform.Extension.briefing_section()]
  def all do
    core = Enum.flat_map(providers(), & &1.briefing_sections())
    taken = MapSet.new(core, & &1.key)

    extensions =
      Enum.reject(Platform.Extensions.briefing_sections(), fn section ->
        if MapSet.member?(taken, section.key) do
          Logger.warning(
            "briefing section #{section.key} is a core key; extension section dropped"
          )

          true
        end
      end)

    core ++ extensions
  end

  @doc "The configured core providers (`providers:`), read per call."
  @spec providers() :: [module()]
  def providers do
    :platform
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:providers, [])
  end

  def summaries(user_id, date) do
    Enum.flat_map(all(), fn section ->
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
    all()
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
