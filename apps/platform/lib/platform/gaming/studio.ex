defmodule Platform.Gaming.Studio do
  @moduledoc "Authorized game workspaces, separate from the public game catalog."
  alias Platform.{Access, Chat, Games, Repo, Tasks}
  import Ecto.Query
  alias Platform.Access.Scope

  def list(user) do
    scope = Scope.for_user(user)
    games = Games.list_published()

    Tasks.list_projects_for_user(user, access_scope: scope)
    |> Enum.reject(& &1.archived_at)
    |> Enum.map(fn project ->
      game =
        Enum.find(games, &(&1["project_id"] == project.id and &1["org_id"] == project.org_id))

      %{project: project, game: game, space: development_space(project, game, scope)}
    end)
    |> Enum.filter(
      &(&1.game || &1.project.config["game_studio"] == true ||
          &1.project.tech_stack["engine"] in ~w(godot unity unreal))
    )
    |> Enum.sort_by(fn entry ->
      index = Enum.find_index(games, &(&1["project_id"] == entry.project.id))
      {index || length(games), entry.project.name}
    end)
  end

  def development_space(project, game, scope) do
    id = (game && game["development_space_id"]) || project.config["development_space_id"]

    with true <- Platform.UUID.valid?(id),
         %{archived_at: nil, kind: "channel"} = space <- Chat.get_space(id),
         true <- space.org_id == project.org_id,
         true <- space.metadata["goal_project_id"] == project.id,
         true <- is_nil(space.metadata["public_game_slug"]),
         :ok <- Access.check(scope, "chat.read", {:space, id}) do
      space
    else
      _ -> nil
    end
  end

  def tasks(nil, _scope), do: []

  def tasks(entry, scope) do
    from(t in Tasks.Task,
      where:
        t.project_id == ^entry.project.id and is_nil(t.deleted_at) and
          t.status not in ["done", "cancelled"],
      order_by: [desc: t.inserted_at, desc: t.id],
      limit: 6
    )
    |> Platform.Access.Query.where_readable(scope, "tasks.read", :task, %{id: :id})
    |> Repo.all()
  end

  def canvases(%{space: %{id: id}}, scope),
    do: Chat.list_recent_canvases([id], limit: 6, access_scope: scope)

  def canvases(_, _scope), do: []
  def playtest_notice(nil, _user), do: "Choose a game project to playtest."

  def playtest_notice(%{space: nil}, _user),
    do: "Connect a development room before starting a shared playtest."

  def playtest_notice(entry, user) do
    provider = Module.concat([Platform, GameStream])

    cond do
      not Code.ensure_loaded?(provider) ->
        "Browser playtests are not installed here yet. Open the published build to play locally."

      not apply(provider, :enabled?, []) ->
        "Browser playtests are disabled on this install. Open the published build to play locally."

      not Access.can?(Scope.for_user(user), "play.use", entry.project) ->
        "Your account does not have permission to start Play sessions for this project."

      not apply(provider, :host_available?, []) ->
        "No Play host is connected. Your published build is still available to play locally."

      is_nil(entry.project.repo_url) or entry.project.repo_url == "" ->
        "Your agent needs to connect the game repository before its first playtest."

      true ->
        nil
    end
  end

  def playtest(nil, _user), do: {:error, :no_project}

  def playtest(entry, user) do
    scope = Scope.for_user(user)
    current = Enum.find(list(user), &(&1.project.id == entry.project.id))
    provider = Module.concat([Platform, GameStream])

    with %{space: %{id: space_id}} <- current,
         :ok <- Access.check(scope, "canvas.write", {:space, space_id}),
         :ok <- Access.authorize(scope, "play.use", current.project),
         %{id: participant_id} <-
           Platform.Repo.get_by(Chat.Participant,
             space_id: space_id,
             participant_type: "user",
             participant_id: user.id
           ),
         true <-
           Code.ensure_loaded?(provider) and
             function_exported?(provider, :start_project_session, 3),
         {:ok, status} <- apply(provider, :start_project_session, [current.project.id, user, []]) do
      document = %{
        "version" => 1,
        "revision" => 1,
        "root" => %{
          "id" => "root",
          "type" => "stack",
          "props" => %{"gap" => 12},
          "children" => [
            %{
              "id" => "game-stream",
              "type" => "game_stream",
              "props" => %{
                "session_id" => status.session_id,
                "project_id" => current.project.id,
                "review_sha" => status.review_sha,
                "branch" => status.branch,
                "title" => current.project.name <> " · project playtest",
                "latency_warn_ms" => 50
              }
            }
          ]
        },
        "theme" => %{},
        "bindings" => %{},
        "meta" => %{}
      }

      case Chat.create_canvas(%{
             space_id: space_id,
             created_by: participant_id,
             title: "Playtest " <> String.slice(status.review_sha, 0, 12),
             document: document
           }) do
        {:ok, canvas} ->
          {:ok, "/canvases/" <> canvas.id}

        error ->
          apply(provider, :stop_session, [status.session_id, "Could not create playtest canvas"])
          error
      end
    else
      _ -> {:error, :playtest_unavailable}
    end
  end
end
