defmodule PlatformWeb.ControlCenter.CharacterBuilderTest do
  @moduledoc """
  Task 01a1b6ad stage 2: the character builder on /control.

  Selectors are the stage's INVENTORY (the comp's createAgent markup). One
  render serves both layouts and app.css splits them at 768px, so each step
  asserts both the phone-only `.ba-mini` and the desktop-only `.ba-bside`,
  and the last describe pins the media rules that hide one or the other.
  The pixel diff against the comp lives outside the repo.

  Every count is taken before and after, so rows another test or the
  install made cannot satisfy an assertion.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  import Platform.AsyncAssertions

  alias Platform.AgentHost.{FakeHost, Reconciler}

  alias Platform.Agents.{
    Agent,
    Archetypes,
    Burrow,
    Character,
    ColorPalette,
    NativeAgents,
    WorkspaceFile
  }

  alias Platform.Chat.Space
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Repo
  alias PlatformWeb.ControlCenter.CharacterBuilder

  @app_css Path.expand("../../../../assets/css/app.css", __DIR__)
  @steps CharacterBuilder.step_ids()

  setup %{conn: conn} do
    admin = Platform.TenancyFixtures.root_admin!()
    %{conn: init_test_session(conn, current_user_id: admin.id), admin: admin}
  end

  defp counts do
    %{
      agents: Repo.aggregate(Agent, :count),
      files: Repo.aggregate(WorkspaceFile, :count),
      dms: Repo.aggregate(from(s in Space, where: s.kind == "dm"), :count)
    }
  end

  defp open(conn, step \\ nil, cls \\ nil) do
    q = [create: "1"] ++ if(step, do: [step: step], else: []) ++ if(cls, do: [cls: cls], else: [])
    {:ok, view, _html} = live(conn, "/control?" <> URI.encode_query(q))
    view
  end

  defp count(view, selector) do
    view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.count()
  end

  defp attr(view, selector, name) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
  end

  defp text(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
  end

  defp click(view, selector), do: view |> element(selector) |> render_click()
  defp next(view), do: click(view, "#ba-next")
  defp back(view), do: click(view, "#ba-back")
  defp step(view), do: view |> attr("#character-builder", "data-step") |> List.first()

  defp go_to(view, id) do
    target = Enum.find_index(@steps, &(&1 == id))
    current = Enum.find_index(@steps, &(&1 == step(view)))

    cond do
      current < target -> Enum.each(current..(target - 1), fn _ -> next(view) end)
      current > target -> Enum.each(target..(current - 1), fn _ -> back(view) end)
      true -> :ok
    end

    assert step(view) == id
    view
  end

  defp pick_color(view, color),
    do: view |> form("#ba-color-form") |> render_change(%{"color" => color})

  defp type_name(view, name),
    do: view |> form("#ba-name-form") |> render_change(%{"n" => name})

  defp mini_portrait(view), do: view |> attr("#ba-mini [data-portrait]", "data-portrait")
  defp slot(view), do: view |> attr("#character-builder .ba-modal", "data-agent-slot")

  # ── Inventory, every step, both layouts ───────────────────────────

  describe "inventory" do
    test "the shell on every step: ftop, eight dots, mini and bside except on reveal", %{
      conn: conn
    } do
      for {id, i} <- Enum.with_index(@steps) do
        view = open(conn, id)
        last? = id == "reveal"

        assert has_element?(view, "#character-builder.ba-flow .ba-modal[role=dialog]")
        assert has_element?(view, ".ba-ftop")
        assert count(view, ".ba-dots i") == 8
        assert count(view, ".ba-dots i.on") == 1
        assert count(view, ".ba-dots i.done") == i
        assert attr(view, ".ba-dots", "aria-label") == ["Step #{i + 1} of 8"]

        if i == 0 do
          assert has_element?(view, ".ba-ftop .tbtn.muted#ba-cancel", "Cancel")
          refute has_element?(view, "#ba-back")
        else
          assert has_element?(view, ".ba-ftop .tbtn#ba-back", "‹ Back")
          refute has_element?(view, "#ba-cancel")
        end

        assert has_element?(view, "#ba-skip", "Skip") == not last?
        assert has_element?(view, ".ba-mini#ba-mini") == not last?
        assert has_element?(view, ".ba-bside #ba-live .ba-card") == not last?

        if last? do
          assert has_element?(view, ".ba-ffoot .ba-btn.ag.full#ba-life", "Bring Forge to life")
          assert has_element?(view, ".ba-ffoot .ba-link#ba-restart", "Change something")
        else
          label = if id == "ai", do: "Reveal", else: "Next"
          assert has_element?(view, ".ba-ffoot .ba-btn.ag.full#ba-next", label)
          assert has_element?(view, ".ba-bside small", "live preview")
          assert text(view, "#ba-mini span") =~ "Builder · Orange"
        end
      end
    end

    test "class: six classes, the default pressed, verbatim copy, Advanced", %{conn: conn} do
      view = open(conn, "class")
      assert has_element?(view, ".ba-h1", "Pick a class")

      assert has_element?(
               view,
               ".ba-sub",
               "Sets its starting toolkit and a vibe. You can change anything later."
             )

      assert count(view, ".ba-classes .ba-class") == 6

      for a <- Archetypes.all() do
        assert has_element?(view, ~s{.ba-class[data-cls="#{a.id}"][data-agent-slot="#{a.color}"]})
        assert has_element?(view, ~s{.ba-class[data-cls="#{a.id}"] b}, a.n)
        assert has_element?(view, ~s{.ba-class[data-cls="#{a.id}"] span}, a.vibe)
      end

      assert attr(view, ~s{.ba-class[aria-pressed="true"]}, "data-cls") == ["builder"]
      assert has_element?(view, "#ba-advanced", "Advanced")
    end

    test "name: big input, dice, five more names, the handle line", %{conn: conn} do
      view = open(conn, "name")
      assert has_element?(view, ".ba-h1", "What do you call it?")
      assert has_element?(view, ".ba-sub", "Roll for a builder name, or type your own.")
      assert has_element?(view, ~s{.ba-bigname input#ba-agname[maxlength="24"][value="Forge"]})
      assert has_element?(view, ".ba-bigname .ba-dice[aria-label='Shuffle name']")
      assert has_element?(view, ".ba-lbl", "More builder names")
      assert count(view, ".ba-chips .ba-chip[data-nm]") == 5
      refute has_element?(view, ~s{.ba-chip[data-nm="Forge"]})
      assert has_element?(view, ".ba-sub", "You'll call it in chat as")
      assert has_element?(view, ".ba-sub b", "@Forge")
    end

    test "colour: the ten palette slots as radios, the class colour checked", %{conn: conn} do
      view = open(conn, "color")
      assert has_element?(view, ".ba-h1", "Pick its colour")

      assert has_element?(
               view,
               ".ba-sub",
               "Its name, AI pill, avatar ring and message rail all wear it."
             )

      assert count(view, ".ba-swatches label") == 10

      for c <- ColorPalette.all() do
        assert has_element?(view, ~s{.ba-swatches label[data-agent-slot="#{c.id}"]}, c.label)
        assert has_element?(view, ~s{.ba-swatches label[data-agent-slot="#{c.id}"] i})
        assert has_element?(view, ~s{.ba-swatches label[data-agent-slot="#{c.id}"] em})
      end

      assert attr(view, ".ba-swatches input[checked]", "value") == ["orange"]
      assert has_element?(view, ".ba-sub", "Ten slots, same as the platform's agent palette.")
    end

    test "colour: the small label names the first agent wearing a slot", %{conn: conn} do
      %Agent{}
      |> Agent.changeset(%{slug: "wears-teal", name: "Wears Teal", status: "active"})
      |> Ecto.Changeset.put_change(:color, "teal")
      |> Repo.insert!()

      view = open(conn, "color")
      assert has_element?(view, ~s{.ba-swatches label[data-agent-slot="teal"] em}, "Wears Teal")
      assert text(view, ~s{.ba-swatches label[data-agent-slot="lime"] em}) == ""
    end

    test "portrait: eight faces and the upload slot", %{conn: conn} do
      view = open(conn, "portrait")
      assert has_element?(view, ".ba-h1", "Give it a face")
      assert has_element?(view, ".ba-sub", "Generated in orange. Or bring your own.")
      assert count(view, ".ba-pors button[data-por]") == 8

      for p <- Archetypes.portraits() do
        assert has_element?(view, ~s{.ba-pors button[data-por="#{p}"] svg})
      end

      assert attr(view, ~s{.ba-pors button[aria-pressed="true"]}, "data-por") == ["visor"]
      assert has_element?(view, ".ba-pors label.up#ba-upload", "Upload")
      assert has_element?(view, ".ba-pors label.up input[type=file]")
    end

    test "personality: four dials, fourteen traits, three pressed, the first line", %{conn: conn} do
      view = open(conn, "personality")
      assert has_element?(view, ".ba-h1", "Personality")
      assert has_element?(view, ".ba-sub", "Four dials and three traits. That's it.")
      assert count(view, ".ba-slider input[type=range]") == 4
      assert count(view, ".ba-slider .ends span.lean") == 4
      assert has_element?(view, ".ba-lbl", "Three traits")
      assert has_element?(view, ".ba-lbl span", "· 3/3")
      assert count(view, ".ba-chips .ba-chip[data-tr]") == 14
      assert count(view, ~s{.ba-chip[data-tr][aria-pressed="true"]}) == 3
      assert has_element?(view, ".ba-says#ba-says small", "FIRST THING IT SAYS")
      assert has_element?(view, ".ba-says", "Point me at the branch.")
    end

    test "voice: dial, stops, fine-tune, try it, what it gets", %{conn: conn} do
      view = open(conn, "voice")
      assert has_element?(view, ".ba-h1", "How does Forge talk?")

      assert has_element?(
               view,
               ".ba-sub",
               "From a quick text to a full formal brief. Slide it, then try it on below."
             )

      assert has_element?(view, ".ba-vdial .ba-vnow b", "Casual")
      assert has_element?(view, ~s{.ba-vdial input.ba-vrange[type=range][min="0"][max="4"]})
      assert count(view, ".ba-vstops button") == 5
      assert attr(view, ~s{.ba-vstops button[aria-pressed="true"]}, "data-vp") == ["1"]
      assert has_element?(view, ".ba-vft summary", "Fine-tune")
      assert has_element?(view, ".ba-vft .ba-vtw", "· Casual defaults")
      assert count(view, ".ba-vft .r") == 4
      assert has_element?(view, ".ba-vft .ba-link", "Reset to preset")
      assert has_element?(view, ".ba-vtry .hd b", "Try it")
      assert has_element?(view, ".ba-vtry .hd span", "tap a prompt or type your own")
      assert count(view, ".ba-vtry .ba-chip[data-vq]") == 4
      assert has_element?(view, ~s{.ba-vtry input.ba-vin[placeholder="Ask Forge anything…"]})
      assert has_element?(view, ".ba-vread summary", "What Forge gets")

      expected = Enum.join(Character.v_prompt_lines(Character.v_new(1)), "\n")
      assert text(view, ".ba-vread pre") == expected
    end

    test "reveal: the card, what it writes, confetti, no mini or bside", %{conn: conn} do
      view = open(conn, "reveal")
      assert has_element?(view, ".ba-revwrap .ba-card.reveal[data-agent-slot=orange]")
      assert has_element?(view, ".ba-card .ctop b", "Forge")
      assert has_element?(view, ".ba-card .ft", "Burrow")
      refute text(view, ".ba-card .ft") =~ "·"
      assert has_element?(view, ".ba-writes", "Creates")
      assert has_element?(view, ".ba-writes code", "IDENTITY.md")
      assert has_element?(view, ".ba-writes code", "orange")
      assert has_element?(view, ".ba-writes code", "casual")
      assert has_element?(view, ".ba-writes b", "works with you")
      assert has_element?(view, ".ba-confetti[aria-hidden=true]")
      assert count(view, ".ba-confetti i") == 26
    end

    test "the card's № is the agent count plus one", %{conn: conn} do
      before = Repo.aggregate(Agent, :count)
      view = open(conn, "reveal")
      n = before + 1
      assert has_element?(view, ".ba-card .ft", "№ " <> String.pad_leading("#{n}", 3, "0"))
    end
  end

  # ── Behaviour ─────────────────────────────────────────────────────

  describe "state" do
    test "the Add button opens the builder at the class step", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/control")
      refute has_element?(view, "#character-builder")
      click(view, "#add-agent-btn-sidebar")
      assert step(view) == "class"
    end

    test "deep link cls= applies the class", %{conn: conn} do
      view = open(conn, "color", "scout")
      assert attr(view, ".ba-swatches input[checked]", "value") == ["teal"]
      assert text(view, "#ba-mini span") =~ "Scout · Teal"
    end

    test "back and forth keeps every choice", %{conn: conn} do
      view = open(conn)
      click(view, ~s{.ba-class[data-cls="scout"]})
      go_to(view, "name")
      type_name(view, "Margo")
      go_to(view, "color")
      pick_color(view, "rose")
      go_to(view, "voice")
      click(view, ~s{.ba-vstops button[data-vp="4"]})
      go_to(view, "class")
      assert attr(view, ~s{.ba-class[aria-pressed="true"]}, "data-cls") == ["scout"]

      go_to(view, "name")
      assert attr(view, "#ba-agname", "value") == ["Margo"]
      go_to(view, "color")
      assert attr(view, ".ba-swatches input[checked]", "value") == ["rose"]
      go_to(view, "voice")
      assert attr(view, ~s{.ba-vstops button[aria-pressed="true"]}, "data-vp") == ["4"]
      go_to(view, "reveal")
      assert has_element?(view, ".ba-card .ctop b", "Margo")
      assert has_element?(view, ".ba-writes code", "exhaustive")
    end

    test "a class change keeps touched fields and resets the rest", %{conn: conn} do
      view = open(conn)
      click(view, ~s{.ba-class[data-cls="scout"]})
      go_to(view, "color")
      pick_color(view, "rose")
      go_to(view, "class")
      click(view, ~s{.ba-class[data-cls="scribe"]})

      scribe = Archetypes.get("scribe")
      assert slot(view) == ["rose"]
      assert mini_portrait(view) == [scribe.portrait]
      assert text(view, "#ba-mini .tr") =~ Enum.join(scribe.traits, "")

      go_to(view, "personality")

      for s <- Archetypes.sliders() do
        assert attr(view, ~s{input[data-sl="#{s.k}"]}, "value") == ["#{scribe.sl[s.k]}"]
      end
    end

    test "a touched dial survives a class change", %{conn: conn} do
      view = open(conn, "personality")
      view |> form("#ba-dials-form") |> render_change(%{"sl" => %{"bold" => "9"}})
      go_to(view, "class")
      click(view, ~s{.ba-class[data-cls="producer"]})
      go_to(view, "personality")
      assert attr(view, ~s{input[data-sl="bold"]}, "value") == ["9"]
    end

    test "dials move the lean and the first line; a fourth trait drops the first", %{
      conn: conn
    } do
      view = open(conn, "personality")

      view
      |> form("#ba-dials-form")
      |> render_change(%{"sl" => %{"chatty" => "90", "playful" => "10"}})

      assert has_element?(view, ".ba-slider .ends span.lean", "Chatty")
      assert has_element?(view, ".ba-slider .ends span.lean", "Formal")
      assert text(view, "#ba-says") =~ "Good morning"
      assert text(view, "#ba-says") =~ "Happy to walk through it whenever."

      click(view, ~s{.ba-chip[data-tr="skeptic"]})

      assert attr(view, ~s{.ba-chip[aria-pressed="true"]}, "data-tr") |> Enum.sort() ==
               Enum.sort(["tests first", "owns the fix", "skeptic"])
    end

    test "roll and a name chip change the name", %{conn: conn} do
      view = open(conn, "name")
      click(view, "#ba-dice")
      [rolled] = attr(view, "#ba-agname", "value")
      assert rolled != "Forge"
      assert rolled in Archetypes.get("builder").names
      click(view, ~s{.ba-chip[data-nm="Anvil"]})
      assert attr(view, "#ba-agname", "value") == ["Anvil"]
      assert has_element?(view, ".ba-sub b", "@Anvil")
    end

    test "voice knobs, reset and a typed prompt", %{conn: conn} do
      view = open(conn, "voice")
      click(view, ~s{.ba-vft button[data-vk="emoji"][data-vv="0"]})
      assert has_element?(view, ".ba-vft .ba-vtw", "· 1 tweak")
      assert text(view, ".ba-vread pre") =~ "No emoji."
      click(view, ".ba-vft [data-vreset]")
      assert has_element?(view, ".ba-vft .ba-vtw", "· Casual defaults")
      # Picking the preset's own value is not a tweak (the comp's vc.ov rule).
      click(view, ~s{.ba-vft button[data-vk="emoji"][data-vv="0"]})
      click(view, ~s{.ba-vft button[data-vk="emoji"][data-vv="1"]})
      assert has_element?(view, ".ba-vft .ba-vtw", "· Casual defaults")

      view |> form("#ba-vfree-form") |> render_submit(%{"q" => "Plan the offsite"})
      assert has_element?(view, ".ba-vb.me", "Plan the offsite")
      assert has_element?(view, ".ba-vb.ag .ba-typing")
    end
  end

  # ── Persistence ───────────────────────────────────────────────────

  describe "nothing persists until Bring to life" do
    for {id, i} <- Enum.with_index(CharacterBuilder.step_ids()),
        how <- [:cancel_or_back, :escape, :scrim, :navigate] do
      test "abandoning at #{id} by #{how} writes nothing", %{conn: conn} do
        before = counts()
        view = open(conn)
        click(view, ~s{.ba-class[data-cls="scout"]})
        Enum.each(1..unquote(i)//1, fn _ -> next(view) end)
        assert step(view) == unquote(id)

        case unquote(how) do
          :cancel_or_back ->
            Enum.each(1..unquote(i)//1, fn _ -> back(view) end)
            click(view, "#ba-cancel")
            refute has_element?(view, "#character-builder")

          :escape ->
            view |> element("#character-builder") |> render_keydown(%{"key" => "Escape"})
            refute has_element?(view, "#character-builder")

          :scrim ->
            view |> with_target("#character-builder") |> render_click("close", %{})
            refute has_element?(view, "#character-builder")

          :navigate ->
            # A live navigation replaces the LiveView; the builder's state goes with it.
            {:ok, fresh, _html} = live_redirect(view, to: ~p"/control")
            refute has_element?(fresh, "#character-builder")
        end

        assert counts() == before
      end
    end

    test "closing a builder the URL opened drops the query", %{conn: conn} do
      view = open(conn, "name")
      click(view, "#ba-back")
      click(view, "#ba-cancel")
      assert_patch(view, ~p"/control")
    end

    test "Bring to life writes the agent, its three files and the DM, then opens it", %{
      conn: conn
    } do
      before = counts()
      view = open(conn)
      click(view, ~s{.ba-class[data-cls="scout"]})
      go_to(view, "name")
      type_name(view, "Lark")
      go_to(view, "color")
      pick_color(view, "indigo")
      go_to(view, "portrait")
      click(view, ~s{.ba-pors button[data-por="fox"]})
      go_to(view, "personality")

      view
      |> form("#ba-dials-form")
      |> render_change(%{
        "sl" => %{"chatty" => "20", "bold" => "80", "playful" => "10", "collab" => "90"}
      })

      go_to(view, "voice")
      click(view, ~s{.ba-vstops button[data-vp="3"]})
      click(view, ~s{.ba-vft button[data-vk="emoji"][data-vv="1"]})
      go_to(view, "reveal")
      assert counts() == before

      click(view, "#ba-life")

      agent = Repo.get_by!(Agent, name: "Lark")
      assert_patch(view, ~p"/control/#{agent.slug}")
      refute has_element?(view, "#character-builder")

      assert counts() == %{
               agents: before.agents + 1,
               files: before.files + 3,
               dms: before.dms + 1
             }

      assert agent.color == "indigo"
      c = agent.metadata["character"]
      assert c["archetype"] == "scout"
      assert c["portrait"] == "fox"
      assert c["sliders"] == %{"chatty" => 20, "bold" => 80, "playful" => 10, "collab" => 90}
      assert c["voice"]["preset"] == "professional"
      assert c["voice"]["overrides"] == %{"emoji" => 1}
    end
  end

  # ── Permission (task 01a1ae4b's rule) ─────────────────────────────

  describe "a member who may not create an ownerless agent" do
    setup %{conn: conn} do
      user = World.create_user!()

      World.plain_member!(
        user,
        Repo.get!(Platform.Tenancy.Org, Platform.TenancyFixtures.acme_org_id())
      )

      %{member_conn: init_test_session(conn, current_user_id: user.id)}
    end

    test "sees Bring to life disabled with the reason, and a forged life writes nothing", %{
      member_conn: conn
    } do
      before = counts()
      view = open(conn, "reveal")
      assert has_element?(view, ~s{#ba-life[aria-disabled="true"]})
      refute has_element?(view, "#ba-life[phx-click]")
      assert has_element?(view, "#ba-life-locked", CharacterBuilder.locked_line())

      view |> with_target("#character-builder") |> render_click("life", %{})
      assert counts() == before
    end
  end

  # ── Advanced: the old flows, unchanged ────────────────────────────

  describe "Advanced" do
    for {card, heading} <- [
          {"federate", "Federate an Agent"},
          {"import", "Import from Workspace"},
          {"external", "External Agent"},
          {"create", "Create Custom Agent"}
        ] do
      test "opens #{card} with its existing heading", %{conn: conn} do
        {:ok, view, _html} = live(conn, ~p"/control")
        click(view, "#add-agent-btn-sidebar")
        click(view, "#ba-advanced")
        refute has_element?(view, "#character-builder")
        refute render(view) =~ "From a Template"
        click(view, "#choose-#{unquote(card)}")
        assert has_element?(view, "h2", unquote(heading))
      end
    end

    test "Run on this server is offered only with an agent host", %{conn: conn} do
      previous = Application.get_env(:platform, :agent_host_token)
      Application.put_env(:platform, :agent_host_token, "agent-host-token-01a1b6ad-s2")

      on_exit(fn ->
        if previous,
          do: Application.put_env(:platform, :agent_host_token, previous),
          else: Application.delete_env(:platform, :agent_host_token)
      end)

      {:ok, view, _html} = live(conn, ~p"/control")
      click(view, "#add-agent-btn-sidebar")
      click(view, "#ba-advanced")
      refute has_element?(view, "#choose-native")

      :ok = Reconciler.host_joined(self(), %{"profile" => "contained"})
      {:ok, view, _html} = live(conn, ~p"/control")
      click(view, "#add-agent-btn-sidebar")
      click(view, "#ba-advanced")
      assert has_element?(view, "#choose-native", "Run on this server")
      click(view, "#choose-native")
      assert has_element?(view, "h2", "Run on this server")
    end

    test "Create Custom still creates the agent", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/control")
      click(view, "#add-agent-btn-sidebar")
      click(view, "#ba-advanced")
      click(view, "#choose-create")

      view
      |> form("#create-agent-form", create_agent: %{name: "Manual One", slug: "manual-one"})
      |> render_submit()

      assert Repo.get_by(Agent, name: "Manual One")
    end
  end

  # ── The swatch fix (task 01a1b34f) and the layout split ───────────

  describe "guards" do
    test "every visually-hidden input in the builder sits in a positioned label", %{conn: conn} do
      for {id, form} <- [{"color", "#ba-color-form"}, {"portrait", "#ba-upload-form"}] do
        view = open(conn, id)
        doc = view |> render() |> LazyHTML.from_document()
        all = doc |> LazyHTML.query("#{form} input.sr-only") |> Enum.count()
        positioned = doc |> LazyHTML.query("#{form} label.relative input.sr-only") |> Enum.count()
        assert all > 0
        assert positioned == all
      end
    end

    test "app.css positions the swatch label and splits the layouts at 768px" do
      css = File.read!(@app_css)
      assert css =~ ~r/\.ba-swatches label\{position:relative;/
      [_, phone] = Regex.run(~r/@media \(max-width: 767\.98px\)\{(.*?)\n\}/s, css)
      [_, desk] = Regex.run(~r/@media \(min-width: 768px\)\{(.*?)\n\}/s, css)
      assert phone =~ ".ba-bside{display:none}"
      assert desk =~ ".ba-mini{display:none}"
      assert desk =~ ".ba-flow .ba-modal{width:min(980px,94vw);height:min(660px,92vh)"
      assert desk =~ ".ba-flow .ba-classes{grid-template-columns:1fr 1fr 1fr}"
    end

    test "a colour pick changes only the builder's state", %{conn: conn} do
      view = open(conn, "color")
      pick_color(view, "indigo")
      assert slot(view) == ["indigo"]
      assert attr(view, ".ba-swatches input[checked]", "value") == ["indigo"]
      pick_color(view, "not-a-slot")
      assert slot(view) == ["indigo"]
    end
  end

  # ── Step 7: Which AI should it use (task 01a1b84b stage 2) ────────

  describe "step 7: which AI" do
    setup do
      previous = Application.get_env(:platform, PlatformWeb.ConnectAiLive)

      Application.put_env(
        :platform,
        PlatformWeb.ConnectAiLive,
        Keyword.put(previous || [], :claude_login_timeout_ms, 500)
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:platform, PlatformWeb.ConnectAiLive, previous),
          else: Application.delete_env(:platform, PlatformWeb.ConnectAiLive)
      end)

      fake = start_supervised!({FakeHost, report_after_ms: 0})
      assert_eventually(fn -> Reconciler.host_pid() == fake end, 3_000)
      %{fake: fake}
    end

    defp pick_ai(view, provider), do: click(view, ~s{#ba-ai-#{provider}})

    # The step's own markup (the page around it has warning tokens of its own).
    defp step_html(view) do
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#ba-step-ai")
      |> LazyHTML.to_html()
    end

    defp new_agent(before), do: Repo.one!(from(a in Agent, where: a.id not in ^before))
    defp agent_ids, do: Repo.all(from(a in Agent, select: a.id))

    test "inventory: dot 7 of 8, title, subhead, two tiles in provider order, skip line, Reveal enabled",
         %{conn: conn} do
      view = open(conn, "ai")
      assert step(view) == "ai"
      assert count(view, ".ba-dots i") == 8
      assert attr(view, ".ba-dots", "aria-label") == ["Step 7 of 8"]
      assert has_element?(view, ~s{.ba-dots i.on[title="AI"]})
      assert has_element?(view, "#ba-step-ai .ba-h1", "Which AI should Forge use?")

      assert has_element?(
               view,
               "#ba-step-ai .ba-sub",
               "Sign in with a plan you already pay for. No API key."
             )

      order = Enum.map(PlatformWeb.ConnectAiLive.choices(), &Atom.to_string/1)
      assert attr(view, "#ba-ai .ba-ai-tiles .ba-class", "data-provider") == order
      assert order == ["codex", "claude_subscription"]
      assert has_element?(view, ~s{#ba-ai-claude_subscription[aria-pressed="false"] b}, "Claude")
      assert has_element?(view, "#ba-ai-claude_subscription span", "Pro or Max plan")
      assert has_element?(view, ~s{#ba-ai-codex[aria-pressed="false"] b}, "ChatGPT")
      assert has_element?(view, "#ba-ai-codex span", "Your ChatGPT plan")
      assert count(view, "#ba-ai img, #ba-ai svg") == 0

      assert has_element?(
               view,
               "#ba-ai-later.ba-link",
               "Not now? Connect from Forge's page later."
             )

      assert has_element?(view, "#ba-skip", "Skip")
      assert has_element?(view, ".ba-ffoot #ba-next.ba-btn.ag.full", "Reveal")
      refute has_element?(view, "#ba-next[disabled]")
      refute has_element?(view, "#ba-ai-panel")
      refute has_element?(view, ".ba-card .vc[data-runs-on]")
      refute has_element?(view, "#ba-mini-runs-on")
      # The retired title appears nowhere, not even as a literal here.
      refute render(view) =~ Enum.join(["Connect", "a", "brain"], " ")
      refute step_html(view) =~ "warning"
    end

    test "Skip creates nothing; Bring to life then makes a built_in agent with no connection", %{
      conn: conn
    } do
      before = counts()
      ids = agent_ids()
      view = open(conn, "ai")
      click(view, "#ba-skip")
      assert step(view) == "reveal"
      assert counts() == before
      refute has_element?(view, ".ba-card.reveal .vc[data-runs-on]")

      click(view, "#ba-life")
      assert counts().agents == before.agents + 1
      agent = new_agent(ids)
      assert agent.runtime_type == "built_in"
      refute NativeAgents.managed?(agent)
      assert NativeAgents.ai_login(agent) == nil
      assert_patch(view, ~p"/control/#{agent.slug}")
    end

    test "the skip line is a skip too", %{conn: conn} do
      before = counts()
      view = open(conn, "ai")
      click(view, "#ba-ai-later")
      assert step(view) == "reveal"
      assert counts() == before
    end

    test "picking Claude creates one agent and adopts it; the good code connects it and the card says Runs on; Bring to life updates, no duplicate",
         %{conn: conn, admin: admin} do
      before = counts()
      ids = agent_ids()
      view = open(conn)
      click(view, ~s{.ba-class[data-cls="scout"]})
      go_to(view, "name")
      type_name(view, "Lark")
      go_to(view, "ai")

      pick_ai(view, "claude_subscription")
      assert counts().agents == before.agents + 1
      agent = new_agent(ids)
      assert agent.name == "Lark"
      assert has_element?(view, ~s{#ba-ai-claude_subscription[aria-pressed="true"]})

      assert has_element?(
               view,
               ~s{#ba-ai-panel[data-agent-id="#{agent.id}"][data-connected="false"]}
             )

      assert_eventually(fn -> has_element?(view, "a#ba-ai-claude-open") end, 3_000)
      runtime = NativeAgents.get_managed_runtime(Repo.reload!(agent))
      assert runtime.harness == "claude_code"
      assert runtime.managed_by == "install"
      assert runtime.owner_user_id == admin.id
      assert has_element?(view, "#ba-ai-panel", "Sign in to Claude")
      assert has_element?(view, "#ba-ai-panel", "Paste the code Claude shows you")
      refute has_element?(view, ".ba-card .vc[data-runs-on]")

      view |> element("a#ba-ai-claude-open") |> render_click()
      assert has_element?(view, "#ba-ai-claude-waiting.text-info", "Waiting for the code")
      refute step_html(view) =~ "warning"
      assert has_element?(view, ".ba-ffoot #ba-next", "Reveal")
      refute has_element?(view, "#ba-next[disabled]")

      code = FakeHost.claude_login_code()
      view |> form("#ba-ai-claude-form", %{"code" => code}) |> render_submit()

      assert_eventually(
        fn -> has_element?(view, "#ba-ai-claude-connected", "Connected as owner@example.com") end,
        3_000
      )

      assert has_element?(view, "#ba-ai-claude-connected .text-success")
      refute render(view) =~ code

      # The Runs on row, in the preview the moment sign-in completes.
      assert_eventually(
        fn -> has_element?(view, ".ba-bside .ba-card .vc[data-runs-on] b", "Claude Max") end,
        3_000
      )

      assert has_element?(view, ".ba-bside .ba-card .vc[data-runs-on] span", "Runs on")
      assert has_element?(view, "#ba-mini-runs-on", "Runs on · Claude Max")

      assert NativeAgents.ai_login(Repo.reload!(agent)) ==
               %{"provider" => "claude", "account" => "owner@example.com", "plan" => "max"}

      # Still one agent; a later edit lands on it through Bring to life.
      assert counts().agents == before.agents + 1
      go_to(view, "color")
      pick_color(view, "indigo")
      go_to(view, "reveal")
      assert has_element?(view, ".ba-card.reveal .vc[data-runs-on] b", "Claude Max")
      assert has_element?(view, ".ba-confetti")

      click(view, "#ba-life")
      assert_patch(view, ~p"/control/#{agent.slug}")
      assert counts().agents == before.agents + 1
      assert Repo.aggregate(from(a in Agent, where: a.name == "Lark"), :count) == 1
      agent = Repo.reload!(agent)
      assert agent.color == "indigo"
      assert NativeAgents.get_managed_runtime(agent).harness == "claude_code"
    end

    test "a ChatGPT pick reaches connected through the fake device login", %{conn: conn} do
      before = counts()
      ids = agent_ids()
      view = open(conn, "ai")
      pick_ai(view, "codex")
      assert counts().agents == before.agents + 1
      agent = new_agent(ids)

      assert_eventually(
        fn -> has_element?(view, "#ba-ai-code", FakeHost.device_code()) end,
        3_000
      )

      assert has_element?(view, "#ba-ai-panel", "Sign in to ChatGPT")
      assert has_element?(view, "#ba-ai-panel", "Enter this code there:")
      assert NativeAgents.get_managed_runtime(Repo.reload!(agent)).harness == "codex"

      :ok = FakeHost.complete(agent.id)

      assert_eventually(
        fn -> has_element?(view, "#ba-ai-codex-connected", "Connected to ChatGPT") end,
        3_000
      )

      assert_eventually(
        fn -> has_element?(view, ".ba-bside .ba-card .vc[data-runs-on] b", "ChatGPT") end,
        3_000
      )

      assert has_element?(view, "#ba-mini-runs-on", "Runs on · ChatGPT")
      refute render(view) =~ "Disconnect"
      assert counts().agents == before.agents + 1
    end

    for how <- [:escape, :scrim, :cancel] do
      test "leaving by #{how} after the early create opens the agent's page, deletes nothing", %{
        conn: conn
      } do
        before = counts()
        ids = agent_ids()
        view = open(conn, "ai")
        pick_ai(view, "claude_subscription")
        agent = new_agent(ids)

        case unquote(how) do
          :escape ->
            view |> element("#character-builder") |> render_keydown(%{"key" => "Escape"})

          :scrim ->
            view |> with_target("#character-builder") |> render_click("close", %{})

          :cancel ->
            go_to(view, "class")
            click(view, "#ba-cancel")
        end

        assert_patch(view, ~p"/control/#{agent.slug}")
        refute has_element?(view, "#character-builder")
        assert counts().agents == before.agents + 1
        assert Repo.reload!(agent)
      end
    end

    test "a member who may not create sees the tiles disabled like Bring to life, and a forged pick writes nothing",
         %{conn: conn} do
      user = World.create_user!()

      World.plain_member!(
        user,
        Repo.get!(Platform.Tenancy.Org, Platform.TenancyFixtures.acme_org_id())
      )

      conn = init_test_session(conn, current_user_id: user.id)
      before = counts()
      view = open(conn, "ai")
      assert count(view, ~s{#ba-ai .ba-class[aria-disabled="true"][data-locked="true"]}) == 2
      refute has_element?(view, "#ba-ai .ba-class[phx-click]")
      assert has_element?(view, "#ba-ai-locked", CharacterBuilder.locked_line())

      view
      |> with_target("#character-builder")
      |> render_click("pick_ai", %{"provider" => "claude_subscription"})

      assert counts() == before
      refute has_element?(view, "#ba-ai-panel")
    end

    test "B3: with Burrow connected, the new agent's step shows not connected and inherits nothing",
         %{conn: conn, admin: admin} do
      {:ok, burrow} = Burrow.ensure(admin.id, "claude_code")

      :ok =
        Reconciler.agent_state(Reconciler.host_pid(), %{
          "agent_id" => burrow.id,
          "state" => "running"
        })

      assert_eventually(fn -> Burrow.connected?() end, 3_000)

      {:ok, _} =
        NativeAgents.put_ai_login(burrow, %{
          "provider" => "claude",
          "account" => "burrow@example.com",
          "plan" => "max"
        })

      ids = agent_ids()
      view = open(conn, "ai")
      refute has_element?(view, ".ba-card .vc[data-runs-on]")
      pick_ai(view, "claude_subscription")
      agent = new_agent(ids)
      assert_eventually(fn -> has_element?(view, "a#ba-ai-claude-open") end, 3_000)
      assert has_element?(view, ~s{#ba-ai-panel[data-connected="false"]})
      refute has_element?(view, "#ba-ai-connected")
      refute has_element?(view, ".ba-card .vc[data-runs-on]")
      refute render(view) =~ "burrow@example.com"
      refute render(view) =~ "Burrow's account"
      assert NativeAgents.ai_login(Repo.reload!(agent)) == nil
    end
  end
end
