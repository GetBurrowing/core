defmodule Platform.Social.ClipCopyUpdateLockTest do
  @moduledoc """
  `social_clip_update_copy` against a REAL competing transaction, with the
  interleaving forced, not hoped for.

  A second connection opens a transaction, takes the clip row `FOR UPDATE`
  and changes it (approves it, removes it, or rewrites its copy) WITHOUT
  committing. The tool then runs in a Task, passes its first (unlocked) read
  and must be BLOCKED on that clip row: proved from the database, not from a
  sleep, by `pg_blocking_pids` of the tool's backend naming the holder's pid,
  the tool's backend waiting on a heavyweight lock with its `FOR UPDATE`
  query on `social_clips` as the statement, and a tuple lock on `social_clips`
  taken by it. Nothing has been written at that point. When the holder commits
  the tool decides again on the COMMITTED row: refused, copy unchanged,
  nothing broadcast, no audit event.

  Without the clip's `FOR UPDATE` the tool never blocks (the first assertion
  fails); without the recheck of the editable state or of the copy token under
  the lock, it writes over the holder's change (the last assertions fail).
  The world is committed and removed by hand afterwards. Every wait is bounded.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Platform.SocialFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Federation.ToolArguments
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{AgentDrafts, Clip, ClipReviewFeed, Post}

  setup do
    Sandbox.mode(Repo, :auto)
    w = render_world!()
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

    profile = w.profile |> Ecto.Changeset.change(drafting_agent_id: w.agent.id) |> Repo.update!()
    w = %{w | profile: profile}
    token = ClipReviewFeed.copy_rev(Repo.get!(Clip, clip.id))

    on_exit(fn ->
      try do
        Repo.delete_all(from(p in Post, where: p.clip_id == ^clip.id))
        Repo.delete_all(from(i in Platform.Social.Idea, where: i.profile_id == ^w.profile.id))

        Repo.delete_all(
          from(e in Platform.Audit.Event,
            where:
              e.event_type == "platform.social.clip_copy_updated" and e.resource_id == ^clip.id
          )
        )

        Repo.delete_all(from(c in Clip, where: c.id == ^clip.id))
        Repo.delete_all(from(a in Platform.Social.Account, where: a.profile_id == ^w.profile.id))
        Repo.delete_all(from(p in Platform.Social.Profile, where: p.id == ^w.profile.id))
        Repo.delete_all(from(a in Platform.Agents.Agent, where: a.id == ^w.agent.id))
      after
        Sandbox.mode(Repo, :manual)
      end
    end)

    Phoenix.PubSub.subscribe(Platform.PubSub, Social.clips_topic(w.profile.id))
    %{w: w, clip: clip, token: token, before: Repo.get!(Clip, clip.id)}
  end

  # Holder: its own connection and transaction; locks the clip row, applies
  # `change` (a keyword for update_all), reports its backend pid, and holds
  # everything UNCOMMITTED until `:release` (or ten seconds, then rolls back).
  defp holder(clip, change) do
    parent = self()

    Task.async(fn ->
      Repo.transaction(fn ->
        %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
        _locked = Repo.one(from(c in Clip, where: c.id == ^clip.id, lock: "FOR UPDATE"))
        {1, _} = Repo.update_all(from(c in Clip, where: c.id == ^clip.id), set: change)
        send(parent, {:held, pid})

        receive do
          :release -> :ok
        after
          10_000 -> Repo.rollback(:timeout)
        end
      end)
    end)
  end

  defp tool(ctx, args) do
    Task.async(fn ->
      ToolArguments.dispatch(
        "social_clip_update_copy",
        Map.merge(%{"clip_id" => ctx.clip.id, "expected_copy_rev" => ctx.token}, args),
        %{agent_id: ctx.w.agent.id}
      )
    end)
  end

  # What the database says about who waits on `holder_pid`: the backends it
  # blocks, each with its statement, wait type and the tuple locks it holds on
  # social_clips.
  defp blocked_by(holder_pid) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT a.pid, a.wait_event_type, a.state, a.query,
               (SELECT count(*) FROM pg_locks l
                 WHERE l.pid = a.pid AND l.locktype = 'tuple'
                   AND l.relation = 'social_clips'::regclass)
        FROM pg_stat_activity a
        WHERE $1 = ANY(pg_blocking_pids(a.pid))
        """,
        [holder_pid]
      )

    Enum.map(rows, fn [pid, wait, state, query, tuple_locks] ->
      %{pid: pid, wait: wait, state: state, query: query, tuple_locks: tuple_locks}
    end)
  end

  # pg_blocking_pids/1 is live, but pg_stat_activity is a per-statement
  # snapshot: a backend can already wait on the holder while its snapshot row
  # still says wait_event_type "Client" (seen once: a lock test failed on
  # `blocked.wait == "Lock"`). So poll until the snapshot has caught up, i.e.
  # the waiter reads as a Lock wait, and keep the last observation for the
  # failure message instead of asserting on a half-updated row.
  defp await_blocked(holder_pid, tries \\ 100, last \\ []) do
    case blocked_by(holder_pid) do
      [%{wait: "Lock"} | _] = blocked ->
        blocked

      seen when tries > 0 ->
        Process.sleep(50)
        await_blocked(holder_pid, tries - 1, seen)

      seen ->
        flunk(
          "the tool never showed as a Lock wait on the holder's clip row; " <>
            "last observed waiters: #{inspect(if seen == [], do: last, else: seen)}"
        )
    end
  end

  defp assert_blocked_on_the_clip_row(holder_pid, tool_task) do
    assert [blocked] = await_blocked(holder_pid)
    assert blocked.wait == "Lock"
    assert blocked.query =~ "social_clips"
    assert blocked.query =~ ~r/FOR UPDATE/i
    assert blocked.tuple_locks >= 1, "the waiter holds a tuple lock on social_clips"
    # Still blocked: no result, so nothing has been decided or written.
    assert Task.yield(tool_task, 0) == nil
    :ok
  end

  defp release_and_await(holder_task, tool_task) do
    send(holder_task.pid, :release)
    assert {:ok, _} = Task.await(holder_task, 10_000)
    Task.await(tool_task, 10_000)
  end

  defp assert_nothing_from_the_tool(ctx, expected_clip) do
    now = Repo.get!(Clip, ctx.clip.id)
    assert {now.title, now.caption} == {expected_clip.title, expected_clip.caption}
    refute_receive {:social_clip, _}, 100

    assert Repo.aggregate(
             from(e in Platform.Audit.Event,
               where:
                 e.event_type == "platform.social.clip_copy_updated" and
                   e.resource_id == ^ctx.clip.id
             ),
             :count
           ) == 0

    now
  end

  test "an approval in flight: the tool blocks on the clip row, then refuses clip_not_editable",
       ctx do
    approver_id = ctx.w.approver.id

    holder =
      holder(ctx.clip,
        review_status: "approved",
        reviewed_by_user_id: approver_id,
        reviewed_at: DateTime.utc_now()
      )

    assert_receive {:held, holder_pid}, 5_000
    tool = tool(ctx, %{"title" => "Agent edit", "caption" => "Agent edit caption"})

    assert_blocked_on_the_clip_row(holder_pid, tool)
    # The holder's uncommitted approval is invisible; the committed copy is untouched.
    assert_nothing_from_the_tool(ctx, ctx.before)

    assert {:error, %{code: :clip_not_editable}} = release_and_await(holder, tool)
    now = assert_nothing_from_the_tool(ctx, ctx.before)
    assert now.review_status == "approved"
  end

  test "a removal in flight: the tool blocks on the clip row, then reads it as not found", ctx do
    holder = holder(ctx.clip, removed_at: DateTime.utc_now())
    assert_receive {:held, holder_pid}, 5_000
    tool = tool(ctx, %{"title" => "Agent edit"})

    assert_blocked_on_the_clip_row(holder_pid, tool)
    assert_nothing_from_the_tool(ctx, ctx.before)

    assert {:error, %{code: :not_found}} = release_and_await(holder, tool)
    now = assert_nothing_from_the_tool(ctx, ctx.before)
    assert now.removed_at
  end

  test "a human copy save in flight: the tool blocks, then refuses stale_copy and keeps the human's words",
       ctx do
    holder = holder(ctx.clip, caption: "Human caption", title: "Human title")
    assert_receive {:held, holder_pid}, 5_000
    tool = tool(ctx, %{"title" => "Agent edit"})

    assert_blocked_on_the_clip_row(holder_pid, tool)
    assert_nothing_from_the_tool(ctx, ctx.before)

    assert {:error, %{code: :stale_copy}} = release_and_await(holder, tool)
    now = Repo.get!(Clip, ctx.clip.id)
    assert {now.title, now.caption} == {"Human title", "Human caption"}
    refute_receive {:social_clip, _}, 100
  end
end
