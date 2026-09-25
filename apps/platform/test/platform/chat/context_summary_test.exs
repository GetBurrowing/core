defmodule Platform.Chat.ContextSummaryTest do
  @moduledoc """
  Task 01a0d8de stage 1: `Platform.Chat.ContextSummary.summarize/3`.

  Every scope assertion is made on the messages the STUB PROVIDER received,
  not on the returned text, because the provider is the boundary the
  viewer's grant must not be crossed at. Each exclusion carries a positive
  control in the same test: the excluded message is shown to exist (read
  back unbounded), so a green cannot come from a space that never held it.

  `async: false`: the stub and the config are app env.
  """

  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.ContextSummary
  alias Platform.Chat.ContextSummaryCache
  alias Platform.Chat.ExternalScope
  alias Platform.Chat.Participant
  alias Platform.Experiments
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Variant
  alias Platform.Test.ChatContextSummaryStub, as: Stub

  @reply "Rowan asked which tasks need approval.\nThe agent answers that six are waiting."

  defp unique, do: System.unique_integer([:positive])

  defp sentinel(tag), do: "SENT#{tag}X#{unique()}"

  defp channel! do
    n = unique()

    {:ok, space} =
      Chat.create_space(%{name: "Context #{n}", slug: "context-#{n}", kind: "channel"})

    space
  end

  defp user! do
    n = unique()

    Repo.insert!(%User{
      name: "Viewer #{n}",
      email: "context-summary-#{n}@example.com",
      oidc_sub: "sub-context-summary-#{n}"
    })
  end

  defp agent! do
    n = unique()

    Repo.insert!(%Platform.Agents.Agent{
      name: "Context Agent #{n}",
      slug: "context-agent-#{n}",
      status: "active"
    })
  end

  defp participant!(space_id, type, id, name) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: type,
        participant_id: id,
        display_name: name,
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

  defp setup_space(_ctx) do
    space = channel!()
    user = user!()
    agent = agent!()
    viewer = participant!(space.id, "user", user.id, user.name)
    agent_p = participant!(space.id, "agent", agent.id, agent.name)
    %{space: space, viewer: viewer, agent_p: agent_p}
  end

  # Everything the provider was shown on the next call, as one string.
  defp provider_input! do
    assert_receive {:context_summary_stub_called, _creds, messages, opts}
    {Enum.map_join(messages, "\n", & &1.content), opts}
  end

  defp attach_telemetry! do
    id = "context-summary-test-#{unique()}"
    pid = self()

    :telemetry.attach(
      id,
      [:platform, :chat, :context_summary],
      fn _event, measurements, metadata, _ ->
        send(pid, {:summary_event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp cache_keys_for(message_id) do
    ContextSummaryCache.table()
    |> :ets.tab2list()
    |> Enum.filter(fn {{id, _scope}, _v, _exp} -> id == message_id end)
  end

  setup :setup_space

  describe "thread isolation" do
    setup do
      Stub.install!(Stub.text(@reply))
    end

    test "a top-level agent message never reads thread replies", ctx do
      top = sentinel("TOP")
      in_thread = sentinel("THREAD")

      root = post!(ctx.space.id, ctx.viewer.id, "root #{top}")
      {:ok, thread} = Chat.create_thread_for_message(ctx.space.id, root.id)
      reply = post!(ctx.space.id, ctx.viewer.id, "reply #{in_thread}", thread_id: thread.id)
      agent_msg = post!(ctx.space.id, ctx.agent_p.id, "you need to take action on 6")

      # POSITIVE CONTROL: the thread reply is in the space and precedes the agent message.
      assert reply.id in Enum.map(Chat.list_messages(ctx.space.id, thread_id: thread.id), & &1.id)

      assert {:ok, result} = ContextSummary.summarize(agent_msg, ctx.viewer)
      {input, _opts} = provider_input!()

      assert input =~ top
      refute input =~ in_thread
      assert result.source_message_ids == [root.id]
    end

    test "a threaded agent message never reads the top level or a sibling thread", ctx do
      top = sentinel("TOP")
      mine = sentinel("MINE")
      sibling = sentinel("SIBLING")

      root = post!(ctx.space.id, ctx.viewer.id, "root #{top}")
      other_root = post!(ctx.space.id, ctx.viewer.id, "other root")
      {:ok, thread} = Chat.create_thread_for_message(ctx.space.id, root.id)
      {:ok, other} = Chat.create_thread_for_message(ctx.space.id, other_root.id)

      _sib = post!(ctx.space.id, ctx.viewer.id, "sibling #{sibling}", thread_id: other.id)
      in_thread = post!(ctx.space.id, ctx.viewer.id, "question #{mine}", thread_id: thread.id)

      agent_msg =
        post!(ctx.space.id, ctx.agent_p.id, "answer", thread_id: thread.id)

      # POSITIVE CONTROL: the top-level root and the sibling reply both exist.
      all_ids = Enum.map(Chat.list_messages(ctx.space.id), & &1.id)
      assert root.id in all_ids
      assert length(all_ids) == 5

      assert {:ok, result} = ContextSummary.summarize(agent_msg, ctx.viewer)
      {input, _opts} = provider_input!()

      assert input =~ mine
      refute input =~ top
      refute input =~ sibling
      assert result.source_message_ids == [in_thread.id]
    end
  end

  describe "the viewer's history grant" do
    setup do
      Stub.install!(Stub.text(@reply))
    end

    test "a bounded viewer never sees a message before their grant; an unbounded one does",
         ctx do
      early = sentinel("EARLY")
      late = sentinel("LATE")

      early_msg = post!(ctx.space.id, ctx.agent_p.id, "early #{early}")
      boundary = DateTime.utc_now()
      late_msg = post!(ctx.space.id, ctx.agent_p.id, "late #{late}")
      agent_msg = post!(ctx.space.id, ctx.agent_p.id, "the answer")

      user2 = user!()
      bounded = participant!(ctx.space.id, "user", user2.id, user2.name) |> stamp!(boundary)

      # Unbounded viewer (NULL grant): positive control for the early message.
      assert is_nil(ctx.viewer.history_visible_from)
      assert {:ok, open} = ContextSummary.summarize(agent_msg, ctx.viewer)
      {open_input, _} = provider_input!()
      assert open_input =~ early
      assert open.source_message_ids == [early_msg.id, late_msg.id]

      assert {:ok, narrow} = ContextSummary.summarize(agent_msg, bounded)
      {narrow_input, _} = provider_input!()
      refute narrow_input =~ early
      assert narrow_input =~ late
      assert narrow.source_message_ids == [late_msg.id]

      # Two bounds, two entries: the bounded viewer was NOT served the open summary.
      assert length(cache_keys_for(agent_msg.id)) == 2
    end

    test "two viewers with the same bound share one entry", ctx do
      post!(ctx.space.id, ctx.agent_p.id, "earlier")
      agent_msg = post!(ctx.space.id, ctx.agent_p.id, "the answer")

      user2 = user!()
      second = participant!(ctx.space.id, "user", user2.id, user2.name)

      assert {:ok, _} = ContextSummary.summarize(agent_msg, ctx.viewer)
      assert_receive {:context_summary_stub_called, _, _, _}
      assert {:ok, _} = ContextSummary.summarize(agent_msg, second)
      refute_receive {:context_summary_stub_called, _, _, _}, 50

      assert length(cache_keys_for(agent_msg.id)) == 1
    end

    test "a viewer participant from another space is refused", ctx do
      post!(ctx.space.id, ctx.agent_p.id, "earlier")
      agent_msg = post!(ctx.space.id, ctx.agent_p.id, "the answer")

      other = channel!()
      stranger = participant!(other.id, "user", user!().id, "Stranger")

      assert {:error, :not_a_participant} = ContextSummary.summarize(agent_msg, stranger)
      refute_receive {:context_summary_stub_called, _, _, _}, 50
    end

    test "an external scope that is not a member of the space reads nothing", ctx do
      post!(ctx.space.id, ctx.agent_p.id, "earlier #{sentinel("EXT")}")
      agent_msg = post!(ctx.space.id, ctx.agent_p.id, "the answer")

      scope = %ExternalScope{user_id: Ecto.UUID.generate(), external?: true}

      assert {:error, :no_history} = ContextSummary.summarize(agent_msg, nil, scope: scope)
      refute_receive {:context_summary_stub_called, _, _, _}, 50

      # POSITIVE CONTROL: the internal read of the same message does reach the provider.
      assert {:ok, _} = ContextSummary.summarize(agent_msg, nil)
      assert_receive {:context_summary_stub_called, _, _, _}
    end
  end

  describe "the history window" do
    setup do
      Stub.install!(Stub.text(@reply))
    end

    test "messages at or after the agent message, and deleted messages, are excluded", ctx do
      gone = sentinel("GONE")
      after_s = sentinel("AFTER")

      kept = post!(ctx.space.id, ctx.viewer.id, "kept")
      deleted = post!(ctx.space.id, ctx.viewer.id, "deleted #{gone}")
      {:ok, _} = Chat.delete_message(deleted)
      agent_msg = post!(ctx.space.id, ctx.agent_p.id, "the answer")
      later = post!(ctx.space.id, ctx.viewer.id, "later #{after_s}")

      # POSITIVE CONTROL: the later message is live in the space.
      assert later.id in Enum.map(Chat.list_messages(ctx.space.id), & &1.id)

      assert {:ok, result} = ContextSummary.summarize(agent_msg, ctx.viewer)
      {input, _} = provider_input!()

      refute input =~ gone
      refute input =~ after_s
      assert result.source_message_ids == [kept.id]
      refute agent_msg.id in result.source_message_ids
    end

    test "max_messages bounds the read", ctx do
      Application.put_env(:platform, :chat_context_summary, %{
        provider: :ollama,
        model: "stub-model",
        max_messages: 2
      })

      ids = for i <- 1..5, do: post!(ctx.space.id, ctx.viewer.id, "m#{i}").id
      agent_msg = post!(ctx.space.id, ctx.agent_p.id, "the answer")

      assert {:ok, result} = ContextSummary.summarize(agent_msg, ctx.viewer)
      assert result.source_message_ids == Enum.take(ids, -2)
    end

    test "no prior message gives :no_history and no provider call", ctx do
      agent_msg = post!(ctx.space.id, ctx.agent_p.id, "the first message")

      assert {:error, :no_history} = ContextSummary.summarize(agent_msg, ctx.viewer)
      refute_receive {:context_summary_stub_called, _, _, _}, 50
    end
  end

  describe "configuration" do
    test "provider :none gives :not_configured and never calls the provider", ctx do
      Stub.install!(Stub.text(@reply), %{provider: :none})

      post!(ctx.space.id, ctx.viewer.id, "earlier")
      agent_msg = post!(ctx.space.id, ctx.agent_p.id, "the answer")

      assert {:error, :not_configured} = ContextSummary.summarize(agent_msg, ctx.viewer)
      refute_receive {:context_summary_stub_called, _, _, _}, 50
    end

    test "with nothing configured the default is :none" do
      prev = Application.get_env(:platform, :chat_context_summary)
      Application.delete_env(:platform, :chat_context_summary)
      on_exit(fn -> if prev, do: Application.put_env(:platform, :chat_context_summary, prev) end)

      assert Platform.Chat.ContextSummary.Config.summary().provider == :none
      refute Platform.Chat.ContextSummary.Config.enabled?()
    end

    test "an unknown provider string reads as :none, never a new atom" do
      assert Platform.Chat.ContextSummary.Config.parse_provider("nope-#{unique()}") == :none
      assert Platform.Chat.ContextSummary.Config.parse_provider("ollama") == :ollama
    end

    test "provider opts carry only the allowlisted keys, no tools", ctx do
      Stub.install!(Stub.text(@reply))
      post!(ctx.space.id, ctx.viewer.id, "earlier")
      agent_msg = post!(ctx.space.id, ctx.agent_p.id, "the answer")

      assert {:ok, _} = ContextSummary.summarize(agent_msg, ctx.viewer)
      {_input, opts} = provider_input!()

      assert Keyword.keys(opts) -- [:system, :model, :max_tokens, :temperature, :base_url] == []
      assert opts[:model] == "stub-model"
    end
  end

  describe "output" do
    setup do
      Stub.install!(Stub.text(@reply))
    end

    test "a mention token in the model output is made inert", ctx do
      token = "@" <> "[" <> "some-agent-#{unique()}" <> "]"
      Stub.reply!(Stub.text("Asked by #{token} about approvals."))

      post!(ctx.space.id, ctx.viewer.id, "earlier")
      agent_msg = post!(ctx.space.id, ctx.agent_p.id, "the answer")

      assert {:ok, %{text: text}} = ContextSummary.summarize(agent_msg, ctx.viewer)
      refute text =~ "@" <> "["
      assert text =~ "＠["
    end

    test "output is at most three lines and 400 characters", ctx do
      long = String.duplicate("word ", 200)
      Stub.reply!(Stub.text("one\n\ntwo\nthree\nfour #{long}"))

      post!(ctx.space.id, ctx.viewer.id, "earlier")
      agent_msg = post!(ctx.space.id, ctx.agent_p.id, "the answer")

      assert {:ok, %{text: text}} = ContextSummary.summarize(agent_msg, ctx.viewer)
      assert text == "one\ntwo\nthree"

      assert String.length(ContextSummary.shape_output("a\nb\n" <> long)) == 400
    end

    test "a provider error is returned and not cached", ctx do
      Stub.reply!(fn _, _, _ -> {:error, :boom} end)

      post!(ctx.space.id, ctx.viewer.id, "earlier")
      agent_msg = post!(ctx.space.id, ctx.agent_p.id, "the answer")

      assert {:error, :boom} = ContextSummary.summarize(agent_msg, ctx.viewer)
      assert cache_keys_for(agent_msg.id) == []

      Stub.reply!(Stub.text(@reply))
      assert {:ok, _} = ContextSummary.summarize(agent_msg, ctx.viewer)
    end
  end

  describe "cache and telemetry" do
    setup do
      Stub.install!(Stub.text(@reply))
    end

    test "a cache hit calls the provider once and reports cache: :hit", ctx do
      attach_telemetry!()
      post!(ctx.space.id, ctx.viewer.id, "earlier")
      agent_msg = post!(ctx.space.id, ctx.agent_p.id, "the answer")

      assert {:ok, first} = ContextSummary.summarize(agent_msg, ctx.viewer)
      assert {:ok, second} = ContextSummary.summarize(agent_msg, ctx.viewer)
      assert first == second

      assert_receive {:context_summary_stub_called, _, _, _}
      refute_receive {:context_summary_stub_called, _, _, _}, 50

      message_id = agent_msg.id

      assert_receive {:summary_event, %{latency_ms: ms, input_messages: 1},
                      %{message_id: ^message_id, cache: :miss, outcome: :ok}}
                     when is_integer(ms)

      assert_receive {:summary_event, %{input_messages: 1},
                      %{message_id: ^message_id, cache: :hit, outcome: :ok}}
    end

    test "an expired entry is a miss", ctx do
      post!(ctx.space.id, ctx.viewer.id, "earlier")
      agent_msg = post!(ctx.space.id, ctx.agent_p.id, "the answer")

      assert {:ok, _} = ContextSummary.summarize(agent_msg, ctx.viewer)
      assert_receive {:context_summary_stub_called, _, _, _}

      [{key, value, _exp}] = cache_keys_for(agent_msg.id)

      :ets.insert(
        ContextSummaryCache.table(),
        {key, value, System.monotonic_time(:millisecond) - 1}
      )

      assert {:ok, _} = ContextSummary.summarize(agent_msg, ctx.viewer)
      assert_receive {:context_summary_stub_called, _, _, _}
    end

    test "concurrent misses for one key collapse into one provider call", ctx do
      test_pid = self()

      Stub.reply!(fn _, _, _ ->
        send(test_pid, {:blocked, self()})

        receive do
          :release -> {:ok, %{content: @reply}}
        after
          5_000 -> {:error, :never_released}
        end
      end)

      post!(ctx.space.id, ctx.viewer.id, "earlier")
      agent_msg = post!(ctx.space.id, ctx.agent_p.id, "the answer")
      key = {agent_msg.id, ContextSummary.scope_key(agent_msg, ctx.viewer, nil)}

      first = Task.async(fn -> ContextSummary.summarize(agent_msg, ctx.viewer) end)
      assert_receive {:blocked, runner}, 2_000

      second = Task.async(fn -> ContextSummary.summarize(agent_msg, ctx.viewer) end)
      wait_until(fn -> waiters(key) == 1 end)

      send(runner, :release)
      assert {:ok, a} = Task.await(first)
      assert {:ok, b} = Task.await(second)
      assert a == b

      refute_receive {:blocked, _}, 50
    end
  end

  describe "the chat.context_summary experiment" do
    setup do
      Stub.install!(Stub.text(@reply))
    end

    test "the control snapshots the configured defaults" do
      assert {:ok, %{"provider" => "ollama", "model" => "stub-model", "max_messages" => 20}} =
               Platform.Experiments.Surfaces.ChatContextSummary.control_payload(
                 "chat.context_summary",
                 []
               )
    end

    test "a running variant's model reaches the provider, and the arm is sticky", ctx do
      experiment = running_experiment!()
      post!(ctx.space.id, ctx.viewer.id, "earlier")
      agent_msg = post!(ctx.space.id, ctx.agent_p.id, "the answer")

      assert {:ok, result} = ContextSummary.summarize(agent_msg, ctx.viewer)
      {_input, opts} = provider_input!()
      assert opts[:model] == "treatment-model"
      assert result.experiment_id == experiment.id
      assert result.variant == "treatment"

      # Every NEW subject would now get control; this message must not move.
      Repo.update_all(from(v in Variant, where: v.experiment_id == ^experiment.id),
        set: [weight: 0]
      )

      Repo.update_all(
        from(v in Variant,
          where: v.experiment_id == ^experiment.id and v.slug == ^Experiment.control_slug()
        ),
        set: [weight: 1000]
      )

      ContextSummaryCache.clear()
      assert {:ok, again} = ContextSummary.summarize(agent_msg, ctx.viewer)
      {_input, opts2} = provider_input!()
      assert opts2[:model] == "treatment-model"
      assert again.variant == "treatment"

      assert [%Assignment{subject_type: "message"}] =
               Repo.all(from(a in Assignment, where: a.experiment_id == ^experiment.id))
    end

    test "with the install's provider :none an experiment cannot start" do
      Application.put_env(:platform, :chat_context_summary, %{provider: :none})

      {:ok, experiment} =
        Experiments.create_experiment(%{
          slug: "ctx-summary-off-#{unique()}",
          name: "Off",
          surface_key: "chat.context_summary",
          surface_target: "chat.context_summary"
        })

      assert {:error, _} = Experiments.start(experiment, %User{id: Ecto.UUID.generate()})
    end
  end

  test "the cache is a supervised child of the platform application" do
    assert pid = Process.whereis(ContextSummaryCache)
    assert Process.alive?(pid)
    assert :ets.info(ContextSummaryCache.table()) != :undefined
  end

  defp running_experiment! do
    {:ok, experiment} =
      Experiments.create_experiment(%{
        slug: "ctx-summary-#{unique()}",
        name: "Context summary model",
        surface_key: "chat.context_summary",
        surface_target: "chat.context_summary"
      })

    {:ok, _} =
      Experiments.add_variant(experiment, %{
        slug: "treatment",
        payload: %{"provider" => "ollama", "model" => "treatment-model", "max_messages" => 5},
        weight: 1
      })

    {:ok, %Experiment{status: "running"} = running} =
      Experiments.start(experiment, %User{id: Ecto.UUID.generate()})

    Repo.update_all(
      from(v in Variant,
        where: v.experiment_id == ^running.id and v.slug == ^Experiment.control_slug()
      ),
      set: [weight: 0]
    )

    running
  end

  defp waiters(key) do
    state = :sys.get_state(ContextSummaryCache)

    case Map.get(state.in_flight, key) do
      %{waiters: waiters} -> length(waiters)
      nil -> 0
    end
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end
end
