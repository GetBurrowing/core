defmodule Platform.Social.ClipDraftLockConcurrencyTest do
  @moduledoc """
  Two real database connections. A writer holds an UNCOMMITTED change to the
  authority `ClipDecisions.draft_clip/5` decided on before it took its locks
  (the approver list, an account's owner, an account's archive). The draft
  waits on that row lock, and on release must decide again on the COMMITTED
  row: refused, with the clip still pending and no post written. A draft
  running on its pre-flight structs would succeed here, so these tests fail
  without the re-read under the lock. The world is committed and removed by
  hand afterwards. Every wait is bounded.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Platform.SocialFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{AgentDrafts, Clip, ClipDecisions, Post, Publisher.Fake}

  setup do
    Sandbox.mode(Repo, :auto)
    Fake.reset()
    w = render_world!()
    other = member!(user!(), w.org_id)
    file = stored_file!(w.project, "clip bytes #{unique()}", "clip.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{
          "file_id" => file.id,
          "title" => "Agent title",
          "caption" => "Agent caption",
          "duration_s" => 30.0,
          "width" => 1080,
          "height" => 1920
        },
        w.agent.id
      )

    on_exit(fn ->
      try do
        # Posts, then the world's rows; orgs last. A leftover is reported, not hidden.
        Repo.delete_all(from(p in Post, where: p.clip_id == ^clip.id))
        Repo.delete_all(from(i in Platform.Social.Idea, where: i.profile_id == ^w.profile.id))
        Repo.delete_all(from(c in Clip, where: c.id == ^clip.id))
        Repo.delete_all(from(a in Platform.Social.Account, where: a.profile_id == ^w.profile.id))
        Repo.delete_all(from(p in Platform.Social.Profile, where: p.id == ^w.profile.id))
      after
        Sandbox.mode(Repo, :manual)
      end
    end)

    %{w: w, clip: clip, other: other}
  end

  defp draft(ctx, account_ids) do
    ClipDecisions.draft_clip(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id, %{
      "render_id" => render_id!(ctx.clip),
      "account_ids" => account_ids
    })
  end

  # Runs `write` in a transaction, tells the test, and holds it open,
  # uncommitted, until `:release` (or ten seconds).
  defp writer(write) do
    parent = self()

    Task.async(fn ->
      Repo.transaction(fn ->
        {:ok, _} = write.()
        send(parent, :written)

        receive do
          :release -> :ok
        after
          10_000 -> Repo.rollback(:timeout)
        end
      end)
    end)
  end

  defp assert_refused_untouched(ctx, drafter, writer_task, reason) do
    assert Task.yield(drafter, 400) == nil, "the draft must block on the row lock"
    send(writer_task.pid, :release)
    assert {:ok, _} = Task.await(writer_task, 10_000)
    assert {:error, ^reason} = Task.await(drafter, 10_000)

    clip = Repo.get!(Clip, ctx.clip.id)
    assert {clip.review_status, clip.reviewed_by_user_id} == {"pending", nil}
    assert Repo.aggregate(from(p in Post, where: p.clip_id == ^ctx.clip.id), :count) == 0
    assert Fake.calls(:publish) == []
  end

  test "an approver removal in flight refuses the draft once it commits", ctx do
    remover =
      writer(fn ->
        Social.update_profile(ctx.w.org_id, ctx.w.profile, %{approver_user_ids: [ctx.other.id]})
      end)

    assert_receive :written, 5_000
    drafter = Task.async(fn -> draft(ctx, [ctx.w.x.id]) end)
    assert_refused_untouched(ctx, drafter, remover, :not_an_approver)
  end

  test "an account archive in flight refuses the draft once it commits", ctx do
    archiver = writer(fn -> Social.archive_account(ctx.w.org_id, ctx.w.x) end)
    assert_receive :written, 5_000
    drafter = Task.async(fn -> draft(ctx, [ctx.w.x.id]) end)
    assert_refused_untouched(ctx, drafter, archiver, :account_not_in_profile)
  end

  test "an owner transfer in flight refuses the draft once it commits", ctx do
    mover = writer(fn -> Social.set_account_owner(ctx.w.org_id, ctx.w.x, ctx.other.id) end)
    assert_receive :written, 5_000
    drafter = Task.async(fn -> draft(ctx, [ctx.w.x.id]) end)
    assert_refused_untouched(ctx, drafter, mover, :not_the_owner)
  end
end
