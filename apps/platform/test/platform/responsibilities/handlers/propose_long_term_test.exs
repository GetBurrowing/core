defmodule Platform.Responsibilities.Handlers.ProposeLongTermTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.ProposeLongTerm` — the
  weekly Historian sweep that surfaces candidate long-term entries for
  the next `memory.dreaming` pass to consider.
  """
  use Platform.DataCase, async: false

  alias Platform.Responsibilities.Handlers.ProposeLongTerm
  alias Platform.Responsibilities.Responsibility

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: ProposeLongTerm.key(),
      feature: "memory",
      trigger_kind: "cron",
      trigger_config: %{"expression" => "0 5 * * 0"},
      scope: "per_org",
      context_provided: ["recent_journal", "org_identity"],
      enabled: true
    }
  end

  describe "register/0" do
    test "declares one spec with the canonical key + weekly cron expression" do
      [spec] = ProposeLongTerm.register()

      assert spec.key == "memory.propose_long_term"
      assert spec.feature == "memory"
      assert spec.trigger_kind == "cron"
      assert spec.trigger_config == %{"expression" => "0 5 * * 0"}
      assert spec.scope == "per_org"
      assert spec.context_provided == ["recent_journal", "org_identity"]
      assert spec.default_prompt_template == "memory.propose_long_term.v1"
      assert spec.output_contract == %{"proposals" => "list[string]"}
      assert spec.cost_profile == "low_freq_capable"
      assert spec.metadata["owner"] == "platform.memory"
    end
  end

  describe "handle_output/3" do
    test "returns :ok for a well-shaped proposals list" do
      payload = %{
        "proposals" => [
          "Prefer short async summaries over meetings.",
          "Ship small PRs; rebase early."
        ]
      }

      assert :ok = ProposeLongTerm.handle_output(responsibility(), payload, %{kind: :cron})
    end

    test "returns :ok for an atom-keyed proposals list" do
      payload = %{proposals: ["atom-keyed proposal"]}

      assert :ok = ProposeLongTerm.handle_output(responsibility(), payload, %{kind: :cron})
    end

    test "returns :ok for a malformed payload (log-and-move-on)" do
      # Proposal handler is intentionally lenient — Historian's next
      # dreaming pass is the arbiter, not this handler. Malformed
      # payloads log a warning and return :ok.
      assert :ok = ProposeLongTerm.handle_output(responsibility(), %{}, %{kind: :cron})
      assert :ok = ProposeLongTerm.handle_output(responsibility(), "bare string", %{kind: :cron})
      assert :ok = ProposeLongTerm.handle_output(responsibility(), nil, %{kind: :cron})
    end

    test "arity-2 delegates to arity-3" do
      assert :ok = ProposeLongTerm.handle_output(responsibility(), %{"proposals" => []})
    end
  end

  describe "gather_context/2" do
    test "merges :recent_journal and :org_identity slots" do
      assert {:ok, ctx} = ProposeLongTerm.gather_context(responsibility(), %{})
      assert Map.has_key?(ctx, :recent_journal)
      assert Map.has_key?(ctx, :org_identity)
    end
  end
end
