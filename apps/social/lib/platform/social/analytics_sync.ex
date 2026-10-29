defmodule Platform.Social.AnalyticsSync do
  @moduledoc """
  Bounded analytics polling, disabled outside production unless opted in.
  A locked SyncState row serializes each org across workers. Each request,
  absolute snapshots and cursor/checkpoint commit together; a crash rolls
  them all back. Capture the feed cursor BEFORE the historical baseline.

  Analytics postId differs from publisher latePostId. Only a matching
  baseline can establish analytics_external_id. Delta requires this ID, platform post, account, profile and org. Feed
  order wins even when syncedAt goes backwards. Empty pages persist both
  nextCursor and the prior request position, replayed for settling writes.
  Retry deadlines survive restarts, with no immediate network retry.
  """
  use GenServer
  import Ecto.Query
  alias Platform.Repo
  alias Platform.Social.{Account, Post, Profile}
  alias Platform.Social.Analytics.{SyncState, Zernio}

  @interval 60_000
  @pace 1_100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @impl true
  def init(opts) do
    defaults = [start: Application.get_env(:platform, :env) == :prod]
    configured = Keyword.merge(defaults, Application.get_env(:social, :analytics_sync, []))
    opts = Keyword.merge(configured, opts)
    if opts[:start] == true and Keyword.get(opts, :boot_sweep, true), do: send(self(), :sweep)
    {:ok, opts}
  end

  @impl true
  def handle_info(:sweep, opts) do
    if opts[:start] == true do
      for org <- connected_orgs(), do: sync_org(org, opts)
      Process.send_after(self(), :sweep, Keyword.get(opts, :interval_ms, @interval))
    end

    if opts[:notify], do: send(opts[:notify], {:analytics_swept, self()})
    {:noreply, opts}
  end

  @doc "Explicit bounded work for one org; never an ordinary dev/test startup hook."
  def sync_org(org_id, opts \\ []) do
    Enum.reduce_while(1..max(Keyword.get(opts, :max_requests, 10), 1), :ok, fn _, _ ->
      case step(org_id, opts) do
        {:ok, :more} -> {:cont, :ok}
        {:ok, result} -> {:halt, {:ok, result}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp connected_orgs do
    Repo.all(
      from(a in Account,
        join: p in Profile,
        on: p.id == a.profile_id,
        where: a.provider == "zernio" and a.status == "connected" and is_nil(a.archived_at),
        distinct: true,
        select: p.org_id
      )
    )
  end

  defp posts(org_id) do
    from(po in Post,
      join: a in Account,
      on: po.account_id == a.id,
      join: p in Profile,
      on: a.profile_id == p.id,
      where:
        p.org_id == ^org_id and a.provider == "zernio" and a.status == "connected" and
          is_nil(a.archived_at) and po.status == "published" and
          not is_nil(po.external_id) and po.external_id != "" and
          not is_nil(po.platform_post_id) and po.platform_post_id != "" and
          not is_nil(a.provider_account_ref) and a.provider_account_ref != "" and
          not is_nil(p.provider_profile_ref) and p.provider_profile_ref != "",
      select: {po, a, p}
    )
  end

  defp step(org_id, opts) do
    Repo.transaction(
      fn ->
        Repo.insert!(%SyncState{org_id: org_id}, on_conflict: :nothing)
        state = Repo.one!(from(s in SyncState, where: s.org_id == ^org_id, lock: "FOR UPDATE"))

        if state.retry_at && DateTime.compare(state.retry_at, DateTime.utc_now()) == :gt,
          do: :deferred,
          else: do_step(state, opts)
      end,
      timeout: 60_000
    )
  end

  defp do_step(%{cursor: nil} = state, opts) do
    case request(fn -> Zernio.delta() end, opts) do
      {:ok, page} ->
        save(state,
          cursor: page.next_cursor,
          replay_cursor: nil,
          cursor_captured_at: DateTime.utc_now(),
          bootstrap_after_post_id: nil,
          bootstrap_complete: false,
          retry_at: nil
        )

        :more

      {:error, reason} ->
        defer(state, reason)
    end
  end

  defp do_step(state, opts) do
    query = posts(state.org_id)

    query =
      if state.bootstrap_complete do
        from([po, _, _] in query, where: is_nil(po.analytics_external_id))
      else
        if state.bootstrap_after_post_id do
          from([po, _, _] in query, where: po.id > ^state.bootstrap_after_post_id)
        else
          query
        end
      end

    case Repo.one(from([po, _, _] in query, order_by: po.id, limit: 1)) do
      nil ->
        state =
          if state.bootstrap_complete, do: state, else: save(state, bootstrap_complete: true)

        delta(state, opts)

      {post, account, _profile} ->
        baseline(state, post, account, opts)
    end
  end

  defp baseline(state, post, account, opts) do
    case request(fn -> Zernio.post(post.external_id) end, opts) do
      {:ok, result} ->
        if result.late_post_id == post.external_id or result.post_id == post.external_id do
          for snapshot <- result.data,
              snapshot.post_id == result.post_id,
              snapshot.account_id == account.provider_account_ref,
              snapshot.platform == vendor_platform(account.platform),
              snapshot.platform_post_id == post.platform_post_id do
            write_metrics(post, snapshot, analytics_external_id: result.post_id)
          end
        end

        if is_nil(Repo.get!(Post, post.id).analytics_external_id) do
          defer(state, :baseline_pending)
        else
          unless state.bootstrap_complete,
            do: save(state, bootstrap_after_post_id: post.id, retry_at: nil)

          :more
        end

      {:error, reason} ->
        defer(state, reason)
    end
  end

  defp delta(state, opts) do
    cursor = state.replay_cursor || state.cursor

    case request(fn -> Zernio.delta(cursor) end, opts) do
      {:ok, page} ->
        for snapshot <- page.data, not snapshot.deleted? do
          query =
            from([po, a, p] in posts(state.org_id),
              where:
                po.analytics_external_id == ^snapshot.post_id and
                  po.platform_post_id == ^snapshot.platform_post_id and
                  a.platform == ^local_platform(snapshot.platform) and
                  a.provider_account_ref == ^snapshot.account_id and
                  p.provider_profile_ref == ^snapshot.profile_id
            )

          for {post, _, _} <- Repo.all(query), do: write_metrics(post, snapshot)
        end

        save(state,
          cursor: page.next_cursor,
          replay_cursor: if(page.data == [], do: cursor),
          retry_at: nil
        )

        if page.has_more and page.data != [], do: :more, else: :caught_up

      {:error, {:http_status, 400}} ->
        # Zernio documents expired cursors as 400; take a fresh cursor first.
        save(state,
          cursor: nil,
          replay_cursor: nil,
          bootstrap_complete: false,
          bootstrap_after_post_id: nil,
          retry_at: nil
        )

        :more

      {:error, reason} ->
        defer(state, reason)
    end
  end

  defp local_platform("twitter"), do: "x"
  defp local_platform(platform), do: platform
  defp vendor_platform("x"), do: "twitter"
  defp vendor_platform(platform), do: platform

  defp write_metrics(post, snapshot, extra \\ []) do
    post
    |> Ecto.Changeset.change(
      [metrics: snapshot.metrics, metrics_synced_at: snapshot.synced_at] ++ extra
    )
    |> Repo.update!()
  end

  defp save(state, changes), do: state |> Ecto.Changeset.change(changes) |> Repo.update!()

  defp defer(state, reason) do
    seconds =
      case reason do
        {:retry_after, _, seconds} when is_integer(seconds) -> max(seconds, 1)
        _ -> 60
      end

    save(state, retry_at: DateTime.add(DateTime.utc_now(), seconds, :second))
    {:deferred, reason}
  end

  defp request(fun, opts) do
    # Install-wide lock spaces analytics requests across orgs and nodes.
    Repo.query!("SELECT pg_advisory_xact_lock(734002911)")
    Process.sleep(max(Keyword.get(opts, :pace_ms, @pace), 0))
    fun.()
  end
end
