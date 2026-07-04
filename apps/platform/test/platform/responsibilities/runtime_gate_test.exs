defmodule Platform.Responsibilities.RuntimeGateTest do
  @moduledoc """
  Table-driven tests for the soft-fail runtime-type gate (task
  019f2566 stage 4).

  Exercises `compatible?/2` across the cartesian product of gated
  responsibility keys × canonical agent runtime shapes, plus a few
  nil-tolerance rows.
  """
  use ExUnit.Case, async: true

  alias Platform.Agents.Agent
  alias Platform.Responsibilities.Responsibility
  alias Platform.Responsibilities.RuntimeGate

  doctest RuntimeGate

  # ── Fixtures ──────────────────────────────────────────────────────────

  defp responsibility(key), do: %Responsibility{key: key}

  defp agent_external_narrow do
    # Hermione shape — llama.cpp / OpenAI-compat / Ollama.
    %Agent{kind: "external"}
  end

  defp agent_fed_conversational_no_marker do
    # Dalton shape — federated conversational Claude with no
    # explicit dispatch handler. THIS is the trap.
    %Agent{kind: "native", runtime_type: "external"}
  end

  defp agent_fed_conversational_with_marker do
    # Federated conversational agent that has been explicitly wired
    # (via metadata marker) to handle dispatches.
    %Agent{
      kind: "native",
      runtime_type: "external",
      metadata: %{"responds_to_dispatch" => true}
    }
  end

  defp agent_built_in do
    # In-BEAM runtime — the summarizer built-in.
    %Agent{kind: "native", runtime_type: "built_in"}
  end

  # ── meetings.summarize table ─────────────────────────────────────────

  describe "compatible?/2 — meetings.summarize" do
    setup do
      %{r: responsibility("meetings.summarize")}
    end

    test "external narrow agent (Hermione-shape) is compatible", %{r: r} do
      assert RuntimeGate.compatible?(r, agent_external_narrow()) == :ok
    end

    test "federated conversational with responds_to_dispatch marker is compatible", %{r: r} do
      assert RuntimeGate.compatible?(r, agent_fed_conversational_with_marker()) == :ok
    end

    test "federated conversational without marker soft-fails (Dalton-shape trap)", %{r: r} do
      assert RuntimeGate.compatible?(r, agent_fed_conversational_no_marker()) ==
               {:soft_fail, :conversational_agent_no_dispatch_handler}
    end

    test "built-in native agent is compatible", %{r: r} do
      assert RuntimeGate.compatible?(r, agent_built_in()) == :ok
    end
  end

  # ── meetings.intent_classify table ───────────────────────────────────

  describe "compatible?/2 — meetings.intent_classify" do
    setup do
      %{r: responsibility("meetings.intent_classify")}
    end

    test "external narrow agent is compatible", %{r: r} do
      assert RuntimeGate.compatible?(r, agent_external_narrow()) == :ok
    end

    test "federated conversational with marker is compatible", %{r: r} do
      assert RuntimeGate.compatible?(r, agent_fed_conversational_with_marker()) == :ok
    end

    test "federated conversational without marker soft-fails", %{r: r} do
      assert RuntimeGate.compatible?(r, agent_fed_conversational_no_marker()) ==
               {:soft_fail, :conversational_agent_no_dispatch_handler}
    end

    test "built-in native agent is compatible", %{r: r} do
      assert RuntimeGate.compatible?(r, agent_built_in()) == :ok
    end
  end

  # ── Unknown responsibility keys ──────────────────────────────────────

  describe "compatible?/2 — unknown responsibility keys" do
    test "unknown key with the Dalton-shape agent still returns :ok" do
      # The gate is opt-in per responsibility. Anything not on the
      # dispatch list is unreasoned-about and defaults to :ok.
      r = responsibility("some.new_feature")
      assert RuntimeGate.compatible?(r, agent_fed_conversational_no_marker()) == :ok
    end

    test "unknown key with a built-in agent returns :ok" do
      r = responsibility("some.new_feature")
      assert RuntimeGate.compatible?(r, agent_built_in()) == :ok
    end
  end

  # ── Nil tolerance ────────────────────────────────────────────────────

  describe "compatible?/2 — nil tolerance" do
    test "nil responsibility returns :ok" do
      assert RuntimeGate.compatible?(nil, agent_fed_conversational_no_marker()) == :ok
    end

    test "nil agent returns :ok" do
      assert RuntimeGate.compatible?(responsibility("meetings.summarize"), nil) == :ok
    end

    test "both nil returns :ok" do
      assert RuntimeGate.compatible?(nil, nil) == :ok
    end
  end
end
