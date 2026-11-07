defmodule Platform.Habits.LearnedDefaultsRungPinTest do
  @moduledoc """
  Task 01a1b814: pins the learned-defaults rung for a picker history of
  4xB / 3xC in one space, against the `habits.learned_defaults` control
  thresholds (no experiment seeded): prefill_threshold 0.6, min_signals 3.

  Working as designed, not a counting bug. `Platform.Habits.suggest/4`
  pre-fills the top target only when BOTH hold:

    * confidence = top target's (accepted + chosen - overridden) / the
      decayed weight of every signal for the action in the space
      >= prefill_threshold 0.6, and
    * the TOP TARGET's own decayed accepted + chosen count >= min_signals 3
      (not the space's total signal count).

  Each picker pick writes exactly one `chosen` signal (the first at rung
  `none`, later ones at rung `rank`). At the 4th open only three picks have
  happened (B, C, B), so B's count is 2: every earlier pick counts, nothing
  is excluded and decay over seconds is negligible against a 30-day
  half-life. The "3 signals" in the report was the space total.
  """

  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Habits
  alias Platform.Habits.Signal
  alias Platform.Repo

  @action "chat.message_attention"

  setup do
    unique = System.unique_integer([:positive])

    {:ok, room} =
      Chat.create_space(%{name: "room #{unique}", slug: "room-#{unique}", kind: "channel"})

    %{
      actor: user!("Member Actor", unique),
      b: user!("Member B", unique),
      c: user!("Member C", unique),
      room: room
    }
  end

  defp user!(name, unique) do
    slug = name |> String.downcase() |> String.replace(" ", "-")

    Repo.insert!(%User{
      email: "#{slug}-#{unique}@example.com",
      name: name,
      oidc_sub: "oidc-#{slug}-#{unique}"
    })
  end

  defp target(%User{id: id}), do: %{target_type: "user", target_id: id}

  # One `chosen` signal per pick, as MessageAttentionHooks.record_pick writes
  # it: the first pick happens before any suggestion exists (rung `none`),
  # later ones at rung `rank` (picking someone else at `rank` writes no
  # `overridden`).
  defp picks!(actor, room, sequence) do
    sequence
    |> Enum.with_index()
    |> Enum.each(fn {%User{} = picked, i} ->
      t = target(picked)

      {:ok, %Signal{}} =
        Habits.record(%{
          actor_user_id: actor.id,
          space_id: room.id,
          action: @action,
          target_type: t.target_type,
          target_id: t.target_id,
          outcome: "chosen",
          rung: if(i == 0, do: "none", else: "rank")
        })
    end)
  end

  # `:now` is read right after the picks, so every signal is milliseconds old.
  defp open(actor, room) do
    Habits.suggest(actor.id, room.id, @action, now: DateTime.utc_now())
  end

  defp ranked_ids(%{ranked: ranked}), do: Enum.map(ranked, & &1.target_id)

  defp signal_rows(actor, room) do
    Signal
    |> where([s], s.actor_user_id == ^actor.id and s.space_id == ^room.id)
    |> Repo.all()
  end

  test "control thresholds are prefill_threshold 0.6 and min_signals 3", %{actor: actor} do
    payload = Habits.variant(actor.id)
    assert payload["prefill_threshold"] == 0.6
    assert payload["min_signals"] == 3
  end

  test "a. B,C,B then 4th open: conf 0.667 >= prefill_threshold 0.6 but B count 2 < min_signals 3 -> ranked [B, C], prefill nil, act nil",
       %{actor: actor, b: b, c: c, room: room} do
    picks!(actor, room, [b, c, b])
    s = open(actor, room)

    assert ranked_ids(s) == [b.id, c.id]

    assert s.prefill == nil,
           "B has 2 of 3 signals (conf 0.667 >= 0.6) but its own count 2 < min_signals 3; " <>
             "the gate is per target, not the space total of 3"

    assert s.act == nil

    rows = signal_rows(actor, room)
    assert length(rows) == 3, "exactly one signal row per pick"
    assert Enum.all?(rows, &(&1.outcome == "chosen")), "no overridden rows at rung rank"
  end

  test "b. after B,C,B,C,B,C,B (4B/3C): B count 4 >= min_signals 3 but conf 0.571 < prefill_threshold 0.6 -> ranked [B, C], prefill nil",
       %{actor: actor, b: b, c: c, room: room} do
    picks!(actor, room, [b, c, b, c, b, c, b])
    s = open(actor, room)

    assert ranked_ids(s) == [b.id, c.id]

    assert s.prefill == nil,
           "B count 4 clears min_signals 3, but its share 4/7 = 0.571 < prefill_threshold 0.6"

    assert s.act == nil

    rows = signal_rows(actor, room)
    assert length(rows) == 7, "exactly one signal row per pick"
    assert Enum.all?(rows, &(&1.outcome == "chosen")), "no overridden rows at rung rank"
  end

  # Caveat found on the dev server (task 01a1b814): the count is a DECAYED
  # weight compared with a 1.0e-6 tolerance. Three picks spread over more than
  # about a second weigh just under 3.0 (2.99998 after a minute at a 30-day
  # half-life), so through the real picker the rung 2 pre-fill needs a 4th
  # pick. These cases hold only because the picks here are milliseconds apart.
  describe "c. contrast (anti-vacuity): the gate does fire at min_signals 3 with conf >= 0.6" do
    test "B,B,B then open: conf 1.0, count 3 = min_signals -> prefill B",
         %{actor: actor, b: b, room: room} do
      picks!(actor, room, [b, b, b])
      s = open(actor, room)

      assert ranked_ids(s) == [b.id]
      assert s.prefill == target(b), "count 3 = min_signals 3 and conf 1.0 >= 0.6 must pre-fill"
    end

    test "B,B,C,B then open: count 3, conf 0.75 -> prefill B",
         %{actor: actor, b: b, c: c, room: room} do
      picks!(actor, room, [b, b, c, b])
      s = open(actor, room)

      assert ranked_ids(s) == [b.id, c.id]
      assert s.prefill == target(b), "count 3 = min_signals 3 and conf 0.75 >= 0.6 must pre-fill"
    end
  end
end
