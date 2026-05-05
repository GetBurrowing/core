defmodule Platform.Orchestration.ProviderGuidanceTest do
  use ExUnit.Case, async: true

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Orchestration.ProviderGuidance

  @claude_marker "For Claude Code agents (mandatory)"

  describe "for_agent/2" do
    test "returns empty string for nil agent (back-compat)" do
      assert ProviderGuidance.for_agent(nil) == ""
      assert ProviderGuidance.for_agent(nil, %AgentRuntime{}) == ""
    end

    test "returns Claude block when runtime declares product=claude_channel" do
      runtime = %AgentRuntime{
        metadata: %{"client_info" => %{"product" => "claude_channel", "version" => "0.2.0"}}
      }

      agent = %Agent{slug: "dalton", model_config: %{}}

      result = ProviderGuidance.for_agent(agent, runtime)
      assert result =~ @claude_marker
      assert result == ProviderGuidance.claude_subagent_guidance()
    end

    test "returns empty string when runtime declares product=openclaw (no provider guidance yet)" do
      runtime = %AgentRuntime{
        metadata: %{"client_info" => %{"product" => "openclaw", "version" => "0.6.2"}}
      }

      agent = %Agent{slug: "geordi", model_config: %{"primary" => "qwen3-coder"}}

      assert ProviderGuidance.for_agent(agent, runtime) == ""
    end

    test "model-name fallback: unknown runtime + claude-named primary model returns Claude block" do
      # Older plugin without client_info — runtime metadata is empty.
      runtime = %AgentRuntime{metadata: %{}}
      agent = %Agent{slug: "saru", model_config: %{"primary" => "claude-opus-4-7"}}

      assert ProviderGuidance.for_agent(agent, runtime) =~ @claude_marker
    end

    test "model-name fallback: unknown runtime + non-claude primary model returns empty" do
      runtime = %AgentRuntime{metadata: %{}}
      agent = %Agent{slug: "qwen-bot", model_config: %{"primary" => "qwen3-coder:30b"}}

      assert ProviderGuidance.for_agent(agent, runtime) == ""
    end

    test "model-name fallback: unknown runtime + missing model returns empty" do
      runtime = %AgentRuntime{metadata: %{}}
      agent = %Agent{slug: "no-model", model_config: %{}}

      assert ProviderGuidance.for_agent(agent, runtime) == ""
    end

    test "no runtime supplied: falls through to model-name path" do
      agent = %Agent{slug: "claude-only", model_config: %{"primary" => "claude-sonnet-4-6"}}

      assert ProviderGuidance.for_agent(agent) =~ @claude_marker
    end

    test "no runtime supplied + non-claude model returns empty" do
      agent = %Agent{slug: "openai-only", model_config: %{"primary" => "gpt-4o"}}

      assert ProviderGuidance.for_agent(agent) == ""
    end

    test "case-insensitive model match" do
      agent = %Agent{slug: "shouty", model_config: %{"primary" => "CLAUDE-OPUS-4-7"}}

      assert ProviderGuidance.for_agent(agent) =~ @claude_marker
    end

    test "model_config with atom key still matches" do
      agent = %Agent{slug: "atom-keys", model_config: %{primary: "claude-3-5-sonnet"}}

      assert ProviderGuidance.for_agent(agent) =~ @claude_marker
    end

    test "claude_channel runtime trumps non-claude model" do
      # A Claude-channel plugin can technically host any underlying model
      # selection. The handshake is the source of truth.
      runtime = %AgentRuntime{
        metadata: %{"client_info" => %{"product" => "claude_channel"}}
      }

      agent = %Agent{slug: "weird", model_config: %{"primary" => "qwen3-coder"}}

      assert ProviderGuidance.for_agent(agent, runtime) =~ @claude_marker
    end

    test "openclaw runtime trumps claude-named model" do
      # OpenClaw runtime can route to Claude models via a different path,
      # but the agent is not literally a Claude Code agent — no subagent block.
      runtime = %AgentRuntime{
        metadata: %{"client_info" => %{"product" => "openclaw"}}
      }

      agent = %Agent{slug: "openclaw-claude", model_config: %{"primary" => "claude-opus-4-7"}}

      assert ProviderGuidance.for_agent(agent, runtime) == ""
    end
  end

  describe "claude_subagent_guidance/0" do
    test "exposes the canonical Claude block content" do
      block = ProviderGuidance.claude_subagent_guidance()
      assert block =~ @claude_marker
      assert block =~ "Spawn it via the Agent tool"
      assert block =~ "fresh context"
    end

    test "instructs the agent to spawn the subagent as a background process" do
      block = ProviderGuidance.claude_subagent_guidance()
      assert block =~ "background process"
      assert block =~ "run_in_background: true"
      assert block =~ ~r/parent.*responsive|parent responsiveness/
      # Discourage polling — Claude Code notifies on completion.
      assert block =~ ~r/do NOT poll/i
    end
  end
end
