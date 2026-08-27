defmodule PlatformWeb.SpaceTopicsTest do
  @moduledoc """
  Registration-count tests for `PlatformWeb.SpaceTopics`.

  Every count is read DIRECTLY from `Registry.lookup(Platform.PubSub, topic)`
  and filtered to `self()`. Deliberately not read through a `Chat.PubSub`
  helper, and deliberately not read from `:chat_space_holders` — that assign is
  the code under test writing its own answer, so asserting on it would be
  circular.

  Every absence assertion carries its positive control IN THE SAME TEST BODY: an
  assertion of "0 registrations" on a topic nobody ever subscribed passes for
  free, so each test also exhibits a topic that IS held at the same moment.
  """

  use ExUnit.Case, async: true

  alias PlatformWeb.SpaceTopics

  # Invented ids as hygiene -- no real space ids in test fixtures.
  setup do
    on_exit(fn -> :ok end)

    %{
      alpha: "space-alpha-" <> unique(),
      beta: "space-beta-" <> unique(),
      gamma: "space-gamma-" <> unique()
    }
  end

  defp unique, do: Integer.to_string(System.unique_integer([:positive]))

  defp socket, do: SpaceTopics.ensure_holders(%Phoenix.LiveView.Socket{})

  # Count this pid's registrations on the raw topic string, bypassing every
  # helper in the module under test.
  defp registrations(space_id) do
    me = self()

    Platform.PubSub
    |> Registry.lookup("chat:space:" <> space_id)
    |> Enum.count(fn {pid, _meta} -> pid == me end)
  end

  describe "hold/3" do
    test "two holds by different owners take exactly one registration", %{
      alpha: alpha,
      beta: beta
    } do
      s = socket()
      assert registrations(alpha) == 0

      s = SpaceTopics.hold(s, alpha, :roster)
      s = SpaceTopics.hold(s, alpha, :chat_active)

      assert registrations(alpha) == 1
      # Positive control for the scoping: a different id is untouched.
      assert registrations(beta) == 0

      _ = s
    end

    test "a repeated hold by the same owner is idempotent", %{alpha: alpha, beta: beta} do
      s = socket()
      s = SpaceTopics.hold(s, alpha, :roster)
      s = SpaceTopics.hold(s, alpha, :roster)
      s = SpaceTopics.hold(s, alpha, :roster)

      assert registrations(alpha) == 1

      # Positive control: the mechanism can reach 1 on another id too, so the
      # count above is not pinned by something global.
      s = SpaceTopics.hold(s, beta, :presence)
      assert registrations(beta) == 1

      _ = s
    end

    test "an unrecognised owner atom raises rather than creating a phantom holder",
         %{alpha: alpha} do
      s = socket()

      assert_raise FunctionClauseError, fn ->
        SpaceTopics.hold(s, alpha, :rostr)
      end

      # Positive control in the same body: the correctly spelled owner works,
      # so the raise above is about the atom and not about the arguments.
      s = SpaceTopics.hold(s, alpha, :roster)
      assert registrations(alpha) == 1
      assert SpaceTopics.held_by?(s, alpha, :roster)
    end
  end

  describe "release/3" do
    test "release by the first of two owners keeps the registration; the second drops it",
         %{alpha: alpha, beta: beta} do
      s = socket()
      s = SpaceTopics.hold(s, alpha, :roster)
      s = SpaceTopics.hold(s, alpha, :chat_active)
      # Held throughout as the positive control for every count below.
      s = SpaceTopics.hold(s, beta, :tasks_exec)

      assert registrations(alpha) == 1

      s = SpaceTopics.release(s, alpha, :roster)
      assert registrations(alpha) == 1
      assert registrations(beta) == 1

      s = SpaceTopics.release(s, alpha, :chat_active)
      assert registrations(alpha) == 0
      # Positive control: beta is still held at the moment alpha reads 0, so
      # the 0 is a real release and not a topic nobody ever subscribed.
      assert registrations(beta) == 1

      _ = s
    end

    test "release by a never-holder does not unsubscribe", %{alpha: alpha, beta: beta} do
      s = socket()
      s = SpaceTopics.hold(s, alpha, :roster)
      s = SpaceTopics.hold(s, beta, :presence)

      assert registrations(alpha) == 1

      # :chat_active never held alpha. An unguarded decrement would unsubscribe
      # here and silently kill delivery for :roster.
      s = SpaceTopics.release(s, alpha, :chat_active)

      assert registrations(alpha) == 1
      assert SpaceTopics.held_by?(s, alpha, :roster)

      # And the release really is a no-op rather than a swallowed error: the
      # genuine holder can still release it to 0, with beta as the control.
      s = SpaceTopics.release(s, alpha, :roster)
      assert registrations(alpha) == 0
      assert registrations(beta) == 1

      _ = s
    end

    # This is the test that kills the `MapSet.member?/2` guard in `release/3`.
    # The four earlier cases do NOT: dropping the guard still leaves a
    # non-empty remainder whenever some other owner holds the space, and
    # unsubscribing an already-unsubscribed topic is invisible at the registry.
    # The guard only becomes observable when the pid holds a registration this
    # module did not take -- which is the state stages 2-4 spend their whole
    # rollout in, since each adopts one surface at a time and the rest keep
    # calling `Chat.PubSub.subscribe/1` raw.
    test "release for an unheld space does not destroy a registration taken outside the module",
         %{alpha: alpha, beta: beta} do
      s = socket()
      s = SpaceTopics.hold(s, beta, :roster)

      # A not-yet-adopted surface subscribes alpha raw, exactly as shell_live
      # and tasks_live still do on main.
      :ok = Platform.Chat.PubSub.subscribe(alpha)
      assert registrations(alpha) == 1

      # This module has no holder recorded for alpha. Releasing must not touch
      # it -- an unguarded decrement would compute an empty remainder and call
      # `unsubscribe/1`, silently killing the other surface's delivery.
      s = SpaceTopics.release(s, alpha, :chat_active)

      assert registrations(alpha) == 1
      assert registrations(beta) == 1

      :ok = Platform.Chat.PubSub.unsubscribe(alpha)
      assert registrations(alpha) == 0
      # Positive control for that 0 in the same body.
      assert registrations(beta) == 1

      _ = s
    end

    test "release on a space that was never held anywhere is a no-op", %{
      alpha: alpha,
      gamma: gamma
    } do
      s = socket()
      s = SpaceTopics.hold(s, alpha, :roster)

      s = SpaceTopics.release(s, gamma, :roster)

      assert registrations(gamma) == 0
      # Positive control: alpha is held in the same body, so the 0 above is
      # not the free pass a never-subscribed topic gives every assertion.
      assert registrations(alpha) == 1

      _ = s
    end
  end

  describe "release_all/2" do
    test "drops one owner from every id, unsubscribing exactly those that emptied",
         %{alpha: alpha, beta: beta, gamma: gamma} do
      s = socket()
      # alpha: held by :presence alone -> must empty.
      s = SpaceTopics.hold(s, alpha, :presence)
      # beta: held by :presence AND :chat_active -> must survive.
      s = SpaceTopics.hold(s, beta, :presence)
      s = SpaceTopics.hold(s, beta, :chat_active)
      # gamma: :presence never held it -> must survive untouched.
      s = SpaceTopics.hold(s, gamma, :roster)

      assert registrations(alpha) == 1
      assert registrations(beta) == 1
      assert registrations(gamma) == 1

      s = SpaceTopics.release_all(s, :presence)

      assert registrations(alpha) == 0
      # Positive controls for that 0, asserted in the same body.
      assert registrations(beta) == 1
      assert registrations(gamma) == 1

      refute SpaceTopics.held_by?(s, beta, :presence)
      assert SpaceTopics.held_by?(s, beta, :chat_active)
      assert SpaceTopics.held_by?(s, gamma, :roster)

      _ = s
    end

    test "release_all for an owner holding nothing changes no registration", %{
      alpha: alpha,
      beta: beta
    } do
      s = socket()
      s = SpaceTopics.hold(s, alpha, :roster)
      s = SpaceTopics.hold(s, beta, :chat_active)

      s = SpaceTopics.release_all(s, :tasks_exec)

      assert registrations(alpha) == 1
      assert registrations(beta) == 1

      # And the same call really can reach 0 when the owner does hold, so the
      # unchanged counts above are not vacuous.
      s = SpaceTopics.release_all(s, :roster)
      assert registrations(alpha) == 0
      assert registrations(beta) == 1

      _ = s
    end
  end

  describe "ensure_holders/1" do
    test "is idempotent and does not discard live holders", %{alpha: alpha, beta: beta} do
      s = socket()
      s = SpaceTopics.hold(s, alpha, :roster)

      # ShellLive's on_mount seeds, then the view's own mount/3 calls it again.
      s = SpaceTopics.ensure_holders(s)
      s = SpaceTopics.ensure_holders(s)

      assert SpaceTopics.held_by?(s, alpha, :roster)
      assert registrations(alpha) == 1
      assert registrations(beta) == 0

      # If re-seeding had wiped the map, this release would look like a
      # never-holder no-op and alpha would stay at 1.
      s = SpaceTopics.release(s, alpha, :roster)
      assert registrations(alpha) == 0

      _ = s
    end

    test "seeds an empty map on a socket that has never seen it" do
      s = SpaceTopics.ensure_holders(%Phoenix.LiveView.Socket{})
      assert s.assigns[:chat_space_holders] == %{}
    end
  end

  test "owners/0 is the closed set the guards enforce" do
    assert SpaceTopics.owners() == [
             :roster,
             :presence,
             :chat_rail,
             :chat_active,
             :tasks_exec,
             :meeting
           ]
  end

  describe ":meeting owner" do
    test "owners/0 includes :meeting" do
      assert :meeting in SpaceTopics.owners()
    end

    test "a :meeting hold on a space already held by :presence takes no second registration",
         %{alpha: alpha, beta: beta} do
      s = socket()
      s = SpaceTopics.hold(s, alpha, :presence)
      assert registrations(alpha) == 1

      # MeetingLive mounts inside the same shell pid as ShellLive. A raw
      # `Chat.PubSub.subscribe/1` here would take a SECOND registration and
      # every broadcast would arrive twice.
      s = SpaceTopics.hold(s, alpha, :meeting)

      assert registrations(alpha) == 1
      # Positive control: the mechanism can reach 1 on another id, so the count
      # above is not pinned by something global.
      s = SpaceTopics.hold(s, beta, :meeting)
      assert registrations(beta) == 1

      _ = s
    end

    test "releasing :meeting while :presence still holds leaves the registration DELIVERING",
         %{alpha: alpha, beta: beta} do
      s = socket()
      s = SpaceTopics.hold(s, alpha, :presence)
      s = SpaceTopics.hold(s, alpha, :meeting)
      s = SpaceTopics.hold(s, beta, :roster)

      s = SpaceTopics.release(s, alpha, :meeting)

      assert registrations(alpha) == 1
      assert registrations(beta) == 1
      assert SpaceTopics.held_by?(s, alpha, :presence)
      refute SpaceTopics.held_by?(s, alpha, :meeting)

      # A count of 1 is NOT delivery. A release that corrupted the surviving
      # registration would still read as 1 and this test would pass while the
      # feature is broken, so assert the message actually arrives.
      :ok = Platform.Chat.PubSub.broadcast(alpha, {:space_topics_probe, alpha})
      assert_receive {:space_topics_probe, ^alpha}, 500

      # ...and exactly once: no duplicate registration survived either.
      refute_receive {:space_topics_probe, ^alpha}, 50

      # Positive control for the assert_receive: the same probe on a topic this
      # pid does NOT hold does not arrive.
      s = SpaceTopics.release(s, alpha, :presence)
      assert registrations(alpha) == 0
      :ok = Platform.Chat.PubSub.broadcast(alpha, {:space_topics_probe, alpha})
      refute_receive {:space_topics_probe, ^alpha}, 100
      # ...while beta, still held, does deliver.
      :ok = Platform.Chat.PubSub.broadcast(beta, {:space_topics_probe, beta})
      assert_receive {:space_topics_probe, ^beta}, 500

      _ = s
    end

    test "a :meeting release by a socket that never held it does not unsubscribe",
         %{alpha: alpha, beta: beta} do
      s = socket()
      s = SpaceTopics.hold(s, alpha, :presence)
      s = SpaceTopics.hold(s, beta, :roster)

      # :meeting never held alpha. An unguarded decrement would compute an
      # empty remainder and unsubscribe, silently killing :presence delivery.
      s = SpaceTopics.release(s, alpha, :meeting)

      assert registrations(alpha) == 1
      assert registrations(beta) == 1
      assert SpaceTopics.held_by?(s, alpha, :presence)

      :ok = Platform.Chat.PubSub.broadcast(alpha, {:space_topics_probe, alpha})
      assert_receive {:space_topics_probe, ^alpha}, 500

      _ = s
    end

    test "an unknown owner atom still raises with :meeting in the set", %{alpha: alpha} do
      s = socket()

      # The closed set is ENFORCED, not merely documented -- adding a sixth tag
      # must not have opened it up.
      assert_raise FunctionClauseError, fn -> SpaceTopics.hold(s, alpha, :meetings) end
      assert_raise FunctionClauseError, fn -> SpaceTopics.hold(s, alpha, :meting) end

      # Positive control in the same body: the correct spelling works, so the
      # raises above are about the atom and not the arguments.
      s = SpaceTopics.hold(s, alpha, :meeting)
      assert registrations(alpha) == 1
      assert SpaceTopics.held_by?(s, alpha, :meeting)
    end

    test "release_all/2 drops :meeting without touching a co-held space",
         %{alpha: alpha, beta: beta} do
      s = socket()
      s = SpaceTopics.hold(s, alpha, :meeting)
      s = SpaceTopics.hold(s, beta, :meeting)
      s = SpaceTopics.hold(s, beta, :presence)

      s = SpaceTopics.release_all(s, :meeting)

      assert registrations(alpha) == 0
      assert registrations(beta) == 1
      refute SpaceTopics.held_by?(s, beta, :meeting)
      assert SpaceTopics.held_by?(s, beta, :presence)

      _ = s
    end
  end
end
