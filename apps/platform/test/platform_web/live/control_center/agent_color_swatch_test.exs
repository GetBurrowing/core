defmodule PlatformWeb.ControlCenter.AgentColorSwatchTest do
  @moduledoc """
  Task 01a1b34f — clicking a Color family swatch on the agent detail page
  blanked the pane and the colour could not be saved.

  Not a server crash. The swatch radios are `sr-only peer`, and `sr-only` is
  `position: absolute`. Inside a `<label>` with no positioning, the radio's
  containing block is the app shell's `<main data-scroll-container>`, which is
  `overflow-hidden`. The radio's static position sits deep inside the inner
  control-center scroller, so it overflows that main; clicking the label
  focuses the radio and the browser scrolls the overflow-hidden main to
  reveal it. The whole pane slides out of view and cannot be scrolled back,
  so "Update identity" is unreachable.

  The fix is `relative` on the swatch label, which makes the label the
  radio's containing block. LiveViewTest cannot measure scrollTop, so the
  structural guard below is the honest LiveView-level reproduction: every
  visually-hidden radio in these forms must have a positioned label ancestor.
  It is RED on the unfixed markup.

  The server-path and toggle cases pin what was already true (the LiveView
  survives a colour change and persists it), so a later "fix" in server code
  cannot regress them. Every fixture starts at "teal" and picks "indigo", so a
  no-op save cannot pass.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Agents.Agent
  alias Platform.Agents.NativeAgents
  alias Platform.Repo

  @start_color "teal"
  @picked_color "indigo"

  setup %{conn: conn} do
    user = Platform.TenancyFixtures.root_admin!()
    %{conn: init_test_session(conn, current_user_id: user.id), user: user}
  end

  defp create_agent(attrs) do
    %Agent{}
    |> Agent.changeset(
      Map.merge(
        %{
          slug: "swatch-agent-#{System.unique_integer([:positive, :monotonic])}",
          name: "Swatch Agent",
          status: "active",
          color: @start_color
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp external_agent, do: create_agent(%{runtime_type: "external", name: "Swatch External"})

  defp built_in_agent, do: create_agent(%{runtime_type: "built_in", name: "Swatch Built In"})

  defp native_agent(user) do
    {:ok, agent, _runtime} =
      NativeAgents.create(user.id, %{
        name: "Swatch Native #{System.unique_integer([:positive])}",
        harness: "claude_code"
      })

    agent |> Ecto.Changeset.change(color: @start_color) |> Repo.update!()
  end

  # Every visually-hidden radio inside `form_selector` must sit inside a
  # positioned label. `LazyHTML.query/2` descends the whole tree; the check
  # walks each radio's label ancestor by querying radios scoped under
  # `label.relative` and comparing counts with all hidden radios.
  defp assert_hidden_radios_positioned(html, form_selector) do
    doc = LazyHTML.from_document(html)

    all = doc |> LazyHTML.query("#{form_selector} input.sr-only[type=radio]") |> Enum.count()

    positioned =
      doc
      |> LazyHTML.query("#{form_selector} label.relative input.sr-only[type=radio]")
      |> Enum.count()

    assert all > 0, "expected visually-hidden radios in #{form_selector}, found none"

    assert positioned == all,
           "#{all - positioned} of #{all} sr-only radios in #{form_selector} have no " <>
             "label.relative ancestor; their containing block becomes the shell's " <>
             "overflow-hidden <main>, which the browser scrolls on click"
  end

  defp checked_color(view, form_selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s{#{form_selector} input[name="config[color]"][checked]})
    |> LazyHTML.attribute("value")
  end

  describe "structural guard: hidden radios are positioned by their label" do
    test "external agent identity form", %{conn: conn} do
      agent = external_agent()
      {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")
      assert has_element?(view, "#federated-identity-form")
      assert_hidden_radios_positioned(render(view), "#federated-identity-form")
    end

    test "native agent identity form", %{conn: conn, user: user} do
      agent = native_agent(user)
      {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")
      assert has_element?(view, "#federated-identity-form")
      assert_hidden_radios_positioned(render(view), "#federated-identity-form")
    end

    test "built-in agent config form", %{conn: conn} do
      agent = built_in_agent()
      {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")
      assert has_element?(view, "#agent-config-form")
      assert_hidden_radios_positioned(render(view), "#agent-config-form")
    end

    test "onboarding create-agent form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/control")
      render_click(view, "choose_onboarding", %{"flow" => "create"})
      assert has_element?(view, "#create-agent-form")
      assert_hidden_radios_positioned(render(view), "#create-agent-form")
    end

    test "onboarding external-agent form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/control")
      render_click(view, "open_onboarding_chooser", %{})
      render_click(view, "choose_onboarding", %{"flow" => "external"})
      assert has_element?(view, "#external-agent-form")
      assert_hidden_radios_positioned(render(view), "#external-agent-form")
    end
  end

  describe "server path: a colour-only change and save" do
    for {label, form_id, kind} <- [
          {"external", "#federated-identity-form", :external},
          {"native", "#federated-identity-form", :native},
          {"built-in", "#agent-config-form", :built_in}
        ] do
      test "#{label}: change keeps the view alive, submit persists only the colour",
           %{conn: conn, user: user} do
        agent =
          case unquote(kind) do
            :external -> external_agent()
            :native -> native_agent(user)
            :built_in -> built_in_agent()
          end

        {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

        view
        |> element(unquote(form_id))
        |> render_change(%{"config" => %{"color" => @picked_color}})

        assert is_binary(render(view))
        assert checked_color(view, unquote(form_id)) == [@picked_color]

        view
        |> element(unquote(form_id))
        |> render_submit(%{"config" => %{"color" => @picked_color}})

        updated = Repo.get!(Agent, agent.id)
        assert updated.color == @picked_color
        assert updated.name == agent.name
      end
    end
  end

  describe "#103 regression: the accepts-chat toggle beside an unsaved colour" do
    test "toggle still flips accepts_chat and the unsaved colour survives", %{conn: conn} do
      agent = external_agent()
      assert agent.accepts_chat == true

      {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

      view
      |> element("#federated-identity-form")
      |> render_change(%{"config" => %{"color" => @picked_color}})

      view
      |> form("#agent-accepts-chat-form", agent_chat: %{accepts_chat: "false"})
      |> render_change()

      assert Repo.get!(Agent, agent.id).accepts_chat == false
      assert Repo.get!(Agent, agent.id).color == @start_color
      assert checked_color(view, "#federated-identity-form") == [@picked_color]
    end
  end
end
