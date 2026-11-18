defmodule Platform.Responsibilities.Handlers.MeetingSummarizeReturnTest do
  @moduledoc """
  The return path for a `meetings.summarize` job delegated to a native or
  federated agent (a Claude Code runtime, for one).

  The Router sends such an agent a one-way signal (`dispatch_native/6`), so
  its reply is never read and never reaches `handle_output/3`. Before the
  `meeting_summary_complete` tool, the prompt even told it to "return the
  summary as plain text", which went nowhere: the transcript stayed
  `processing`, holding the router claim, with no summary and no reason.

  Covered here, end to end:

    * the prompt a native assignee receives names the tool, the transcript
      id and the input hash; an external (HTTP) agent's prompt does not;
    * the tool persists the summary through `handle_output/3`;
    * every refusal leaves the row untouched.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation.ToolSurface
  alias Platform.Meetings
  alias Platform.Meetings.Transcript
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.MeetingSummarize
  alias Platform.Responsibilities.Router
  alias Platform.Roles

  @capture_key :meeting_summarize_return_capture_pid

  defmodule CaptureDispatcher do
    @moduledoc false
    def maybe_dispatch(signal) do
      pid = Application.get_env(:platform, :meeting_summarize_return_capture_pid)
      if is_pid(pid), do: send(pid, {:captured_signal, signal})
      :ok
    end
  end

  setup do
    Application.put_env(:platform, @capture_key, self())

    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {CaptureDispatcher, :maybe_dispatch}
    )

    on_exit(fn ->
      Application.delete_env(:platform, @capture_key)
      Application.delete_env(:platform, :responsibility_router_native_dispatcher)
    end)

    :ok
  end

  # A Claude Code runtime's shape: a native agent on an external runtime.
  defp federated_agent! do
    %Agent{}
    |> Agent.changeset(%{
      slug: "summary-return-#{System.unique_integer([:positive])}",
      name: "Summary Return",
      status: "active",
      kind: "native",
      runtime_type: "external"
    })
    |> Repo.insert!()
  end

  defp assign!(agent) do
    {:ok, _} = Roles.set_override(MeetingSummarize.key(), agent.id)
    agent
  end

  defp responsibility_row! do
    case Responsibilities.get_by_key(MeetingSummarize.key()) do
      nil ->
        [attrs] = MeetingSummarize.register()
        {:ok, row} = Responsibilities.create_responsibility(attrs)
        row

      row ->
        row
    end
  end

  defp space! do
    {:ok, space} = Chat.create_space(%{kind: "execution"})
    _ = ExecutionSpace.ensure_system_participant(space.id)
    space
  end

  defp transcript!(space, opts \\ []) do
    {:ok, transcript} =
      Meetings.create_transcript(%{
        room_id: "space-#{space.id}",
        space_id: space.id,
        status: Keyword.get(opts, :status, "processing"),
        segments: [
          %{"speaker_name" => "Sam", "text" => "We ship on Friday.", "start_time" => 0}
        ]
      })

    if Keyword.get(opts, :claimed, true) do
      {:ok, :claimed} = Meetings.claim_router_dispatch(transcript.id)
    end

    Meetings.get_transcript(transcript.id)
  end

  defp call_tool(agent, args),
    do: ToolSurface.execute("meeting_summary_complete", args, %{agent: agent})

  describe "the prompt a dispatch carries" do
    test "a native assignee is told to return through meeting_summary_complete" do
      agent = federated_agent!() |> assign!()
      space = space!()
      transcript = transcript!(space, claimed: false)

      capture_log(fn ->
        Router.fire_trigger(
          responsibility_row!(),
          %{
            kind: :event_topic,
            payload: %{transcript_id: transcript.id, space_id: space.id}
          },
          %{}
        )
      end)

      assert_receive {:captured_signal, signal}, 2_000
      prompt = signal.metadata.prompt

      assert prompt =~ "We ship on Friday."
      assert prompt =~ "meeting_summary_complete"
      assert prompt =~ transcript.id
      assert prompt =~ Transcript.summary_fingerprint(transcript)
      # The instruction that lost every summary is gone.
      refute prompt =~ "plain text"
      assert signal.metadata.agent_slug == agent.slug
    end

    test "an external agent's prompt does not mention the tool: its reply IS the output" do
      context = %{
        agent_kind: :ext_single_responsibility,
        meeting_transcript: %{
          transcript_id: Ecto.UUID.generate(),
          summary_input_hash: "h",
          formatted_text: "[00:00:00] Sam: Hi"
        }
      }

      assert {:ok, %{system: system, user: user}} = MeetingSummarize.build_prompt(context)
      refute system <> user =~ "meeting_summary_complete"

      # Control: the same context for a federated runtime does carry it.
      assert {:ok, %{user: fed_user}} =
               MeetingSummarize.build_prompt(%{context | agent_kind: :fed_conversational})

      assert fed_user =~ "meeting_summary_complete"
    end

    test "an unclassified caller keeps the reply-is-the-output prompt" do
      context = %{
        meeting_transcript: %{transcript_id: Ecto.UUID.generate(), formatted_text: "x: y"}
      }

      assert {:ok, %{user: user}} = MeetingSummarize.build_prompt(context)
      refute user =~ "meeting_summary_complete"
    end
  end

  describe "meeting_summary_complete" do
    test "the assignee's summary is persisted and posted, and the row leaves processing" do
      agent = federated_agent!() |> assign!()
      space = space!()
      transcript = transcript!(space)

      assert {:ok, %{transcript_id: id, status: "complete", posted: true}} =
               call_tool(agent, %{
                 "transcript_id" => transcript.id,
                 "summary_input_hash" => Transcript.summary_fingerprint(transcript),
                 "summary" => "## Overview\nShip Friday."
               })

      assert id == transcript.id
      saved = Meetings.get_transcript(transcript.id)
      assert saved.status == "complete"
      assert saved.summary =~ "Ship Friday."
      assert Transcript.summary_current?(saved)

      assert Enum.any?(Chat.list_messages(space.id) || [], fn m ->
               m.metadata["transcript_id"] == transcript.id and
                 m.metadata["source"] == "meeting_summarizer"
             end)

      # A replay is refused, not double-posted.
      assert {:error, %{code: :already_complete}} =
               call_tool(agent, %{"transcript_id" => transcript.id, "summary" => "again"})
    end

    test "the hash is optional; without it the current transcript is summarised" do
      agent = federated_agent!() |> assign!()
      transcript = transcript!(space!())

      assert {:ok, %{status: "complete"}} =
               call_tool(agent, %{"transcript_id" => transcript.id, "summary" => "Short."})
    end

    test "refusals leave the row processing and claimed" do
      agent = federated_agent!() |> assign!()
      other = federated_agent!()
      transcript = transcript!(space!())

      refusals = [
        {other, %{"transcript_id" => transcript.id, "summary" => "x"}, :not_summary_assignee},
        {agent, %{"transcript_id" => transcript.id, "summary" => "   "}, :blank_summary},
        {agent,
         %{
           "transcript_id" => transcript.id,
           "summary" => "x",
           "summary_input_hash" => "not-the-hash"
         }, :stale_summary_input},
        {agent, %{"transcript_id" => Ecto.UUID.generate(), "summary" => "x"},
         :transcript_not_found}
      ]

      for {caller, args, code} <- refusals do
        assert {:error, %{code: ^code}} = call_tool(caller, args)
      end

      row = Meetings.get_transcript(transcript.id)
      assert row.status == "processing"
      assert is_nil(row.summary)
      assert row.router_dispatched_at
    end

    test "a transcript that was never dispatched, or is still recording, is not awaiting a summary" do
      agent = federated_agent!() |> assign!()
      space = space!()

      for transcript <- [
            transcript!(space, claimed: false),
            transcript!(space, status: "recording")
          ] do
        assert {:error, %{code: :not_awaiting_summary}} =
                 call_tool(agent, %{"transcript_id" => transcript.id, "summary" => "x"})
      end
    end

    test "is in the meetings bundle, which every runtime's default profile holds" do
      tool = Enum.find(ToolSurface.tool_definitions(), &(&1.name == "meeting_summary_complete"))
      assert tool.bundle == "meetings"
      assert tool.parameters.transcript_id.required
      assert tool.parameters.summary.required
      refute tool.parameters.summary_input_hash.required
      assert "meetings" in Platform.Agents.AgentRuntime.default_tool_profile()
    end

    test "without an authenticated agent the call is refused" do
      assert {:error, %{code: :unauthorized}} =
               ToolSurface.execute(
                 "meeting_summary_complete",
                 %{"transcript_id" => Ecto.UUID.generate(), "summary" => "x"},
                 %{}
               )
    end
  end
end
