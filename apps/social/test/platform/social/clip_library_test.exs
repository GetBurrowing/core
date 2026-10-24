defmodule Platform.Social.ClipLibraryTest do
  @moduledoc """
  Clip Studio 2/9 (task 01a16662) stage 4: `ClipLibrary.list/3`, every clip
  that reached review with one status entry per post, the five filters plus
  search, and menu counts computed with every OTHER filter applied. Not
  async: ClipPublish runs in its own process.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures

  alias Platform.Social
  alias Platform.Social.{AgentDrafts, Clip, ClipLibrary, ClipPublish, Post, RateLimit}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    RateLimit.reset()
    w = render_world!()
    # Noon UTC, so a minute either side never crosses a date boundary.
    now = DateTime.new!(Date.utc_today(), ~T[12:00:00.000000], "Etc/UTC")

    parked =
      start_supervised!(
        {ClipPublish, name: :clip_library_parked, interval_ms: :infinity, boot_sweep: false}
      )

    {:ok, show_b} =
      Social.create_profile(w.org_id, %{
        name: "Show B #{unique()}",
        project_id: w.project.id,
        approver_user_ids: [w.approver.id],
        space_id: channel!(w.org_id).id
      })

    {:ok, b_x} = Social.create_account(w.org_id, show_b, %{platform: "x"})

    pending =
      submit!(w, w.profile, %{"title" => "Who makes Total War?", "platforms" => ["tiktok"]})
      |> set!(episode_code: "S2E14", rendered_at: now)

    rejected =
      submit!(w, w.profile, %{"caption" => "Budget GPUs explained", "platforms" => ["tiktok"]})
      |> set!(episode_code: "S2E13", rendered_at: days_ago(now, 3))

    {:ok, _} = Social.reject_clip(w.org_id, rejected.id, w.approver.id, "Too long")

    published =
      submit!(w, show_b, %{"title" => "Old one"})
      |> set!(episode_code: "S2E14", rendered_at: days_ago(now, 10))

    {:ok, %{posts: [b_post]}} = approve(w, published, [b_x.id], parked)
    post_set!(b_post, status: "published", external_id: "z_b", published_at: now)

    failed =
      submit!(w, w.profile, %{})
      |> set!(rendered_at: DateTime.add(now, -60, :second))

    {:ok, %{posts: fposts}} = approve(w, failed, [w.tiktok.id, w.x.id], parked)

    for p <- fposts do
      if p.account_id == w.tiktok.id,
        do: post_set!(p, status: "failed", error: "token expired", publish_attempts: 1),
        else: post_set!(p, status: "published", external_id: "z_x", published_at: now)
    end

    candidate = file_clip!(w, 0, 4)
    rendering = file_clip!(w, 4, 8) |> set!(status: "rendering")

    other = render_world!()
    foreign = submit!(other, other.profile, %{"title" => "Who makes Total War?"})

    %{
      w: w,
      now: now,
      show_b: show_b,
      other: other,
      pending: pending,
      rejected: rejected,
      published: published,
      failed: failed,
      candidate: candidate,
      rendering: rendering,
      foreign: foreign
    }
  end

  defp submit!(w, profile, attrs) do
    file = stored_file!(w.project, "rendered clip #{unique()}", "clip.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        profile.id,
        Map.merge(%{"file_id" => file.id, "duration_s" => 30.0}, attrs),
        w.agent.id
      )

    clip
  end

  defp set!(clip, fields) do
    {1, _} = Repo.update_all(from(c in Clip, where: c.id == ^clip.id), set: fields)
    Repo.get!(Clip, clip.id)
  end

  defp post_set!(post, fields),
    do: {1, _} = Repo.update_all(from(p in Post, where: p.id == ^post.id), set: fields)

  defp approve(w, clip, account_ids, server) do
    Social.approve_clip(w.org_id, clip.id, w.approver.id, %{"account_ids" => account_ids},
      publish_server: server
    )
  end

  defp days_ago(now, n), do: DateTime.add(now, -n * 86_400, :second)

  defp list(ctx, filters \\ %{}), do: ClipLibrary.list(ctx.w.org_id, filters, now: ctx.now)

  defp ids(%{items: items}), do: items |> Enum.map(& &1.clip.id) |> Enum.sort()
  defp ids(clips) when is_list(clips), do: clips |> Enum.map(& &1.id) |> Enum.sort()

  test "pending and rejected clips are listed, candidate and rendering are not", ctx do
    result = list(ctx)
    assert ids(result) == ids([ctx.pending, ctx.rejected, ctx.published, ctx.failed])
    assert result.total == 4
    refute ctx.candidate.id in ids(result)
    refute ctx.rendering.id in ids(result)

    states = Map.new(result.items, &{&1.clip.id, &1.state})
    assert states[ctx.pending.id] == "In review"
    assert states[ctx.rejected.id] == "Rejected"
    assert states[ctx.published.id] == "Published"
    assert states[ctx.failed.id] == "Failed"

    # Newest rendered_at first.
    assert Enum.map(result.items, & &1.clip.id) ==
             [ctx.pending.id, ctx.failed.id, ctx.rejected.id, ctx.published.id]
  end

  test "filter show", ctx do
    assert ids(list(ctx, %{"show" => ctx.show_b.id})) == ids([ctx.published])

    assert ids(list(ctx, %{"show" => ctx.w.profile.id})) ==
             ids([ctx.pending, ctx.rejected, ctx.failed])

    # Another org's show, or an unknown id, lists nothing.
    assert list(ctx, %{"show" => ctx.other.profile.id}).items == []
    assert list(ctx, %{"show" => Ecto.UUID.generate()}).items == []
  end

  test "filter episode", ctx do
    assert ids(list(ctx, %{"episode" => "S2E14"})) == ids([ctx.pending, ctx.published])
    assert ids(list(ctx, %{"episode" => "S2E13"})) == ids([ctx.rejected])
    assert list(ctx, %{"episode" => "S9E99"}).items == []
  end

  test "filter date", ctx do
    assert ids(list(ctx, %{"date" => "today"})) == ids([ctx.pending, ctx.failed])
    assert ids(list(ctx, %{"date" => "this_week"})) == ids([ctx.rejected])
    assert ids(list(ctx, %{"date" => "older"})) == ids([ctx.published])
  end

  test "filter platform", ctx do
    # x: posts on x accounts. tiktok: a post on tiktok, or a PENDING clip
    # that names it (the rejected clip names it too, but is not pending).
    assert ids(list(ctx, %{"platform" => "x"})) == ids([ctx.published, ctx.failed])
    assert ids(list(ctx, %{"platform" => "tiktok"})) == ids([ctx.pending, ctx.failed])
    assert list(ctx, %{"platform" => "linkedin"}).items == []
  end

  test "filter status", ctx do
    assert ids(list(ctx, %{"status" => "In review"})) == ids([ctx.pending])
    assert ids(list(ctx, %{"status" => "Rejected"})) == ids([ctx.rejected])
    assert ids(list(ctx, %{"status" => "Published"})) == ids([ctx.published])
    assert ids(list(ctx, %{"status" => "Failed"})) == ids([ctx.failed])
    assert list(ctx, %{"status" => "Scheduled"}).items == []
    assert list(ctx, %{"status" => "Publishing"}).items == []
  end

  test "search matches title and caption and tolerates nil", ctx do
    # Title, case-insensitive; the caption is nil on this clip.
    assert ids(list(ctx, %{"q" => "total WAR"})) == ids([ctx.pending])
    # Caption; the title is nil on this clip.
    assert ids(list(ctx, %{"q" => "gpus"})) == ids([ctx.rejected])
    # LIKE metacharacters are literal.
    assert list(ctx, %{"q" => "%"}).items == []
    assert list(ctx, %{"q" => "_"}).items == []
    # Search composes with the other filters.
    assert list(ctx, %{"q" => "total war", "status" => "Rejected"}).items == []
    # The failed clip has neither title nor caption and is still listed unsearched.
    assert ctx.failed.id in ids(list(ctx, %{"q" => ""}))
  end

  test "counts match the filtered list for every option", ctx do
    actives = [
      %{},
      %{"episode" => "S2E14"},
      %{"date" => "today"},
      %{"platform" => "x", "status" => "Failed"},
      %{"show" => ctx.w.profile.id, "q" => "total"}
    ]

    for active <- actives do
      %{counts: counts} = list(ctx, active)
      assert Map.keys(counts) |> Enum.sort() == ~w(date episode platform show status)

      for {key, options} <- counts, {option, count} <- options do
        expected = list(ctx, Map.put(active, key, option)).total

        assert count == expected,
               "active #{inspect(active)}: #{key}=#{option} counted #{count}, lists #{expected}"
      end
    end

    # The prototype's menus: fixed date and status options, every platform.
    %{counts: counts} = list(ctx)
    assert counts["date"] == %{"today" => 2, "this_week" => 1, "older" => 1}
    assert counts["status"]["Failed"] == 1
    assert counts["status"]["Scheduled"] == 0
    assert Map.has_key?(counts["platform"], "linkedin")
    assert counts["show"] == %{ctx.w.profile.id => 3, ctx.show_b.id => 1}
  end

  test "a library item carries one status per post", ctx do
    item = Enum.find(list(ctx).items, &(&1.clip.id == ctx.failed.id))
    assert length(item.platforms) == 2
    by = Map.new(item.platforms, &{&1.platform, &1})

    assert %{state: :failed, error: "token expired", attempts: 1} = by["tiktok"]
    assert by["tiktok"].reconnect == %{account_id: ctx.w.tiktok.id, platform: "tiktok"}
    assert %{state: :published, reconnect: nil} = by["x"]
    assert item.state == "Failed"

    pending = Enum.find(list(ctx).items, &(&1.clip.id == ctx.pending.id))
    assert pending.platforms == []
  end

  test "another org's clips are absent", ctx do
    refute ctx.foreign.id in ids(list(ctx))
    refute ctx.foreign.id in ids(list(ctx, %{"q" => "total war"}))
    assert ids(ClipLibrary.list(ctx.other.org_id)) == ids([ctx.foreign])

    # A scope that names no org sees nothing.
    assert ClipLibrary.list("not-an-org").items == []
  end

  test "an unknown filter is invalid_filter", ctx do
    for filters <- [
          %{"foo" => "bar"},
          %{"date" => "yesterday"},
          %{"status" => "Done"},
          %{"platform" => "myspace"},
          %{"show" => "not-a-uuid"},
          %{"episode" => 14},
          %{"q" => %{}},
          :not_a_map
        ] do
      assert {:error, :invalid_filter} = list(ctx, filters), inspect(filters)
    end

    # Blank values are simply not applied.
    assert list(ctx, %{"date" => "", "status" => nil}).total == 4
  end
end
