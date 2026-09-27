defmodule PlatformWeb.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by
  channel tests.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo

  using do
    quote do
      import Phoenix.ChannelTest
      import Platform.AsyncAssertions
      import PlatformWeb.ChannelCase

      @endpoint PlatformWeb.Endpoint
    end
  end

  setup tags do
    # The sandbox connection is owned by a SEPARATE agent process, not by the
    # test process — the shape `Platform.DataCase` (task 019f9d80 stage 3) and
    # `PlatformWeb.ConnCase` already use (task 01a0d4d6 stage 1 brings
    # ChannelCase in line). With `Sandbox.checkout(Repo)` the TEST process was
    # the owner, and ExUnit runs `on_exit` after the test process is dead, so
    # no teardown barrier could ever run with a live owner: a
    # `DeadLetterReplay` drain cast by `RuntimeChannel.join/3` was still
    # reading the ledger when the connection went away with its owner.
    # `channel_case_owner_lifecycle_test.exs` pins this.
    owner = Sandbox.start_owner!(Repo, shared: not tags[:async])

    # `start_owner!/2` allows its caller only on the `shared: false` branch;
    # allow the test process explicitly in shared mode so `self()` stays a
    # valid `Sandbox.allow/3` parent in both modes (see `Platform.DataCase`).
    if not tags[:async], do: Sandbox.allow(Repo, owner, self())

    shared_mode? = not tags[:async]

    # `on_exit` runs in a different process after the test is dead, so the
    # scoped quiesce's ownership key must be captured here.
    test_pid = self()

    # Same order as `Platform.DataCase`'s on_exit. Do not invent a third one.
    on_exit(fn ->
      Platform.SandboxHelpers.settle_singletons()

      # Task 01a0d4d6 stage 2: no TaskRouter may outlive the owner. Supervised
      # routers are stopped through the production path; routers a test
      # start_link'ed are already exiting with it and are waited for. Either
      # way `TaskRouter.terminate/2`'s log write lands on a live connection.
      # Before the drain, which then waits for the settle watch a stopped
      # router ends. Shared mode only, for the same reason as
      # `drain_or_warn/1`; see `Platform.SandboxHelpers.stop_task_routers_or_warn/1`.
      if shared_mode?, do: Platform.SandboxHelpers.stop_task_routers_or_warn()

      if shared_mode?, do: Platform.SandboxHelpers.drain_or_warn()

      Platform.SandboxHelpers.quiesce_own_or_warn(test_pid, owner)

      # LAST. Everything above needs a live connection.
      Sandbox.stop_owner(owner)
    end)

    {:ok, sandbox_owner: owner}
  end
end
