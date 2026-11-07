defmodule PlatformWeb.ControlCenter.AgentPageTest do
  @moduledoc """
  Task 01a1b6ad stage 3: the living agent page at /control/:agent_slug.

  Selectors are the stage's INVENTORY (the comp's renderPage markup). Every
  write asserts the row or file it changes, and that a malformed event
  changes nothing. Counts are read before and after, so rows another test
  made cannot satisfy an assertion. The pixel diff lives outside the repo.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Agents.{Agent, Archetypes, Character, MemoryContext}
  alias Platform.Chat
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Repo
  alias PlatformWeb.ControlCenter.AgentPage

  @app_css Path.expand("../../../../assets/css/app.css", __DIR__)

  setup %{conn: conn} do
    admin = Platform.TenancyFixtures.root_admin!()
    n = "Pg" <> String.slice(Ecto.UUID.generate(), 0, 6)
    b = Character.new("producer") |> Map.merge(%{n: n, portrait: "fox", color: "amber"})
    {:ok, %{agent: agent}} = Character.create(b, admin)

    %{conn: init_test_session(conn, current_user_id: admin.id), admin: admin, agent: agent}
  end

  defp open(conn, agent, tab \\ nil) do
    path = "/control/#{agent.slug}" <> if(tab, do: "?tab=#{tab}", else: "")
    {:ok, view, _html} = live(conn, path)
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
    view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> LazyHTML.text()
  end

  defp agent!(agent), do: Repo.get!(Agent, agent.id)
  defp soul_version(agent), do: MemoryContext.get_workspace_file(agent.id, "SOUL.md").version
  defp soul(agent), do: MemoryContext.get_workspace_file(agent.id, "SOUL.md").content

  defp channel!(name) do
    {:ok, space} =
      Chat.create_space(%{
        name: name,
        slug: name <> "-" <> String.slice(Ecto.UUID.generate(), 0, 6),
        kind: "channel"
      })

    space
  end

  # ── Head and tabs ──────────────────────────────────────────────────

  describe "head and tabs" do
    test "renders the comp's head on both layouts", %{conn: conn, agent: agent} do
      view = open(conn, agent)

      assert has_element?(view, ".ba-page.ba-alive[data-agent-slot='amber']")
      assert has_element?(view, ".ba-ptop .ib[data-a='back']")
      assert has_element?(view, ".ba-ptop b", "Agent")
      assert has_element?(view, ".ba-ptop #agent-more[aria-label='More']")
      assert has_element?(view, ".ba-phead #agent-more-desk")
      assert has_element?(view, ".ba-avwrap.idle .ba-por[data-portrait='fox']")
      assert count(view, ".ba-avwrap .ring") == 2
      assert has_element?(view, ".ba-avwrap .st")
      assert has_element?(view, ".ba-pname", agent.name)
      assert has_element?(view, ".ba-pill[data-pill='class']", "🎬 Producer")
      assert has_element?(view, ".ba-pill.st.idle", "idle")
      refute has_element?(view, ".ba-pill.mine")
      assert has_element?(view, ".ba-doing", "idle · wakes on @mention")
      refute has_element?(view, ".ba-doing .ba-typing")
      assert count(view, ".ba-pacts > *") == 3
      assert has_element?(view, ".ba-pacts .ba-btn.ag[data-a='talk']", "🎙 Talk")
      assert has_element?(view, ".ba-pacts [data-a='dm']", "💬 Message")
      assert has_element?(view, ".ba-pacts [data-a='awake'][role='switch'][aria-checked='true']")
    end

    test "seven tabs in the comp's order, Overview selected by default", %{
      conn: conn,
      agent: agent
    } do
      view = open(conn, agent)

      assert text(view, ".ba-ptabs button") |> String.split(~r/\s{2,}/, trim: true) ==
               [
                 "Overview",
                 "Voice",
                 "Connections",
                 "Abilities",
                 "Personality",
                 "Memory & notes",
                 "Stats"
               ]

      assert attr(view, ".ba-ptabs button[aria-selected='true']", "data-tab") == ["overview"]
      assert count(view, ".ba-ptabs[role='tablist'] button[role='tab']") == 7
    end

    test "?tab= deep-links a tab and a tab click patches to it", %{conn: conn, agent: agent} do
      view = open(conn, agent, "voice")
      assert has_element?(view, "[data-body='voice']")

      view |> element(".ba-ptabs button[data-tab='abilities']") |> render_click()
      assert_patch(view, "/control/#{agent.slug}?tab=abilities")
      assert has_element?(view, "[data-body='abilities']")
      assert attr(view, ".ba-ptabs button[aria-selected='true']", "data-tab") == ["abilities"]
    end

    test "an unknown tab falls back to Overview", %{conn: conn, agent: agent} do
      view = open(conn, agent, "bogus")
      assert has_element?(view, "[data-body='overview']")
    end

    test "Connections, Memory & notes and Stats show the tab chrome, body pending", %{
      conn: conn,
      agent: agent
    } do
      for tab <- ~w(connections memory stats) do
        view = open(conn, agent, tab)
        assert has_element?(view, "#ba-pbody [data-pending='#{tab}']")
        assert attr(view, ".ba-ptabs button[aria-selected='true']", "data-tab") == [tab]
      end
    end

    test "Talk goes to the voice route with the agent as partner", %{conn: conn, agent: agent} do
      view = open(conn, agent)

      assert attr(view, ".ba-pacts [data-a='talk']", "href") == [
               "/voice?partner=#{agent.id}"
             ]
    end

    test "Message opens the viewer's DM with the agent", %{
      conn: conn,
      agent: agent,
      admin: admin
    } do
      {:ok, dm} = Chat.find_or_create_dm(admin.id, "agent", agent.id)
      view = open(conn, agent)
      view |> element(".ba-pacts [data-a='dm']") |> render_click()
      assert_redirect(view, "/chat/#{dm.slug || dm.id}")
    end

    test "Awake is the chat toggle: it writes accepts_chat both ways", %{
      conn: conn,
      agent: agent
    } do
      view = open(conn, agent)
      view |> element(".ba-pacts [data-a='awake']") |> render_click()
      assert agent!(agent).accepts_chat == false
      assert has_element?(view, ".ba-pacts [data-a='awake'][aria-checked='false']")

      view |> element(".ba-pacts [data-a='awake']") |> render_click()
      assert agent!(agent).accepts_chat == true
    end

    test "a malformed Awake event writes nothing", %{conn: conn, agent: agent} do
      view = open(conn, agent)
      render_click(view, "set_accepts_chat", %{"awake" => "maybe"})
      assert agent!(agent).accepts_chat == true
    end
  end

  # ── Overview ───────────────────────────────────────────────────────

  describe "Overview" do
    test "the empty state renders the comp's empty copy, never a blank", %{
      conn: conn,
      agent: agent
    } do
      view = open(conn, agent)

      for label <- ["Working on now", "Where it is", "At a glance", "Today"] do
        assert has_element?(view, "[data-body='overview'] .ba-lbl", label)
      end

      assert has_element?(
               view,
               ".ba-now .ba-gempty",
               "Nothing assigned. @ it in any channel to hand it something."
             )

      assert has_element?(view, "[data-tile='shipped'] b", "0")
      assert has_element?(view, "[data-tile='shipped'] span", "tasks shipped")
      assert has_element?(view, "[data-tile='first-reply'] b", "—")
      assert has_element?(view, "[data-tile='first-reply'] span", "median first reply")
      assert has_element?(view, "[data-tile='memories'] b", "0")
      assert has_element?(view, ".ba-tl div", "Idle — wakes on @mention")
      # The builder's DM with its creator is not a channel.
      assert count(view, ".ba-chips .ba-chip[data-sp]") == 0
    end

    test "working on now lists open assigned tasks; tasks shipped counts done ones", %{
      conn: conn,
      agent: agent
    } do
      {:ok, project} = Platform.Tasks.create_project(%{name: "Pg project"})

      task = fn title, status ->
        {:ok, t} =
          Platform.Tasks.create_task(%{
            title: title,
            project_id: project.id,
            assignee_type: "agent",
            assignee_id: agent.id,
            status: status
          })

        t
      end

      open_task = task.("Draft the brief", "in_progress")
      task.("Old thing", "done")

      view = open(conn, agent)
      assert has_element?(view, ".ba-now a[data-now='#{open_task.id}'] b", "Draft the brief")
      assert has_element?(view, ".ba-now a[data-now='#{open_task.id}'] small", "Pg project")
      assert has_element?(view, ".ba-now a[data-now='#{open_task.id}'] .stc", "in progress")
      refute has_element?(view, ".ba-now b", "Old thing")
      refute has_element?(view, ".ba-now .ba-gempty")
      assert has_element?(view, "[data-tile='shipped'] b", "1")
      # An in-progress task is what it is doing.
      assert has_element?(view, ".ba-tl div", "Worked on Draft the brief")

      task.("Another", "done")
      view = open(conn, agent)
      assert has_element?(view, "[data-tile='shipped'] b", "2")
    end

    test "memories is the MemoryContext count and moves with it", %{conn: conn, agent: agent} do
      for i <- 1..3, do: {:ok, _} = MemoryContext.append_memory(agent.id, :long_term, "m#{i}")
      view = open(conn, agent)
      assert has_element?(view, "[data-tile='memories'] b", "3")

      {:ok, _} = MemoryContext.append_memory(agent.id, :long_term, "m4")
      view = open(conn, agent)
      assert has_element?(view, "[data-tile='memories'] b", "4")
    end

    test "where it is: each channel row with its mode's short label", %{
      conn: conn,
      agent: agent
    } do
      alpha = channel!("alpha")
      beta = channel!("beta")
      {:ok, _} = Chat.add_agent_participant(alpha.id, agent, attention_mode: "active")
      {:ok, _} = Chat.add_agent_participant(beta.id, agent, attention_mode: "mention")

      view = open(conn, agent)
      assert has_element?(view, ".ba-chip[data-sp='#{alpha.slug}']", "#alpha")
      assert has_element?(view, ".ba-chip[data-sp='#{alpha.slug}'] small", "· follows along")
      assert has_element?(view, ".ba-chip[data-sp='#{beta.slug}'] small", "· on-mention")
      assert attr(view, ".ba-chip[data-sp='#{alpha.slug}']", "href") == ["/chat/#{alpha.slug}"]
    end

    test "today lists its messages only in spaces the viewer is in", %{
      conn: conn,
      agent: agent,
      admin: admin
    } do
      seen = channel!("seen")
      unseen = channel!("unseen")

      {:ok, _} =
        Chat.add_participant(seen.id, %{
          participant_type: "user",
          participant_id: admin.id,
          joined_at: DateTime.utc_now()
        })

      for space <- [seen, unseen] do
        {:ok, p} = Chat.add_agent_participant(space.id, agent)

        {:ok, _} =
          Chat.post_message(%{
            space_id: space.id,
            participant_id: p.id,
            content_type: "text",
            content: "said in #{space.name}"
          })
      end

      view = open(conn, agent)
      assert has_element?(view, ".ba-tl div", "Replied in #seen")
      refute has_element?(view, ".ba-tl div", "Replied in #unseen")

      view = open(conn, agent, "personality")
      assert has_element?(view, "#ba-said", "said in seen")
    end
  end

  # ── Voice ──────────────────────────────────────────────────────────

  describe "Voice" do
    test "the stage 2 voice block in two columns, with the saved line", %{
      conn: conn,
      agent: agent
    } do
      view = open(conn, agent, "voice")
      assert has_element?(view, ".ba-vhead .ba-lbl", "How #{agent.name} talks")

      assert has_element?(
               view,
               ".ba-vhead .ba-vsaved[role='status']",
               "✓ Saved · applies to new replies"
             )

      refute has_element?(view, ".ba-vsaved.on")
      assert has_element?(view, ".ba-voice.ba-cols > .ba-vc .ba-vdial")
      assert has_element?(view, ".ba-voice.ba-cols > .ba-vc .ba-vtry")
      assert has_element?(view, "#ap-vft.ba-vft")
      assert has_element?(view, "#ap-vread.ba-vread")
    end

    test "a preset change rewrites SOUL.md · Voice and shows Saved", %{
      conn: conn,
      agent: agent
    } do
      v0 = soul_version(agent)
      view = open(conn, agent, "voice")
      view |> element(".ba-vstops button[data-vp='4']") |> render_click()

      agent = agent!(agent)
      assert agent.metadata["character"]["voice"]["preset"] == Archetypes.voice(4).key
      assert soul_version(agent) == v0 + 1
      assert soul(agent) =~ hd(Character.v_prompt_lines(%{p: 4, ov: %{}}))
      assert has_element?(view, ".ba-vsaved.on")
    end

    test "a knob writes an override; Reset clears it", %{conn: conn, agent: agent} do
      view = open(conn, agent, "voice")
      knob = hd(Archetypes.knobs())
      p = Character.from_agent(agent).vc.p
      default = Enum.at(Archetypes.vdef(), p)[knob.k]
      other = Enum.find(0..(length(knob.options) - 1), &(&1 != default))

      view |> element(".ba-vft button[data-vk='#{knob.k}'][data-vv='#{other}']") |> render_click()
      assert agent!(agent).metadata["character"]["voice"]["overrides"] == %{knob.k => other}

      view |> element(".ba-vft [data-vreset]") |> render_click()
      assert agent!(agent).metadata["character"]["voice"]["overrides"] == %{}
    end

    test "malformed voice events write nothing", %{conn: conn, agent: agent} do
      v0 = soul_version(agent)
      before = agent!(agent).metadata
      view = open(conn, agent, "voice")
      render_click(view, "voice_preset", %{"p" => "9"})
      render_click(view, "voice_preset", %{"p" => "x"})
      render_click(view, "voice_knob", %{"k" => "nope", "v" => "1"})
      render_click(view, "voice_knob", %{"k" => hd(Archetypes.knobs()).k, "v" => "99"})
      assert soul_version(agent) == v0
      assert agent!(agent).metadata == before
    end

    test "Try it previews and writes nothing", %{conn: conn, agent: agent} do
      v0 = soul_version(agent)
      view = open(conn, agent, "voice")
      sample = List.last(Archetypes.samples())
      view |> element(".ba-vtry button[data-vq='#{sample.id}']") |> render_click()
      assert has_element?(view, ".ba-vtry button[data-vq='#{sample.id}'][aria-pressed='true']")
      view |> form("#ap-vfree-form", %{"q" => "hello there"}) |> render_submit()
      assert has_element?(view, ".ba-vchat .ba-vb.me", "hello there")
      assert soul_version(agent) == v0
    end
  end

  # ── Personality ────────────────────────────────────────────────────

  describe "Personality" do
    test "renders the comp's dials, traits, voice and buttons", %{conn: conn, agent: agent} do
      view = open(conn, agent, "personality")
      b = Character.from_agent(agent)

      for label <- ["Dials", "Traits · pick three", "Its voice"] do
        assert has_element?(view, "[data-body='personality'] .ba-lbl", label)
      end

      assert count(view, ".ba-slider input[type='range'][data-psl]") == 4
      assert count(view, ".ba-chip[data-ptr]") == 14
      assert count(view, ".ba-chip[data-ptr][aria-pressed='true']") == 3
      assert count(view, ".ba-says") == 2
      assert has_element?(view, "#ba-voice small", "HOW IT WOULD TELL YOU A PR IS READY")
      assert has_element?(view, "#ba-voice", Character.voice_sample(b))
      assert has_element?(view, "#ba-said small", "SOMETHING IT ACTUALLY SAID")
      # Nothing said yet: its first line.
      assert has_element?(
               view,
               "#ba-said",
               Character.first_line(b, "Root Admin") |> String.slice(0, 20)
             )

      assert has_element?(view, "button[data-a='hear'][disabled]", "▶ Hear it")
      assert has_element?(view, "button[data-a='card']", "🃏 Show its card")

      assert has_element?(
               view,
               "[data-body='personality'] .ba-sub",
               "Changes apply from its next turn."
             )
    end

    test "a dial change writes SOUL.md (version + 1) and the voice sample follows", %{
      conn: conn,
      agent: agent
    } do
      v0 = soul_version(agent)
      view = open(conn, agent, "personality")
      sl = Character.from_agent(agent).sl

      view
      |> form("#ap-dials-form", %{"sl" => Map.merge(sl, %{"chatty" => "20", "bold" => "90"})})
      |> render_change()

      agent = agent!(agent)
      assert agent.metadata["character"]["sliders"]["chatty"] == 20
      assert agent.metadata["character"]["sliders"]["bold"] == 90
      assert soul_version(agent) == v0 + 1
      assert soul(agent) =~ "20"
      assert has_element?(view, "#ba-voice", Character.voice_sample(Character.from_agent(agent)))
      assert has_element?(view, ".ba-slider .ends span.lean", "Terse")
    end

    test "a malformed dial writes nothing", %{conn: conn, agent: agent} do
      v0 = soul_version(agent)
      before = agent!(agent).metadata
      view = open(conn, agent, "personality")
      render_change(view, "page_dials", %{"sl" => %{"chatty" => "abc", "bold" => "101"}})
      render_change(view, "page_dials", %{"nope" => "1"})
      assert soul_version(agent) == v0
      assert agent!(agent).metadata == before
    end

    test "a trait click toggles it, three at most, and writes SOUL.md", %{
      conn: conn,
      agent: agent
    } do
      v0 = soul_version(agent)
      before = Character.from_agent(agent).traits
      view = open(conn, agent, "personality")
      view |> element(".ba-chip[data-ptr='skeptic']") |> render_click()

      traits = agent!(agent).metadata["character"]["traits"]
      assert length(traits) == 3
      assert "skeptic" in traits
      assert traits == tl(before) ++ ["skeptic"]
      assert soul_version(agent) == v0 + 1
      assert soul(agent!(agent)) =~ "skeptic"
      assert has_element?(view, ".ba-chip[data-ptr='skeptic'][aria-pressed='true']")
    end

    test "an unknown trait writes nothing", %{conn: conn, agent: agent} do
      v0 = soul_version(agent)
      view = open(conn, agent, "personality")
      render_click(view, "page_trait", %{"tr" => "not a trait"})
      assert soul_version(agent) == v0
    end

    test "Show its card renders the stage 2 card", %{conn: conn, agent: agent} do
      view = open(conn, agent, "personality")
      refute has_element?(view, "#ba-cardslot .ba-card")
      view |> element("button[data-a='card']") |> render_click()
      assert has_element?(view, "#ba-cardslot .ba-card.reveal[data-agent-slot='amber']")
      assert has_element?(view, "#ba-cardslot .ba-card .ctop b", agent.name)
    end

    test "Hear it is enabled only when voice_config names a provider", %{
      conn: conn,
      agent: agent
    } do
      {:ok, _} =
        agent
        |> Agent.changeset(%{voice_config: %{"provider" => "elevenlabs", "voice_id" => "v"}})
        |> Repo.update()

      view = open(conn, agent, "personality")
      refute has_element?(view, "button[data-a='hear'][disabled]")

      assert view |> element("button[data-a='hear']") |> render_click() =~
               "voice_config elevenlabs"
    end
  end

  # ── Abilities ──────────────────────────────────────────────────────

  describe "Abilities" do
    test "ten toolkit switches with the comp's lines, and the empty channel state", %{
      conn: conn,
      agent: agent
    } do
      view = open(conn, agent, "abilities")
      assert count(view, ".ba-group.ba-tk .ba-row[role='switch'][data-tk]") == 10

      on = attr(view, ".ba-tk .ba-row[aria-checked='true']", "data-tk")

      assert on ==
               Archetypes.fetch("producer").toolkit
               |> Enum.sort_by(&Enum.find_index(Archetypes.toolkit_ids(), fn x -> x == &1 end))

      assert has_element?(view, ".ba-tk [data-tk='deploy'] small", "merges to main (= ships)")
      assert has_element?(view, ".ba-tk [data-tk='email'] .ba-sw")

      assert has_element?(
               view,
               "[data-body='abilities'] .ba-sub",
               "credentials stay in the vault (0 granted)."
             )

      assert has_element?(view, "[data-body='abilities'] .ba-lbl", "Mode, per channel")
      assert has_element?(view, ".ba-chmode .ba-gempty", "Not in any channel yet.")
      assert has_element?(view, "button[data-a='addsp']", "＋ Add to a channel")
    end

    test "a toolkit switch writes tools_config and TOOLS.md", %{conn: conn, agent: agent} do
      v0 = MemoryContext.get_workspace_file(agent.id, "TOOLS.md").version
      view = open(conn, agent, "abilities")
      view |> element(".ba-tk [data-tk='web']") |> render_click()

      assert "web" in agent!(agent).tools_config["toolkit"]
      assert MemoryContext.get_workspace_file(agent.id, "TOOLS.md").version == v0 + 1
      assert has_element?(view, ".ba-tk [data-tk='web'][aria-checked='true']")

      view |> element(".ba-tk [data-tk='web']") |> render_click()
      refute "web" in agent!(agent).tools_config["toolkit"]
    end

    test "an unknown tool writes nothing", %{conn: conn, agent: agent} do
      before = agent!(agent).tools_config
      view = open(conn, agent, "abilities")
      render_click(view, "page_toolkit", %{"tk" => "rm -rf"})
      assert agent!(agent).tools_config == before
    end

    test "mode per channel writes the participant's attention_mode", %{
      conn: conn,
      agent: agent
    } do
      alpha = channel!("alpha")
      {:ok, _} = Chat.add_agent_participant(alpha.id, agent, attention_mode: "mention")
      view = open(conn, agent, "abilities")

      assert has_element?(view, ".ba-chmode .r[data-space='#{alpha.slug}'] b", "#alpha")
      assert count(view, ".ba-chmode .r[data-space='#{alpha.slug}'] .ba-seg button") == 3

      assert has_element?(
               view,
               ".ba-chmode button[data-m='mention'][aria-pressed='true']",
               "On mention"
             )

      view
      |> element(".ba-chmode .r[data-space='#{alpha.slug}'] button[data-m='active']")
      |> render_click()

      assert Chat.get_agent_participant(alpha.id, agent.id).attention_mode == "active"

      assert has_element?(
               view,
               ".ba-chmode button[data-m='active'][aria-pressed='true']",
               "Follows along"
             )

      view
      |> element(".ba-chmode .r[data-space='#{alpha.slug}'] button[data-m='all']")
      |> render_click()

      assert Chat.get_agent_participant(alpha.id, agent.id).attention_mode == "all"
    end

    test "a malformed mode, or a space the agent is not in, writes nothing", %{
      conn: conn,
      agent: agent
    } do
      alpha = channel!("alpha")
      other = channel!("other")
      {:ok, _} = Chat.add_agent_participant(alpha.id, agent, attention_mode: "mention")
      view = open(conn, agent, "abilities")

      render_click(view, "page_mode", %{"space" => alpha.id, "mode" => "heartbeat"})
      render_click(view, "page_mode", %{"space" => alpha.id, "mode" => "bogus"})
      render_click(view, "page_mode", %{"space" => "not-a-uuid", "mode" => "all"})
      render_click(view, "page_mode", %{"space" => other.id, "mode" => "all"})
      assert Chat.get_agent_participant(alpha.id, agent.id).attention_mode == "mention"
      assert Chat.get_agent_participant(other.id, agent.id) == nil
    end

    test "＋ Add to a channel opens the add-to-space modal and adds it on mention", %{
      conn: conn,
      agent: agent
    } do
      alpha = channel!("alpha")
      view = open(conn, agent, "abilities")
      view |> element("button[data-a='addsp']") |> render_click()
      assert has_element?(view, "#add-space-modal")

      view
      |> form("#add-space-modal form", %{"space_id" => alpha.id, "role" => "member"})
      |> render_submit()

      assert Chat.get_agent_participant(alpha.id, agent.id).attention_mode == "mention"
      assert has_element?(view, ".ba-chmode .r[data-space='#{alpha.slug}']")
      refute has_element?(view, ".ba-chmode .ba-gempty")
    end
  end

  # ── Advanced settings and permissions ──────────────────────────────

  describe "Advanced settings" do
    test "⋯ opens every old control; the tab body hides while it is open", %{
      conn: conn,
      agent: agent
    } do
      view = open(conn, agent)
      assert has_element?(view, "#agent-advanced.hidden")

      view |> element("#agent-more") |> render_click()
      refute has_element?(view, "#agent-advanced.hidden")
      assert has_element?(view, "#ba-pbody.hidden")
      assert has_element?(view, "#agent-more[aria-expanded='true']")

      for sel <- ~w(#agent-accepts-chat-form #delete-agent #start-runtime #agent-config-form) do
        assert has_element?(view, "#agent-advanced " <> sel), sel
      end

      view |> element("#agent-more-desk") |> render_click()
      assert has_element?(view, "#agent-advanced.hidden")
    end

    test "a tab click closes Advanced settings", %{conn: conn, agent: agent} do
      view = open(conn, agent)
      view |> element("#agent-more") |> render_click()
      view |> element(".ba-ptabs button[data-tab='voice']") |> render_click()
      assert has_element?(view, "#agent-advanced.hidden")
    end
  end

  describe "an agent built before characters" do
    setup do
      {:ok, legacy} =
        %Agent{}
        |> Agent.changeset(%{
          slug: "legacy-#{System.unique_integer([:positive])}",
          name: "Legacy",
          status: "active"
        })
        |> Repo.insert()

      {:ok, _} = MemoryContext.upsert_workspace_file(legacy.id, "SOUL.md", "hand written")
      %{legacy: legacy}
    end

    test "renders the page, says where its SOUL.md lives and never overwrites it", %{
      conn: conn,
      legacy: legacy
    } do
      view = open(conn, legacy, "personality")
      assert has_element?(view, ".ba-pname", "Legacy")
      refute has_element?(view, ".ba-pill[data-pill='class']")
      assert has_element?(view, "[data-legacy]", "Advanced settings")

      render_change(view, "page_dials", %{"sl" => %{"chatty" => "10"}})
      render_click(view, "page_trait", %{"tr" => "skeptic"})
      render_click(view, "voice_preset", %{"p" => "1"})
      assert MemoryContext.get_workspace_file(legacy.id, "SOUL.md").content == "hand written"
      assert agent!(legacy).metadata["character"] == nil
    end

    test "its toolkit switch writes the row only", %{conn: conn, legacy: legacy} do
      view = open(conn, legacy, "abilities")
      view |> element(".ba-tk [data-tk='tasks']") |> render_click()
      assert agent!(legacy).tools_config["toolkit"] == ["tasks"]
      assert MemoryContext.get_workspace_file(legacy.id, "TOOLS.md") == nil
    end
  end

  describe "a member who may not manage the agent" do
    setup %{conn: conn} do
      user = World.create_user!()

      World.plain_member!(
        user,
        Repo.get!(Platform.Tenancy.Org, Platform.TenancyFixtures.acme_org_id())
      )

      %{member_conn: init_test_session(conn, current_user_id: user.id)}
    end

    test "sees the page with the writes disabled, and forged writes change nothing", %{
      member_conn: conn,
      agent: agent
    } do
      alpha = channel!("alpha")
      {:ok, _} = Chat.add_agent_participant(alpha.id, agent, attention_mode: "mention")
      v0 = soul_version(agent)
      before = agent!(agent)
      view = open(conn, agent, "abilities")

      assert has_element?(view, ".ba-tk .ba-row[disabled]")
      assert has_element?(view, ".ba-pacts [data-a='awake'][disabled]")
      refute has_element?(view, "button[data-a='addsp']")

      render_click(view, "page_toolkit", %{"tk" => "web"})
      render_click(view, "page_mode", %{"space" => alpha.id, "mode" => "all"})
      render_click(view, "page_trait", %{"tr" => "skeptic"})
      render_change(view, "page_dials", %{"sl" => %{"chatty" => "1"}})
      render_click(view, "voice_preset", %{"p" => "0"})
      render_click(view, "set_accepts_chat", %{"awake" => "false"})

      after_ = agent!(agent)
      assert after_.tools_config == before.tools_config
      assert after_.metadata == before.metadata
      assert after_.accepts_chat == before.accepts_chat
      assert soul_version(agent) == v0
      assert Chat.get_agent_participant(alpha.id, agent.id).attention_mode == "mention"
    end
  end

  # ── Layout rules ───────────────────────────────────────────────────

  describe "app.css" do
    test "the comp's .desk rules sit in the 768px media query" do
      css = File.read!(@app_css)
      [_, page] = String.split(css, "/* ── Living agent page (task 01a1b6ad stage 3)", parts: 2)
      [page, _] = String.split(page, "/* ── end living agent page ── */", parts: 2)

      [_, desk] = String.split(page, "@media (min-width: 768px){", parts: 2)
      assert desk =~ ".ba-ptop{display:none}"
      assert desk =~ ".ba-pmore{display:inline-flex}"
      assert desk =~ ".ba-page .ba-cols{grid-template-columns:1.2fr 1fr}"
      assert desk =~ ".ba-tk{grid-template-columns:1fr 1fr}"
      assert page =~ ".ba-pmore{display:none;"
      refute page =~ ~r/#[0-9a-fA-F]{3,6}\b/
    end

    test "tab ids are the comp's" do
      assert AgentPage.tab_ids() ==
               ~w(overview voice connections abilities personality memory stats)
    end
  end
end
