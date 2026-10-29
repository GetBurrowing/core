defmodule PlatformWeb.SocialResultsTab do
  @moduledoc "Measured results for freshly authorized profiles, with no predicted scores."
  use PlatformWeb.SocialTab
  alias Platform.Social
  alias Platform.Social.{MetricCount, Results}
  alias PlatformWeb.SocialScope
  @impl true
  def enabled?, do: true
  @impl true
  def all_brands?, do: true
  @impl true
  def events, do: ~w(results_period results_expand results_recycle)
  @impl true
  def init(socket),
    do:
      assign(socket,
        results_period: 30,
        results_rows: [],
        results_accounts: [],
        results_candidates: [],
        results_expanded: MapSet.new(),
        results_notice: nil,
        weekly_note_query: %{}
      )

  @impl true
  def load(socket) do
    profiles = profiles(socket)
    accounts = Social.list_accounts_for_profiles(fresh_user(socket), Enum.map(profiles, & &1.id))

    account_results =
      Enum.map(accounts, fn a ->
        %{
          account: a,
          brand: Enum.find(profiles, &(&1.id == a.profile_id)).name,
          times: Results.best_times(a),
          count: Results.best_times_count(a),
          progress: Results.weekly_progress(a)
        }
      end)

    rows = Results.by_idea(profiles, socket.assigns.results_period)

    candidates =
      Enum.map(Results.recycle_candidates(profiles), fn c ->
        p = Enum.find(profiles, &(&1.id == c.profile_id))
        Map.put(c, :can_recycle?, approver?(socket, p))
      end)

    assign(socket,
      results_rows: rows,
      results_accounts: account_results,
      results_candidates: candidates,
      results_expanded:
        MapSet.intersection(socket.assigns.results_expanded, MapSet.new(rows, & &1.key))
    )
  end

  defp profiles(socket) do
    visible = if human?(fresh_user(socket)), do: SocialScope.visible_profiles(socket), else: []

    case socket.assigns[:scope] do
      :all -> visible
      {:profile, %{id: id}} -> Enum.filter(visible, &(&1.id == id))
      _ -> []
    end
  end

  defp approver?(socket, profile) do
    case fresh_user(socket) do
      %{id: id} = user ->
        human?(user) and Social.approver_check(profile.org_id, profile, id) == :ok

      _ ->
        false
    end
  end

  @impl true
  def handle_event("results_period", %{"period" => p}, s) when p in ["7", "30", "90"],
    do: {:noreply, s |> assign(:results_period, String.to_integer(p)) |> load()}

  def handle_event("results_expand", %{"key" => key}, s) do
    s = load(s)
    set = s.assigns.results_expanded

    set =
      if Enum.any?(s.assigns.results_rows, &(&1.key == key)),
        do: if(MapSet.member?(set, key), do: MapSet.delete(set, key), else: MapSet.put(set, key)),
        else: set

    {:noreply, assign(s, :results_expanded, set)}
  end

  def handle_event("results_recycle", %{"id" => id}, s) do
    profiles = profiles(s)

    result =
      with %{profile_id: pid} <-
             Enum.find(Results.recycle_candidates(profiles), &(&1.idea_id == id)),
           %{id: uid} = user <- fresh_user(s),
           true <- human?(user),
           %{org_id: org} <- Enum.find(profiles, &(&1.id == pid)) do
        scope = if Platform.Tenancy.visibility(user) == :root_all, do: :root, else: {:tenant, org}
        Results.recycle(scope, id, uid, profiles: profiles)
      else
        _ -> {:error, :not_found}
      end

    text =
      case result do
        {:ok, _} -> "New idea created in Inbox with the original versions as references."
        _ -> "This idea could not be recycled. Refresh your access and try again."
      end

    {:noreply, s |> assign(:results_notice, text) |> load()}
  end

  def handle_event(_, _, s), do: {:noreply, load(s)}
  @impl true
  def from_query(socket, query),
    do:
      assign(
        socket,
        :weekly_note_query,
        Map.take(query, ~w(profile profile_id weekly_note_week weekly_note_target))
      )

  @impl true
  def pane(assigns) do
    ~H"""
    <section
      data-role="social-results"
      class="space-y-6 bg-base-100 text-sm text-base-content [font-family:'Public_Sans',sans-serif]"
    >
      <.live_component
        module={PlatformWeb.SocialWeeklyNote}
        id="social-weekly-notes"
        user={@user}
        scope={@scope}
        query={@weekly_note_query}
      />
      <div class="flex flex-wrap items-center justify-between gap-4">
        <div class="join" role="group" aria-label="Results period">
          <button
            :for={p <- [7, 30, 90]}
            type="button"
            phx-click="results_period"
            phx-value-period={p}
            aria-pressed={to_string(@results_period == p)}
            class={[
              "btn btn-sm join-item",
              if(@results_period == p, do: "btn-neutral", else: "btn-ghost")
            ]}
          >
            {p}d
          </button>
        </div>
        <div class="flex flex-wrap gap-x-5 gap-y-3" aria-label="Weekly posting goals">
          <div
            :for={i <- @results_accounts}
            class="flex items-center gap-2"
            data-role="results-account"
          >
            <div class="relative flex size-10 shrink-0 items-center justify-center">
              <svg
                :if={i.progress}
                viewBox="0 0 40 40"
                class="absolute inset-0 size-10 -rotate-90"
                aria-hidden="true"
                data-role="goal-ring"
              >
                <circle cx="20" cy="20" r="18" fill="none" class="stroke-base-300" stroke-width="2" />
                <circle
                  cx="20"
                  cy="20"
                  r="18"
                  fill="none"
                  class="stroke-primary"
                  stroke-width="2"
                  pathLength="100"
                  stroke-dasharray={"#{goal_percent(i.progress)} 100"}
                />
              </svg>
              <span
                class="flex size-8 items-center justify-center rounded-full bg-base-200 text-xs text-neutral dark:text-neutral-content"
                aria-label={platform_label(i.account.platform)}
              >
                {initial(platform_label(i.account.platform))}
              </span>
            </div>
            <div>
              <p class="text-neutral dark:text-neutral-content">
                {platform_label(i.account.platform)} <span class="text-xs">{i.account.handle}</span>
              </p>
              <p :if={@scope == :all} class="text-xs text-neutral dark:text-neutral-content">
                {i.brand}
              </p>
              <p
                :if={i.progress}
                class="font-mono tabular-nums text-xs text-base-content"
                data-role="goal-label"
              >
                {i.progress.published} of {i.progress.goal} this week
              </p>
            </div>
          </div>
        </div>
      </div>
      <p
        :if={@results_notice}
        role="status"
        class="rounded-lg border border-base-300 p-3 text-neutral dark:text-neutral-content"
      >
        {@results_notice}
      </p>
      <div :if={@results_accounts != []} class="space-y-2" data-role="best-times">
        <details
          :for={i <- @results_accounts}
          class="rounded-lg border border-base-300"
          id={"best-times-#{i.account.id}"}
        >
          <summary class="cursor-pointer px-4 py-3 text-neutral dark:text-neutral-content">
            Best times · {platform_label(i.account.platform)} {i.account.handle}<span :if={
              @scope == :all
            }> · {i.brand}</span>
          </summary>
          <div class="px-4 pb-4">
            <p :if={is_nil(i.times)} class="text-info" data-role="insufficient-posts">
              Not enough posts yet ({i.count}/10)
            </p>
            <div
              :if={i.times}
              class="overflow-x-auto"
              tabindex="0"
              aria-label={"Best posting times for #{i.account.handle}"}
            >
              <table class="w-full max-w-xl table-fixed text-xs" data-role="best-times-heatmap">
                <caption class="pb-3 text-left text-neutral dark:text-neutral-content">
                  {i.times.timezone} · own account data · intensity is mean engagement per post
                </caption>
                <thead>
                  <tr>
                    <th class="w-16 text-left font-normal text-neutral dark:text-neutral-content">
                      Hour
                    </th>
                    <th
                      :for={d <- days()}
                      class="pb-2 font-normal text-neutral dark:text-neutral-content"
                    >
                      {d}
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={h <- 0..21//3}>
                    <th class="py-1 text-left font-normal text-neutral dark:text-neutral-content">
                      {h}–{h + 3}
                    </th>
                    <td :for={d <- 1..7} class="p-0.5">
                      <div
                        tabindex="0"
                        title={cell_title(i.times, d, h)}
                        aria-label={cell_title(i.times, d, h)}
                        class="h-5 rounded-sm bg-base-200"
                      >
                        <div :if={bucket(i.times, d, h)} class={cell_class(i.times, d, h)}></div>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </details>
      </div>
      <div data-role="results-ideas" class="divide-y divide-base-300 border-y border-base-300">
        <p :if={@results_rows == []} class="py-8 text-center text-neutral dark:text-neutral-content">
          No published results in this period.
        </p>
        <article :for={r <- @results_rows} id={"result-#{r.key}"}>
          <button
            type="button"
            phx-click="results_expand"
            phx-value-key={r.key}
            aria-expanded={to_string(MapSet.member?(@results_expanded, r.key))}
            aria-controls={"versions-#{r.key}"}
            class="flex w-full items-center gap-3 py-4 text-left hover:bg-base-200/50 focus-visible:outline-2 focus-visible:outline-neutral"
          >
            <.icon
              name={
                if(MapSet.member?(@results_expanded, r.key),
                  do: "hero-chevron-down",
                  else: "hero-chevron-right"
                )
              }
              class="size-4 shrink-0 text-neutral dark:text-neutral-content"
            />
            <span class="min-w-0 flex-1">
              <span class="block min-w-0 truncate">
                {if(r.idea_id, do: r.title, else: "(no idea) #{r.title}")}
              </span>
              <span
                :if={@scope == :all}
                class="badge badge-sm badge-ghost mt-1 text-neutral dark:text-neutral-content"
              >
                {r.brand}
              </span>
            </span>
            <span class="shrink-0 whitespace-nowrap font-mono tabular-nums text-base-content">
              {count(r.engagement)} <span class="text-xs">eng · {length(r.versions)} vers</span>
            </span>
          </button>
          <div
            :if={MapSet.member?(@results_expanded, r.key)}
            id={"versions-#{r.key}"}
            class="mb-4 flex snap-x snap-mandatory gap-3 overflow-x-auto pb-2 sm:gap-0 sm:divide-x sm:divide-base-300"
            tabindex="0"
            aria-label={"Platform versions for #{r.title}"}
          >
            <section
              :for={v <- r.versions}
              class="w-[85%] min-w-[85%] shrink-0 snap-start rounded-lg border border-base-300 p-4 sm:w-auto sm:min-w-56 sm:flex-1 sm:rounded-none sm:border-0"
              data-role="result-version"
            >
              <div class="flex items-center justify-between gap-2">
                <h3 class="text-neutral dark:text-neutral-content">{platform_label(v.platform)}</h3>
                <a
                  :if={safe_link(v.external_url)}
                  href={safe_link(v.external_url)}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="link text-neutral dark:text-neutral-content"
                  aria-label={"Open live #{platform_label(v.platform)} post"}
                >
                  Live post ↗
                </a>
              </div>
              <p class="mt-1 text-xs text-neutral dark:text-neutral-content">
                {Calendar.strftime(v.published_at, "%b %-d %H:%M UTC")}
              </p>
              <p class="mt-3 h-5 text-neutral dark:text-neutral-content">
                <span :if={v.data_state == :no_data} data-role="no-data">No data yet</span>
              </p>
              <dl class="mt-3 space-y-1.5">
                <div
                  :for={m <- ~w(views likes comments shares saves reach)a}
                  class="flex justify-between gap-6"
                >
                  <dt class="text-neutral dark:text-neutral-content">{m}</dt>
                  <dd class="font-mono tabular-nums text-base-content" data-metric={m}>
                    {count(v.metrics[m])}
                  </dd>
                </div>
                <div class="flex justify-between gap-6 border-t border-base-300 pt-2">
                  <dt class="text-neutral dark:text-neutral-content">rate</dt>
                  <dd class="font-mono tabular-nums text-base-content" data-metric="rate">
                    {rate(v.engagement_rate)}
                  </dd>
                </div>
              </dl>
            </section>
          </div>
        </article>
      </div>
      <section aria-label="Recycle candidates" data-role="recycle-candidates">
        <h2 class="mb-3 text-sm font-medium">Recycle candidates</h2>
        <p :if={@results_candidates == []} class="text-neutral dark:text-neutral-content">
          No ideas ready to recycle yet.
        </p>
        <div
          :for={c <- @results_candidates}
          class="flex flex-col gap-3 border-b border-base-300 py-3 sm:flex-row sm:items-center sm:justify-between"
          id={"recycle-#{c.idea_id}"}
        >
          <div class="min-w-0">
            <p class="truncate">{c.title}</p>
            <p class="mt-1 text-xs text-neutral dark:text-neutral-content">
              <span class="font-mono tabular-nums text-base-content">{count(c.engagement)}</span>
              eng · {short_date(c.published_at)}
            </p>
          </div>
          <button
            :if={c.can_recycle?}
            type="button"
            phx-click="results_recycle"
            phx-value-id={c.idea_id}
            phx-disable-with="Creating idea…"
            class="btn btn-outline btn-secondary btn-sm shrink-0"
          >
            Recycle as new idea
          </button>
        </div>
      </section>
    </section>
    """
  end

  defp count(nil), do: "—"
  defp count(v), do: MetricCount.format(v)
  defp rate(nil), do: "—"
  defp rate(v), do: :erlang.float_to_binary(v * 100, decimals: 1) <> "%"
  defp goal_percent(%{goal: g, published: n}) when g > 0, do: min(100, n / g * 100)
  defp goal_percent(_), do: 0
  defp days, do: ~w(Mon Tue Wed Thu Fri Sat Sun)
  defp bucket(t, d, h), do: Enum.find(t.buckets, &(&1.weekday == d and &1.hour == h))

  defp cell_title(t, d, h) do
    prefix = "#{Enum.at(days(), d - 1)} #{h}–#{h + 3}: "

    case bucket(t, d, h) do
      nil -> prefix <> "No data yet"
      b -> prefix <> "#{b.engagement} eng / #{b.post_count} posts"
    end
  end

  defp cell_class(t, d, h) do
    b = bucket(t, d, h)
    max = t.buckets |> Enum.map(& &1.mean_engagement) |> Enum.max(fn -> 0 end)
    ratio = if max > 0, do: b.mean_engagement / max, else: 0

    opacity =
      cond do
        ratio >= 0.75 -> "opacity-100"
        ratio >= 0.5 -> "opacity-75"
        ratio >= 0.25 -> "opacity-50"
        true -> "opacity-25"
      end

    "h-full rounded-sm bg-primary " <> opacity
  end

  defp safe_link(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> url
      _ -> nil
    end
  end

  defp safe_link(_), do: nil
end
