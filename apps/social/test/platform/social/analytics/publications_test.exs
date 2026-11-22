defmodule Platform.Social.Analytics.PublicationsTest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures
  alias Platform.Repo
  alias Platform.Social.Analytics.Publications

  @now ~U[2026-11-22 06:00:00.000000Z]

  setup do
    {profile, account} = social_account!(org_id!(), "youtube")

    profile =
      Repo.update!(Ecto.Changeset.change(profile, provider_profile_ref: "profile-fixture"))

    account =
      Repo.update!(
        Ecto.Changeset.change(account,
          provider: "zernio",
          status: "connected",
          provider_account_ref: "account-fixture"
        )
      )

    binding = %{
      org_id: profile.org_id,
      profile_id: profile.id,
      account_id: account.id,
      provider_account_ref: account.provider_account_ref,
      provider_profile_ref: profile.provider_profile_ref,
      platform: "youtube"
    }

    query = %{kind: "discovery", from_date: ~D[2026-11-01], to_date: ~D[2026-11-22], cursor: nil}
    {:ok, binding: binding, query: query, account: account}
  end

  defp row(views \\ 66, attrs \\ %{}) do
    Map.merge(
      %{
        native_id: "Abcdefg_123",
        external_id: "analytics-fixture",
        published_at: ~U[2026-11-16 01:33:50.000000Z],
        vendor_synced_at: ~U[2026-11-22 05:04:31.000000Z],
        sync_status: "synced",
        metrics: %{"views" => views},
        is_owner: true,
        is_ad: false,
        vendor_url: nil
      },
      attrs
    )
  end

  defp page(rows, attrs \\ %{}) do
    Map.merge(
      %{data: rows, has_more: false, next_cursor: nil, stale: false, missing_ids: []},
      attrs
    )
  end

  defp write(binding, query, page),
    do: apply(Publications, :apply_page, [binding, query, page, @now])

  defp latest(binding), do: apply(Publications, :latest, [binding, [now: @now]])

  test "replayed completed pages are idempotent and store zero separately from unavailable",
       ctx do
    assert {:ok, _} = write(ctx.binding, ctx.query, page([row(0)]))
    assert {:ok, _} = write(ctx.binding, ctx.query, page([row(0)]))
    assert latest(ctx.binding).metrics == %{"views" => 0}
    assert Repo.aggregate(Platform.Social.Analytics.Publication, :count) == 1

    assert {:ok, _} =
             write(
               ctx.binding,
               ctx.query,
               page([row(nil, %{vendor_synced_at: DateTime.add(@now, 1)})])
             )

    assert latest(ctx.binding).metrics == %{"views" => nil}
  end

  test "newer vendor observations can lower counts while older and contradictory equal times do not overwrite",
       ctx do
    assert {:ok, _} = write(ctx.binding, ctx.query, page([row()]))
    assert {:ok, _} = write(ctx.binding, ctx.query, page([row(12, %{vendor_synced_at: @now})]))
    assert latest(ctx.binding).metrics["views"] == 12
    assert {:ok, _} = write(ctx.binding, ctx.query, page([row(999)]))
    assert latest(ctx.binding).metrics["views"] == 12
    assert {:ok, _} = write(ctx.binding, ctx.query, page([row(15, %{vendor_synced_at: @now})]))
    assert latest(ctx.binding).metrics["views"] == 12
    assert latest(ctx.binding).ambiguous_count >= 1
  end

  test "pending or unavailable observations retain known measurements with their provenance",
       ctx do
    assert {:ok, _} = write(ctx.binding, ctx.query, page([row()]))

    assert {:ok, _} =
             write(
               ctx.binding,
               ctx.query,
               page([row(nil, %{sync_status: "pending", vendor_synced_at: nil})])
             )

    assert latest(ctx.binding).metrics["views"] == 66
    assert latest(ctx.binding).vendor_synced_at == row().vendor_synced_at
    assert latest(ctx.binding).sync_status == "pending"
    assert latest(ctx.binding).fetched_at == @now
  end

  test "missing vendor time cannot silently revise an existing observation", ctx do
    assert {:ok, _} = write(ctx.binding, ctx.query, page([row(66, %{vendor_synced_at: nil})]))
    assert latest(ctx.binding).source_stale
    assert {:ok, _} = write(ctx.binding, ctx.query, page([row(99, %{vendor_synced_at: nil})]))
    assert latest(ctx.binding).metrics["views"] == 66
    assert latest(ctx.binding).ambiguous_count == 1
  end

  test "an older nullable observation cannot erase trusted publication identity", ctx do
    assert {:ok, _} = write(ctx.binding, ctx.query, page([row()]))
    partial = row(nil, %{vendor_synced_at: nil, published_at: nil, is_owner: nil})
    assert {:ok, _} = write(ctx.binding, ctx.query, page([partial]))
    assert latest(ctx.binding).published_at == ~U[2026-11-16 01:33:50.000000Z]
    assert latest(ctx.binding).metrics["views"] == 66
    assert latest(ctx.binding).ambiguous_count == 1
  end

  test "an identical successful observation ends an ambiguity streak", ctx do
    assert {:ok, _} = write(ctx.binding, ctx.query, page([row()]))
    assert {:ok, _} = write(ctx.binding, ctx.query, page([row(99)]))
    assert latest(ctx.binding).ambiguous_count == 1
    assert {:ok, _} = write(ctx.binding, ctx.query, page([row()]))
    assert latest(ctx.binding).ambiguous_count == 0
  end

  test "an interleaved refresh cannot erase membership in an unfinished discovery scan", ctx do
    assert {:ok, _} =
             write(ctx.binding, ctx.query, page([row()], %{has_more: true, next_cursor: "next"}))

    refresh = %{ctx.query | kind: "refresh", from_date: ~D[2026-11-16], to_date: ~D[2026-11-16]}
    assert {:ok, _} = write(ctx.binding, refresh, page([row()]))
    assert {:ok, _} = write(ctx.binding, %{ctx.query | cursor: "next"}, page([]))
    assert latest(ctx.binding).metrics["views"] == 66
  end

  test "query or account binding mismatch cannot reuse a continuation cursor", ctx do
    assert {:ok, state} =
             write(ctx.binding, ctx.query, page([row()], %{has_more: true, next_cursor: "next"}))

    assert state.cursor == "next"
    wrong_window = %{ctx.query | cursor: "next", from_date: ~D[2026-11-02]}
    assert {:error, :checkpoint_mismatch} = write(ctx.binding, wrong_window, page([]))
    changed = %{ctx.binding | provider_account_ref: "other"}
    assert {:error, :binding_changed} = write(changed, %{ctx.query | cursor: "next"}, page([]))
    assert latest(ctx.binding).metrics["views"] == 66
  end

  test "cache and checkpoint participate in the same rollback", ctx do
    assert {:error, :forced} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        write(
                          ctx.binding,
                          ctx.query,
                          page([row()], %{has_more: true, next_cursor: "next"})
                        )

               Repo.rollback(:forced)
             end)

    assert latest(ctx.binding) == nil
    assert Repo.aggregate(Platform.Social.Analytics.PublicationSyncState, :count) == 0
  end

  test "a complete fresh covering scan demotes absent rows without deleting them; partial and stale scans do not",
       ctx do
    assert {:ok, _} = write(ctx.binding, ctx.query, page([row()]))

    assert {:ok, _} =
             write(ctx.binding, ctx.query, page([], %{has_more: true, next_cursor: "next"}))

    assert latest(ctx.binding)
    assert {:ok, _} = write(ctx.binding, %{ctx.query | cursor: "next"}, page([], %{stale: true}))
    assert latest(ctx.binding)
    assert {:ok, _} = write(ctx.binding, ctx.query, page([]))
    assert latest(ctx.binding) == nil
    assert Repo.aggregate(Platform.Social.Analytics.Publication, :count) == 1
    assert {:ok, _} = write(ctx.binding, ctx.query, page([row()]))
    assert latest(ctx.binding)
  end

  test "ownership and advertising flags are observations, never eligibility predicates", ctx do
    assert {:ok, _} = write(ctx.binding, ctx.query, page([row(66, %{is_owner: nil, is_ad: nil})]))
    assert latest(ctx.binding).metrics["views"] == 66
    assert latest(ctx.binding).is_owner == nil
    assert latest(ctx.binding).is_ad == nil

    newer =
      row(99, %{
        native_id: "Abcdefg_456",
        is_owner: false,
        is_ad: true,
        published_at: ~U[2026-11-17 01:33:50.000000Z]
      })

    assert {:ok, _} = write(ctx.binding, ctx.query, page([newer]))
    assert latest(ctx.binding).native_id == "Abcdefg_456"
    assert latest(ctx.binding).is_ad == true
  end

  test "a changed connection hides previous identity and account deletion removes only derived cache",
       ctx do
    assert {:ok, _} = write(ctx.binding, ctx.query, page([row()]))
    Repo.update!(Ecto.Changeset.change(ctx.account, provider_account_ref: "new-connection"))
    assert latest(ctx.binding) == nil
    Repo.delete!(Repo.get!(Platform.Social.Account, ctx.account.id))
    assert Repo.aggregate(Platform.Social.Analytics.Publication, :count) == 0
  end

  test "a confirmed-owned publication in the future cannot become the latest observation", ctx do
    assert {:ok, _} =
             write(
               ctx.binding,
               ctx.query,
               page([row(9, %{published_at: DateTime.add(@now, 3600)})])
             )

    assert latest(ctx.binding) == nil
  end

  test "checked ranges preserve gaps and resolve only a completed authoritative interval", ctx do
    assert {:ok, state} = write(ctx.binding, ctx.query, page([row()]))
    assert state.checked_ranges == [%{"from" => "2026-11-01", "to" => "2026-11-22"}]
    older = %{ctx.query | from_date: ~D[2026-09-01], to_date: ~D[2026-09-30]}

    assert {:ok, state} =
             write(ctx.binding, older, page([], %{has_more: true, next_cursor: "older-next"}))

    assert state.incomplete_ranges == [%{"from" => "2026-09-01", "to" => "2026-09-30"}]
    assert length(state.checked_ranges) == 1
    assert {:ok, state} = write(ctx.binding, %{older | cursor: "older-next"}, page([]))
    assert state.incomplete_ranges == []

    assert state.checked_ranges == [
             %{"from" => "2026-09-01", "to" => "2026-09-30"},
             %{"from" => "2026-11-01", "to" => "2026-11-22"}
           ]
  end

  test "a complete refresh can demote the newest row without deleting it or touching older listed rows",
       ctx do
    older = row(12, %{native_id: "Abcdefg_456", published_at: ~U[2026-11-15 01:00:00.000000Z]})
    assert {:ok, _} = write(ctx.binding, ctx.query, page([row(), older]))
    refresh = %{kind: "refresh", from_date: ~D[2026-11-16], to_date: ~D[2026-11-16], cursor: nil}
    assert {:ok, _} = write(ctx.binding, refresh, page([]))
    assert latest(ctx.binding).native_id == older.native_id
    assert Repo.aggregate(Platform.Social.Analytics.Publication, :count) == 2

    assert Repo.get_by!(Platform.Social.Analytics.Publication, native_id: "Abcdefg_123").not_listed
  end

  test "a pending response breaks the conflict streak and is not labelled as the last conflict",
       ctx do
    assert {:ok, _} = write(ctx.binding, ctx.query, page([row()]))
    assert {:ok, _} = write(ctx.binding, ctx.query, page([row(999)]))
    assert latest(ctx.binding).ambiguous_count == 1
    later = DateTime.add(@now, 10)

    assert {:ok, _} =
             Publications.apply_page(
               ctx.binding,
               ctx.query,
               page([row(nil, %{sync_status: "pending", vendor_synced_at: nil})]),
               later
             )

    observed = latest(ctx.binding)
    assert observed.fetched_at == later
    assert observed.ambiguous_count == 0
    assert observed.ambiguous_observation == nil
    assert observed.sync_status == "pending"
    assert observed.metrics["views"] == 66
    assert {:ok, _} = write(ctx.binding, ctx.query, page([row(999)]))
    assert latest(ctx.binding).ambiguous_count == 1
  end
end
