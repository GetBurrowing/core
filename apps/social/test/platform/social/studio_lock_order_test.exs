defmodule Platform.Social.StudioLockOrderTest do
  @moduledoc """
  The Studio lock order, proved from the SQL each write sends: the profile row
  first, then the account row(s) in ASCENDING id order, then the post (the clip
  for `accept_render/4`), whatever order the caller named the accounts in
  (the locked-row rule). `FOR SHARE` locks do not conflict
  with each other, so the order is asserted on the statements themselves, not
  on a deadlock that cannot happen in a single connection.
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Platform.Social
  alias Platform.Social.{AgentDrafts, Studio}

  setup do
    w = studio_world!()
    clip = w |> pending_clip!() |> make_studio_clip!()

    {:ok, third} =
      Social.create_account(w.org_id, w.profile, %{platform: "linkedin", handle: "@lock3"})

    %{w: w, clip: clip, rid: render_id!(clip), third: third}
  end

  # The lock statements `fun` sends in this process, in order:
  # `{table, first_param}` where `table` is :profile, :account, :post or :clip.
  defp lock_trace(fun) do
    parent = self()
    id = "lock-trace-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:platform, :repo, :query],
      fn _event, _measurements, %{query: query, params: params}, _config ->
        if self() == parent, do: send(parent, {:sql, query, params})
      end,
      nil
    )

    try do
      result = fun.()
      {result, collect([])}
    after
      :telemetry.detach(id)
    end
  end

  defp collect(acc) do
    receive do
      {:sql, query, params} -> collect(lock_of(query, params) ++ acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  @tables [
    {~s(FROM "social_profiles"), :profile},
    {~s(FROM "social_accounts"), :account},
    {~s(FROM "social_posts"), :post},
    {~s(FROM "social_clips"), :clip}
  ]

  defp lock_of(query, params) do
    if query =~ ~r/FOR (SHARE|UPDATE)\s*$/ do
      case Enum.find(@tables, fn {from, _} -> String.contains?(query, from) end) do
        {_, table} -> [{table, id_param(params)}]
        nil -> []
      end
    else
      []
    end
  end

  defp id_param([first | _]) when is_binary(first) do
    case Ecto.UUID.cast(first) do
      {:ok, id} -> id
      :error -> first
    end
  end

  defp id_param(_), do: nil

  # Each attempt (one `profile` lock starts it) is profile, accounts ascending,
  # then exactly one post or clip. `:clip` (accept_render) may then be followed
  # by the locked posts it replays, never by anything else: the replayed post is
  # the last lock (profile, accounts, clip, post).
  defp assert_ordered(trace, final) do
    segments =
      trace
      |> Enum.chunk_while(
        [],
        fn
          {:profile, _} = p, [] -> {:cont, [p]}
          {:profile, _} = p, acc -> {:cont, Enum.reverse(acc), [p]}
          other, acc -> {:cont, [other | acc]}
        end,
        fn
          [] -> {:cont, []}
          acc -> {:cont, Enum.reverse(acc), []}
        end
      )
      |> Enum.map(&Enum.reverse(&1))
      |> Enum.map(&Enum.reverse/1)

    assert segments != [], "no lock statements were seen"

    for seg <- segments do
      assert [{:profile, _} | rest] = seg, "the profile row must be locked first: #{inspect(seg)}"
      {accounts, tail} = Enum.split_while(rest, &match?({:account, _}, &1))
      ids = Enum.map(accounts, &elem(&1, 1))
      assert accounts != []

      assert ids == Enum.sort(ids),
             "accounts must be locked in ascending id order: #{inspect(ids)}"

      assert ids == Enum.uniq(ids)

      case {final, tail} do
        {:clip, [{:clip, _} | posts]} ->
          assert Enum.all?(posts, &match?({:post, _}, &1)),
                 "after the clip only replayed posts are locked: #{inspect(tail)}"

        _ ->
          assert [{^final, _}] = tail,
                 "after the accounts only the #{final} row is locked: #{inspect(tail)}"
      end
    end

    segments
  end

  defp lock_ids(segments), do: for(seg <- segments, {:account, id} <- seg, do: id)

  test "approve, plan, cancel, revoke, request_changes, resubmit: profile, account, post", %{w: w} do
    post = submitted_post!(w, w.x)

    {{:ok, %{post: approved, approval: receipt}}, t} =
      lock_trace(fn -> Studio.approve_version(w.org_id, post.id, w.approver.id, expect(post)) end)

    assert_ordered(t, :post)

    at = DateTime.add(DateTime.utc_now(), 3_600, :second)

    {{:ok, %{post: planned}}, t} =
      lock_trace(fn ->
        Studio.plan_post(w.org_id, approved.id, w.approver.id, expect(approved), at)
      end)

    assert_ordered(t, :post)

    {{:ok, cancelled}, t} =
      lock_trace(fn ->
        Studio.cancel_plan(w.org_id, planned.id, w.approver.id, expect(planned))
      end)

    assert_ordered(t, :post)

    {{:ok, revoked}, t} =
      lock_trace(fn ->
        Studio.revoke_approval(
          w.org_id,
          cancelled.id,
          w.approver.id,
          expect(cancelled, %{approval_id: receipt.id}),
          "why"
        )
      end)

    assert_ordered(t, :post)

    {{:ok, rejected}, t} =
      lock_trace(fn ->
        Studio.request_changes(w.org_id, revoked.id, w.approver.id, expect(revoked), "fix")
      end)

    assert_ordered(t, :post)

    {{:ok, _}, t} =
      lock_trace(fn ->
        Studio.resubmit(w.org_id, rejected.id, w.approver.id, expect(rejected), "done")
      end)

    assert_ordered(t, :post)
  end

  test "save_version edit and the agent delegate: profile, account, post", %{w: w} do
    post = submitted_post!(w, w.x)

    {{:ok, %{post: edited}}, t} =
      lock_trace(fn ->
        Studio.save_version(
          w.org_id,
          post.id,
          {:human, w.approver.id},
          %{body: "edit"},
          expect(post)
        )
      end)

    assert_ordered(t, :post)

    {{:ok, _}, t} =
      lock_trace(fn ->
        AgentDrafts.update_agent_draft(w.scope, edited.id, %{"body" => "agent"},
          agent_id: w.agent.id
        )
      end)

    assert_ordered(t, :post)
  end

  test "a retarget locks old and new account in ascending id order, either way round",
       %{w: w, third: third} do
    [low, high] = Enum.sort_by([w.x, third], & &1.id)

    for {from, to} <- [{low, high}, {high, low}] do
      post = submitted_post!(w, from)

      {{:ok, _}, t} =
        lock_trace(fn ->
          Studio.save_version(
            w.org_id,
            post.id,
            {:human, w.approver.id},
            %{account_id: to.id},
            expect(post)
          )
        end)

      segments = assert_ordered(t, :post)
      assert lock_ids(segments) == [low.id, high.id]
    end
  end

  test "accept_render locks the destinations ascending, whatever order they are named in",
       %{w: w, clip: clip, rid: rid, third: third} do
    all = [w.x, w.tiktok, third]
    sorted = all |> Enum.map(& &1.id) |> Enum.sort()

    for order <- [all, Enum.reverse(all), Enum.shuffle(all)] do
      {result, t} =
        lock_trace(fn ->
          Studio.accept_render(w.org_id, clip.id, w.approver.id, %{
            render_id: rid,
            account_ids: Enum.map(order, & &1.id)
          })
        end)

      assert {:ok, _} = result
      segments = assert_ordered(t, :clip)
      assert lock_ids(segments) == sorted
    end
  end

  test "a replay of a retargeted post locks the current account too, still ascending",
       %{w: w, clip: clip, rid: rid, third: third} do
    {:ok, %{posts: [post]}} =
      Studio.accept_render(w.org_id, clip.id, w.approver.id, %{
        render_id: rid,
        account_ids: [w.x.id]
      })

    {:ok, _} =
      Studio.save_version(
        w.org_id,
        post.id,
        {:human, w.approver.id},
        %{account_id: third.id},
        expect(post)
      )

    {result, t} =
      lock_trace(fn ->
        Studio.accept_render(w.org_id, clip.id, w.approver.id, %{
          render_id: rid,
          account_ids: [w.x.id]
        })
      end)

    assert {:ok, %{posts: [again]}} = result
    assert again.account_id == third.id
    segments = assert_ordered(t, :clip)

    # The replayed post is locked (FOR UPDATE), after the clip, and is the row
    # returned: the last lock of the last pass.
    assert [{:clip, _}, {:post, _}] = List.last(segments) |> Enum.take(-2)

    assert List.last(segments)
           |> Enum.filter(&match?({:account, _}, &1))
           |> Enum.map(&elem(&1, 1)) ==
             Enum.sort([w.x.id, third.id])
  end
end
