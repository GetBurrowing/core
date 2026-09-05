defmodule Platform.Meetings.AgentDelayReasonTest do
  @moduledoc """
  Task 01a06e07 stage 2 — `Platform.Meetings.AgentDelayReason.for_agent/1`.

  Pure function tests: every assertion here builds a facts map by hand
  and calls `for_agent/1` directly. No DB, no ETS, no process.

  ## The anti-vacuity mutation

  The stage's own instructions specify a mutation to run against
  `for_agent/1`: make it return one fixed string for every input, and
  the test that compares the reply-budget clause against the
  no-voice-worker clause — asserting the two strings DIFFER, never
  against a hardcoded literal — must go RED. That test is
  "the reply-budget clause and the no-voice-worker clause are different
  sentences" below.

  Verified by hand, not by CI: temporarily replacing `for_agent/1`'s body
  with `def for_agent(_facts), do: "still running a tool"` and running
  this file. Result (reverted immediately after, not left in the tree):

      4) test the reply-budget clause and the no-voice-worker clause are different sentences (Platform.Meetings.AgentDelayReasonTest)
         test/platform/meetings/agent_delay_reason_test.exs:135
         Assertion with != failed, both sides are exactly equal
         code: assert budget != no_voice
         left: "still running a tool"
         stacktrace:
           test/platform/meetings/agent_delay_reason_test.exs:141: (test)

      16 tests, 13 failures

  13 of the 16 tests in this file went red under the mutation (every one
  that names a specific cause), this one among them. See the stage
  report for the full command and output. The mutation detonated: a
  hardcoded return value is caught, and a test that only asserted "a
  reason is present" or "matches a literal" would not have caught it.
  """
  use ExUnit.Case, async: true

  alias Platform.Meetings.AgentDelayReason

  describe "each specific cause shows immediately, before the default age threshold" do
    test "reply budget exhausted, at age_s: 0" do
      assert AgentDelayReason.for_agent(%{
               reply_budget_exhausted?: true,
               reply_budget_reset_in_s: 42,
               age_s: 0
             }) == "reply budget resets in 42s"
    end

    test "no voice worker seated, at age_s: 0" do
      assert AgentDelayReason.for_agent(%{no_voice_worker?: true, age_s: 0}) ==
               "no voice worker in this room"
    end

    test "agent chain too deep, at age_s: 0" do
      assert AgentDelayReason.for_agent(%{agent_chain_too_deep?: true, age_s: 0}) ==
               "waiting for a human to speak"
    end

    test "runtime offline, at age_s: 0" do
      assert AgentDelayReason.for_agent(%{runtime_offline?: true, age_s: 0}) ==
               "agent went offline"
    end
  end

  describe "the default clause is withheld until age_s reaches the threshold" do
    test "default_shows_after_s/0 is 10" do
      assert AgentDelayReason.default_shows_after_s() == 10
    end

    test "no clause and no cause below the threshold: nil" do
      assert is_nil(AgentDelayReason.for_agent(%{age_s: 0}))
      assert is_nil(AgentDelayReason.for_agent(%{age_s: 9}))
      assert is_nil(AgentDelayReason.for_agent(%{}))
    end

    test "the default clause appears exactly at the threshold, and after it" do
      assert AgentDelayReason.for_agent(%{age_s: 10}) == "still running a tool"
      assert AgentDelayReason.for_agent(%{age_s: 600}) == "still running a tool"
    end
  end

  describe "priority — a specific cause beats the default regardless of age" do
    test "a specific cause at age_s: 0 outranks the not-yet-eligible default" do
      assert AgentDelayReason.for_agent(%{no_voice_worker?: true, age_s: 0}) != nil
    end

    test "a specific cause still wins even once the default would also be eligible" do
      assert AgentDelayReason.for_agent(%{agent_chain_too_deep?: true, age_s: 600}) ==
               "waiting for a human to speak"
    end
  end

  describe "priority among the specific causes, in the order the stage specifies" do
    test "reply budget beats no voice worker" do
      assert AgentDelayReason.for_agent(%{
               reply_budget_exhausted?: true,
               reply_budget_reset_in_s: 5,
               no_voice_worker?: true
             }) == "reply budget resets in 5s"
    end

    test "no voice worker beats agent chain too deep" do
      assert AgentDelayReason.for_agent(%{no_voice_worker?: true, agent_chain_too_deep?: true}) ==
               "no voice worker in this room"
    end

    test "agent chain too deep beats runtime offline" do
      assert AgentDelayReason.for_agent(%{agent_chain_too_deep?: true, runtime_offline?: true}) ==
               "waiting for a human to speak"
    end

    test "runtime offline beats the eligible default" do
      assert AgentDelayReason.for_agent(%{runtime_offline?: true, age_s: 600}) ==
               "agent went offline"
    end
  end

  describe "missing keys read as their honest default, not as a crash" do
    test "an empty map is a legal input" do
      assert is_nil(AgentDelayReason.for_agent(%{}))
    end

    test "reply_budget_exhausted? without a reset-in value still produces a sentence" do
      assert AgentDelayReason.for_agent(%{reply_budget_exhausted?: true}) ==
               "reply budget resets in 0s"
    end
  end

  # ── THE mutation-catching test ──────────────────────────────────────────
  #
  # This is the one the stage instructions require: it asserts the two
  # strings DIFFER FROM EACH OTHER, never against a hardcoded constant on
  # either side. A `for_agent/1` that returns one fixed string for every
  # input — the specified mutation — makes `budget == no_voice` and this
  # goes RED. See the moduledoc for the verbatim failure this mutation
  # produced when actually run.
  test "the reply-budget clause and the no-voice-worker clause are different sentences" do
    budget =
      AgentDelayReason.for_agent(%{reply_budget_exhausted?: true, reply_budget_reset_in_s: 12})

    no_voice = AgentDelayReason.for_agent(%{no_voice_worker?: true})

    assert budget != no_voice
    # Anti-vacuity on the anti-vacuity test: both sides must be real,
    # non-nil strings, or "different" would be trivially true because one
    # side is nil.
    assert is_binary(budget)
    assert is_binary(no_voice)
  end
end
