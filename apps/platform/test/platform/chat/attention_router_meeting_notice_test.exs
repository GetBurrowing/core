defmodule Platform.Chat.AttentionRouterMeetingNoticeTest do
  @moduledoc """
  A meeting notice posted into a user<->agent DM routes to no agent
  (task 01a174e2 stage 2).

  In a DM every message is routed to the agent as `:directed`, so before the
  `meeting_notice?/1` exit in `AttentionRouter.do_route/2` a Meeting Summary
  row woke the DM's agent, and an agent that could not answer posted
  "couldn't reply" under the summary.

  The DM's agent is external with no `runtime_id`, so a dispatch to it ALWAYS
  posts a `ReplyFailure` notice (`AgentResponder.dispatch_to_runtime/2`). The
  positive control below pins that: a plain user message in the same DM does
  produce the notice, so "no notice" after a meeting row is evidence the row
  was not routed, not that the fixture cannot fail. The dedupe window is 0 so
  an earlier notice cannot hide a later one.
  """
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{AttentionRouter, Message, Participant, ReplyFailure}
  alias Platform.Meetings
  alias Platform.Repo

  setup do
    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    previous_window = Application.get_env(:platform, :reply_failure_notice_dedupe_s)

    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)
    Application.put_env(:platform, :reply_failure_notice_dedupe_s, 0)

    on_exit(fn ->
      restore(:chat_agent_dispatch_mode, previous_mode)
      restore(:reply_failure_notice_dedupe_s, previous_window)
    end)

    router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
    Sandbox.allow(Repo, self(), router)

    test_pid = self()
    handler_id = "meeting-notice-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :chat, :attention_routed],
        fn _event, _measurements, meta, _ -> send(test_pid, {:routed, meta}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    user = user!()
    agent = external_agent!()
    {:ok, dm} = Chat.find_or_create_dm(user.id, "agent", agent.id)

    user_p =
      Repo.get_by!(Participant,
        space_id: dm.id,
        participant_type: "user",
        participant_id: user.id
      )

    agent_p =
      Repo.get_by!(Participant,
        space_id: dm.id,
        participant_type: "agent",
        participant_id: agent.id
      )

    %{dm: dm, user_p: user_p, agent_p: agent_p}
  end

  defp restore(key, nil), do: Application.delete_env(:platform, key)
  defp restore(key, value), do: Application.put_env(:platform, key, value)

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "meeting-notice-#{n}@example.com",
      name: "Meeting Notice #{n}",
      oidc_sub: "oidc-meeting-notice-#{n}"
    })
  end

  # External, no runtime_id: any dispatch posts a :no_runtime ReplyFailure.
  defp external_agent! do
    n = System.unique_integer([:positive])

    %Agent{}
    |> Agent.changeset(%{
      slug: "meeting-notice-agent-#{n}",
      name: "Notice Agent #{n}",
      status: "active",
      runtime_type: "external"
    })
    |> Repo.insert!()
  end

  defp drain, do: :ok = GenServer.call(AttentionRouter, :__drain__)

  defp notices(space_id) do
    space_id
    |> Chat.list_messages(limit: 100)
    |> Enum.filter(&ReplyFailure.notice?/1)
  end

  defp only_message_with_source!(space_id, source) do
    assert [%Message{} = message] =
             space_id
             |> Chat.list_messages(limit: 100)
             |> Enum.filter(&((&1.metadata || %{})["source"] == source))

    message
  end

  # Every poster of a meeting notice, keyed by the source it writes.
  @posters %{
    "meeting_summarizer" => &__MODULE__.post_summary/2,
    "meeting_summarizer_fallback" => &__MODULE__.post_fallback/2,
    "meeting_transcription_failure" => &__MODULE__.post_transcription_failure/2,
    "meeting_action_items" => &__MODULE__.post_action_items/2
  }

  def post_summary(space_id, transcript_id),
    do: Meetings.post_summary_to_space(space_id, transcript_id, "## Summary\n\nThey talked.")

  def post_fallback(space_id, transcript_id),
    do:
      Meetings.post_fallback_notice(space_id, transcript_id, %{
        previously_assigned_agent: nil,
        stalled_for_ms: 47_000,
        mode: :completed
      })

  def post_transcription_failure(space_id, transcript_id),
    do: Meetings.post_transcription_failure_to_space(space_id, transcript_id)

  def post_action_items(space_id, transcript_id),
    do: Meetings.post_action_items_to_space(space_id, transcript_id, ["Send the deck"])

  describe "POSITIVE CONTROL: the fixture can fail" do
    test "a plain user message in the DM is routed :directed and produces the notice",
         %{dm: dm, user_p: user_p, agent_p: agent_p} do
      {:ok, message} =
        Chat.post_message(%{
          space_id: dm.id,
          participant_id: user_p.id,
          content_type: "text",
          content: "are you there?"
        })

      drain()

      message_id = message.id
      agent_p_id = agent_p.id

      assert_receive {:routed,
                      %{message_id: ^message_id, recipient_id: ^agent_p_id, reason: :directed}}

      assert [%Message{} = notice] = notices(dm.id)
      assert notice.metadata["message_id"] == message.id
    end
  end

  describe "a meeting notice in a user<->agent DM" do
    for {source, _poster} <- @posters do
      @source source

      test "#{source}: routes to no agent and posts no 'couldn't reply'", %{dm: dm} do
        poster = Map.fetch!(@posters, @source)
        transcript_id = Ecto.UUID.generate()

        assert :ok = poster.(dm.id, transcript_id)
        drain()

        message = only_message_with_source!(dm.id, @source)
        assert message.content_type == "system"
        assert AttentionRouter.meeting_notice?(message)

        # The post's own telemetry-driven routing: nothing routed, no notice.
        message_id = message.id
        refute_received {:routed, %{message_id: ^message_id}}
        assert notices(dm.id) == []

        # The explicit route repeats that path and must be empty too.
        assert {:ok, []} = AttentionRouter.route(message)
        drain()
        assert notices(dm.id) == []
      end
    end
  end

  describe "meeting_notice?/1" do
    test "recognises exactly the four meeting sources, and only as system rows" do
      assert Enum.sort(AttentionRouter.meeting_notice_sources()) ==
               Enum.sort(Map.keys(@posters))

      for source <- Map.keys(@posters) do
        assert AttentionRouter.meeting_notice?(%Message{
                 content_type: "system",
                 metadata: %{"source" => source}
               })

        refute AttentionRouter.meeting_notice?(%Message{
                 content_type: "text",
                 metadata: %{"source" => source}
               })
      end

      refute AttentionRouter.meeting_notice?(%Message{
               content_type: "system",
               metadata: %{"source" => "meetings.say"}
             })

      refute AttentionRouter.meeting_notice?(%Message{content_type: "system", metadata: nil})
      refute AttentionRouter.meeting_notice?(nil)
    end
  end
end
