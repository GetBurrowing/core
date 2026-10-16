defmodule PlatformWeb.AccessViewAs do
  @moduledoc "The shell's own rail destinations for a view-as target."

  alias Platform.Tenancy
  alias PlatformWeb.Components.IconRail

  def rail_keys(%{surface: :external_chat}), do: []
  def rail_keys(%{surface: :agent}), do: []

  def rail_keys(%{scope: scope}) do
    root_user = Tenancy.root_admin_preloaded?(scope.actor)
    IconRail.destinations(root_user: root_user) |> Enum.map(& &1.key)
  end
end
