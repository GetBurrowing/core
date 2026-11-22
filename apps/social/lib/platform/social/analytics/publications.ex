defmodule Platform.Social.Analytics.Publications do
  @moduledoc "Atomic read-only list projection; callers separately authorize human display."
  import Ecto.Query
  alias Platform.Repo
  alias Platform.Social.{Account, Profile}

  alias Platform.Social.Analytics.{
    AccountScope,
    Publication,
    PublicationSyncState,
    PublicationCoverage
  }

  def valid_binding?(binding) do
    valid_ids? =
      Enum.all?([:org_id, :profile_id, :account_id], &Platform.UUID.valid?(binding[&1]))

    if valid_ids? and binding[:platform] == "youtube" and
         Enum.all?(
           [:provider_account_ref, :provider_profile_ref],
           &(is_binary(binding[&1]) and binding[&1] != "")
         ) do
      provider = AccountScope.provider_filter()

      Repo.exists?(
        from(a in Account,
          as: :analytics_account,
          join: p in Profile,
          on: p.id == a.profile_id,
          where: ^provider,
          where:
            a.id == ^binding.account_id and p.id == ^binding.profile_id and
              p.org_id == ^binding.org_id,
          where: a.status == "connected" and is_nil(a.archived_at) and a.platform == "youtube",
          where:
            a.provider_account_ref == ^binding.provider_account_ref and
              p.provider_profile_ref == ^binding.provider_profile_ref
        )
      )
    else
      false
    end
  end

  def latest(binding, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    if valid_binding?(binding) do
      binding
      |> rows()
      |> where([p], not p.not_listed and p.published_at <= ^now)
      |> order_by([p], desc: p.published_at, asc: p.native_id)
      |> limit(1)
      |> Repo.one()
    end
  end

  def query_hash(binding, query) do
    {binding.account_id, binding.profile_id, binding.provider_account_ref,
     binding.provider_profile_ref, "youtube", query.kind, query.from_date, query.to_date, "all",
     "published-desc", 50}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def apply_page(binding, query, page, now) do
    Repo.transaction(fn ->
      unless valid_binding?(binding), do: Repo.rollback(:binding_changed)
      state = state!(binding, query, now)

      case apply_locked_page(binding, query, page, now, state) do
        {:ok, stored} -> stored
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Validate before mutating a checkpoint already locked by the request transaction."
  def apply_locked_page(binding, query, page, now, state) do
    cond do
      not Repo.in_transaction?() ->
        {:error, :transaction_context}

      not valid_binding?(binding) ->
        {:error, :binding_changed}

      not valid_page?(query, page) ->
        {:error, :invalid_page}

      state.query_hash != query_hash(binding, query) or state.cursor != query.cursor or
        state.provider_account_ref != binding.provider_account_ref or
          state.provider_profile_ref != binding.provider_profile_ref ->
        {:error, :checkpoint_mismatch}

      page.next_cursor in state.seen_cursors ->
        {:error, :cursor_loop}

      true ->
        case coverage_changes(state, query, page, now) do
          {:error, _} = error -> error
          changes -> {:ok, persist_page(binding, query, page, now, state, changes)}
        end
    end
  end

  defp persist_page(binding, query, page, now, state, coverage) do
    complete_rows? =
      Enum.all?(page.data, fn row ->
        match?(%DateTime{}, row.published_at) and DateTime.compare(row.published_at, now) != :gt
      end)

    safe = state.scan_safe and page.stale == false and page.missing_ids == [] and complete_rows?
    Enum.each(page.data, &observe(binding, query, state.scan_id, &1, now, not safe))

    if not page.has_more and safe do
      start = DateTime.new!(query.from_date, ~T[00:00:00], "Etc/UTC")
      finish = DateTime.new!(Date.add(query.to_date, 1), ~T[00:00:00], "Etc/UTC")

      binding
      |> rows()
      |> where(
        [p],
        p.published_at >= ^start and p.published_at < ^finish and
          fragment("COALESCE(? ->> ?, '')", p.last_seen_scans, ^query.kind) != ^state.scan_id
      )
      |> Repo.update_all(set: [not_listed: true])
    end

    changes = %{
      cursor: page.next_cursor,
      scan_safe: safe,
      seen_cursors:
        if(page.next_cursor,
          do: [page.next_cursor | state.seen_cursors],
          else: state.seen_cursors
        )
    }

    changes = if page.has_more, do: changes, else: Map.put(changes, :completed_at, now)

    changes =
      if not page.has_more and safe,
        do: Map.merge(changes, %{checked_from: query.from_date, checked_to: query.to_date}),
        else: changes

    state |> Ecto.Changeset.change(Map.merge(changes, coverage)) |> Repo.update!()
  end

  defp coverage_changes(state, query, page, now) do
    safe =
      state.scan_safe and page.stale == false and page.missing_ids == [] and
        Enum.all?(
          page.data,
          &(match?(%DateTime{}, &1.published_at) and DateTime.compare(&1.published_at, now) != :gt)
        )

    checked =
      if not page.has_more and safe,
        do: PublicationCoverage.add(state.checked_ranges, query.from_date, query.to_date),
        else: PublicationCoverage.normalize(state.checked_ranges)

    incomplete =
      if not page.has_more and safe,
        do: PublicationCoverage.subtract(state.incomplete_ranges, query.from_date, query.to_date),
        else: PublicationCoverage.add(state.incomplete_ranges, query.from_date, query.to_date)

    case {checked, incomplete} do
      {a, b} when is_list(a) and is_list(b) ->
        changes = %{checked_ranges: a, incomplete_ranges: b}

        if not page.has_more and safe,
          do: Map.put(changes, :coverage_repaired_at, nil),
          else: changes

      _ ->
        {:error, :invalid_ranges}
    end
  end

  defp valid_page?(query, page) do
    match?(%Date{}, query[:from_date]) and match?(%Date{}, query[:to_date]) and
      Date.diff(query.to_date, query.from_date) in 0..29 and
      query[:kind] in ["discovery", "refresh"] and
      is_list(page[:data]) and
      ((page[:has_more] == false and is_nil(page[:next_cursor])) or
         (page[:has_more] == true and is_binary(page[:next_cursor]) and page.next_cursor != "" and
            page.next_cursor != query[:cursor]))
  end

  defp state!(binding, query, now) do
    Repo.insert!(
      %PublicationSyncState{
        account_id: binding.account_id,
        kind: query.kind,
        provider_account_ref: binding.provider_account_ref,
        provider_profile_ref: binding.provider_profile_ref
      },
      on_conflict: :nothing,
      conflict_target: [:account_id, :kind]
    )

    state =
      Repo.one!(
        from(s in PublicationSyncState,
          where: s.account_id == ^binding.account_id and s.kind == ^query.kind,
          lock: "FOR UPDATE"
        )
      )

    hash = query_hash(binding, query)

    frozen_first? =
      is_nil(query.cursor) and state.query_hash == hash and
        is_nil(state.completed_at) and not is_nil(state.scan_id)

    if is_nil(query.cursor) and not frozen_first? do
      state
      |> Ecto.Changeset.change(%{
        query_hash: hash,
        from_date: query.from_date,
        to_date: query.to_date,
        provider_account_ref: binding.provider_account_ref,
        provider_profile_ref: binding.provider_profile_ref,
        cursor: nil,
        seen_cursors: [],
        scan_id: Ecto.UUID.generate(),
        scan_started_at: now,
        scan_safe: true,
        completed_at: nil
      })
      |> Repo.update!()
    else
      if state.query_hash != hash or state.cursor != query.cursor or
           state.provider_account_ref != binding.provider_account_ref or
           state.provider_profile_ref != binding.provider_profile_ref,
         do: Repo.rollback(:checkpoint_mismatch)

      state
    end
  end

  defp rows(binding) do
    from(p in Publication,
      where: p.account_id == ^binding.account_id and p.profile_id == ^binding.profile_id,
      where:
        p.platform == ^binding.platform and
          p.provider_account_ref == ^binding.provider_account_ref and
          p.provider_profile_ref == ^binding.provider_profile_ref
    )
  end

  defp observe(binding, query, scan, row, now, stale?) do
    existing = Repo.one(from(p in rows(binding), where: p.native_id == ^row.native_id))

    current =
      existing ||
        %Publication{
          account_id: binding.account_id,
          profile_id: binding.profile_id,
          provider_account_ref: binding.provider_account_ref,
          provider_profile_ref: binding.provider_profile_ref,
          platform: "youtube",
          native_id: row.native_id
        }

    attrs =
      Map.take(row, [:sync_status])
      |> Map.merge(%{
        fetched_at: now,
        last_listed_at: now,
        last_seen_scans: Map.put(current.last_seen_scans, query.kind, scan),
        listed_from: query.from_date,
        listed_to: query.to_date,
        not_listed: false,
        # The streak describes consecutive responses set aside, not a past
        # conflict carried across a later pending/unavailable observation.
        ambiguous_count: 0,
        ambiguous_observation: nil,
        source_stale: stale? or row.sync_status != "synced" or is_nil(row.vendor_synced_at)
      })

    usable? = row.sync_status == "synced"

    newer? =
      (is_nil(current.vendor_synced_at) and not is_nil(row.vendor_synced_at)) or
        (not is_nil(row.vendor_synced_at) and
           DateTime.compare(row.vendor_synced_at, current.vendor_synced_at) == :gt)

    metadata = Map.take(row, [:external_id, :vendor_url, :published_at, :is_owner, :is_ad])

    same? =
      row.vendor_synced_at == current.vendor_synced_at and row.metrics == current.metrics and
        Map.take(current, Map.keys(metadata)) == metadata

    attrs =
      cond do
        is_nil(existing) or (usable? and newer?) ->
          attrs
          |> Map.merge(metadata)
          |> Map.merge(%{
            metrics: row.metrics,
            vendor_synced_at: row.vendor_synced_at,
            ambiguous_count: 0,
            ambiguous_observation: nil
          })

        usable? and not same? ->
          Map.merge(attrs, %{
            ambiguous_count: current.ambiguous_count + 1,
            ambiguous_observation: %{
              "metrics" => row.metrics,
              "vendorSyncedAt" =>
                if(row.vendor_synced_at, do: DateTime.to_iso8601(row.vendor_synced_at)),
              "fetchedAt" => DateTime.to_iso8601(now)
            }
          })

        usable? and same? ->
          Map.merge(attrs, %{ambiguous_count: 0, ambiguous_observation: nil})

        true ->
          attrs
      end

    current |> Ecto.Changeset.change(attrs) |> Repo.insert_or_update!()
  end
end
