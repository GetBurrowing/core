defmodule PlatformWeb.AgentFaceEverywhereTest do
  @moduledoc """
  Task 01a00122-553c ("Give agents a face"), stage 5 — the face renders
  everywhere an agent appears.

  The risk this stage carries is INCOMPLETENESS, not incorrectness: a face that
  shows up in chat but not in a meeting rail is half-shipped, and nothing about
  the chat surface working tells you the rail does. So the coverage here is
  deliberately PER SURFACE — one test per place an agent's avatar is drawn, each
  scoped by a selector that only that surface's markup satisfies.

  That structure is the actual guard. Reverting any ONE call site back to its
  hand-rolled circle must turn exactly ONE test red; if a single shared
  assertion covered several surfaces, three of them could quietly ship
  unconverted behind one green check. Every test therefore:

    * finds the avatar through a selector rooted in ITS surface's container,
    * asserts on `data-avatar-mode` / `data-avatar-kind` and the rendered
      letters rather than on Tailwind classes that a restyle may reshuffle,
    * and covers the WITH-image and WITHOUT-image cases together, so one
      unconverted site is one failure rather than two.

  What an imageless agent must still look like is pinned in
  `PlatformWeb.AvatarComponentsTest`: exactly ONE initial over the flat
  `bg-base-300 text-primary` circle, never the seeded `avatar-fallback-N` human
  palette and never `agents.color`. The agent colour is the accent RING the
  caller draws around the avatar, and the two chat surfaces that have a ring
  today assert it survives an image avatar — that is the whole reason
  `render_avatar/1` keeps `rounded-full` on the outer wrapper.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.AvatarComponents, only: [agent_avatar: 1, human_avatar: 1]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tasks

  @image "/agents/11111111-1111-4111-8111-111111111111/avatar?v=GKHEI"

  # ── DOM helpers ──────────────────────────────────────────────────────────
  #
  # `within/2` is what makes the per-surface property real: it roots the search
  # in the container that identifies ONE surface, so an avatar rendered by some
  # other region of the same page cannot satisfy this surface's assertions.

  defp within(html, selector) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find(selector)
  end

  defp mode([el]), do: Floki.attribute([el], "data-avatar-mode") |> List.first()

  defp kind([el]), do: Floki.attribute([el], "data-avatar-kind") |> List.first()

  defp wrapper_class([el]), do: Floki.attribute([el], "class") |> List.first() || ""

  defp img_src([el]), do: [el] |> Floki.find("img") |> Floki.attribute("src") |> List.first()

  # The letters actually drawn, not merely present somewhere in the subtree.
  # `=~ "A"` would survive the agent path widening to two initials.
  defp letters([el]) do
    [el] |> Floki.find(~s(span[aria-hidden="true"])) |> Floki.text() |> String.trim()
  end

  # Every converted surface makes the same two-part claim, so assert it in one
  # place: an agent WITH an avatar draws the stored image (cache token intact),
  # an agent WITHOUT one falls back to a single initial under the agent kind.
  defp assert_agent_face(with_image_html, without_image_html, selector),
    do: assert_agent_face(with_image_html, without_image_html, selector, selector)

  # The LiveView surfaces share one sandbox across both halves of a test, so a
  # second render still carries the first render's rows. Those surfaces pass ONE
  # html and two selectors instead, seeding two agents into the same page and
  # telling them apart there.
  defp assert_agent_face(with_image_html, without_image_html, imaged_selector, plain_selector) do
    imaged = within(with_image_html, imaged_selector)
    plain = within(without_image_html, plain_selector)

    assert length(imaged) == 1,
           "expected exactly one agent avatar at #{imaged_selector}, found #{length(imaged)}"

    assert length(plain) == 1,
           "expected exactly one agent avatar at #{plain_selector}, found #{length(plain)}"

    assert kind(imaged) == "agent"
    assert kind(plain) == "agent"

    assert mode(imaged) == "image",
           "#{imaged_selector}: an agent WITH an avatar must render the stored image"

    assert mode(plain) == "fallback",
           "#{plain_selector}: an agent WITHOUT an avatar must render the initial circle"

    # Stage 2's `?v=` cache token rides through verbatim — never parsed, never
    # stripped, or a changed avatar serves the browser's stale copy.
    assert img_src(imaged) == @image

    initials = letters(plain)

    assert String.length(initials) == 1,
           "#{plain_selector}: agents draw exactly ONE initial (humans get two); " <>
             "got #{inspect(initials)}"

    {imaged, plain}
  end

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp agent!(name, avatar_url) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "face-agent-#{n}",
      name: name,
      status: "active",
      avatar_url: avatar_url,
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    })
  end

  defp user!(opts \\ []) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "face_#{n}@example.com",
      name: Keyword.get(opts, :name, "Face Test User"),
      oidc_sub: "oidc-face-#{n}"
    })
  end

  defp space! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "Face #{n}", slug: "face-#{n}", kind: "channel"})

    space
  end

  defp join_agent(space, agent) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: agent.name,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp join_user(space, user) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  # `/chat` redirects to the first channel the moment one exists; always land on
  # the space the test built.
  defp live_at(conn, path) do
    case live(conn, path) do
      {:error, {:live_redirect, %{to: redirect}}} -> live(conn, redirect)
      ok -> ok
    end
  end

  # ── The fallback circle must actually CENTRE its initial ─────────────────

  describe "the fallback initial is centred" do
    # Found in a screenshot, not in a test: routing the chat row through
    # `agent_avatar/1` put the initial in the TOP-LEFT of the circle, half
    # clipped by its own `overflow: hidden`. `avatar` is a DaisyUI component and
    # `.avatar > div { display: block }` (0,1,1) beats the `flex` utility
    # (0,1,0), so `items-center justify-center` never applied. The old
    # hand-rolled chat circle had no `.avatar` ancestor and centred fine, so
    # this stage introduced it there.
    #
    # These assertions are a DOM proxy for a CSS fact, which is the honest limit
    # of a render test — `avatar-placeholder` is the class that CARRIES the
    # centring, and it must be present in fallback mode and absent with an image
    # (where `display: block` on the child is correct and DaisyUI's
    # `.avatar img` rule sizes the picture).
    test "fallback mode opts into DaisyUI's placeholder centring, image mode does not" do
      assigns = %{}

      agent_plain =
        rendered_to_string(~H"""
        <.agent_avatar name="Bram Toller" />
        """)

      agent_imaged =
        rendered_to_string(~H"""
        <.agent_avatar name="Helga Vantar" avatar_url="/agents/abc/avatar?v=GKHEI" />
        """)

      human_plain =
        rendered_to_string(~H"""
        <.human_avatar name="Dana Reed" seed="s" />
        """)

      assert wrapper_class(within(agent_plain, ~s([data-avatar-kind="agent"]))) =~
               "avatar-placeholder",
             "an imageless agent circle must centre its initial, or the letter " <>
               "renders in the corner and is clipped"

      assert wrapper_class(within(human_plain, ~s([data-avatar-kind="human"]))) =~
               "avatar-placeholder"

      refute wrapper_class(within(agent_imaged, ~s([data-avatar-kind="agent"]))) =~
               "avatar-placeholder"
    end
  end

  # ── Surface 1: the main chat row ─────────────────────────────────────────

  describe "surface: chat message row" do
    defp chat_row_html(avatar_url) do
      assigns = %{
        msg: %{
          id: "msg-1",
          space_id: "space-1",
          participant_id: "p-agent",
          content: "hello from the agent",
          content_type: "text",
          canvas_id: nil,
          inserted_at: ~U[2026-08-15 10:00:00.000000Z],
          day_label: nil,
          reactions: [],
          versions_count: 1,
          corrects_message_id: nil
        },
        participants_map: %{
          "p-agent" => %{name: "Helga Vantar", avatar_url: avatar_url, avatar_seed: nil}
        },
        agent_participant_ids: MapSet.new(["p-agent"])
      }

      rendered_to_string(~H"""
      <PlatformWeb.Components.ChatMessage.chat_message
        dom_id="row-1"
        msg={@msg}
        current_participant={nil}
        agent_participant_ids={@agent_participant_ids}
        agent_colors_map={%{"p-agent" => "#7c3aed"}}
        participants_map={@participants_map}
        quick_emojis={[]}
        pinned_message_ids={MapSet.new()}
        canvases_by_id={%{}}
        attachments_map={%{}}
        thread_previews={%{}}
        expanded_threads={MapSet.new()}
        inline_thread_messages={%{}}
      />
      """)
    end

    test "the agent row renders the stored image, and the accent ring survives it" do
      selector = ~s(.message-avatar [data-avatar-kind="agent"])

      {imaged, plain} =
        assert_agent_face(chat_row_html(@image), chat_row_html(nil), selector)

      assert letters(plain) == "H"

      # `.msg-agent-avatar` IS the accent ring — a box-shadow keyed off
      # `--agent-accent`. It lands on the outer wrapper, so that wrapper must
      # stay round or a box-shadow ring draws as a rectangle. Both modes.
      for el <- [imaged, plain] do
        assert wrapper_class(el) =~ "msg-agent-avatar"
        assert wrapper_class(el) =~ "rounded-full"
      end
    end
  end

  # ── Surface 2: the inline thread preview ─────────────────────────────────

  describe "surface: inline thread preview" do
    # The ROOT message is from a human here, deliberately: it means the only
    # agent avatar in this HTML is the thread reply's, so this test cannot be
    # satisfied by the chat-row site and cannot be broken by it either.
    defp thread_preview_html(avatar_url) do
      root = %{
        id: "msg-root",
        space_id: "space-1",
        participant_id: "p-human",
        content: "a human asked something",
        content_type: "text",
        canvas_id: nil,
        inserted_at: ~U[2026-08-15 10:00:00.000000Z],
        day_label: nil,
        reactions: [],
        versions_count: 1,
        corrects_message_id: nil
      }

      reply = %{
        id: "msg-reply",
        space_id: "space-1",
        participant_id: "p-agent",
        content: "the agent replied in thread",
        content_type: "text",
        canvas_id: nil,
        inserted_at: ~U[2026-08-15 10:01:00.000000Z],
        day_label: nil,
        reactions: [],
        versions_count: 1,
        corrects_message_id: nil
      }

      # A HUMAN reply sits alongside it so the preview's human path is exercised
      # in the same markup the agent path is.
      human_reply = %{reply | id: "msg-reply-human", participant_id: "p-human"}

      assigns = %{
        root: root,
        reply: reply,
        human_reply: human_reply,
        participants_map: %{
          "p-human" => %{name: "Dana Reed", avatar_url: nil, avatar_seed: "seed-dana"},
          "p-agent" => %{name: "Helga Vantar", avatar_url: avatar_url, avatar_seed: nil}
        }
      }

      rendered_to_string(~H"""
      <PlatformWeb.Components.ChatMessage.chat_message
        dom_id="row-root"
        msg={@root}
        current_participant={nil}
        agent_participant_ids={MapSet.new(["p-agent"])}
        agent_colors_map={%{}}
        participants_map={@participants_map}
        quick_emojis={[]}
        pinned_message_ids={MapSet.new()}
        canvases_by_id={%{}}
        attachments_map={%{}}
        thread_previews={%{"msg-root" => %{reply_count: 1}}}
        expanded_threads={MapSet.new(["msg-root"])}
        inline_thread_messages={%{"msg-root" => [@reply, @human_reply]}}
        read_only={true}
      />
      """)
    end

    test "an agent replying in a thread shows its face" do
      selector = ~s(.thread-reply [data-avatar-kind="agent"])

      {_imaged, plain} =
        assert_agent_face(thread_preview_html(@image), thread_preview_html(nil), selector)

      assert letters(plain) == "H"
    end

    test "the human path in the same preview got its avatar back" do
      # Pre-existing gap this stage closed rather than reported: the preview's
      # hand-rolled `msg-avatar` div drew a bare letter for BOTH kinds, and
      # `.msg-avatar` had no rule anywhere in the stylesheet, so a human's
      # stored photo never appeared here either.
      html = thread_preview_html(nil)
      human = within(html, ~s(.thread-reply [data-avatar-kind="human"]))

      assert length(human) == 1
      assert mode(human) == "fallback"
      assert letters(human) == "DR", "humans still get up to two initials"
      refute html =~ ~s(class="msg-avatar)
    end
  end

  # ── Surface 3: the streaming reply bubble ────────────────────────────────

  describe "surface: streaming reply bubble" do
    defp streaming_html(conn, avatar_url) do
      agent = agent!("Helga Vantar", avatar_url)
      user = user!()
      space = space!()
      join_user(space, user)
      agent_participant = join_agent(space, agent)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live_at(conn, ~p"/chat/#{space.slug}")

      send(
        view.pid,
        {:agent_reply_chunk,
         %{
           space_id: space.id,
           chunk_id: "chunk-1",
           text: "thinking out loud",
           done: false,
           participant_id: agent_participant.id
         }}
      )

      render(view)
    end

    test "the face shown WHILE the agent types is the same face", %{conn: conn} do
      # Omit this site and the avatar pops in only once the stream finishes,
      # which reads as a rendering bug rather than as a missing feature.
      selector = ~s([id^="streaming-"] [data-avatar-kind="agent"])

      {imaged, plain} =
        assert_agent_face(streaming_html(conn, @image), streaming_html(conn, nil), selector)

      assert letters(plain) == "H"

      for el <- [imaged, plain] do
        assert wrapper_class(el) =~ "msg-agent-avatar"
        assert wrapper_class(el) =~ "rounded-full"
      end
    end
  end

  # ── Surface 4: the activity feed ─────────────────────────────────────────

  describe "surface: activity feed" do
    defp activity_html(conn) do
      user = user!() |> Platform.TenancyFixtures.member_of_all_orgs!()
      space = space!()
      join_user(space, user)

      for {name, avatar_url} <- [{"Pictured Agent", @image}, {"Faceless Agent", nil}] do
        participant = join_agent(space, agent!(name, avatar_url))

        {:ok, _msg} =
          Chat.post_message(%{
            space_id: space.id,
            participant_id: participant.id,
            content_type: "text",
            content: "#{name} did something worth logging"
          })

        # The feed merges TWO streams and they resolve the agent differently: a
        # message carries `author_agent_id` outright, a canvas carries only
        # `created_by` (the participant row) and has to be joined one hop
        # further out. Seed both or half the seam is unexercised.
        {:ok, _canvas, _canvas_msg} =
          Chat.create_canvas_with_message(space.id, participant.id, %{
            title: "#{name} board"
          })
      end

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, _view, html} = live(conn, ~p"/activity")
      html
    end

    test "the acting agent's row shows its face", %{conn: conn} do
      # The feed used its OWN `avatar_initial/1` over a bare name string — not
      # `PresenceHooks.avatar_initial/2` — and had no avatar source at all until
      # `Chat.list_recent_agent_actions/1` grew `:agent_avatar_url`.
      #
      # Both halves live in ONE render (the sandbox is shared, so a second
      # render would still carry the first's rows) and are told apart by MODE.
      # An unconverted feed satisfies neither selector, because the hand-rolled
      # span it used to draw stamps no `data-avatar-kind` at all.
      html = activity_html(conn)

      imaged = within(html, ~s(li [data-avatar-kind="agent"][data-avatar-mode="image"]))
      plain = within(html, ~s(li [data-avatar-kind="agent"][data-avatar-mode="fallback"]))

      assert imaged != [], "the agent WITH an avatar must render its stored image"
      assert plain != [], "the agent WITHOUT one must render the initial circle"

      assert imaged |> Floki.find("img") |> Floki.attribute("src") |> Enum.uniq() == [@image]

      assert imaged |> Floki.find("img") |> Floki.attribute("alt") |> Enum.uniq() ==
               ["Pictured Agent"]

      assert plain
             |> Floki.find(~s(span[aria-hidden="true"]))
             |> Enum.map(&(Floki.text([&1]) |> String.trim()))
             |> Enum.uniq() == ["F"]

      # The canvas half of the feed's two-stream merge resolves its agent
      # through the participant row rather than through `author_agent_id`. It is
      # a DIFFERENT query, so assert a canvas row specifically carries a face.
      canvas_rows =
        html
        |> Floki.parse_fragment!()
        |> Floki.find("li")
        |> Enum.filter(&(Floki.text([&1]) =~ "Canvas"))

      assert canvas_rows != [], "expected the feed to contain agent-created canvas rows"

      assert canvas_rows
             |> Floki.find(~s([data-avatar-kind="agent"][data-avatar-mode="image"]))
             |> Floki.find("img")
             |> Floki.attribute("src")
             |> Enum.uniq() == [@image],
             "a canvas row's agent must resolve its avatar through the participant hop"
    end
  end

  # ── Surface 5: the meeting participant rail ──────────────────────────────

  describe "surface: meeting participant rail" do
    defp rail_html(avatar_url) do
      assigns = %{
        participants: [
          %{
            id: "mp-agent",
            participant_id: "agent-1",
            participant_type: "agent",
            display_name: "Helga Vantar",
            avatar_url: avatar_url
          }
        ]
      }

      rendered_to_string(~H"""
      <PlatformWeb.Components.Meetings.ParticipantRail.participant_rail
        participants={@participants}
        agents_by_id={%{}}
        meeting={nil}
      />
      """)
    end

    # This section was calling `human_avatar/1`, which is exactly what stage 3
    # split the component apart to stop: it gave agents two initials over the
    # seeded human palette under `data-avatar-kind="human"`.
    #
    # The port of Sam's Ask mockup (shared in Suite's Meeting System
    # space) draws every agent as its `.av` circle with ONE initial, with or
    # without a stored avatar, so this surface no longer goes through
    # `assert_agent_face/3`.
    test "the agents section draws agents, not humans wearing agent names" do
      for html <- [rail_html(@image), rail_html(nil)] do
        [av] =
          html
          |> Floki.parse_fragment!()
          |> Floki.find(~s([data-participant-type="agent"] div.av))

        assert av |> Floki.find(~s(span[aria-hidden="true"])) |> Floki.text() |> String.trim() ==
                 "H"

        refute html =~ ~s(data-avatar-kind="human")
        refute html =~ "avatar-fallback-"
      end
    end
  end

  # ── Surface 6: the meeting agent tile ────────────────────────────────────

  describe "surface: meeting agent tile" do
    defp tile_html(avatar_url) do
      assigns = %{
        agent: %{id: "agent-1", name: "Helga Vantar"},
        avatar_url: avatar_url
      }

      rendered_to_string(~H"""
      <PlatformWeb.Components.Meeting.AgentTile.agent_tile
        agent_participant={@agent}
        avatar_url={@avatar_url}
      />
      """)
    end

    test "the bottom-strip tile draws the agent's face" do
      selector = ~s([data-agent-tile] [data-avatar-kind="agent"])

      {_imaged, plain} = assert_agent_face(tile_html(@image), tile_html(nil), selector)

      assert letters(plain) == "H"
      refute tile_html(nil) =~ "avatar-fallback-"
    end
  end

  # ── Surface 7: the meeting invite roster (the producer row) ──────────────

  describe "surface: meeting invite roster" do
    defp invite_html(avatar_url) do
      assigns = %{
        entry: %{
          id: "agent:producer-1",
          name: "Helga Vantar",
          subtitle: "meeting producer",
          user_id: nil,
          email: nil,
          expires_at: nil,
          external: nil,
          agent: true,
          avatar_url: avatar_url,
          removable: false,
          copy_url: nil
        }
      }

      rendered_to_string(~H"""
      <PlatformWeb.Components.Meetings.InviteControl.invite_row entry={@entry} mode={:live} />
      """)
    end

    test "the meeting producer is an agent and renders as one" do
      # `producer_rows/0` hardcoded `avatar_url: nil` with a real `%Agent{}` in
      # hand, and `invite_row/1` sent every entry through `human_avatar/1`. Both
      # halves had to change or the producer stayed faceless.
      selector = ~s([data-role="meeting-invite-row"] [data-avatar-kind="agent"])

      {_imaged, plain} = assert_agent_face(invite_html(@image), invite_html(nil), selector)

      assert letters(plain) == "H"
    end

    test "a human invitee in the same row component is untouched" do
      assigns = %{
        entry: %{
          id: "invite-1",
          name: "Dana Reed",
          subtitle: nil,
          user_id: "u-1",
          email: nil,
          expires_at: nil,
          external: false,
          agent: false,
          avatar_url: nil,
          removable: false,
          copy_url: nil
        }
      }

      html =
        rendered_to_string(~H"""
        <PlatformWeb.Components.Meetings.InviteControl.invite_row entry={@entry} mode={:live} />
        """)

      human = within(html, ~s([data-role="meeting-invite-row"] [data-avatar-kind="human"]))

      assert length(human) == 1
      assert letters(human) == "DR"
      assert within(html, ~s([data-avatar-kind="agent"])) == []
    end
  end

  # ── Surface 8: the task board assignee chip ──────────────────────────────

  describe "surface: task board assignee chip" do
    defp tasks_html(conn) do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Face Project #{System.unique_integer([:positive])}",
          repo_url: "git@github.com:test/repo.git"
        })

      for {name, avatar_url} <- [{"Pictured Agent", @image}, {"Faceless Agent", nil}] do
        {:ok, _task} =
          Tasks.create_task(%{
            project_id: project.id,
            title: "Task for #{name}",
            status: "backlog",
            priority: "medium",
            assignee_type: "agent",
            assignee_id: agent!(name, avatar_url).id
          })
      end

      user = user!() |> Platform.TenancyFixtures.member_of_all_orgs!()
      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, _view, html} = live(conn, ~p"/tasks")
      html
    end

    test "an agent assigned to a task shows its face on the card", %{conn: conn} do
      # NOT in the stage brief's inventory — found by grepping `data-avatar-kind`
      # rather than the hand-rolled circle shapes the brief searched for. The
      # chip already STAMPED `data-avatar-kind="agent"` by hand while being
      # structurally incapable of ever showing an image.
      #
      # The board draws each card twice (a desktop row and a mobile twin), so
      # this asserts over the SET of chips per agent rather than a single node.
      html = tasks_html(conn)

      imaged = within(html, ~s([data-avatar-kind="agent"][data-avatar-mode="image"]))
      plain = within(html, ~s([data-avatar-kind="agent"][data-avatar-mode="fallback"]))

      assert imaged != [], "no agent assignee chip rendered for the agent with an avatar"
      assert plain != [], "no agent assignee chip rendered for the agent without one"

      assert imaged |> Floki.find("img") |> Floki.attribute("src") |> Enum.uniq() == [@image]

      assert imaged |> Floki.find("img") |> Floki.attribute("alt") |> Enum.uniq() ==
               ["Pictured Agent"]

      assert plain
             |> Floki.find(~s(span[aria-hidden="true"]))
             |> Enum.map(&(Floki.text([&1]) |> String.trim()))
             |> Enum.uniq() == ["F"]
    end
  end

  # ── Surface 9: the inline-thread @mention dropdown ───────────────────────

  describe "surface: inline-thread mention dropdown" do
    defp mention_dropdown_html(avatar_url) do
      msg = %{
        id: "msg-1",
        space_id: "space-1",
        participant_id: "p-human",
        content: "root",
        content_type: "text",
        canvas_id: nil,
        inserted_at: ~U[2026-08-15 10:00:00.000000Z],
        day_label: nil,
        reactions: [],
        versions_count: 1,
        corrects_message_id: nil
      }

      assigns = %{
        msg: msg,
        suggestions: [
          %{
            participant_type: "agent",
            name: "Helga Vantar",
            display_name: "Helga Vantar",
            avatar_url: avatar_url,
            avatar_seed: "agent-seed"
          },
          %{
            participant_type: "user",
            name: "Dana Reed",
            display_name: "Dana Reed",
            avatar_url: nil,
            avatar_seed: "seed-dana"
          },
          %{
            participant_type: "broadcast",
            name: "here",
            display_name: "here",
            avatar_url: nil,
            avatar_seed: nil
          }
        ]
      }

      rendered_to_string(~H"""
      <PlatformWeb.Components.ChatMessage.chat_message
        dom_id="row-1"
        msg={@msg}
        current_participant={nil}
        agent_participant_ids={MapSet.new()}
        agent_colors_map={%{}}
        participants_map={%{"p-human" => %{name: "Dana Reed", avatar_url: nil, avatar_seed: "s"}}}
        quick_emojis={[]}
        pinned_message_ids={MapSet.new()}
        canvases_by_id={%{}}
        attachments_map={%{}}
        thread_previews={%{}}
        expanded_threads={MapSet.new(["msg-1"])}
        inline_thread_messages={%{}}
        mention_suggestions={@suggestions}
        mention_source="inline-thread-compose-form-msg-1"
      />
      """)
    end

    test "an agent you can @mention shows its face in the suggestion row" do
      # This dropdown had NO kind branch at all — agents, humans and the `here`
      # sentinel alike got one hand-rolled letter. Scoped to the dropdown so the
      # thread-reply and chat-row sites cannot satisfy it.
      selector =
        ~s([data-mention-suggestion] [data-avatar-kind="agent"], button [data-avatar-kind="agent"])

      {_imaged, plain} =
        assert_agent_face(mention_dropdown_html(@image), mention_dropdown_html(nil), selector)

      assert letters(plain) == "H"
    end

    test "the human and broadcast rows beside it keep their own treatments" do
      html = mention_dropdown_html(nil)

      human = within(html, ~s(button [data-avatar-kind="human"]))
      assert length(human) == 1
      assert letters(human) == "DR"

      # `@here` is a broadcast sentinel, not a principal — it keeps the
      # megaphone the main compose dropdown gives it rather than borrowing a
      # person's avatar treatment.
      assert within(html, ~s(button .hero-megaphone)) != []
    end
  end

  # ── Surface 10: the /chat quick-meet roster ──────────────────────────────

  describe "surface: chat meeting roster" do
    defp roster_html(avatar_url) do
      assigns = %{
        participants: [
          %{
            participant_type: "agent",
            participant_id: "agent-1",
            display_name: "Helga Vantar",
            avatar_url: avatar_url
          },
          %{
            participant_type: "user",
            participant_id: "user-1",
            display_name: "Dana Reed",
            avatar_url: nil
          }
        ]
      }

      rendered_to_string(~H"""
      <PlatformWeb.ChatLive.Partials.meeting_roster id="roster" participants={@participants} />
      """)
    end

    test "the authoritative who-is-present list shows the agent's face" do
      # Drew `roster_initial/1` — a bitstring-pattern initial helper the usual
      # `String.first` greps never found — over a flat circle for every kind.
      selector = ~s([data-role="meeting-roster-row"] [data-avatar-kind="agent"])

      {_imaged, plain} = assert_agent_face(roster_html(@image), roster_html(nil), selector)

      assert letters(plain) == "H"

      human =
        within(roster_html(nil), ~s([data-role="meeting-roster-row"] [data-avatar-kind="human"]))

      assert length(human) == 1
      assert letters(human) == "DR"
    end
  end

  # ── Surface 11: the Control Center roles panel ───────────────────────────

  describe "surface: control center roles panel" do
    defp roles_panel_html(avatar_url) do
      assigns = %{
        agent: %{
          id: "agent-1",
          name: "Helga Vantar",
          avatar_url: avatar_url,
          kind: "internal",
          external_endpoint_id: nil
        }
      }

      rendered_to_string(~H"""
      <PlatformWeb.ControlCenter.RolesPanel.panel
        roles={[
          %{
            key: "producer",
            name: "Producer",
            description: "Runs the meeting",
            icon: "hero-cpu-chip"
          }
        ]}
        role_bundles={%{}}
        role_assignments_by_key={%{"producer" => @agent}}
        selectable_agents={[]}
      />
      """)
    end

    test "the agent holding a role shows its face, with ONE initial not two" do
      # This cell drew `String.slice(name, 0, 2)` — two letters, the
      # human-shaped treatment the component split exists to stop.
      selector = ~s([data-avatar-kind="agent"])

      {_imaged, plain} =
        assert_agent_face(roles_panel_html(@image), roles_panel_html(nil), selector)

      assert letters(plain) == "H",
             "the roles panel used to render TWO letters here; agents get one"
    end
  end
end
