defmodule Platform.Agents.VoiceBlockTest do
  @moduledoc """
  Task 01a1b6ff stage 1: the voice block text, the banned-phrase data, and
  the block on the shared `Platform.Agents.Manners` prompt paths, resolved
  per agent on the `agents.voice_block` experiment surface.

  Counts use `:binary.matches/2`, never `=~`, because "exactly once" is the
  claim: a block inserted twice still matches `=~`.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Agents.{Agent, Burrow, Manners, MemoryContext, NativeAgents, QuickAgent}
  alias Platform.Agents.VoiceBlock
  alias Platform.Agents.VoiceCheck
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AttentionRouter}
  alias Platform.Experiments
  alias Platform.Experiments.Variant
  alias Platform.Orchestration.PromptTemplates

  @marker "## How you talk"
  @sentinel "VARIANT-SENTINEL-7Q"
  # The control's first rule sentence: present in the control, absent from the variant.
  @control_rule "Say what you're doing and why in the same breath."

  defp count(haystack, needle), do: length(:binary.matches(haystack, needle))

  describe "VoiceBlock.text/0" do
    test "starts with the marker heading and carries it exactly once" do
      text = VoiceBlock.text()
      assert VoiceBlock.marker() == "## How you talk"
      assert String.starts_with?(text, "## How you talk\n")
      assert count(text, "## How you talk") == 1
    end

    test "carries the neighbour character, the canonical nouns and the model rule" do
      text = VoiceBlock.text()
      assert text =~ "shop next door"
      assert text =~ "never a bot or an assistant"
      assert text =~ "which model is underneath"
      assert text =~ "Never open with it."
      assert text =~ "participant"
    end

    test "has at most two quoted examples, neither a product or privacy claim" do
      text = VoiceBlock.text()
      examples = Regex.scan(~r/^"[^"\n]+"$/m, text)
      assert length(examples) in 1..2

      for claim <- [
            "sign-up",
            "sign up",
            "account",
            "phone",
            "link",
            "deleted",
            "Stripe",
            "card details",
            "privacy"
          ] do
        refute String.contains?(String.downcase(text), String.downcase(claim)),
               "the voice block must make no product or privacy claim (found #{inspect(claim)})"
      end
    end

    test "breaks none of its own shape checks" do
      text = VoiceBlock.text()
      assert count(text, "—") == 0
      assert count(text, "!") == 0
    end

    test "does not paste the banned phrases into the prompt" do
      text = VoiceBlock.text()

      for phrase <- VoiceCheck.default_banned() do
        pattern = ~r/(?<![\w])#{Regex.escape(phrase)}(?![\w])/iu

        refute Regex.match?(pattern, text),
               "banned phrase #{inspect(phrase)} appears in the voice block"
      end
    end
  end

  describe "VoiceCheck data" do
    test "five phrase groups plus four named shape checks, the proposal's six groups" do
      assert Keyword.keys(VoiceCheck.groups()) == [
               :openers_and_reactions,
               :assistant_self_talk,
               :closers,
               :therapy_and_apology,
               :brochure_words
             ]

      assert VoiceCheck.shape_checks() == [
               :em_dash,
               :multiple_exclamations,
               :consecutive_question_end,
               :structure_in_short_reply
             ]
    end

    test "default_banned/0 is every group's phrases flattened, non-empty and unique" do
      banned = VoiceCheck.default_banned()
      assert banned == Enum.flat_map(VoiceCheck.groups(), &elem(&1, 1))
      assert length(banned) == 49
      assert Enum.uniq(banned) == banned
      assert Enum.all?(banned, &(is_binary(&1) and String.trim(&1) != ""))
    end

    test "spot-checks the verbatim phrases, punctuation included" do
      banned = VoiceCheck.default_banned()

      for phrase <- [
            "Great!",
            "Of course!",
            "I'd be happy to",
            "Don't hesitate to",
            "game-changer"
          ] do
        assert phrase in banned
      end

      assert VoiceCheck.self_description_names() == ["Claude", "Anthropic", "ChatGPT"]
      assert Enum.all?(VoiceCheck.self_description_names(), &(&1 in banned))
    end
  end

  # ── wiring ──────────────────────────────────────────────────────────

  defmodule StubProvider do
    def chat(_credentials, _messages, opts) do
      if pid = Application.get_env(:platform, :voice_block_test_pid) do
        send(pid, {:voice_block_provider, Keyword.get(opts, :system)})
      end

      {:ok, %{content: "Saturday, then.", model: "stub", usage: %{}}}
    end
  end

  setup do
    keys = [
      :agent_host_token,
      :quick_agent_provider_module,
      :voice_block_test_pid,
      :chat_agent_module,
      :chat_agent_dispatch_mode,
      :agent_workspace_path,
      :codex_auth_file
    ]

    previous = for k <- keys, do: {k, Application.fetch_env(:platform, k)}

    Application.put_env(:platform, :agent_host_token, "voice-block-test-host-token")

    on_exit(fn ->
      for {k, v} <- previous do
        case v do
          {:ok, value} -> Application.put_env(:platform, k, value)
          :error -> Application.delete_env(:platform, k)
        end
      end
    end)
  end

  defp tmp_dir!(label) do
    dir = Path.join(System.tmp_dir!(), "voice-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp native!(name, harness) do
    owner = Platform.TenancyFixtures.root_admin!()
    {:ok, agent, _runtime} = NativeAgents.create(owner.id, %{name: name, harness: harness})
    agent
  end

  defp instructions_key("codex"), do: "AGENTS.md"
  defp instructions_key(_), do: "CLAUDE.md"

  defp started(agent, key),
    do: agent |> NativeAgents.start_files() |> Enum.find(&(&1["key"] == key))

  # The identity template as origin/main shipped it before the shared
  # handoff rule (task 01a1b733) existed: today's template minus that rule.
  # Derived rather than pasted, and checked, so it cannot drift silently.
  defp main_identity(name, harness) do
    text =
      String.replace(
        NativeAgents.identity_template(name, harness),
        Manners.handoff_rule() <> "\n",
        ""
      )

    refute text =~ Manners.marker()
    refute text =~ @marker
    assert text =~ "You run "
    text
  end

  # A running experiment on agents.voice_block whose only live arm carries
  # the sentinel (the control's weight is zeroed, as in the tool-profile
  # surface's test), so every agent resolved afterwards is assigned it.
  defp variant_experiment! do
    {:ok, experiment} =
      Experiments.create_experiment(%{
        slug: "voice-#{System.unique_integer([:positive])}",
        name: "Voice block",
        surface_key: "agents.voice_block",
        surface_target: "agents.voice_block"
      })

    {:ok, _} =
      Experiments.add_variant(experiment, %{
        slug: "treatment",
        payload: %{
          "block" => "#{@marker}\n\nTalk plainly. #{@sentinel}\n",
          "banned" => ["delve"]
        },
        weight: 1
      })

    assert {:ok, _} = Experiments.start(experiment, Platform.TenancyFixtures.root_admin!())

    Repo.update_all(
      from(v in Variant, where: v.experiment_id == ^experiment.id and v.slug == "control"),
      set: [weight: 0]
    )

    experiment
  end

  describe "Manners.ensure/2 and blocks" do
    test "inserts each absent block once, in order, and is idempotent" do
      once = Manners.ensure("# Ada\n\nOld text.\n", Manners.blocks())
      assert count(once, Manners.marker()) == 1
      assert count(once, @marker) == 1
      assert String.ends_with?(once, "\n")
      assert Manners.ensure(once, Manners.blocks()) == once

      {handoff_at, _} = :binary.match(once, Manners.marker())
      {voice_at, _} = :binary.match(once, @marker)
      assert handoff_at < voice_at
    end

    test "a block whose marker is already present is left alone" do
      content = "# Ada\n\n#{@marker}\n\nThe owner's own voice notes.\n"
      out = Manners.ensure(content, Manners.blocks())
      assert count(out, @marker) == 1
      assert out =~ "The owner's own voice notes."
      refute out =~ @control_rule
    end

    test "blocks_for/2 swaps in the caller's voice text" do
      assert [{_, _}, {@marker, "#{@marker}\n\nX"}] =
               Manners.blocks_for(:native_start, "#{@marker}\n\nX")

      assert [{marker, _}] = Manners.blocks_for(:federation_preamble, "#{@marker}\n\nX")
      assert marker == Manners.marker()
    end
  end

  describe "start_files/1" do
    test "a stored origin/main identity file gets the block exactly once, unstored" do
      for harness <- ~w(claude_code codex) do
        agent = native!("Alex #{harness}", harness)
        key = instructions_key(harness)
        main_text = main_identity("Alex #{harness}", harness)
        {:ok, _} = MemoryContext.upsert_workspace_file(agent.id, key, main_text)
        stored = MemoryContext.get_workspace_file(agent.id, key)

        first = started(agent, key)
        assert count(first["content"], @marker) == 1, "#{harness}: once"
        assert first["content"] =~ @control_rule

        second = started(agent, key)
        assert count(second["content"], @marker) == 1, "#{harness}: still once when called twice"
        assert second["content"] == first["content"]

        assert first["version"] == stored.version
        after_start = MemoryContext.get_workspace_file(agent.id, key)
        assert after_start.content == main_text
        assert after_start.version == stored.version
      end
    end

    test "a stored file that already has the marker still carries it once" do
      agent = native!("Sam", "claude_code")
      content = "# Sam\n\n#{@marker}\n\nShort and dry.\n"
      {:ok, _} = MemoryContext.upsert_workspace_file(agent.id, "CLAUDE.md", content)

      sent = started(agent, "CLAUDE.md")["content"]
      assert count(sent, @marker) == 1
      assert sent =~ "Short and dry."
    end

    test "Burrow: once, before the admins section, which stays the tail" do
      owner = Platform.TenancyFixtures.root_admin!()
      {:ok, agent} = Burrow.ensure(owner.id, "claude_code")
      {:ok, _} = MemoryContext.upsert_workspace_file(agent.id, "CLAUDE.md", "# Burrow\n")

      content = started(agent, "CLAUDE.md")["content"]
      assert count(content, @marker) == 1
      assert String.ends_with?(content, Burrow.admins_section())
      [before_admins, _] = String.split(content, "## Owner and admins", parts: 2)
      assert count(before_admins, @marker) == 1
    end

    test "other files are not touched" do
      agent = native!("Sam", "claude_code")
      assert started(agent, ".claude/settings.json")["content"] == "{}"
    end
  end

  describe "the other prompt paths" do
    test "the QuickAgent frame carries the block once" do
      prompt = QuickAgent.build_system_prompt(tmp_dir!("quick"))
      assert count(prompt, @marker) == 1
      assert prompt =~ @control_rule
    end

    test "the seeds and the federation preamble do not carry it" do
      for h <- ~w(claude_code codex) do
        assert count(NativeAgents.identity_template("Sam", h), @marker) == 0
        assert count(Burrow.identity_template("Burrow", h), @marker) == 0
      end

      assert count(PromptTemplates.federation_preamble(%{}), @marker) == 0
    end
  end

  describe "an agents.voice_block experiment arm" do
    test "reaches start_files in place of the control" do
      agent = native!("Riley", "claude_code")

      {:ok, _} =
        MemoryContext.upsert_workspace_file(
          agent.id,
          "CLAUDE.md",
          main_identity("Riley", "claude_code")
        )

      _ = variant_experiment!()

      content = started(agent, "CLAUDE.md")["content"]
      assert count(content, @sentinel) == 1
      assert count(content, @marker) == 1
      refute content =~ @control_rule
    end

    test "reaches QuickAgent driven through AgentResponder's built-in chat" do
      Application.put_env(:platform, :quick_agent_provider_module, StubProvider)
      Application.put_env(:platform, :voice_block_test_pid, self())
      Application.put_env(:platform, :chat_agent_module, QuickAgent)
      Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)
      Application.put_env(:platform, :agent_workspace_path, tmp_dir!("ws"))
      Application.put_env(:platform, :codex_auth_file, auth_file!())

      router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
      Sandbox.allow(Repo, self(), router)
      store = Process.whereis(ActiveAgentStore) || start_supervised!({ActiveAgentStore, []})
      Sandbox.allow(Repo, self(), store)

      _ = variant_experiment!()

      {space, author} = space_with_author()
      agent = builtin_agent!()

      {:ok, participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Voice Agent")

      ActiveAgentStore.set_active(space.id, participant.id)

      {:ok, message} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "When is the tasting?"
        })

      assert :ok = GenServer.call(AttentionRouter, :__drain__)
      flush_provider()
      {:ok, _} = AttentionRouter.route(message)
      assert_receive {:voice_block_provider, system}, 5000
      assert :ok = GenServer.call(AttentionRouter, :__drain__)

      assert count(system, @sentinel) == 1
      assert count(system, @marker) == 1
      refute system =~ @control_rule
    end
  end

  # ── the guard: every path carries exactly the markers blocks_for/1 names ──

  describe "blocks_for/1 guard" do
    test "every prompt path's rendered output carries each of its markers" do
      agent = native!("Guard", "claude_code")
      all = Enum.map(Manners.blocks(), &elem(&1, 0))

      for {id, _mod, _fun} <- Manners.prompt_paths() do
        rendered = render_path(id, agent)
        wanted = Manners.blocks_for(id)

        for marker <- wanted do
          assert count(rendered, marker) == 1, "#{id} must carry #{inspect(marker)} once"
        end

        for marker <- all -- wanted do
          assert count(rendered, marker) == 0, "#{id} must not carry #{inspect(marker)}"
        end
      end
    end
  end

  defp render_path(:native_seed, _agent),
    do: NativeAgents.identity_template("Guard", "claude_code")

  defp render_path(:native_start, agent), do: started(agent, "CLAUDE.md")["content"]
  defp render_path(:burrow_seed, _agent), do: Burrow.identity_template("Burrow", "claude_code")
  defp render_path(:built_in_chat, _agent), do: QuickAgent.build_system_prompt(tmp_dir!("guard"))
  defp render_path(:federation_preamble, _agent), do: PromptTemplates.federation_preamble(%{})

  defp flush_provider do
    receive do
      {:voice_block_provider, _} -> flush_provider()
    after
      0 -> :ok
    end
  end

  defp space_with_author do
    {:ok, space} =
      Chat.create_space(%{
        name: "Voice",
        slug: "voice-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, author} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Sam",
        joined_at: DateTime.utc_now()
      })

    {space, author}
  end

  defp builtin_agent! do
    %Agent{}
    |> Agent.changeset(%{
      name: "Voice Agent",
      slug: "voice-agent-#{System.unique_integer([:positive])}",
      status: "active",
      max_concurrent: 1,
      sandbox_mode: "off",
      model_config: %{"primary" => "openai/gpt-5.4"}
    })
    |> Repo.insert!()
  end

  defp auth_file! do
    path = Path.join(tmp_dir!("auth"), "auth.json")

    File.write!(
      path,
      Jason.encode!(%{
        "auth_mode" => "chatgpt",
        "tokens" => %{"access_token" => "test-access-token", "refresh_token" => "test-refresh"}
      })
    )

    path
  end
end
