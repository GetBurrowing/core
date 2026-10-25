defmodule PlatformWeb.AdminCatchAllHandleInfoTest do
  @moduledoc """
  Every admin LiveView swallows a stray message (Burrow redesign 24, task
  01a1557a stage 5). Stage 5 added the catch-all to the eight that lacked one;
  the rest already had theirs. A message no clause matches would otherwise
  raise FunctionClauseError and take the page down.
  """
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket

  @added [
    PlatformWeb.AdminInsightsLive,
    PlatformWeb.AdminOrgsLive,
    PlatformWeb.AdminPromptsLive,
    PlatformWeb.AdminPrototypesLive,
    PlatformWeb.AdminVaultLive,
    PlatformWeb.UserAccessLive,
    PlatformWeb.AccessLive,
    PlatformWeb.AccessViewAsLive
  ]

  @already [
    PlatformWeb.AdminLive,
    PlatformWeb.AdminBrandingLive,
    PlatformWeb.AdminFederationLive,
    PlatformWeb.AdminSignInUsersLive,
    PlatformWeb.AdminThemesLive,
    PlatformWeb.RecoveryLive,
    PlatformWeb.ExternalRecoveryLive
  ]

  for mod <- @added ++ @already do
    test "#{inspect(mod)} swallows a stray message" do
      mod = unquote(mod)
      Code.ensure_loaded!(mod)
      assert function_exported?(mod, :handle_info, 2)

      socket = %Socket{}

      for msg <- [{:stray, make_ref()}, :unexpected, {:DOWN, make_ref(), :process, self(), :x}] do
        assert {:noreply, ^socket} = mod.handle_info(msg, socket)
      end
    end
  end
end
