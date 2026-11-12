defmodule Platform.Gaming do
  @moduledoc "Opt-in game presentation; existing authorization and accounts stay authoritative."
  def enabled?, do: Platform.Branding.get().experience == "gaming"
  def home_path(game), do: if(enabled?(), do: "/play", else: "/games/" <> game["slug"])
  def projects(nil, _games), do: %{}

  def projects(user, games) do
    allowed =
      Platform.Tasks.list_projects_for_user(user,
        access_scope: Platform.Access.Scope.for_user(user)
      )

    Map.new(games, fn game ->
      project =
        Enum.find(
          allowed,
          &(&1.id == game["project_id"] and &1.org_id == game["org_id"] and is_nil(&1.archived_at))
        )

      {game["slug"], project}
    end)
  end
end
