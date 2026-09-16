defmodule Platform.Meetings.PressWindowTest do
  @moduledoc """
  Tests for `Platform.Meetings.PressWindow` — the per-meeting push-to-talk
  window store and its matching logic (task 01a03f4e, plan v2 stage 1).

  The load-bearing test in this file is
  "a different speaker's segment inside A's window is NOT claimed by A".
  It is written so the negative assertion is demonstrably reachable: the
  same instant is first shown to claim for A, so `:none` for B can only
  be the identity gate talking and not the clock.

  Async-false because the module owns a single named ETS table started
  under `Platform.Application`'s supervision tree.
  """

  use ExUnit.Case, async: false

  alias Platform.Meetings.PressWindow

  @a "user:11111111-1111-7111-8111-111111111111"
  @b "user:22222222-2222-7222-8222-222222222222"

  setup context do
    # Namespace by test so a shared table can't leak state between them.
    meeting_id = "meeting-#{inspect(context.test)}" |> :erlang.phash2() |> Integer.to_string()

    on_exit(fn -> PressWindow.clear_meeting(meeting_id) end)

    t0 = ~U[2026-08-29 12:00:00.000000Z]

    {:ok, meeting_id: meeting_id, t0: t0}
  end

  defp ms(%DateTime{} = t, offset), do: DateTime.add(t, offset, :millisecond)

  describe "the identity gate" do
    test "a speaker's own segment inside their own window is claimed",
         %{meeting_id: m, t0: t0} do
      {:ok, _} = PressWindow.press(m, @a, t0)

      assert {:ok, window} = PressWindow.claim(m, @a, ms(t0, 500))
      assert window.identity == @a
      assert window.pressed_at == t0
    end

    @tag :anti_vacuity
    test "a DIFFERENT speaker's segment inside A's window is NOT claimed by A",
         %{meeting_id: m, t0: t0} do
      # A holds the talk key from t0 to t0+2s.
      {:ok, _} = PressWindow.press(m, @a, t0)
      {:ok, _} = PressWindow.release(m, @a, ms(t0, 2_000))

      # B says something squarely in the middle of A's press. In a real
      # meeting this is just a colleague talking over the top.
      at = ms(t0, 1_000)

      # Reachability guard: this instant genuinely IS inside a live
      # window, so the refute below cannot pass vacuously by the clock
      # having ruled everything out. If this line ever fails, the
      # `:none` assertion underneath stops proving anything.
      assert {:ok, %{identity: @a}} = PressWindow.claim(m, @a, at)

      # The whole point of keying on identity.
      assert PressWindow.claim(m, @b, at) == :none

      # And it is B who is unclaimed, not the meeting that is empty:
      # the window is still sitting in the store, holder A.
      assert [%{identity: @a}] = PressWindow.open_windows_at(m, at)
    end

    test "B's own press claims for B and still does not claim for A",
         %{meeting_id: m, t0: t0} do
      # Both hold at once — concurrent windows, one per identity.
      {:ok, _} = PressWindow.press(m, @a, t0)
      {:ok, _} = PressWindow.press(m, @b, ms(t0, 200))

      at = ms(t0, 400)

      assert {:ok, %{identity: @a}} = PressWindow.claim(m, @a, at)
      assert {:ok, %{identity: @b}} = PressWindow.claim(m, @b, at)
      assert [%{identity: @a}, %{identity: @b}] = PressWindow.open_windows_at(m, at)
    end

    test "an unattributed segment never claims, and a blank identity is never stored",
         %{meeting_id: m, t0: t0} do
      # press/3 refuses a blank holder outright, so there is no way to
      # get a nil-vs-nil match — which keeps the assertions below
      # reachable rather than true-by-absence.
      assert PressWindow.press(m, nil, t0) == {:error, :invalid_identity}
      assert PressWindow.press(m, "", t0) == {:error, :invalid_identity}
      assert PressWindow.press(m, "   ", t0) == {:error, :invalid_identity}
      assert PressWindow.list(m) == []

      # A real window exists; the unattributed segment still gets nothing.
      {:ok, _} = PressWindow.press(m, @a, t0)
      at = ms(t0, 100)

      assert {:ok, _} = PressWindow.claim(m, @a, at)
      assert PressWindow.claim(m, nil, at) == :none
      assert PressWindow.claim(m, "", at) == :none
    end

    test "windows do not leak across meetings", %{meeting_id: m, t0: t0} do
      other = m <> "-other"
      on_exit(fn -> PressWindow.clear_meeting(other) end)

      {:ok, _} = PressWindow.press(m, @a, t0)
      at = ms(t0, 100)

      assert {:ok, _} = PressWindow.claim(m, @a, at)
      assert PressWindow.claim(other, @a, at) == :none
    end
  end

  describe "the time gate" do
    test "a segment arriving before the press is not claimed", %{meeting_id: m, t0: t0} do
      {:ok, _} = PressWindow.press(m, @a, t0)

      assert PressWindow.claim(m, @a, ms(t0, -1)) == :none
      # Reachable: one millisecond later, the same speaker does claim.
      assert {:ok, _} = PressWindow.claim(m, @a, t0)
    end

    test "a released window still claims inside the grace period, and stops after",
         %{meeting_id: m, t0: t0} do
      grace = PressWindow.release_grace_ms()

      {:ok, _} = PressWindow.press(m, @a, t0)
      {:ok, _} = PressWindow.release(m, @a, ms(t0, 1_000))

      # The tail of the utterance: spoken during the press, finalised by
      # the transcriber after the key came up.
      assert {:ok, _} = PressWindow.claim(m, @a, ms(t0, 1_000 + grace))
      assert PressWindow.claim(m, @a, ms(t0, 1_000 + grace + 1)) == :none
    end

    test "a held window stops claiming once max hold elapses", %{meeting_id: m, t0: t0} do
      hold = PressWindow.max_hold_ms()

      {:ok, _} = PressWindow.press(m, @a, t0)

      # Still held — no release ever arrived (closed tab, dropped socket).
      assert {:ok, _} = PressWindow.claim(m, @a, ms(t0, hold))
      assert PressWindow.claim(m, @a, ms(t0, hold + 1)) == :none
    end

    test "an expired held window is replaced by a fresh press, not extended",
         %{meeting_id: m, t0: t0} do
      hold = PressWindow.max_hold_ms()

      {:ok, first} = PressWindow.press(m, @a, t0)
      {:ok, second} = PressWindow.press(m, @a, ms(t0, hold + 1))

      assert first.pressed_at == t0
      assert second.pressed_at == ms(t0, hold + 1)
      assert PressWindow.get(m, @a).pressed_at == ms(t0, hold + 1)
    end

    test "claims/2 counts what claim/3 matched, and a fresh press resets it",
         %{meeting_id: m, t0: t0} do
      hold = PressWindow.max_hold_ms()

      assert PressWindow.claims(m, @a) == 0

      {:ok, _} = PressWindow.press(m, @a, t0)
      assert PressWindow.claims(m, @a) == 0

      assert {:ok, _} = PressWindow.claim(m, @a, ms(t0, 500))
      assert PressWindow.claims(m, @a) == 1

      # A miss records nothing: B's segment inside A's window, and a
      # segment before the press.
      assert PressWindow.claim(m, @b, ms(t0, 600)) == :none
      assert PressWindow.claim(m, @a, ms(t0, -1)) == :none
      assert PressWindow.claims(m, @a) == 1

      # A repeat press over the live window is the SAME window.
      {:ok, _} = PressWindow.press(m, @a, ms(t0, 50))
      assert PressWindow.claims(m, @a) == 1

      # A fresh press after max hold is a new window: nothing claimed yet.
      {:ok, _} = PressWindow.press(m, @a, ms(t0, hold + 1))
      assert PressWindow.claims(m, @a) == 0

      assert {:ok, _} = PressWindow.claim(m, @a, ms(t0, hold + 2))
      assert PressWindow.claims(m, @a) == 1

      assert PressWindow.clear_meeting(m) >= 1
      assert PressWindow.claims(m, @a) == 0
    end
  end

  describe "press/3" do
    test "a repeat press while held keeps the original pressed_at",
         %{meeting_id: m, t0: t0} do
      # One physical press can fire pointerdown and keydown, and a held
      # key repeats. Restarting the clock would drop the beginning of
      # the utterance.
      {:ok, first} = PressWindow.press(m, @a, t0)
      {:ok, repeat} = PressWindow.press(m, @a, ms(t0, 50))

      assert repeat.pressed_at == first.pressed_at
      assert repeat.released_at == nil
      assert length(PressWindow.list(m)) == 1
    end

    test "a press after a release opens a new window", %{meeting_id: m, t0: t0} do
      {:ok, _} = PressWindow.press(m, @a, t0)
      {:ok, _} = PressWindow.release(m, @a, ms(t0, 500))
      {:ok, second} = PressWindow.press(m, @a, ms(t0, 5_000))

      assert second.pressed_at == ms(t0, 5_000)
      assert second.released_at == nil
    end

    test "defaults its stamp to now when none is given", %{meeting_id: m} do
      before = DateTime.utc_now()
      {:ok, window} = PressWindow.press(m, @a)
      after_ = DateTime.utc_now()

      assert DateTime.compare(window.pressed_at, before) != :lt
      assert DateTime.compare(window.pressed_at, after_) != :gt
    end
  end

  describe "release/3" do
    test "refuses to fabricate a window that was never pressed", %{meeting_id: m, t0: t0} do
      assert PressWindow.release(m, @a, t0) == {:error, :no_window}
      assert PressWindow.list(m) == []
    end

    test "a second release does not extend the grace the first one started",
         %{meeting_id: m, t0: t0} do
      {:ok, _} = PressWindow.press(m, @a, t0)
      {:ok, _} = PressWindow.release(m, @a, ms(t0, 1_000))

      assert PressWindow.release(m, @a, ms(t0, 9_000)) == {:error, :no_window}
      assert PressWindow.get(m, @a).released_at == ms(t0, 1_000)
    end

    test "clamps a backwards clock so a window cannot end before it begins",
         %{meeting_id: m, t0: t0} do
      {:ok, _} = PressWindow.press(m, @a, t0)
      {:ok, window} = PressWindow.release(m, @a, ms(t0, -5_000))

      assert window.released_at == t0
      assert DateTime.compare(window.released_at, window.pressed_at) != :lt
    end
  end

  describe "clear_meeting/1" do
    test "drops this meeting's windows and leaves another meeting's alone",
         %{meeting_id: m, t0: t0} do
      other = m <> "-other"
      on_exit(fn -> PressWindow.clear_meeting(other) end)

      {:ok, _} = PressWindow.press(m, @a, t0)
      {:ok, _} = PressWindow.press(m, @b, t0)
      {:ok, _} = PressWindow.press(other, @a, t0)

      assert PressWindow.clear_meeting(m) == 2
      assert PressWindow.list(m) == []
      assert length(PressWindow.list(other)) == 1
    end
  end

  describe "set_target/4" do
    test "records the pressed agent on the live window, and claim/3 carries it",
         %{meeting_id: m, t0: t0} do
      {:ok, opened} = PressWindow.press(m, @a, t0)
      # A fresh window names no agent — the pre-per-agent default.
      assert opened.target_agent_id == nil
      assert opened.target_agent_slug == nil

      agent_id = Ecto.UUID.generate()
      assert {:ok, window} = PressWindow.set_target(m, @a, agent_id, "octavius")
      assert window.target_agent_id == agent_id
      assert window.target_agent_slug == "octavius"

      # The target is durable and rides out on the claim the classifier
      # reads — which is the whole point of storing it here.
      assert %{target_agent_id: ^agent_id, target_agent_slug: "octavius"} =
               PressWindow.get(m, @a)

      assert {:ok, claimed} = PressWindow.claim(m, @a, ms(t0, 500))
      assert claimed.target_agent_id == agent_id
      assert claimed.target_agent_slug == "octavius"
    end

    test "an untargeted press leaves the window's target blank", %{meeting_id: m, t0: t0} do
      {:ok, _} = PressWindow.press(m, @a, t0)
      assert {:ok, window} = PressWindow.set_target(m, @a, nil, nil)
      assert window.target_agent_id == nil
    end

    test "targeting a window that does not exist is a no-op error", %{meeting_id: m} do
      assert PressWindow.set_target(m, @a, Ecto.UUID.generate(), "x") == {:error, :no_window}

      assert PressWindow.set_target(m, "", Ecto.UUID.generate(), "x") ==
               {:error, :invalid_identity}
    end
  end
end
