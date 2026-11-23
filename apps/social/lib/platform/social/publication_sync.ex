defmodule Platform.Social.PublicationSync do
  @moduledoc """
  One list read per durable org allowance, committed before the request.
  The subsequent SyncState-first request transaction intentionally holds
  row and advisory locks through pacing, HTTP and persistence. Existing
  install-wide Retry-After is shared through the org analytics SyncState.
  """
  import Ecto.Query
  alias Platform.Repo
  alias Platform.Social.{Account, Profile, Secrets}

  alias Platform.Social.Analytics.{
    AccountScope,
    Backoff,
    Publication,
    PublicationCoverage,
    PublicationOrgBudget,
    PublicationSyncState,
    Publications,
    SyncState,
    Zernio
  }

  @doc "Current installation opt-in; callers cannot override it through request options."
  def enabled?, do: Application.get_env(:social, :youtube_publications_enabled, false) == true

  def step(org_id, opts \\ []) do
    cond do
      not enabled?() ->
        {:ok, :disabled}

      Repo.in_transaction?() ->
        {:error, :transaction_context}

      not Platform.UUID.valid?(org_id) ->
        {:error, :not_found}

      true ->
        # Read metadata only before reservation/try-locks. The client resolves
        # the actual credential after the shared request lock is acquired.
        case Secrets.zernio_key_status() do
          {:set, _} -> run(org_id, opts)
          _ -> {:ok, :idle}
        end
    end
  end

  @doc "Invalidate only derived list work after the connection writer holds its profile/account locks."
  def invalidate_connection!(%Account{id: account_id}) do
    Repo.update_all(from(s in PublicationSyncState, where: s.account_id == ^account_id),
      set: [
        cursor: nil,
        query_hash: nil,
        scan_id: nil,
        scan_started_at: nil,
        completed_at: nil,
        checked_from: nil,
        checked_to: nil,
        checked_ranges: [],
        incomplete_ranges: [],
        coverage_repaired_at: nil,
        from_date: nil,
        to_date: nil,
        last_attempt_token: Ecto.UUID.generate(),
        next_attempt_at: nil,
        seen_cursors: [],
        window_index: 0,
        history_incomplete: false,
        history_exhausted: false
      ]
    )

    Repo.update_all(from(v in Publication, where: v.account_id == ^account_id),
      set: [source_stale: true]
    )

    :ok
  end

  defp run(org_id, opts) do
    result =
      case transaction(fn -> reserve(org_id, opts) end) do
        {:ok, %{binding: _} = reservation} -> transaction(fn -> request(reservation, opts) end)
        other -> other
      end

    case result do
      {:error, :disabled} ->
        {:ok, :disabled}

      {:error, reason} when reason in [:provider_deferred, :allowance_deferred] ->
        {:ok, :deferred}

      {:error, :provider_busy} ->
        {:ok, :busy}

      other ->
        other
    end
  end

  defp transaction(fun) do
    Repo.transaction(fun, timeout: 60_000)
  rescue
    error in Postgrex.Error ->
      if match?(%{code: :lock_not_available}, error.postgres),
        do: {:ok, :busy},
        else: reraise(error, __STACKTRACE__)
  end

  defp clock(opts), do: Keyword.get(opts, :clock, &DateTime.utc_now/0).()
  defp future?(nil, _), do: false
  defp future?(at, now), do: DateTime.compare(at, now) == :gt

  defp org_state!(org_id) do
    Repo.insert!(%SyncState{org_id: org_id}, on_conflict: :nothing)
    Repo.one!(from(s in SyncState, where: s.org_id == ^org_id, lock: "FOR UPDATE NOWAIT"))
  end

  defp budget!(org_id) do
    Repo.insert!(%PublicationOrgBudget{org_id: org_id}, on_conflict: :nothing)

    Repo.one!(
      from(b in PublicationOrgBudget, where: b.org_id == ^org_id, lock: "FOR UPDATE NOWAIT")
    )
  end

  defp eligible(org_id) do
    provider = AccountScope.provider_filter()

    from(a in Account,
      as: :analytics_account,
      join: p in Profile,
      on: p.id == a.profile_id,
      where: ^provider,
      where:
        p.org_id == ^org_id and a.platform == "youtube" and a.status == "connected" and
          is_nil(a.archived_at),
      where:
        not is_nil(a.provider_account_ref) and a.provider_account_ref != "" and
          not is_nil(p.provider_profile_ref) and p.provider_profile_ref != ""
    )
  end

  defp candidate(org_id, kind, last_id, now) do
    query =
      eligible(org_id)
      |> join(:left, [a], s in PublicationSyncState, on: s.account_id == a.id and s.kind == ^kind)
      |> where(
        [a, p, s],
        is_nil(s.id) or s.provider_account_ref != a.provider_account_ref or
          s.provider_profile_ref != p.provider_profile_ref or
          (is_nil(s.next_attempt_at) or s.next_attempt_at <= ^now)
      )

    query =
      if kind == "refresh" do
        query
        |> join(:inner, [a, p], v in Publication,
          on:
            v.account_id == a.id and v.profile_id == p.id and
              v.provider_account_ref == a.provider_account_ref and
              v.provider_profile_ref == p.provider_profile_ref
        )
        |> where([a, p, s, v], not v.not_listed and v.published_at <= ^now)
        |> distinct([a], a.id)
      else
        query
      end

    query = query |> order_by([a], asc: a.id) |> limit(1) |> select([a], a)

    if last_id do
      Repo.one(where(query, [a], a.id > ^last_id)) || Repo.one(query)
    else
      Repo.one(query)
    end
  end

  defp reserve(org_id, opts) do
    now = clock(opts)
    if Backoff.deadline(now), do: Repo.rollback(:provider_deferred)
    budget = budget!(org_id)
    if future?(budget.next_attempt_at, now), do: Repo.rollback(:allowance_deferred)

    kinds = [
      budget.next_kind,
      if(budget.next_kind == "discovery", do: "refresh", else: "discovery")
    ]

    chosen =
      Enum.find_value(kinds, fn kind ->
        if account = candidate(org_id, kind, budget.last_account_id, now), do: {account, kind}
      end)

    if chosen do
      {account, kind} = chosen

      profile =
        Repo.one!(from(p in Profile, where: p.id == ^account.profile_id and p.org_id == ^org_id))

      binding = binding(account, profile)

      state =
        Repo.one(
          from(s in PublicationSyncState, where: s.account_id == ^account.id and s.kind == ^kind)
        ) ||
          %PublicationSyncState{
            account_id: account.id,
            kind: kind,
            provider_account_ref: account.provider_account_ref,
            provider_profile_ref: profile.provider_profile_ref
          }

      encoded_binding = Map.new(binding, fn {key, value} -> {Atom.to_string(key), value} end)
      key = account.id <> ":" <> kind
      old = budget.reservations[key]

      {query, reset?, started_at} =
        case frozen(old, encoded_binding, state, now) do
          {:ok, query, started} ->
            {query, false, started}

          :new ->
            {query, reset?} = next_query(state, binding, now)
            {query, reset?, now}
        end

      token = Ecto.UUID.generate()

      reservation = %{
        binding: binding,
        query: query,
        token: token,
        basis: state.last_attempt_token,
        reset?: reset?,
        started_at: started_at
      }

      encoded = %{
        "binding" => encoded_binding,
        "query" => %{
          "kind" => query.kind,
          "from_date" => Date.to_iso8601(query.from_date),
          "to_date" => Date.to_iso8601(query.to_date),
          "cursor" => query.cursor
        },
        "query_hash" => Publications.query_hash(binding, query),
        "basis" => state.last_attempt_token,
        "started_at" => DateTime.to_iso8601(started_at),
        "token" => token
      }

      eligible_ids = Repo.all(eligible(org_id) |> select([a], a.id))

      reservations =
        Map.filter(budget.reservations, fn {_, value} ->
          get_in(value, ["binding", "account_id"]) in eligible_ids
        end)
        |> Map.put(key, encoded)

      budget
      |> Ecto.Changeset.change(
        next_attempt_at: DateTime.add(now, 60),
        last_account_id: account.id,
        next_kind: if(kind == "discovery", do: "refresh", else: "discovery"),
        reservations: reservations
      )
      |> Repo.update!()

      reservation
    else
      :idle
    end
  end

  defp frozen(
         %{"binding" => binding, "basis" => basis, "query" => query, "started_at" => started} =
           old,
         binding,
         state,
         now
       )
       when basis == state.last_attempt_token do
    with {:ok, first} <- Date.from_iso8601(query["from_date"]),
         {:ok, last} <- Date.from_iso8601(query["to_date"]),
         {:ok, started, _} <- DateTime.from_iso8601(started),
         true <- DateTime.diff(now, started) in 0..86_399,
         true <- query["kind"] == state.kind,
         normalized = %{
           kind: state.kind,
           from_date: first,
           to_date: last,
           cursor: query["cursor"]
         },
         b = %{
           account_id: binding["account_id"],
           profile_id: binding["profile_id"],
           provider_account_ref: binding["provider_account_ref"],
           provider_profile_ref: binding["provider_profile_ref"]
         },
         true <- old["query_hash"] == Publications.query_hash(b, normalized) do
      {:ok, normalized, started}
    else
      _ -> :new
    end
  end

  defp frozen(_, _, _, _), do: :new

  defp request(claim, opts) do
    org_state = org_state!(claim.binding.org_id)

    profile =
      Repo.one(
        from(p in Profile,
          where: p.id == ^claim.binding.profile_id and p.org_id == ^claim.binding.org_id,
          lock: "FOR SHARE NOWAIT"
        )
      )

    account =
      eligible(claim.binding.org_id)
      |> where(
        [a],
        a.id == ^claim.binding.account_id and a.profile_id == ^claim.binding.profile_id
      )
      |> select([a], a)
      |> lock("FOR SHARE NOWAIT")
      |> Repo.one()

    if is_nil(profile) or is_nil(account) or not Publications.valid_binding?(claim.binding),
      do: Repo.rollback(:binding_changed)

    state = state!(account, profile, claim.query.kind)
    if state.last_attempt_token != claim.basis, do: Repo.rollback(:stale_reservation)
    hash = Publications.query_hash(claim.binding, claim.query)

    if claim.query.cursor && (state.query_hash != hash or state.cursor != claim.query.cursor),
      do: Repo.rollback(:checkpoint_mismatch)

    continuing? =
      not claim.reset? and is_nil(state.completed_at) and not is_nil(state.scan_id) and
        state.query_hash == hash

    attrs = %{
      provider_account_ref: claim.binding.provider_account_ref,
      provider_profile_ref: claim.binding.provider_profile_ref,
      from_date: claim.query.from_date,
      to_date: claim.query.to_date,
      query_hash: hash,
      attempted_at: clock(opts)
    }

    attrs =
      if continuing?,
        do: attrs,
        else:
          Map.merge(attrs, %{
            scan_id: Ecto.UUID.generate(),
            scan_started_at: claim.started_at,
            scan_safe: true,
            seen_cursors: [],
            completed_at: nil
          })

    attrs =
      if claim.reset?,
        do:
          Map.merge(attrs, %{
            cursor: nil,
            window_index: 0,
            checked_from: nil,
            checked_to: nil,
            checked_ranges: [],
            incomplete_ranges: []
          }),
        else: attrs

    # A same-connection restart abandons coverage, not the repair warning.
    # Only a changed provider binding makes that provenance obsolete here.
    attrs =
      if state.provider_account_ref != claim.binding.provider_account_ref or
           state.provider_profile_ref != claim.binding.provider_profile_ref,
         do: Map.put(attrs, :coverage_repaired_at, nil),
         else: attrs

    attrs =
      if not continuing? and claim.query.kind == "discovery" and
           (claim.reset? or state.window_index == 0),
         do: Map.merge(attrs, %{history_incomplete: false, history_exhausted: false}),
         else: attrs

    state = state |> Ecto.Changeset.change(attrs) |> Repo.update!()
    [[available?]] = Repo.query!("SELECT pg_try_advisory_xact_lock(734002911)").rows
    unless available?, do: Repo.rollback(:provider_busy)
    if Backoff.deadline(clock(opts)), do: Repo.rollback(:provider_deferred)
    Process.sleep(max(Keyword.get(opts, :pace_ms, 1_100), 0))
    if Backoff.deadline(clock(opts)), do: Repo.rollback(:provider_deferred)

    # Disabling during lock acquisition or pacing must not admit HTTP.
    # A request already beyond the client's final check may still finish.
    unless enabled?(), do: Repo.rollback(:disabled)

    response =
      Zernio.publications(claim.binding.provider_account_ref,
        profile_ref: claim.binding.provider_profile_ref,
        from_date: claim.query.from_date,
        to_date: claim.query.to_date,
        cursor: claim.query.cursor
      )

    if response == {:error, :disabled}, do: Repo.rollback(:disabled)

    now = clock(opts)
    unless Publications.valid_binding?(claim.binding), do: Repo.rollback(:binding_changed)

    case response do
      {:error, {:retry_after, _, seconds}} ->
        deadline = DateTime.add(now, Backoff.delay(seconds))

        deadline =
          if future?(org_state.provider_retry_at, deadline),
            do: org_state.provider_retry_at,
            else: deadline

        org_state |> Ecto.Changeset.change(provider_retry_at: deadline) |> Repo.update!()

      _ ->
        :ok
    end

    apply_result(claim, state, response, now)
  end

  defp state!(account, profile, kind) do
    Repo.insert!(
      %PublicationSyncState{
        account_id: account.id,
        kind: kind,
        provider_account_ref: account.provider_account_ref,
        provider_profile_ref: profile.provider_profile_ref
      },
      on_conflict: :nothing,
      conflict_target: [:account_id, :kind]
    )

    Repo.one!(
      from(s in PublicationSyncState,
        where: s.account_id == ^account.id and s.kind == ^kind,
        lock: "FOR UPDATE NOWAIT"
      )
    )
  end

  defp binding(account, profile),
    do: %{
      org_id: profile.org_id,
      profile_id: profile.id,
      account_id: account.id,
      provider_account_ref: account.provider_account_ref,
      provider_profile_ref: profile.provider_profile_ref,
      platform: "youtube"
    }

  defp next_query(state, binding, now) do
    old = %{
      kind: state.kind,
      from_date: state.from_date,
      to_date: state.to_date,
      cursor: state.cursor
    }

    same? =
      state.provider_account_ref == binding.provider_account_ref and
        state.provider_profile_ref == binding.provider_profile_ref

    resumable? =
      same? and is_nil(state.completed_at) and not is_nil(state.from_date) and
        not is_nil(state.scan_started_at) and
        DateTime.diff(now, state.scan_started_at) < 86_400 and
        state.query_hash == Publications.query_hash(binding, old)

    if resumable? do
      {old, false}
    else
      reset? = not same? or (is_nil(state.completed_at) and not is_nil(state.scan_started_at))

      {first, last} =
        cond do
          state.kind == "refresh" ->
            video = Publications.latest(binding, now: now)
            if is_nil(video), do: Repo.rollback(:no_candidate)
            day = DateTime.to_date(video.published_at)
            {day, day}

          not reset? and state.window_index > 0 and not is_nil(state.from_date) ->
            {Date.add(state.from_date, -30), Date.add(state.to_date, -30)}

          true ->
            {Date.add(DateTime.to_date(now), -29), DateTime.to_date(now)}
        end

      {%{kind: state.kind, from_date: first, to_date: last, cursor: nil}, reset?}
    end
  end

  defp apply_result(claim, state, {:ok, page}, now) do
    case Publications.apply_locked_page(claim.binding, claim.query, page, now, state) do
      {:ok, stored} ->
        usable? = not is_nil(Publications.latest(claim.binding, now: now))

        backfill? =
          not page.has_more and claim.query.kind == "discovery" and
            not usable? and state.window_index < 11

        delay = if page.has_more or backfill?, do: 0, else: 3600

        stored
        |> Ecto.Changeset.change(
          last_attempt_token: claim.token,
          last_error: if(stored.scan_safe, do: nil, else: "incomplete_observation"),
          history_incomplete: state.history_incomplete or not stored.scan_safe,
          history_exhausted:
            not page.has_more and claim.query.kind == "discovery" and not usable? and
              state.window_index == 11,
          window_index:
            cond do
              page.has_more -> state.window_index
              backfill? -> state.window_index + 1
              true -> 0
            end,
          next_attempt_at: DateTime.add(now, delay)
        )
        |> Repo.update!()

        if page.has_more or backfill? or not stored.scan_safe, do: :incomplete, else: :refreshed

      {:error, reason} when reason in [:binding_changed, :checkpoint_mismatch] ->
        Repo.rollback(reason)

      {:error, reason} ->
        apply_result(claim, state, {:error, reason}, now)
    end
  end

  defp apply_result(claim, state, {:error, reason}, now) do
    {label, delay} =
      case reason do
        {:retry_after, _, seconds} ->
          {"rate_limited", Backoff.delay(seconds)}

        reason when reason in [:invalid_page, :invalid_response, :cursor_loop] ->
          {Atom.to_string(reason), 300}

        :invalid_ranges ->
          {"coverage_repaired", 300}

        :sync_pending ->
          {"pending", 300}

        :analytics_unavailable ->
          {"unavailable", 3600}

        {:http_status, 400} ->
          {"cursor_rejected", 300}

        _ ->
          {"refresh_failed", 300}
      end

    attrs = %{
      last_attempt_token: claim.token,
      last_error: label,
      next_attempt_at: DateTime.add(now, delay)
    }

    attrs =
      case PublicationCoverage.add(
             state.incomplete_ranges,
             claim.query.from_date,
             claim.query.to_date
           ) do
        ranges when is_list(ranges) -> Map.put(attrs, :incomplete_ranges, ranges)
        _ -> attrs
      end

    attrs =
      if label == "coverage_repaired" do
        # Retain attempted_at/from_date/to_date as the last request's
        # provenance, but invalidate every continuation and coverage claim.
        Map.merge(attrs, %{
          checked_ranges: [],
          incomplete_ranges: [],
          coverage_repaired_at: now,
          checked_from: nil,
          checked_to: nil,
          cursor: nil,
          seen_cursors: [],
          query_hash: nil,
          scan_id: nil,
          scan_started_at: nil,
          completed_at: nil,
          scan_safe: false,
          window_index: 0,
          history_incomplete: true,
          history_exhausted: false
        })
      else
        attrs
      end

    attrs =
      if label == "cursor_rejected" and claim.query.cursor,
        do:
          Map.merge(attrs, %{
            cursor: nil,
            seen_cursors: [],
            scan_id: Ecto.UUID.generate(),
            scan_started_at: now,
            scan_safe: true,
            completed_at: nil
          }),
        else: attrs

    state |> Ecto.Changeset.change(attrs) |> Repo.update!()
    :deferred
  end
end
