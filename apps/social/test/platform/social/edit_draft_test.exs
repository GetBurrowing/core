defmodule Platform.Social.EditDraftTest do
  @moduledoc """
  `Social.edit_draft/5` (B3 Queue Drafts): a human edits a legacy draft's
  caption, YouTube title and publish time in ONE transaction, and either saves
  it (still a draft, possibly incomplete) or sends it for review (complete, or
  nothing is written).
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialApprovalFixtures
  import Platform.SocialFixtures, only: [media_file!: 2]

  alias Platform.Inbox.Item
  alias Platform.Social
  alias Platform.Social.{ApprovalCard, Post, PostEvent}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    ctx = approval_fixture()
    a = Repo.update!(Ecto.Changeset.change(ctx.a, status: "connected"))

    {:ok, yt} =
      Social.create_account(ctx.org_id, ctx.profile, %{platform: "youtube", handle: "@htc_yt"})

    yt = Repo.update!(Ecto.Changeset.change(yt, status: "connected"))
    Map.merge(ctx, %{a: a, yt: yt})
  end

  defp future, do: DateTime.add(DateTime.utc_now(), 3600) |> DateTime.truncate(:second)

  defp draft!(ctx, account, attrs \\ %{}) do
    {:ok, post} = Social.create_post(ctx.org_id, account, attrs)
    assert post.status == "draft"
    post
  end

  defp yt_draft!(ctx, attrs \\ %{}) do
    video = media_file!(ctx.org_id, "video/mp4")
    draft!(ctx, ctx.yt, Map.merge(%{media_file_ids: [video.id]}, attrs))
  end

  defp side_effects(post) do
    %{
      cards: Repo.aggregate(ApprovalCard, :count),
      items: Repo.aggregate(from(i in Item, where: i.source_id == ^post.id), :count),
      events: Repo.aggregate(from(e in PostEvent, where: e.post_id == ^post.id), :count)
    }
  end

  describe "attrs keys" do
    test "string keys are refused, never silently dropped", ctx do
      p = draft!(ctx, ctx.a, %{body: "Original"})

      assert {:error, {:invalid_keys, ["body"]}} =
               Social.edit_draft(ctx.org_id, p.id, ctx.h1.id, %{"body" => "Changed"})

      assert Repo.get!(Post, p.id).body == "Original"
    end
  end

  describe "save (submit: false)" do
    test "saves an incomplete draft and stays a draft", ctx do
      p = draft!(ctx, ctx.a)

      assert {:ok, saved} =
               Social.edit_draft(ctx.org_id, p.id, ctx.h1.id, %{body: "Half done"}, submit: false)

      assert saved.status == "draft"
      assert saved.body == "Half done"
      assert is_nil(saved.scheduled_at)
      assert side_effects(p).cards == 0
    end

    test "saves caption, time and the YouTube title, leaving other options alone", ctx do
      p = yt_draft!(ctx)

      p =
        Repo.update!(Ecto.Changeset.change(p, platform_options: %{"first_comment" => "Keep me"}))

      at = future()

      assert {:ok, saved} =
               Social.edit_draft(
                 ctx.org_id,
                 p.id,
                 ctx.h1.id,
                 %{body: "Desc", title: "Real title", scheduled_at: at},
                 []
               )

      assert saved.status == "draft"
      assert saved.platform_options == %{"title" => "Real title", "first_comment" => "Keep me"}
      assert DateTime.compare(saved.scheduled_at, at) == :eq
      assert saved.media_file_ids == p.media_file_ids
    end

    test "absent keys are left alone; nil time clears it", ctx do
      p = draft!(ctx, ctx.a, %{body: "Keep", scheduled_at: future()})
      assert {:ok, same} = Social.edit_draft(ctx.org_id, p.id, ctx.h1.id, %{}, submit: false)
      assert same.body == "Keep" and same.scheduled_at == p.scheduled_at

      assert {:ok, cleared} =
               Social.edit_draft(ctx.org_id, p.id, ctx.h1.id, %{scheduled_at: nil}, submit: false)

      assert is_nil(cleared.scheduled_at)
    end

    test "still obeys the field validators: refused, nothing changes", ctx do
      p = yt_draft!(ctx, %{body: "Original"})
      before = Repo.get!(Post, p.id)
      events = side_effects(p)

      assert {:error, %Ecto.Changeset{}} =
               Social.edit_draft(
                 ctx.org_id,
                 p.id,
                 ctx.h1.id,
                 %{body: String.duplicate("a", 10_001)},
                 submit: false
               )

      assert {:error, %Ecto.Changeset{}} =
               Social.edit_draft(
                 ctx.org_id,
                 p.id,
                 ctx.h1.id,
                 %{body: "Changed", title: String.duplicate("t", 101)},
                 submit: false
               )

      assert Repo.get!(Post, p.id) == before
      assert side_effects(p) == events
    end

    test "a title for a non-YouTube account is refused", ctx do
      p = draft!(ctx, ctx.a, %{body: "Orig"})
      before = Repo.get!(Post, p.id)

      assert {:error, %Ecto.Changeset{} = cs} =
               Social.edit_draft(ctx.org_id, p.id, ctx.h1.id, %{body: "New", title: "No"}, [])

      assert cs.errors[:title]
      assert Repo.get!(Post, p.id) == before
    end

    test "a user who may not edit is refused and nothing changes", ctx do
      p = draft!(ctx, ctx.a, %{body: "Orig"})
      before = Repo.get!(Post, p.id)

      assert {:error, :not_an_approver} =
               Social.edit_draft(ctx.org_id, p.id, ctx.n.id, %{body: "Mine"}, [])

      assert {:error, :not_a_human} =
               Social.edit_draft(ctx.org_id, p.id, ctx.g.id, %{body: "Agent"}, [])

      assert Repo.get!(Post, p.id) == before
    end

    test "another org cannot reach the post", ctx do
      p = draft!(ctx, ctx.a)

      assert {:error, :not_found} =
               Social.edit_draft(Ecto.UUID.generate(), p.id, ctx.h1.id, %{body: "x"}, [])
    end

    test "only a legacy draft: not needs_approval, not studio", ctx do
      {p, _card} = pending_post!(ctx, ctx.a, %{scheduled_at: future()})
      before = Repo.get!(Post, p.id)

      assert {:error, :not_a_draft} =
               Social.edit_draft(ctx.org_id, p.id, ctx.h1.id, %{body: "x"}, [])

      assert Repo.get!(Post, p.id) == before

      s = draft!(ctx, ctx.a)
      s = Repo.update!(Ecto.Changeset.change(s, flow: "studio"))

      assert {:error, :studio_post} =
               Social.edit_draft(ctx.org_id, s.id, ctx.h1.id, %{body: "x"}, [])
    end

    test "records one human edited event when something changed", ctx do
      p = draft!(ctx, ctx.a, %{body: "Old"})
      {:ok, _} = Social.edit_draft(ctx.org_id, p.id, ctx.h1.id, %{body: "New"}, [])

      assert [%{action: "edited", actor_kind: "human", body_before: "Old", body_after: "New"}] =
               Repo.all(from(e in PostEvent, where: e.post_id == ^p.id and e.action == "edited"))
    end
  end

  describe "send for review (submit: true)" do
    test "complete: needs_approval, ONE card and inbox rows, after commit", ctx do
      p = yt_draft!(ctx, %{body: "Desc", platform_options: nil})
      at = future()

      assert {:ok, sent} =
               Social.edit_draft(ctx.org_id, p.id, ctx.h1.id, %{title: "Title", scheduled_at: at},
                 submit: true
               )

      assert sent.status == "needs_approval"
      assert sent.platform_options["title"] == "Title"
      assert Repo.aggregate(ApprovalCard, :count) == 1
      assert %ApprovalCard{} = Platform.Social.Approvals.live_card(p.id)

      assert Repo.aggregate(
               from(i in Item, where: i.source_id == ^p.id and i.kind == "social_post_approval"),
               :count
             ) == 2
    end

    test "the card hook runs only after the outer transaction has released", ctx do
      p = draft!(ctx, ctx.a, %{body: "Ready"})
      me = self()
      id = "edit-draft-sql-#{System.unique_integer([:positive])}"
      event = Platform.Repo.config()[:telemetry_prefix] ++ [:query]

      :telemetry.attach(id, event, fn _e, _m, %{query: q}, _c -> send(me, {:sql, q}) end, nil)

      try do
        assert {:ok, _} =
                 Social.edit_draft(ctx.org_id, p.id, ctx.h1.id, %{scheduled_at: future()},
                   submit: true
                 )
      after
        :telemetry.detach(id)
      end

      queries = collect_sql([])

      # Savepoint depth when the approval card row is inserted (Ecto logs the
      # transaction as begin / commit, savepoints in the sandbox).
      {depth, card_depths} =
        Enum.reduce(queries, {0, []}, fn q, {depth, seen} ->
          cond do
            q == "begin" -> {depth + 1, seen}
            q in ["commit", "rollback"] -> {depth - 1, seen}
            q =~ ~s(INSERT INTO "social_approval_cards") -> {depth, [depth | seen]}
            true -> {depth, seen}
          end
        end)

      assert depth == 0

      assert card_depths == [0],
             "approval card inserted at transaction depth #{inspect(card_depths)}"

      assert "begin" in queries, "no transaction was observed"
    end

    test "incomplete: refused with the missing lines, EVERYTHING rolled back, no side effects",
         ctx do
      p = yt_draft!(ctx, %{body: "Old body", scheduled_at: nil})
      before = Repo.get!(Post, p.id)
      fx = side_effects(p)

      # title is set and the body edited, but no publish time: title, body, time are all discarded.
      assert {:error, {:incomplete_post, lines}} =
               Social.edit_draft(
                 ctx.org_id,
                 p.id,
                 ctx.h1.id,
                 %{body: "Edited body", title: "Edited title"},
                 submit: true
               )

      assert lines == ["Choose a publish time."]
      assert Repo.get!(Post, p.id) == before
      assert side_effects(p) == fx
      assert Repo.aggregate(ApprovalCard, :count) == 0
    end

    test "incomplete on text and title lists every missing field", ctx do
      p = yt_draft!(ctx)

      assert {:error, {:incomplete_post, lines}} =
               Social.edit_draft(ctx.org_id, p.id, ctx.h1.id, %{scheduled_at: future()},
                 submit: true
               )

      assert "Add the post text." in lines
      assert Enum.any?(lines, &(&1 =~ "video title"))
    end

    test "a draft-only account's draft goes to its by-hand card; approval still refuses it",
         ctx do
      d = Repo.update!(Ecto.Changeset.change(ctx.d, status: "connected"))
      p = draft!(ctx, d, %{body: "Notes"})

      assert {:ok, _} =
               Social.edit_draft(ctx.org_id, p.id, ctx.h1.id, %{body: "More notes"},
                 submit: false
               )

      # The completeness gate lets the copy/by-hand request reach the card
      # (`PublishingCompleteness.submission/2`); only approval refuses it.
      assert {:ok, sent} =
               Social.edit_draft(ctx.org_id, p.id, ctx.h1.id, %{scheduled_at: future()},
                 submit: true
               )

      assert sent.status == "needs_approval"

      assert {:error, {:incomplete_post, ["This account is draft-only; it does not publish."]}} =
               Social.approve_post(ctx.org_id, sent, ctx.h1.id)
    end

    test "unauthorised user cannot submit", ctx do
      p = draft!(ctx, ctx.a, %{body: "Ready", scheduled_at: future()})

      assert {:error, :not_an_approver} =
               Social.edit_draft(ctx.org_id, p.id, ctx.n.id, %{}, submit: true)

      assert Repo.get!(Post, p.id).status == "draft"
      assert Repo.aggregate(ApprovalCard, :count) == 0
    end
  end

  # SQL text of every query the edit ran, in order.
  defp collect_sql(acc) do
    receive do
      {:sql, q} -> collect_sql([q | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
