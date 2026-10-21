defmodule PlatformWeb.AccessViewAs do
  @moduledoc "The shell's own rail destinations for a view-as target."

  alias Platform.Tenancy
  alias PlatformWeb.Components.IconRail

  def rail_keys(%{surface: :external_chat}), do: []
  def rail_keys(%{surface: :agent}), do: []

  def rail_keys(%{scope: scope}) do
    root_user = Tenancy.root_admin_preloaded?(scope.actor)
    # The desktop rail's tiles: a More-sheet-only (`:sheet`) destination such
    # as Changelog is not a rail tile (task 01a1557a-807f stage 2).
    IconRail.destinations(root_user: root_user)
    |> Enum.filter(&(&1.cluster in IconRail.desktop_clusters()))
    |> Enum.map(& &1.key)
  end
end
