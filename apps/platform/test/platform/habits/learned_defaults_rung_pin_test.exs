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
    * the TOP TARGET's own RAW (undecayed) count of accepted + chosen
      signals in the lookback window >= min_signals 3 (not the space's
      total signal count). min_signals is a number of times, so three picks
      spread over days are three however much each has decayed.

  A pick at rung `none` or `rank` writes one `chosen` signal. A pick at an
  open that showed a pre-fill writes `accepted` for the pre-filled target,
  or `chosen` for the pick plus `overridden` for the pre-filled target. At
  the 4th open only three picks have happened (B, C, B), so B's count is 2.
  The "3 signals" in the report was the space total.
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

  # Backdates every signal row the actor has in the room that is newer than
  # `at` (the rows just written) to `at`.
  defp backdate!(actor, room, at) do
    Signal
    |> where([s], s.actor_user_id == ^actor.id and s.space_id == ^room.id)
    |> where([s], s.inserted_at > ^at)
    |> Repo.update_all(set: [inserted_at: at])
  end

  defp record!(actor, room, %User{} = who, outcome, rung) do
    t = target(who)

    {:ok, %Signal{}} =
      Habits.record(%{
        actor_user_id: actor.id,
        space_id: room.id,
        action: @action,
        target_type: t.target_type,
        target_id: t.target_id,
        outcome: outcome,
        rung: rung
      })
  end

  # Drives the history the way MessageAttentionHooks.record_pick does: each
  # open reads suggest/4 at that open's time, and the pick is recorded at the
  # rung that open showed. Opens are one hour apart, ending an hour before
  # now. Returns the suggestion seen at each open.
  defp picker!(actor, room, sequence) do
    base = DateTime.add(DateTime.utc_now(), -(length(sequence) + 1) * 3600, :second)

    sequence
    |> Enum.with_index()
    |> Enum.map(fn {%User{} = picked, i} ->
      at = DateTime.add(base, i * 3600, :second)
      s = Habits.suggest(actor.id, room.id, @action, now: at)

      cond do
        s.prefill == target(picked) ->
          record!(actor, room, picked, "accepted", "prefill")

        s.prefill ->
          record!(actor, room, picked, "chosen", "prefill")
          {:ok, %Signal{}} = record_overridden!(actor, room, s.prefill)

        s.ranked != [] ->
          record!(actor, room, picked, "chosen", "rank")

        true ->
          record!(actor, room, picked, "chosen", "none")
      end

      backdate!(actor, room, at)
      s
    end)
  end

  defp chosen_at!(actor, room, who, at) do
    record!(actor, room, who, "chosen", "rank")
    backdate!(actor, room, at)
  end

  defp record_overridden!(actor, room, prefill) do
    Habits.record(
      Map.merge(prefill, %{
        actor_user_id: actor.id,
        space_id: room.id,
        action: @action,
        outcome: "overridden",
        rung: "prefill"
      })
    )
  end

  defp signal_trace(actor, room, names) do
    Signal
    |> where([s], s.actor_user_id == ^actor.id and s.space_id == ^room.id)
    |> order_by([s], asc: s.inserted_at, asc: s.id)
    |> Repo.all()
    |> Enum.map(&{Map.fetch!(names, &1.target_id), &1.outcome, &1.rung})
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

  test "b. real picker B,C,B,B,C,B,C: pre-fill B fires at the 5th open (3B/1C: conf 0.75, count 3); picking C writes chosen@prefill C + overridden@prefill B; 8th open ranks [C, B], prefill nil",
       %{actor: actor, b: b, c: c, room: room} do
    seen = picker!(actor, room, [b, c, b, b, c, b, c])

    fourth = Enum.at(seen, 3)
    assert ranked_ids(fourth) == [b.id, c.id]
    assert fourth.prefill == nil, "4th open: B count 2 < min_signals 3"

    fifth = Enum.at(seen, 4)
    assert ranked_ids(fifth) == [b.id, c.id]

    assert fifth.prefill == target(b),
           "5th open: B count 3 = min_signals 3 and conf 3/4 = 0.75 >= 0.6 must pre-fill B"

    for i <- [5, 6] do
      assert Enum.at(seen, i).prefill == nil, "open #{i + 1}: the override leaves no pre-fill"
    end

    eighth = open(actor, room)

    assert ranked_ids(eighth) == [c.id, b.id],
           "B 4 picks - 1 override vs C 3 picks: C's picks are newer, so C sorts first"

    assert eighth.prefill == nil
    assert eighth.act == nil

    names = %{b.id => :b, c.id => :c}

    assert signal_trace(actor, room, names) == [
             {:b, "chosen", "none"},
             {:c, "chosen", "rank"},
             {:b, "chosen", "rank"},
             {:b, "chosen", "rank"},
             {:c, "chosen", "prefill"},
             {:b, "overridden", "prefill"},
             {:b, "chosen", "rank"},
             {:c, "chosen", "rank"}
           ]
  end

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

  # Found on the dev server (task 01a1b814): min_signals used to be compared
  # with the DECAYED count, so three picks a minute apart weighed 2.99998 and
  # never pre-filled. It is now the raw count; these picks are days apart.
  describe "d. min_signals counts picks, not decayed weight" do
    test "three picks of B at now-2d, now-1d, now -> prefill B at the next open",
         %{actor: actor, b: b, room: room} do
      now = DateTime.utc_now()

      for days <- [2, 1, 0] do
        chosen_at!(actor, room, b, DateTime.add(now, -days * 86_400, :second))
      end

      s = Habits.suggest(actor.id, room.id, @action, now: DateTime.add(now, 1, :second))

      assert hd(s.ranked).score < 3.0, "the decayed weight is under 3"
      assert s.prefill == target(b), "three picks = min_signals 3 must pre-fill"
    end

    test "two picks of B at now-1d, now -> no prefill",
         %{actor: actor, b: b, room: room} do
      now = DateTime.utc_now()

      for days <- [1, 0] do
        chosen_at!(actor, room, b, DateTime.add(now, -days * 86_400, :second))
      end

      s = Habits.suggest(actor.id, room.id, @action, now: DateTime.add(now, 1, :second))

      assert ranked_ids(s) == [b.id]
      assert s.prefill == nil, "two picks < min_signals 3"
    end
  end
end
