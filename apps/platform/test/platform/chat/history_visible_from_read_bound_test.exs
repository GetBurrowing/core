defmodule Platform.Chat.HistoryVisibleFromReadBoundTest do
  @moduledoc """
  Task 01a0ac64-a959-7001-9ca2-e429535a1bb2 stage 2.

  Stage 1 stamped `chat_participants.history_visible_from` on rows created by
  the mention grant. Stamping it changed nothing observable on its own: the
  agent-facing read, `Chat.list_messages/2`, filtered only on `space_id` and
  `deleted_at`, and `ExternalScope.scope_by_space_id/2` is the IDENTITY clause
  for the nil scope every agent caller passes. So a newly granted agent could
  still read the space from the beginning. This stage bounds that read.

  Every bounded assertion here carries a POSITIVE CONTROL in the same run: the
  pre-grant messages are read back unbounded in the same test. Asserting only
  "the bounded read returned 2 rows" would pass against a rig that never wrote
  the pre-grant messages at all, which is the failure mode this class of test
  has (a green from an empty space proves nothing about a filter).
  """

  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

  defp agent! do
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Platform.Agents.Agent{
        name: "History Reader #{n}",
        slug: "history-reader-#{n}",
        status: "active"
      })

    owner = Platform.TenancyFixtures.root_admin!()

    runtime =
      %Platform.Agents.AgentRuntime{}
      |> Platform.Agents.AgentRuntime.changeset(%{
        runtime_id: "history-reader-#{n}",
        owner_user_id: owner.id,
        agent_id: agent.id,
        auth_token_hash:
          Platform.Agents.AgentRuntime.hash_token(Platform.Agents.AgentRuntime.generate_token()),
        status: "active"
      })
      |> Repo.insert!()

    {:ok, _profile} =
      Platform.Access.RuntimeProfiles.create_for_runtime(
        runtime,
        Platform.Agents.AgentRuntime.default_tool_profile(),
        nil
      )

    agent
  end

  defp channel! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "History #{n}", slug: "history-#{n}", kind: "channel"})

    space
  end

  defp agent_participant!(space_id, agent) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: agent.name,
        role: "member",
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp post!(space_id, participant_id, content, opts \\ []) do
    {:ok, m} =
      Chat.post_message(%{
        space_id: space_id,
        thread_id: Keyword.get(opts, :thread_id),
        participant_id: participant_id,
        content_type: "text",
        content: content
      })

    m
  end

  defp stamp!(%Participant{} = p, %DateTime{} = at) do
    Repo.update!(Ecto.Changeset.change(p, history_visible_from: at))
  end

  defp tool_ids(space_id, agent, opts \\ []) do
    args =
      %{"space_id" => space_id, "limit" => 20}
      |> Map.merge(Map.new(opts, fn {k, v} -> {to_string(k), v} end))

    {:ok, %{messages: messages}} =
      ToolSurface.execute("space_get_messages", args, %{agent_id: agent.id})

    Enum.map(messages, & &1.id)
  end

  describe "Chat.list_messages/2 :as_participant" do
    setup do
      space = channel!()
      agent = agent!()
      p = agent_participant!(space.id, agent)

      pre_a = post!(space.id, p.id, "pre-grant A")
      pre_b = post!(space.id, p.id, "pre-grant B")
      boundary = DateTime.utc_now()
      post_a = post!(space.id, p.id, "post-grant A")
      post_b = post!(space.id, p.id, "post-grant B")

      %{
        space: space,
        agent: agent,
        participant: p,
        boundary: boundary,
        pre: [pre_a.id, pre_b.id],
        post: [post_a.id, post_b.id]
      }
    end

    test "a stamped participant reads only messages at or after the grant", ctx do
      stamped = stamp!(ctx.participant, ctx.boundary)

      bounded = Chat.list_messages(ctx.space.id, as_participant: stamped)
      bounded_ids = Enum.map(bounded, & &1.id)

      # POSITIVE CONTROL, same run: the pre-grant rows really are in the space.
      unbounded_ids = ctx.space.id |> Chat.list_messages() |> Enum.map(& &1.id)
      assert Enum.sort(unbounded_ids) == Enum.sort(ctx.pre ++ ctx.post)

      assert Enum.sort(bounded_ids) == Enum.sort(ctx.post)

      for id <- ctx.pre do
        refute id in bounded_ids
      end
    end

    test "a participant id (not the struct) resolves the same bound", ctx do
      stamp!(ctx.participant, ctx.boundary)

      ids =
        ctx.space.id
        |> Chat.list_messages(as_participant: ctx.participant.id)
        |> Enum.map(& &1.id)

      assert Enum.sort(ids) == Enum.sort(ctx.post)
    end

    test "a NULL history_visible_from leaves the read unbounded", ctx do
      assert is_nil(Repo.get!(Participant, ctx.participant.id).history_visible_from)

      ids =
        ctx.space.id
        |> Chat.list_messages(as_participant: ctx.participant)
        |> Enum.map(& &1.id)

      assert Enum.sort(ids) == Enum.sort(ctx.pre ++ ctx.post)
    end

    test "an absent :as_participant opt is byte-identical to today", ctx do
      stamp!(ctx.participant, ctx.boundary)

      ids = ctx.space.id |> Chat.list_messages() |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort(ctx.pre ++ ctx.post)
    end

    test "the bound composes with the before_id cursor", ctx do
      stamped = stamp!(ctx.participant, ctx.boundary)
      [_post_a, post_b] = ctx.post

      # Unbounded, paging back past the newest post-grant message reaches the
      # pre-grant rows — the positive control for the cursor itself.
      unbounded =
        ctx.space.id
        |> Chat.list_messages(before_id: post_b)
        |> Enum.map(& &1.id)

      assert Enum.any?(unbounded, &(&1 in ctx.pre))

      bounded =
        ctx.space.id
        |> Chat.list_messages(before_id: post_b, as_participant: stamped)
        |> Enum.map(& &1.id)

      assert bounded == [hd(ctx.post)]
    end

    test "the bound composes with the after_id cursor", ctx do
      stamped = stamp!(ctx.participant, ctx.boundary)
      [pre_a, _pre_b] = ctx.pre

      unbounded =
        ctx.space.id
        |> Chat.list_messages(after_id: pre_a, order: :asc)
        |> Enum.map(& &1.id)

      assert Enum.any?(unbounded, &(&1 in ctx.pre))

      bounded =
        ctx.space.id
        |> Chat.list_messages(after_id: pre_a, order: :asc, as_participant: stamped)
        |> Enum.map(& &1.id)

      assert bounded == ctx.post
    end

    test "the bound composes with thread_id", ctx do
      [pre_a, _] = ctx.pre
      {:ok, thread} = Chat.create_thread_for_message(ctx.space.id, pre_a)

      pre_reply = post!(ctx.space.id, ctx.participant.id, "pre reply", thread_id: thread.id)
      boundary = DateTime.utc_now()
      post_reply = post!(ctx.space.id, ctx.participant.id, "post reply", thread_id: thread.id)

      stamped = stamp!(ctx.participant, boundary)

      unbounded =
        ctx.space.id |> Chat.list_messages(thread_id: thread.id) |> Enum.map(& &1.id)

      assert pre_reply.id in unbounded
      assert post_reply.id in unbounded

      bounded =
        ctx.space.id
        |> Chat.list_messages(thread_id: thread.id, as_participant: stamped)
        |> Enum.map(& &1.id)

      assert bounded == [post_reply.id]
    end
  end

  describe "the agent-facing tool surface" do
    setup do
      space = channel!()
      agent = agent!()
      p = agent_participant!(space.id, agent)

      pre = post!(space.id, p.id, "pre-grant tool")
      boundary = DateTime.utc_now()
      post = post!(space.id, p.id, "post-grant tool")

      %{space: space, agent: agent, participant: p, boundary: boundary, pre: pre, post: post}
    end

    test "space_get_messages hides pre-grant history from a stamped agent", ctx do
      stamp!(ctx.participant, ctx.boundary)

      ids = tool_ids(ctx.space.id, ctx.agent)

      # POSITIVE CONTROL, same run: the pre-grant message is in the space and
      # a direct unbounded read still returns it.
      unbounded = ctx.space.id |> Chat.list_messages() |> Enum.map(& &1.id)
      assert ctx.pre.id in unbounded

      assert ids == [ctx.post.id]
      refute ctx.pre.id in ids
    end

    test "space_get_messages is unchanged for an agent with NULL history_visible_from", ctx do
      ids = tool_ids(ctx.space.id, ctx.agent)

      assert Enum.sort(ids) == Enum.sort([ctx.pre.id, ctx.post.id])
    end
  end
end
