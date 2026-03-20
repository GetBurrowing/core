defmodule Platform.DataCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a database connection.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo

  using do
    quote do
      alias Platform.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Platform.DataCase
    end
  end

  setup tags do
    :ok = Sandbox.checkout(Repo)

    unless tags[:async] do
      Sandbox.mode(Repo, {:shared, self()})
    end

    # Allow supervised GenServers that use Repo (e.g. AttentionRouter) to
    # share the test sandbox connection so telemetry-driven DB calls don't
    # raise DBConnection.OwnershipError.
    supervised_with_repo = [
      Platform.Chat.AttentionRouter,
      Platform.Agents.ContextBroker,
      Platform.Chat.ContextPlane
    ]

    Enum.each(supervised_with_repo, fn name ->
      if pid = Process.whereis(name) do
        Sandbox.allow(Repo, self(), pid)
      end
    end)

    # Drain the AttentionRouter's message queue before the sandbox is released.
    # A synchronous call guarantees any in-flight telemetry handle_info messages
    # have been fully processed (and their Repo calls completed) before the
    # sandbox owner exits and the connection is freed.
    on_exit(fn ->
      for name <- [Platform.Chat.AttentionRouter, Platform.Chat.ContextPlane] do
        if pid = Process.whereis(name) do
          try do
            GenServer.call(pid, :__drain__, 2_000)
          catch
            :exit, _ -> :ok
          end
        end
      end
    end)

    :ok
  end
end
