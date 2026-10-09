defmodule PlatformWeb.LifecycleActionsTest do
  @moduledoc """
  The lifecycle flash copy names the root org by its role, never by one
  install's org name (task 01a116de stage 2).
  """
  use ExUnit.Case, async: true

  alias PlatformWeb.LifecycleActions

  test "the :not_deletable message names the root org generically" do
    assert LifecycleActions.error_message(:not_deletable) ==
             "The root org can't be archived or deleted."
  end
end
