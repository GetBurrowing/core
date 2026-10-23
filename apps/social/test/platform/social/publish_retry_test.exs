defmodule Platform.Social.PublishRetryTest do
  @moduledoc """
  The rate-limit retry sweep (task 01a165f1, stage 2). Each test starts its
  own `PublishRetry` with no timer and drives it with `sweep_now/1`. The
  Fake's call log and the rate-limit counters are global ETS tables, so
  this file runs `async: false`.
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures

  alias Platform.Social.{Post, PublishRetry, Publishing, RateLimit}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    RateLimit.reset()
    previous = Application.get_env(:social, :rate_limit)
    on_exit(fn -> Application.put_env(:social, :rate_limit, previous) end)

    org_id = org_id!()
    {_profile, account} = social_account!(org_id, "linkedin")

    name = :"publish_retry_#{System.unique_integer([:positive])}"
    pid = start_supervised!({PublishRetry, name: name, interval_ms: :infinity})
    Ecto.Adapters.SQL.Sandbox.allow(Platform.Repo, self(), pid)

    %{org_id: org_id, account: account, server: name}
  end

  # A post refused by the rate limit, with retry_after moved to `at`.
  defp rate_limited!(ctx, at) do
    Application.put_env(:social, :rate_limit, per_window: 0, window_ms: 3_600_000)
    post = approved_post!(ctx.org_id, ctx.account)
    assert {:error, :rate_limited} = Publishing.publish_post(ctx.org_id, post.id)
    Application.put_env(:social, :rate_limit, per_window: 25, window_ms: 3_600_000)
    RateLimit.reset()

    Repo.get!(Post, post.id)
    |> Ecto.Changeset.change(retry_after: at)
    |> Repo.update!()
  end

  defp media_rejected!(ctx) do
    {_, insta} = social_account!(ctx.org_id, "instagram", %{platform_account_type: "personal"})
    video = media_file!(ctx.org_id, "video/mp4")

    post =
      approved_post!(ctx.org_id, insta, %{
        media_file_ids: [video.id],
        media_meta: %{video.id => %{"duration_s" => 30}}
      })

    assert {:error, {:media_rejected, _}} = Publishing.publish_post(ctx.org_id, post.id)
    row = Repo.get!(Post, post.id)
    assert row.refused_reason == "media_rejected"

    # Even with a past retry_after, only rate_limited is ever auto-retried.
    row |> Ecto.Changeset.change(retry_after: past()) |> Repo.update!()
  end

  defp past, do: DateTime.add(DateTime.utc_now(), -60, :second)
  defp future, do: DateTime.add(DateTime.utc_now(), 3_600, :second)

  test "publishes a due rate_limited post; ignores a not-yet-due one and a media_rejected one",
       ctx do
    due = rate_limited!(ctx, past())
    not_due = rate_limited!(ctx, future())
    media = media_rejected!(ctx)

    assert [{id, {:ok, %Post{status: "scheduled"}}}] = PublishRetry.sweep_now(ctx.server)
    assert id == due.id

    row = Repo.get!(Post, due.id)

    assert {row.status, row.refused_reason, row.refused_at, row.retry_after} ==
             {"scheduled", nil, nil, nil}

    assert [{:publish, [_, %{idempotency_key: key}], _}] = Fake.calls(:publish)
    assert key == due.id

    assert Repo.get!(Post, not_due.id) == not_due
    assert Repo.get!(Post, media.id) == media
  end

  test "two sweeps publish once", ctx do
    due = rate_limited!(ctx, past())

    assert [{_, {:ok, _}}] = PublishRetry.sweep_now(ctx.server)
    assert [] = PublishRetry.sweep_now(ctx.server)

    assert length(Fake.calls(:publish)) == 1
    assert Repo.get!(Post, due.id).status == "scheduled"
  end

  test "a second rate limit writes a new retry_after and keeps it approved", ctx do
    due = rate_limited!(ctx, past())
    Application.put_env(:social, :rate_limit, per_window: 0, window_ms: 3_600_000)

    assert [{_, {:error, :rate_limited}}] = PublishRetry.sweep_now(ctx.server)

    row = Repo.get!(Post, due.id)
    assert {row.status, row.refused_reason} == {"approved", "rate_limited"}
    assert DateTime.compare(row.retry_after, DateTime.utc_now()) == :gt
    assert Fake.calls(:publish) == []

    # Not due again until the new retry_after.
    assert [] = PublishRetry.sweep_now(ctx.server)
  end

  test "due/1 orders by retry_after" do
    ctx = %{org_id: org_id!()}
    {_, account} = social_account!(ctx.org_id, "linkedin")
    ctx = Map.put(ctx, :account, account)
    later = rate_limited!(ctx, DateTime.add(DateTime.utc_now(), -10, :second))
    earlier = rate_limited!(ctx, DateTime.add(DateTime.utc_now(), -100, :second))

    ids =
      PublishRetry.due() |> Enum.map(&elem(&1, 1)) |> Enum.filter(&(&1 in [later.id, earlier.id]))

    assert ids == [earlier.id, later.id]
  end
end
