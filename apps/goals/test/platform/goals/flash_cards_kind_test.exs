defmodule Platform.Goals.FlashCardsKindTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.GoalsFixtures
  import Platform.Goals.BriefFixtures
  alias Platform.Goals
  alias Platform.Goals.CanvasKinds.FlashCards

  defmodule KindHost do
    use PlatformWeb, :live_view
    alias Platform.Goals.CanvasKinds.FlashCards

    def mount(_params, session, socket) do
      viewer =
        case session["viewer_shape"] do
          "tuple" -> {:user, session["viewer_id"]}
          "map" -> %{id: session["viewer_id"]}
          _ -> Platform.Accounts.get_user(session["viewer_id"])
        end

      node = %{"kind" => "flash_cards", "props" => %{"ask_id" => session["ask_id"]}}
      {:ok, assign(socket, viewer: viewer, node: node)}
    end

    def render(assigns) do
      ~H"""
      <main data-role="flash-kind-host">
        <FlashCards.render node={@node} viewer={@viewer} dom_id_scope="kind-test" />
      </main>
      """
    end
  end

  setup do: setup_brief()

  test "the enabled extension registers the kind and the disabled extension contributes none" do
    assert Platform.Chat.Canvas.Kinds.get("flash_cards") == FlashCards
    assert Goals.Extension.canvas_kinds() == [FlashCards]
    assert Platform.Extensions.validate() == :ok
    refute FlashCards.inline_opens_canvas?()

    Application.put_env(:goals, :enabled, false)
    assert Goals.Extension.canvas_kinds() == []
    assert Platform.Chat.Canvas.Kinds.get("flash_cards") == nil
    assert Platform.Extensions.validate() == :ok
  end

  test "props carry only a UUID ask id, never deck content" do
    id = Ecto.UUID.generate()
    assert FlashCards.validate_props(%{"ask_id" => id}) == :ok

    for props <- [
          %{},
          %{"ask_id" => "not-a-uuid"},
          %{"ask_id" => nil},
          %{"ask_id" => 123},
          %{"ask_id" => id, "front" => "A secret front"},
          %{
            "ask_id" => id,
            "cards" => [%{"front" => "A secret front", "back" => "A secret back"}]
          },
          %{ask_id: id}
        ] do
      assert {:error, _} = FlashCards.validate_props(props)
    end
  end

  test "the kind loads cards for its addressee but hides them from an unaddressed owner and nil viewer",
       %{conn: conn} = c do
    addressee = member!(c.org)
    space = space!(c.org)

    for user <- [c.owner, addressee] do
      {:ok, _} =
        Platform.Access.Grants.grant(%{
          principal: user,
          permission: "goals.use",
          resource: {:space, space.id}
        })
    end

    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, addressee.id})

    cards = [
      %{"front" => "Private front one", "back" => "Private back one"},
      %{"front" => "Private front two", "back" => "Private back two"}
    ]

    ask =
      queued(c, %{
        kind: "practice",
        payload: %{"cards" => cards},
        addressed_user_ids: [addressee.id]
      })

    # The owner can read the ask through the context, but is not its addressee.
    assert {:ok, %{id: id}} = Goals.get_ask(c.owner, ask.id)
    assert id == ask.id

    for shape <- ["user", "tuple"] do
      {:ok, addressed, addressed_html} =
        live_isolated(conn, KindHost,
          session: %{"ask_id" => ask.id, "viewer_id" => addressee.id, "viewer_shape" => shape}
        )

      assert addressed_html =~ "Private front one"
      assert render(addressed) =~ "Turn it over"
    end

    for {viewer_id, shape} <- [
          {c.owner.id, "user"},
          {c.owner.id, "tuple"},
          {nil, "user"},
          {Ecto.UUID.generate(), "tuple"},
          {addressee.id, "map"}
        ] do
      {:ok, view, html} =
        live_isolated(conn, KindHost,
          session: %{"ask_id" => ask.id, "viewer_id" => viewer_id, "viewer_shape" => shape}
        )

      for card <- cards, text <- Map.values(card) do
        refute html =~ text
        refute render(view) =~ text
      end

      refute has_element?(view, "[aria-label='Turn the card over']")
    end
  end

  test "one source file implements the deck and a planted second implementation is detected" do
    root = Path.expand("../../../lib", __DIR__)

    sources =
      for path <- Path.wildcard(Path.join(root, "**/*")),
          File.regular?(path),
          do: {path, File.read!(path)}

    assert [_one_deck] = deck_sources(sources)

    assert deck_sources([
             {"first.ex", "Turn it over"},
             {"second.ex", "Turn it over"},
             {"other.ex", "No deck here"}
           ]) == ["first.ex", "second.ex"]

    assert deck_sources([{"one.ex", "Turn it over / Turn it over"}]) == ["one.ex"]
  end

  defp deck_sources(sources) do
    for {path, text} <- sources, String.contains?(text, "Turn it over"), do: path
  end
end
