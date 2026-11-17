defmodule PlatformWeb.CanvasEpisodeBoardLiveTest do
  @moduledoc """
  Task 01a1eaf6 stage 2: an episode board, created from the `episode_board`
  template, rendered by the standalone canvas page through the real
  renderer dispatch. Assertions use `has_element?/2` (and `LazyHTML.query/2`
  for counts), never `LazyHTML.filter/2`, which matches root nodes only.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.ExternalUserFixtures

  alias Platform.Chat
  alias Platform.Chat.Canvas.Templates
  alias Platform.Tenancy

  setup %{conn: conn} do
    org = Tenancy.get_org_by_slug!("globex")
    space = channel!(%{org_id: org.id, name: "How to Computer"})
    user = create_user!()
    participant = add_user!(space.id, user.id)

    %{conn: login(conn, user.id), space: space, user: participant}
  end

  defp board!(space, user, document) do
    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => user.id,
        "title" => "Ep 14 board",
        "document" => document
      })

    canvas
  end

  test "renders the rail, Needs you and the run sheet with show mode", %{
    conn: conn,
    space: space,
    user: user
  } do
    canvas = board!(space, user, Templates.get("episode_board").document)
    {:ok, view, html} = live(conn, ~p"/canvases/#{canvas.id}")

    assert has_element?(view, ~s|[data-role="episode-title"]|, "Ep 14 · The AI savings cliff")
    assert has_element?(view, ~s|[data-role="records-line"] time.font-mono|)

    stages =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s|[data-role="production-rail"] [data-role="rail-stage"]|)
      |> Enum.flat_map(&LazyHTML.attribute(&1, "data-stage"))

    assert stages == ~w(pitch research run_sheet logistics record post retro)

    assert has_element?(
             view,
             ~s|[data-role="rail-stage"][data-current="true"][data-stage="run_sheet"]|
           )

    assert has_element?(view, ~s|[data-role="needs-you-count"]|, "Needs you (1)")
    assert has_element?(view, ~s|[data-role="needs-you-option"]|, "Pick the town")
    assert has_element?(view, ~s|[data-role="segment-name"]|, "Cold open")
    assert has_element?(view, ~s|[data-role="segment-callback"]|, "↩ callback Ep 9")
    assert has_element?(view, ~s|[data-role="stat-card"] [data-role="stat-source"]|)
    assert has_element?(view, ~s|button[data-role="show-mode-toggle"]|, "Show mode")
    assert has_element?(view, ~s|[data-role="show-timer"][phx-update="ignore"]|)
    assert has_element?(view, "details summary", "Research brief")
  end

  test "an emptied Needs you collapses to the plain empty copy", %{
    conn: conn,
    space: space,
    user: user
  } do
    {:ok, document} =
      Platform.Chat.CanvasPatch.apply(
        Templates.get("episode_board").document,
        {:set_props, "needs_you", %{"items" => []}}
      )

    canvas = board!(space, user, document)

    {:ok, view, _html} = live(conn, ~p"/canvases/#{canvas.id}")

    assert has_element?(view, ~s|[data-role="needs-you-empty"]|, "Nothing needs you this week.")
    refute has_element?(view, ~s|[data-role="needs-you-count"]|)
  end
end
