defmodule PlatformWeb.GamingController do
  use PlatformWeb, :controller
  plug :put_layout, html: false
  plug :put_root_layout, html: false

  def home(conn, params) do
    if Platform.Gaming.enabled?() do
      games =
        Platform.Games.list_published() |> Enum.sort_by(&{&1["slug"] != "voltron", &1["title"]})

      mode = if params["mode"] in ["create", "discover"], do: params["mode"], else: "play"
      query =
        case params["catalog"] do
          %{"q" => value} when is_binary(value) -> String.slice(value, 0, 100)
          _ -> ""
        end

      visible_games =
        Enum.filter(
          games,
          &String.contains?(
            String.downcase(&1["title"] <> " " <> &1["summary"]),
            String.downcase(query)
          )
        )

      user = Platform.Games.user(get_session(conn, :current_user_id))
      communities = Map.new(games, &{&1["slug"], Platform.Games.community(&1, user)})

      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> render(:home,
        games: games,
        visible_games: visible_games,
        mode: mode,
        search_form: Phoenix.Component.to_form(%{"q" => query}, as: :catalog),
        projects: Platform.Gaming.projects(user, games),
        communities: communities,
        user: user,
        branding: Platform.Branding.get(),
        creator?: not is_nil(user) and Platform.Access.authorize_install(user) == :ok,
        csrf_token: Plug.CSRFProtection.get_csrf_token()
      )
    else
      send_resp(conn, 404, "Not found")
    end
  end
end
