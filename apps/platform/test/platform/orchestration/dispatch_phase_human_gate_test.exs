defmodule Platform.Orchestration.DispatchPhaseHumanGateTest do
  use ExUnit.Case, async: true

  alias Platform.Orchestration.DispatchPhase

  @pr_merge_manual %{"type" => "pr_merge", "config" => %{"auto_merge" => false}}
  @pr_merge_auto %{"type" => "pr_merge", "config" => %{"auto_merge" => true}}

  describe "human_gated_pending?/2" do
    test "pr_merged alone under a manual pr_merge strategy is human gated" do
      assert DispatchPhase.human_gated_pending?(["pr_merged"], @pr_merge_manual)
    end

    test "pr_merged alone with auto_merge: true is agent drivable" do
      refute DispatchPhase.human_gated_pending?(["pr_merged"], @pr_merge_auto)
    end

    test "auto_merge read off the strategy map itself when config is absent" do
      refute DispatchPhase.human_gated_pending?(
               ["pr_merged"],
               %{"type" => "pr_merge", "auto_merge" => true}
             )

      assert DispatchPhase.human_gated_pending?(["pr_merged"], %{"type" => "pr_merge"})
    end

    test "a mixed set containing an agent-passable kind is not human gated" do
      refute DispatchPhase.human_gated_pending?(["pr_merged", "ci_passed"], @pr_merge_manual)
    end

    test "ci_passed alone is agent-passable — a red CI gate is a real stall" do
      refute DispatchPhase.human_gated_pending?(["ci_passed"], @pr_merge_manual)
    end

    test "ci_check alone is agent-passable" do
      refute DispatchPhase.human_gated_pending?(["ci_check"], @pr_merge_manual)
    end

    test "no pending validations is not human gated" do
      refute DispatchPhase.human_gated_pending?([], @pr_merge_manual)
    end

    test "pr_merged under a non-pr_merge strategy is not human gated" do
      refute DispatchPhase.human_gated_pending?(["pr_merged"], %{"type" => "docker_deploy"})
    end

    test "manual_approval is human gated under any strategy" do
      assert DispatchPhase.human_gated_pending?(["manual_approval"], %{"type" => "docker_deploy"})
      assert DispatchPhase.human_gated_pending?(["manual_approval"], @pr_merge_auto)
    end
  end
end
