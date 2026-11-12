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
  def tint(game) do
    case game["theme_color"] do
      color when is_binary(color) -> if Regex.match?(~r/^#[a-fA-F0-9]{6}$/, color), do: color, else: "#4d8bff"
      _ -> "#4d8bff"
    end
  end

  def workspace_path(_game, nil, _user), do: nil
  def workspace_path(game, project, user) do
    scope = Platform.Access.Scope.for_user(user)
    with id when is_binary(id) <- game["development_space_id"],
         true <- Platform.UUID.valid?(id),
         %{archived_at: nil, kind: "channel"} = space <- Platform.Chat.get_space(id),
         true <- space.org_id == project.org_id,
         true <- space.metadata["goal_project_id"] == project.id,
         true <- is_nil(space.metadata["public_game_slug"]),
         :ok <- Platform.Access.check(scope, "chat.read", {:space, id}) do
      "/chat/" <> space.slug
    else
      _ -> "/files/" <> project.id
    end
  end

  def workspace_project(nil, _user), do: nil
  def workspace_project(space, user) do
    if user && is_nil(space.metadata["public_game_slug"]) &&
         Platform.Access.check(Platform.Access.Scope.for_user(user), "chat.read", {:space, space.id}) == :ok do
      games = Platform.Games.list_published()
      project_map = projects(user, games)
      Enum.find_value(games, fn game ->
        project = project_map[game["slug"]]
        if project && project.id == space.metadata["goal_project_id"] && project.org_id == space.org_id,
          do: project
      end)
    end
  end

end
