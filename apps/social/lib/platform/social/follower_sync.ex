defmodule Platform.Social.FollowerSync do
  @moduledoc """
  One bounded follower read per org on the existing analytics sweep. The org
  sync row serializes workers; profile/account rows are re-read under locks
  before requesting or writing. Durable hourly success checks and retry
  deadlines preserve prior observations through errors and restarts.
  """
  import Ecto.Query
  alias Platform.Repo
  alias Platform.Social.{Account, AccountTicker, FollowerSyncState, Profile}
  alias Platform.Social.Analytics.{Backoff, SyncState, Zernio}

  @doc "One due account, at most one request. No scheduler or ordinary dev/test startup of its own."
  def sync_org(org_id, opts \\ []) do
    if Platform.UUID.valid?(org_id) do
      now = Keyword.get(opts, :now, DateTime.utc_now())

      Repo.transaction(
        fn ->
          Repo.insert!(%SyncState{org_id: org_id}, on_conflict: :nothing)

          org_state =
            Repo.one!(from(s in SyncState, where: s.org_id == ^org_id, lock: "FOR UPDATE NOWAIT"))

          if org_state.retry_at && DateTime.compare(org_state.retry_at, now) == :gt do
            :deferred
          else
            refresh_due(org_id, org_state, now, opts)
          end
        end,
        timeout: 60_000
      )
    else
      {:error, :not_found}
    end
  rescue
    error in Postgrex.Error ->
      if match?(%{code: :lock_not_available}, error.postgres),
        do: {:ok, :busy},
        else: reraise(error, __STACKTRACE__)
  end

  defp eligible(query) do
    from(a in query,
      where:
        a.provider == "zernio" and a.status == "connected" and
          is_nil(a.archived_at) and a.platform != "linkedin" and
          not is_nil(a.provider_account_ref) and a.provider_account_ref != ""
    )
  end

  defp refresh_due(org_id, org_state, now, opts) do
    candidate =
      Account
      |> eligible()
      |> join(:inner, [a], p in Profile, on: p.id == a.profile_id)
      |> join(:left, [a, _], s in FollowerSyncState, on: s.account_id == a.id)
      |> where(
        [_, p, _],
        p.org_id == ^org_id and not is_nil(p.provider_profile_ref) and
          p.provider_profile_ref != ""
      )
      |> where(
        [a, _, s],
        is_nil(s.account_id) or s.provider_account_ref != a.provider_account_ref or
          is_nil(s.next_attempt_at) or s.next_attempt_at <= ^now
      )
      |> order_by([a, _, s], asc_nulls_first: s.attempted_at, asc: a.id)
      |> limit(1)
      |> Repo.one()

    if candidate do
      # Persisted candidate IDs came from the org-scoped eligibility query.
      profile =
        Repo.one(
          from(p in Profile,
            where: p.id == ^candidate.profile_id and p.org_id == ^org_id,
            lock: "FOR SHARE NOWAIT"
          )
        )

      account =
        Account
        |> eligible()
        |> where([a], a.id == ^candidate.id and a.profile_id == ^candidate.profile_id)
        |> lock("FOR SHARE NOWAIT")
        |> Repo.one()

      if profile && account && is_binary(profile.provider_profile_ref) &&
           profile.provider_profile_ref != "" do
        fetch(account, org_state, now, opts)
      else
        :idle
      end
    else
      :idle
    end
  end

  defp fetch(account, org_state, now, opts) do
    Repo.insert!(
      %FollowerSyncState{
        account_id: account.id,
        provider_account_ref: account.provider_account_ref
      },
      on_conflict: :nothing
    )

    state =
      Repo.one!(
        from(s in FollowerSyncState,
          where: s.account_id == ^account.id,
          lock: "FOR UPDATE NOWAIT"
        )
      )

    state =
      if state.provider_account_ref != account.provider_account_ref do
        state
        |> Ecto.Changeset.change(
          provider_account_ref: account.provider_account_ref,
          succeeded_at: nil,
          attempted_at: nil,
          next_attempt_at: nil,
          last_error: nil,
          source_stale: false,
          stale_since: nil
        )
        |> Repo.update!()
      else
        state
      end

    [[available?]] = Repo.query!("SELECT pg_try_advisory_xact_lock(734002911)").rows

    if available? do
      if Backoff.deadline(now), do: :deferred, else: request(account, state, org_state, now, opts)
    else
      :busy
    end
  end

  defp request(account, state, org_state, now, opts) do
    Process.sleep(max(Keyword.get(opts, :pace_ms, 1_100), 0))
    finish = DateTime.to_date(now)

    result =
      Zernio.account_followers(account.provider_account_ref,
        from_date: Date.add(finish, -89),
        to_date: finish
      )

    with {:ok, page} <- result,
         {:ok, count} <- AccountTicker.record(account, page, now) do
      state
      |> Ecto.Changeset.change(
        provider_account_ref: account.provider_account_ref,
        attempted_at: now,
        succeeded_at: now,
        next_attempt_at: DateTime.add(now, 3600),
        last_error: nil,
        source_stale: page.stale,
        stale_since: page.stale_since
      )
      |> Repo.update!()

      {:refreshed, count}
    else
      {:error, reason} -> failed(account, state, org_state, reason, now)
    end
  end

  defp failed(account, state, org_state, reason, now) do
    {label, delay} =
      case reason do
        {:retry_after, _, seconds} -> {:rate_limited, seconds}
        {:transport, _} -> {:transport, 60}
        {:http_status, _} -> {:http_error, 60}
        :identity_mismatch -> {:identity_mismatch, 60}
        :credentials_unavailable -> {:credentials_unavailable, 60}
        _ -> {:invalid_response, 60}
      end

    retry_at = DateTime.add(now, delay)

    state
    |> Ecto.Changeset.change(
      provider_account_ref: account.provider_account_ref,
      attempted_at: now,
      next_attempt_at: retry_at,
      last_error: Atom.to_string(label)
    )
    |> Repo.update!()

    if match?({:retry_after, _, _}, reason),
      do:
        org_state
        |> Ecto.Changeset.change(retry_at: retry_at, provider_retry_at: retry_at)
        |> Repo.update!()

    {:failed, label}
  end
end
