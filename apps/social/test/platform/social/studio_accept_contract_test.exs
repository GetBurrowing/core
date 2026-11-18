defmodule Platform.Social.StudioAcceptContractTest do
  @moduledoc """
  Social Studio slice B: a replayed acceptance with split authority, and
  several destinations (all or nothing, one envelope,
  ascending by account id, independent of the caller's order). The
  describe blocks name each case.
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Platform.Social
  alias Platform.Social.{Post, Studio}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    w = studio_world!()
    clip = w |> pending_clip!() |> make_studio_clip!()

    accounts =
      for {platform, handle} <- [
            {"linkedin", "@c3"},
            {"instagram", "@d4"},
            {"youtube", "@e5"}
          ] do
        {:ok, account} =
          Social.create_account(w.org_id, w.profile, %{platform: platform, handle: handle})

        account
      end

    [third, fourth, fifth] = accounts
    %{w: w, clip: clip, rid: render_id!(clip), third: third, fourth: fourth, fifth: fifth}
  end

  defp accept(w, clip, rid, accounts, user \\ nil),
    do:
      Studio.accept_render(w.org_id, clip.id, (user || w.approver).id, %{
        render_id: rid,
        account_ids: Enum.map(accounts, & &1.id)
      })

  defp retarget!(w, post, account, user \\ nil) do
    {:ok, %{post: moved}} =
      Studio.save_version(
        w.org_id,
        post.id,
        {:human, (user || w.approver).id},
        %{account_id: account.id},
        expect(post)
      )

    moved
  end

  defp own!(w, account, user) do
    {:ok, account} = Social.set_account_owner(w.org_id, account, user.id)
    account
  end

  # The rows a replay must leave alone, for the whole database of this test.
  defp snapshot(post) do
    {fresh(post), receipts(post), actions(post), write_counts()}
  end

  # Runs `fun` and returns {result, [acceptance-key lookups it ran]}: the SQL
  # that filters posts by `clip_render_id`, which only the lookup of an
  # existing (render, account) post and the duplicate-destination check do.
  defp with_key_lookups(fun) do
    parent = self()
    id = "key-lookups-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:platform, :repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if self() == parent and String.contains?(query, ~s("clip_render_id" = $)),
          do: send(parent, {:key_lookup, query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain_lookups([])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain_lookups(acc) do
    receive do
      {:key_lookup, q} -> drain_lookups([q | acc])
    after
      0 -> acc
    end
  end

  describe "replaying acceptance for A after a retarget" do
    test "returns the retargeted post unchanged, sequentially, and never retargets back",
         %{w: w, clip: clip, rid: rid, third: third, fourth: fourth} do
      {:ok, %{posts: [post]}} = accept(w, clip, rid, [w.x])
      moved = retarget!(w, post, third)
      before = snapshot(moved)

      for _ <- 1..2 do
        assert {:ok, %{posts: [again]}} = accept(w, clip, rid, [w.x])
        assert {again.id, again.account_id} == {post.id, third.id}
        assert again.accepted_account_id == w.x.id
        assert snapshot(again) == before
      end

      # B -> C, then the key is still A
      moved2 = retarget!(w, moved, fourth)
      before2 = snapshot(moved2)
      assert {:ok, %{posts: [again]}} = accept(w, clip, rid, [w.x])

      assert {again.id, again.account_id, again.accepted_account_id} ==
               {post.id, fourth.id, w.x.id}

      assert snapshot(again) == before2
    end
  end

  describe "acceptance cannot occupy a destination reached by retarget" do
    test "the destinations envelope, even for one destination, nothing changed",
         %{w: w, clip: clip, rid: rid, third: third} do
      {:ok, %{posts: [post]}} = accept(w, clip, rid, [w.x])
      moved = retarget!(w, post, third)
      before = snapshot(moved)

      assert {:error, {:destinations, [%{account_id: id, reason: :duplicate_destination}]}} =
               accept(w, clip, rid, [third])

      assert id == third.id
      assert snapshot(moved) == before
      assert Repo.aggregate(Post, :count) == 1
    end
  end

  describe "a replay needs the requested and the current destination" do
    setup %{w: w, clip: clip, rid: rid, third: third} do
      u1 = w.approver
      u2 = user!() |> member!(w.org_id)
      own!(w, w.x, u1)
      third = own!(w, third, u1)

      {:ok, %{posts: [post]}} = accept(w, clip, rid, [w.x])
      moved = retarget!(w, post, third)
      third = own!(w, third, u2)
      %{u1: u1, u2: u2, moved: moved, third: third}
    end

    test "authorised on A only: B's ordinary owner refusal, no post and no id",
         %{w: w, clip: clip, rid: rid, u1: u1, moved: moved} do
      before = snapshot(moved)

      assert {:error, {:destinations, [%{account_id: id, reason: :not_the_owner}]} = error} =
               accept(w, clip, rid, [w.x], u1)

      assert id == w.x.id
      refute inspect(error) =~ moved.id
      assert snapshot(moved) == before
    end

    test "authorised on B only: refused at A first, and no acceptance-key lookup ran",
         %{w: w, clip: clip, rid: rid, u2: u2, moved: moved} do
      before = snapshot(moved)

      {result, lookups} = with_key_lookups(fn -> accept(w, clip, rid, [w.x], u2) end)

      assert {:error, {:destinations, [%{account_id: id, reason: :not_the_owner}]} = result} =
               result

      assert id == w.x.id
      refute inspect(result) =~ moved.id
      assert lookups == [], "a refused A must not look the acceptance key up"
      assert snapshot(moved) == before
    end

    test "authorised on both (control): the post comes back unchanged, and the lookup does run",
         %{w: w, clip: clip, rid: rid, u1: u1, moved: moved, third: third} do
      own!(w, third, u1)
      before = snapshot(moved)

      {result, lookups} = with_key_lookups(fn -> accept(w, clip, rid, [w.x], u1) end)

      assert {:ok, %{posts: [again]}} = result
      assert again.id == moved.id
      assert lookups != []
      assert snapshot(again) == before
    end
  end

  describe "replay of an archived requested account" do
    test "is refused like every other write on it (the check order runs before the lookup)",
         %{w: w, clip: clip, rid: rid} do
      {:ok, %{posts: [post]}} = accept(w, clip, rid, [w.x])
      {:ok, _} = Social.archive_account(w.org_id, w.x)
      before = snapshot(post)

      {result, lookups} = with_key_lookups(fn -> accept(w, clip, rid, [w.x]) end)

      assert {:error, {:destinations, [%{account_id: id, reason: :account_archived}]}} = result
      assert id == w.x.id
      assert lookups == []
      assert snapshot(post) == before
    end
  end

  describe "replay when the current account of the post is archived" do
    test "B's :account_archived refusal, no post and no id, nothing changed",
         %{w: w, clip: clip, rid: rid, third: third} do
      {:ok, %{posts: [post]}} = accept(w, clip, rid, [w.x])
      moved = retarget!(w, post, third)
      {:ok, _} = Social.archive_account(w.org_id, third)
      before = snapshot(moved)

      assert {:error, {:destinations, [%{account_id: id, reason: :account_archived}]} = error} =
               accept(w, clip, rid, [w.x])

      assert id == w.x.id
      refute inspect(error) =~ moved.id
      assert snapshot(moved) == before
    end
  end

  describe "mixed failures are complete, ordered and atomic" do
    setup %{w: w, clip: clip, rid: rid, third: third, fourth: fourth, fifth: fifth} do
      # w.x: valid and new. w.tiktok: archived. third: owned by someone else.
      # fourth: a valid account already occupied by a retargeted post.
      {:ok, _} = Social.archive_account(w.org_id, w.tiktok)
      other = user!() |> member!(w.org_id)
      own!(w, third, other)

      {:ok, %{posts: [post]}} = accept(w, clip, rid, [fifth])
      moved = retarget!(w, post, fourth)

      expected =
        [
          %{account_id: w.tiktok.id, reason: :account_archived},
          %{account_id: third.id, reason: :not_the_owner},
          %{account_id: fourth.id, reason: :duplicate_destination}
        ]
        |> Enum.sort_by(& &1.account_id)

      %{moved: moved, expected: expected, all: [w.x, w.tiktok, third, fourth]}
    end

    test "every refused destination, ascending by account id, whatever the caller's order",
         %{w: w, clip: clip, rid: rid, moved: moved, expected: expected, all: all} do
      before = snapshot(moved)

      for order <- permutations(all) do
        assert {:error, {:destinations, ^expected}} = accept(w, clip, rid, order)
      end

      # A (w.x) was never created, nothing else moved, no event was written
      assert snapshot(moved) == before
      assert Repo.aggregate(Post, :count) == 1
      assert send_calls() == []
    end

    test "a single refused destination uses the same envelope", %{
      w: w,
      clip: clip,
      rid: rid,
      third: third
    } do
      assert {:error, {:destinations, [%{account_id: id, reason: :not_the_owner}]}} =
               accept(w, clip, rid, [third])

      assert id == third.id
    end

    test "each destination is decided in the check order, :duplicate_destination last",
         %{w: w, clip: clip, rid: rid, fourth: fourth} do
      # fourth is occupied (duplicate) AND archived: archived is checked first.
      {:ok, _} = Social.archive_account(w.org_id, fourth)

      assert {:error, {:destinations, [%{account_id: id, reason: :account_archived}]}} =
               accept(w, clip, rid, [fourth])

      assert id == fourth.id
    end

    test "all or nothing: a replay plus a new post whose event fails leaves nothing new",
         %{w: w, clip: clip, rid: rid, fifth: fifth, moved: moved} do
      before = write_counts()
      fail_event!("submitted")
      assert_raise Ecto.ConstraintError, fn -> accept(w, clip, rid, [w.x, fifth]) end
      assert write_counts() == before
      assert snapshot(moved) |> elem(0) == fresh(moved)
    end
  end

  describe "several accounts, replays and new posts together" do
    test "existing posts come back unchanged, new ones get one created and one submitted",
         %{w: w, clip: clip, rid: rid} do
      {:ok, %{posts: [first]}} = accept(w, clip, rid, [w.x])
      first_before = Tuple.delete_at(snapshot(first), 3)

      for order <- [[w.x, w.tiktok], [w.tiktok, w.x]] do
        assert {:ok, %{posts: posts}} = accept(w, clip, rid, order)
        assert Enum.map(posts, & &1.account_id) == Enum.sort([w.x.id, w.tiktok.id])
      end

      assert Tuple.delete_at(snapshot(first), 3) == first_before
      new = Repo.get_by!(Post, account_id: w.tiktok.id)
      assert actions(new) == ~w(created submitted)
      assert Repo.aggregate(Post, :count) == 2
    end

    test "with one refused destination nothing new commits and no event is written",
         %{w: w, clip: clip, rid: rid, third: third} do
      {:ok, %{posts: [first]}} = accept(w, clip, rid, [w.x])
      other = user!() |> member!(w.org_id)
      own!(w, third, other)
      before = snapshot(first)

      assert {:error, {:destinations, [%{reason: :not_the_owner}]}} =
               accept(w, clip, rid, [third, w.tiktok, w.x])

      assert snapshot(first) == before
      assert Repo.aggregate(Post, :count) == 1
    end
  end

  defp permutations([]), do: [[]]

  defp permutations(list),
    do: for(x <- list, rest <- permutations(list -- [x]), do: [x | rest])
end
