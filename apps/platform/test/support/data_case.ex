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

    :ok
  end
end
