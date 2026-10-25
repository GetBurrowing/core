defmodule PlatformWeb.AccessViewAs do
  @moduledoc "The shell's own navigation destinations for a view-as target."

  alias Platform.Tenancy
  alias PlatformWeb.Components.Sidebar

  def rail_keys(%{surface: :external_chat}), do: []
  def rail_keys(%{surface: :agent}), do: []

  # The desktop sidebar's rows (Burrow redesign 22 stage 1): the tab bar's
  # link tabs then the More sheet's rows, through the same Scope filter the
  # real shell applies, so a view-as preview lists what the target's sidebar
  # lists.
  def rail_keys(%{scope: scope}) do
    root_user = Tenancy.root_admin_preloaded?(scope.actor)
    Sidebar.row_keys(scope, root_user)
  end
end
