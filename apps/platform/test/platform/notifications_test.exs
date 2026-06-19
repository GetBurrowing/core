defmodule Platform.NotificationsTest do
  use ExUnit.Case, async: true

  alias Platform.Notifications

  @payload %{title: "Meeting starting", body: "Standup begins now", url: "/meetings/abc"}

  describe "fan_out_to_humans/2" do
    test "returns :ok with empty recipient list" do
      assert :ok = Notifications.fan_out_to_humans([], @payload)
    end

    test "returns :ok with a populated list (no exception in test env)" do
      # In :test env the Task is suppressed (see module docstring on the
      # Ecto-sandbox race), so this exercises the fast path and proves the
      # function returns synchronously without crashing.
      assert :ok = Notifications.fan_out_to_humans(["p-1", "p-2", "p-3"], @payload)
    end
  end

  describe "fan_out_to_humans/3 with :exclude_participant_id" do
    test "filters the excluded participant from recipients" do
      result =
        Notifications.recipients(
          ["sender-1", "recipient-2", "recipient-3"],
          exclude_participant_id: "sender-1"
        )

      assert result == ["recipient-2", "recipient-3"]
    end

    test "no-op when exclude_participant_id is not in the list" do
      result =
        Notifications.recipients(
          ["a", "b", "c"],
          exclude_participant_id: "not-present"
        )

      assert result == ["a", "b", "c"]
    end

    test "exclude_participant_id: nil leaves the list intact" do
      result = Notifications.recipients(["a", "b"], exclude_participant_id: nil)
      assert result == ["a", "b"]
    end

    test "fan_out_to_humans accepts the option and still returns :ok" do
      assert :ok =
               Notifications.fan_out_to_humans(
                 ["sender", "alice", "bob"],
                 @payload,
                 exclude_participant_id: "sender"
               )
    end
  end

  describe "recipients/2 hygiene" do
    test "deduplicates participant_ids" do
      assert Notifications.recipients(["a", "a", "b", "a"], []) == ["a", "b"]
    end

    test "drops nil participant_ids" do
      assert Notifications.recipients(["a", nil, "b", nil], []) == ["a", "b"]
    end
  end

  describe "idempotency at the helper layer" do
    test "calling fan_out_to_humans twice with the same list is :ok both times" do
      # Dedup is the caller's job (see stage 3's notified_at column); the
      # helper itself is a pure fan-out and must remain side-effect-free
      # in test env regardless of how many times it's called.
      assert :ok = Notifications.fan_out_to_humans(["p-1", "p-2"], @payload)
      assert :ok = Notifications.fan_out_to_humans(["p-1", "p-2"], @payload)
    end
  end
end
