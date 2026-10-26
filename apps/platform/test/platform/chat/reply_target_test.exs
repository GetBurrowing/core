defmodule Platform.Chat.ReplyTargetTest do
  @moduledoc """
  Task 01a174f5 stage 1: `Platform.Chat.ReplyTarget`, the validation of a
  member's MAIN-LOG reply target, and the `Chat.post_message/2`
  `:reply_to_message_id` attr that uses it. Routing of a kept target is in
  `Platform.Chat.AttentionRouterTest` ("reply target").
  """

  use Platform.DataCase, async: true

  alias Platform.Chat
  alias Platform.Chat.ReplyTarget
  alias Platform.Repo

  defp agent! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Agents.Agent{
      name: "Agent B #{n}",
      slug: "reply-target-agent-#{n}",
      status: "active"
    })
  end

  defp channel! do
    n = System.unique_integer([:positive])
    {:ok, space} = Chat.create_space(%{name: "Reply #{n}", slug: "reply-t-#{n}", kind: "channel"})
    space
  end

  defp member!(space_id) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Member",
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp post!(space_id, participant_id, content, extra \\ %{}) do
    {:ok, msg} =
      Chat.post_message(
        Map.merge(
          %{
            space_id: space_id,
            participant_id: participant_id,
            content_type: "text",
            content: content
          },
          extra
        )
      )

    msg
  end

  setup do
    space = channel!()
    {:ok, agent_p} = Chat.add_agent_participant(space.id, agent!(), display_name: "Agent B")
    member = member!(space.id)
    target = post!(space.id, agent_p.id, "the viewer fix is in review")
    %{space: space, agent_p: agent_p, member: member, target: target}
  end

  describe "validate/3" do
    test "a top-level, agent-authored, same-space target is kept", ctx do
      assert {:ok, %{id: id}} = ReplyTarget.validate(ctx.target.id, ctx.space.id, ctx.member)
      assert id == ctx.target.id
      # The id form of the author works the same.
      assert {:ok, _} = ReplyTarget.validate(ctx.target.id, ctx.space.id, ctx.member.id)
    end

    test "a target in another space is refused as other_space", ctx do
      other = channel!()
      {:ok, other_agent} = Chat.add_agent_participant(other.id, agent!(), display_name: "Agent A")
      foreign = post!(other.id, other_agent.id, "elsewhere")

      # POSITIVE CONTROL: the same message is a valid target in its own space.
      assert {:ok, _} = ReplyTarget.validate(foreign.id, other.id, member!(other.id))

      assert {:drop, "other_space"} = ReplyTarget.validate(foreign.id, ctx.space.id, ctx.member)
    end

    test "a thread message is refused as not_top_level", ctx do
      {:ok, thread} = Chat.create_thread_for_message(ctx.space.id, ctx.target.id)

      in_thread =
        post!(ctx.space.id, ctx.agent_p.id, "inside the thread", %{thread_id: thread.id})

      # Agent-authored and same-space, so only the thread placement differs.
      assert in_thread.participant_id == ctx.agent_p.id

      assert {:drop, "not_top_level"} =
               ReplyTarget.validate(in_thread.id, ctx.space.id, ctx.member)
    end

    test "a human-authored target is refused as not_agent", ctx do
      other_member = member!(ctx.space.id)
      human = post!(ctx.space.id, other_member.id, "a person said this")
      assert is_nil(human.thread_id)

      assert {:drop, "not_agent"} = ReplyTarget.validate(human.id, ctx.space.id, ctx.member)
    end

    test "ReplyContext's checks apply: invalid uuid, missing, deleted", ctx do
      assert {:drop, "invalid_uuid"} = ReplyTarget.validate("nope", ctx.space.id, ctx.member)
      assert {:drop, "invalid_uuid"} = ReplyTarget.validate(42, ctx.space.id, ctx.member)

      assert {:drop, "not_found"} =
               ReplyTarget.validate(Ecto.UUID.generate(), ctx.space.id, ctx.member)

      ctx.target
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond))
      |> Repo.update!()

      assert {:drop, "deleted"} = ReplyTarget.validate(ctx.target.id, ctx.space.id, ctx.member)
    end

    test "a target older than the author's history grant is refused", ctx do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      late =
        ctx.member
        |> Ecto.Changeset.change(history_visible_from: DateTime.truncate(future, :microsecond))
        |> Repo.update!()

      assert {:drop, "outside_grant"} = ReplyTarget.validate(ctx.target.id, ctx.space.id, late)
    end
  end

  describe "Chat.post_message/2 :reply_to_message_id" do
    test "a valid target is stored as metadata reply_to_message_id on a top-level message", ctx do
      reply =
        post!(ctx.space.id, ctx.member.id, "when does it ship?", %{
          reply_to_message_id: ctx.target.id,
          metadata: %{"x" => 1}
        })

      assert reply.thread_id == nil
      assert reply.metadata == %{"x" => 1, "reply_to_message_id" => ctx.target.id}
      # No thread is ever created for the agent's message.
      assert Chat.get_thread_for_message(ctx.target.id) == nil
    end

    test "an invalid target is dropped silently and the message still posts", ctx do
      other_member = member!(ctx.space.id)
      human = post!(ctx.space.id, other_member.id, "a person said this")

      for bad <- ["nope", Ecto.UUID.generate(), human.id] do
        reply = post!(ctx.space.id, ctx.member.id, "still posts", %{reply_to_message_id: bad})
        assert reply.content == "still posts"
        refute Map.has_key?(reply.metadata, "reply_to_message_id")
      end
    end

    test "a message posted with a thread_id never keeps the attr", ctx do
      {:ok, thread} = Chat.create_thread_for_message(ctx.space.id, ctx.target.id)

      reply =
        post!(ctx.space.id, ctx.member.id, "in thread", %{
          thread_id: thread.id,
          reply_to_message_id: ctx.target.id
        })

      assert reply.thread_id == thread.id
      refute Map.has_key?(reply.metadata, "reply_to_message_id")
    end
  end
end
