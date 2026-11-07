defmodule Platform.Secretary.PassTest do
  @moduledoc """
  One batch end to end (task 01a1b721 stage 3): budget ceilings charged at
  dispatch, real usage, the no-AI and failure paths, the retry cap, and the
  fallback grouping.

  Mutants these name: remove the per-person ceiling check (M12) -> "a
  person over their ceiling" goes red; remove the install-wide check (M13)
  -> "the install ceiling" goes red.
  """
  use Platform.DataCase, async: false

  import Platform.SecretaryFixtures

  alias Platform.Experiments.Surfaces.SecretaryPolicy
  alias Platform.Secretary.{Budget, Fallback, Pass, Settings, Store}

  @payload SecretaryPolicy.control()

  setup do
    test_pid = self()
    handler = "secretary-pass-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      Pass.event(),
      fn _event, measurements, metadata, _ -> send(test_pid, {:batch, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp run(user, opts) do
    Pass.run(
      user,
      Keyword.merge(
        [
          eligible: eligible(),
          request: request(self()),
          payload: @payload,
          install_payload: @payload
        ],
        opts
      )
    )
  end

  test "a person over their ceiling: no host call, fallback, telemetry :budget_exhausted" do
    user = person!()
    item = inbox_item!(user, "task_plan_review")
    {:ok, _} = Settings.put(user.id, %{"daily_token_ceiling" => 1000})

    assert {:ok, :budget_exhausted} = run(Platform.Accounts.get_user(user.id), [])
    refute_received {:oneshot_called, _, _}

    assert_received {:batch, %{reserved_tokens: 0}, %{outcome: :budget_exhausted, user_id: uid}}
    assert uid == user.id

    assert %{model_version: "fallback", group_key: "fallback:reviews", needs_you_now: false} =
             Store.get_evaluation(user.id, "inbox_item", item.id)

    assert [%{status: "budget_exhausted"}] = Store.list_batches(user.id)
  end

  test "under the ceiling the same person is asked (positive control)" do
    user = person!()
    inbox_item!(user, "task_plan_review")
    {:ok, _} = Settings.put(user.id, %{"daily_token_ceiling" => 1_000_000})

    assert {:ok, :submitted} = run(Platform.Accounts.get_user(user.id), [])
    assert_received {:oneshot_called, _, _}
  end

  test "the install ceiling: two people under their own ceilings, the second is refused" do
    first = person!("i1")
    second = person!("i2")
    inbox_item!(first)
    inbox_item!(second)

    assert {:ok, :submitted} = run(first, [])
    assert_received {:oneshot_called, _, _}

    spent = Budget.install_spent_today()
    assert spent > 0
    # The second person's own day is empty, and their ceiling is the payload's.
    assert Budget.spent_today(second.id) == 0

    install = Map.put(@payload, "install_daily_token_ceiling", spent + 1)
    assert {:ok, :budget_exhausted} = run(second, install_payload: install)
    refute_received {:oneshot_called, _, _}
  end

  test "real usage is recorded and the reservation still counts" do
    user = person!()
    inbox_item!(user)

    assert {:ok, :submitted} = run(user, [])
    assert [%{status: "submitted", actual_tokens: 23, reserved_tokens: reserved}] =
             Store.list_batches(user.id)

    assert reserved > 23
    assert Budget.spent_today(user.id) == reserved
    assert_received {:batch, %{actual_tokens: 23, reserved_tokens: ^reserved}, %{outcome: :submitted}}
  end

  test "a timeout keeps its reservation and falls back with a failed attempt" do
    user = person!()
    item = inbox_item!(user, "chat_mention")

    assert {:ok, :failed} = run(user, request: request(self(), {:error, :timeout}))
    assert [%{status: "expired", reserved_tokens: reserved}] = Store.list_batches(user.id)
    assert reserved > 0
    assert Budget.spent_today(user.id) == reserved

    assert %{model_version: "fallback", failed_attempts: 1, group_key: "fallback:mentions"} =
             Store.get_evaluation(user.id, "inbox_item", item.id)
  end

  test "no subscription AI: batch no_ai, nothing reserved, no host call" do
    user = person!()
    inbox_item!(user)

    assert {:ok, :no_ai} = run(user, eligible: fn -> {:error, :no_subscription_ai} end)
    refute_received {:oneshot_called, _, _}
    assert [%{status: "no_ai", reserved_tokens: 0}] = Store.list_batches(user.id)
  end

  test "retry cap: a ref that failed twice is not re-sent until it has new activity" do
    user = person!()
    capped = inbox_item!(user)
    failing = request(self(), {:error, :failed})

    assert {:ok, :failed} = run(user, request: failing)
    assert {:ok, :failed} = run(user, request: failing)
    assert_received {:oneshot_called, _, _}
    assert_received {:oneshot_called, _, _}

    assert {:ok, :noop} = run(user, [])
    refute_received {:oneshot_called, _, _}

    # New activity (a new item) batches again, without the capped ref.
    fresh = inbox_item!(user, "task_plan_review")
    assert {:ok, :submitted} = run(user, [])
    assert_received {:oneshot_called, _, prompt}
    assert prompt =~ fresh.id
    refute prompt =~ capped.id
  end

  test "a briefing row is an input, and under the fallback it is in Briefings" do
    user = person!()
    item = inbox_item!(user, "briefing", "the morning briefing")

    assert {:ok, :no_ai} = run(user, eligible: fn -> {:error, :no_subscription_ai} end)

    assert %{group_key: "fallback:briefings", tag: "fyi"} =
             Store.get_evaluation(user.id, "inbox_item", item.id)

    assert {:ok, :submitted} = run(user, [])
    assert_received {:oneshot_called, _, prompt}
    assert prompt =~ "the morning briefing"
    assert %{model_version: "host:test:claude_code"} = Store.get_evaluation(user.id, "inbox_item", item.id)
  end

  describe "Fallback.classify/2" do
    test "the mapping table" do
      table = [
        {"inbox:task_plan_review", false, {"reviews", "decide"}},
        {"inbox:review_request_pending", false, {"reviews", "decide"}},
        {"inbox:task_sponsor_assigned", false, {"reviews", "decide"}},
        {"inbox:lifecycle_step_failed", false, {"reviews", "decide"}},
        {"inbox:social_post_approval", false, {"reviews", "decide"}},
        {"inbox:social_account_disconnected", false, {"reviews", "decide"}},
        {"inbox:some_extension_kind", false, {"reviews", "decide"}},
        {"inbox:chat_mention", false, {"mentions", "waiting"}},
        {"chat:channel", true, {"mentions", "waiting"}},
        {"chat:channel", false, {nil, "quiet"}},
        {"inbox:meeting_starting", false, {"meetings", "fyi"}},
        {"inbox:meeting_invited", false, {"meetings", "fyi"}},
        {"inbox:meeting_cancelled", false, {"meetings", "fyi"}},
        {"calendar:event", false, {"meetings", "fyi"}},
        {"inbox:briefing", false, {"briefings", "fyi"}},
        {"inbox:meeting_briefing", false, {"briefings", "fyi"}},
        {"todo:kept", false, {"todos", "todo"}},
        {"todo:suggested", false, {"todos", "todo"}},
        {"meeting:action_item", false, {nil, "quiet"}}
      ]

      for {kind, mentioned?, expected} <- table do
        assert Fallback.classify(kind, mentioned?) == expected, kind
      end

      assert Enum.map(Fallback.groups(), &elem(&1, 1)) ==
               ["Reviews and approvals", "Mentions", "Meetings", "Briefings", "Your to-dos"]
    end
  end
end
