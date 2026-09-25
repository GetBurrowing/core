defmodule Platform.Chat.ReplyContextTest do
  @moduledoc """
  Task 01a0d8de stage 2: `Platform.Chat.ReplyContext.normalize/3`, the
  validation of the optional `in_reply_to_message_id` and `context` fields a
  federated runtime may put on a reply frame. The wire-level half (the channel
  merges the additions and reports `dropped` in its ack) is in
  `PlatformWeb.RuntimeChannelTest`.
  """

  use Platform.DataCase, async: true

  alias Platform.Chat
  alias Platform.Chat.ReplyContext
  alias Platform.Repo

  defp agent! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Agents.Agent{
      name: "Reply Ctx Agent #{n}",
      slug: "reply-ctx-agent-#{n}",
      status: "active"
    })
  end

  defp channel! do
    n = System.unique_integer([:positive])
    {:ok, space} = Chat.create_space(%{name: "Reply #{n}", slug: "reply-#{n}", kind: "channel"})
    space
  end

  defp post!(space_id, participant_id, content) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: content
      })

    msg
  end

  # The at-bracket opener, built at runtime so no literal token sits in source.
  defp opener, do: "@" <> "["

  setup do
    agent = agent!()
    space = channel!()
    {:ok, participant} = Chat.add_agent_participant(space.id, agent)
    %{agent: agent, space: space, participant: participant}
  end

  describe "in_reply_to_message_id" do
    test "(a) a same-space target is kept under reply_to_message_id", ctx do
      target = post!(ctx.space.id, ctx.participant.id, "the question")

      assert {%{"reply_to_message_id" => id}, []} =
               ReplyContext.normalize(
                 %{"in_reply_to_message_id" => target.id},
                 ctx.space.id,
                 ctx.participant.id
               )

      assert id == target.id
    end

    test "(b) a target in another space the agent can also write to is dropped as other_space",
         ctx do
      other = channel!()
      {:ok, other_participant} = Chat.add_agent_participant(other.id, ctx.agent)
      target = post!(other.id, other_participant.id, "elsewhere")

      assert {additions, [%{field: "in_reply_to_message_id", reason: "other_space"}]} =
               ReplyContext.normalize(
                 %{"in_reply_to_message_id" => target.id},
                 ctx.space.id,
                 ctx.participant.id
               )

      refute Map.has_key?(additions, "reply_to_message_id")
    end

    test "(c) a non-UUID is dropped as invalid_uuid", ctx do
      for bad <- ["not-a-uuid", "", 42, %{"id" => "x"}] do
        assert {%{}, [%{field: "in_reply_to_message_id", reason: "invalid_uuid"}]} ==
                 ReplyContext.normalize(
                   %{"in_reply_to_message_id" => bad},
                   ctx.space.id,
                   ctx.participant.id
                 )
      end
    end

    test "(c) an unknown id is dropped as not_found", ctx do
      assert {%{}, [%{field: "in_reply_to_message_id", reason: "not_found"}]} ==
               ReplyContext.normalize(
                 %{"in_reply_to_message_id" => Ecto.UUID.generate()},
                 ctx.space.id,
                 ctx.participant.id
               )
    end

    test "(c) a deleted target is dropped as deleted", ctx do
      target = post!(ctx.space.id, ctx.participant.id, "to be deleted")
      {:ok, _} = Chat.delete_message(target)

      assert {%{}, [%{field: "in_reply_to_message_id", reason: "deleted"}]} ==
               ReplyContext.normalize(
                 %{"in_reply_to_message_id" => target.id},
                 ctx.space.id,
                 ctx.participant.id
               )
    end

    test "(c) a target older than the agent's history_visible_from is dropped as outside_grant",
         ctx do
      target = post!(ctx.space.id, ctx.participant.id, "before the grant")

      {:ok, bounded} =
        Chat.update_participant(ctx.participant, %{
          history_visible_from: DateTime.add(target.inserted_at, 1, :second)
        })

      assert {%{}, [%{field: "in_reply_to_message_id", reason: "outside_grant"}]} ==
               ReplyContext.normalize(
                 %{"in_reply_to_message_id" => target.id},
                 ctx.space.id,
                 bounded.id
               )
    end

    # Positive control for outside_grant: a grant exactly at the target's
    # insert time keeps it (the `>=` of `bound_by_history_grant`), so the
    # drop above is the bound and not a blanket refusal of bounded agents.
    test "a target inserted exactly at history_visible_from is kept", ctx do
      target = post!(ctx.space.id, ctx.participant.id, "at the grant")

      {:ok, bounded} =
        Chat.update_participant(ctx.participant, %{history_visible_from: target.inserted_at})

      assert {%{"reply_to_message_id" => id}, []} =
               ReplyContext.normalize(
                 %{"in_reply_to_message_id" => target.id},
                 ctx.space.id,
                 bounded.id
               )

      assert id == target.id
    end

    test "an absent or null field is neither stored nor reported", ctx do
      assert {%{}, []} == ReplyContext.normalize(%{}, ctx.space.id, ctx.participant.id)

      assert {%{}, []} ==
               ReplyContext.normalize(
                 %{"in_reply_to_message_id" => nil, "context" => nil},
                 ctx.space.id,
                 ctx.participant.id
               )
    end
  end

  describe "context" do
    test "(a) a plain line is stored under reply_context", ctx do
      assert {%{"reply_context" => "Answering the PWA task stage 4"}, []} ==
               ReplyContext.normalize(
                 %{"context" => "  Answering the PWA task stage 4  "},
                 ctx.space.id,
                 ctx.participant.id
               )
    end

    test "(d) a 500-character context is capped at 200 graphemes ending in an ellipsis", ctx do
      long = String.duplicate("abcde", 100)

      assert {%{"reply_context" => stored}, []} =
               ReplyContext.normalize(%{"context" => long}, ctx.space.id, ctx.participant.id)

      assert String.length(stored) == 200
      assert String.ends_with?(stored, "…")
      assert String.starts_with?(long, String.trim_trailing(stored, "…"))
    end

    test "(d) the cap counts graphemes, not bytes", ctx do
      # 200 multi-byte graphemes fit exactly and are not cut.
      exact = String.duplicate("é", 200)

      assert {%{"reply_context" => ^exact}, []} =
               ReplyContext.normalize(%{"context" => exact}, ctx.space.id, ctx.participant.id)
    end

    test "(d) a multi-line context becomes one line with single spaces", ctx do
      assert {%{"reply_context" => "first line second line third"}, []} ==
               ReplyContext.normalize(
                 %{"context" => "first line\r\n\n  second\tline\n\nthird\n"},
                 ctx.space.id,
                 ctx.participant.id
               )
    end

    test "(d) control characters are stripped", ctx do
      assert {%{"reply_context" => "abcdef"}, []} ==
               ReplyContext.normalize(
                 %{"context" => "abc" <> <<0>> <> "d" <> <<27>> <> "ef"},
                 ctx.space.id,
                 ctx.participant.id
               )
    end

    test "(d) a non-string context is dropped as not_string", ctx do
      for bad <- [42, true, ["a"], %{"a" => 1}] do
        assert {%{}, [%{field: "context", reason: "not_string"}]} ==
                 ReplyContext.normalize(%{"context" => bad}, ctx.space.id, ctx.participant.id)
      end
    end

    test "a context that is empty after sanitising is dropped as empty", ctx do
      for blank <- ["", "   ", "\n\t\n", <<0, 1, 2>>] do
        assert {%{}, [%{field: "context", reason: "empty"}]} ==
                 ReplyContext.normalize(%{"context" => blank}, ctx.space.id, ctx.participant.id)
      end
    end

    test "(e) a mention token in context is stored with no at-bracket sequence left", ctx do
      token = opener() <> ctx.agent.slug <> "]"
      raw = "please ask " <> token <> " about it"

      # The fixture really carries the sequence the parser matches.
      assert String.contains?(raw, opener())

      assert {%{"reply_context" => stored}, []} =
               ReplyContext.normalize(%{"context" => raw}, ctx.space.id, ctx.participant.id)

      refute String.contains?(stored, opener())
      assert stored == "please ask ＠[" <> ctx.agent.slug <> "] about it"
    end

    test "(e) a here-token in context is escaped too", ctx do
      raw = "cc " <> opener() <> "here]"

      assert {%{"reply_context" => stored}, []} =
               ReplyContext.normalize(%{"context" => raw}, ctx.space.id, ctx.participant.id)

      refute String.contains?(stored, opener())
    end
  end

  test "both fields together, one valid and one dropped, report only the dropped one", ctx do
    assert {%{"reply_context" => "ok"}, [%{field: "in_reply_to_message_id", reason: "not_found"}]} ==
             ReplyContext.normalize(
               %{"in_reply_to_message_id" => Ecto.UUID.generate(), "context" => "ok"},
               ctx.space.id,
               ctx.participant.id
             )
  end
end
