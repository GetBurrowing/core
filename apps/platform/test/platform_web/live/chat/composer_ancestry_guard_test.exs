defmodule PlatformWeb.ChatLive.ComposerAncestryGuardTest do
  @moduledoc """
  Structural guard for the composer field's focus (redesign rung 10, stage 5;
  gate case 7007).

  The chat field (`#compose_text`) and the thread reply field are
  contenteditables. When a LiveView patch inserts a node among the siblings
  of any of their ancestors, AHEAD of that ancestor, LiveView's DOM patch
  re-appends every sibling after the inserted node, and a moved
  contenteditable loses focus. LiveView restores focus only for textual
  inputs, so the field stays blurred and a phone keyboard drops. Measured on
  the dev rig: the typing indicator, a first streaming bubble, a thread reply
  arriving, and the jump-to-latest chip each blurred the field this way.

  What comes and goes there therefore lives inside an always-rendered,
  box-less slot (`class="contents"`) or an always-rendered wrapper whose
  contents alone are conditional.

  This guard pins the rule rather than the cases. For every ancestor of the
  field, the list of its preceding siblings (by id, data-role, or tag and
  class) must be IDENTICAL across every state that can change while someone
  is typing. A new conditional sibling anywhere on that chain changes the
  list in the state that shows it, and the test names the state and the
  ancestor.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Repo

  # ── the signature ─────────────────────────────────────────────────────────

  # For each ancestor of the element with `id`, innermost first: the
  # ancestor's own key and the keys of its element siblings that precede it.
  def chain_signature(html, id) do
    tree = html |> LazyHTML.from_fragment() |> LazyHTML.to_tree()

    case path_to(tree, id) do
      nil -> raise "no ##{id} in the render"
      path -> Enum.reverse(path)
    end
  end

  defp path_to(nodes, id) when is_list(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.find_value(fn
      {{tag, attrs, children} = node, i} when is_binary(tag) ->
        level = {key(node), nodes |> Enum.take(i) |> Enum.flat_map(&element_key/1)}

        cond do
          attr(attrs, "id") == id -> [level]
          sub = path_to(children, id) -> [level | sub]
          true -> nil
        end

      _ ->
        nil
    end)
  end

  defp element_key({tag, _attrs, _children} = node) when is_binary(tag), do: [key(node)]
  defp element_key(_), do: []

  defp key({tag, attrs, _children}) do
    cond do
      id = attr(attrs, "id") -> "##{id}"
      role = attr(attrs, "data-role") -> "#{tag}[data-role=#{role}]"
      true -> "#{tag}.#{attrs |> attr("class") |> to_string() |> String.split() |> List.first()}"
    end
  end

  defp attr(attrs, name) do
    Enum.find_value(attrs, fn
      {^name, value} -> value
      _ -> nil
    end)
  end

  # The first ancestor level where two signatures differ, for the message.
  defp first_difference(a, b) do
    Enum.zip(a, b) |> Enum.find(fn {x, y} -> x != y end) ||
      {:depth, length(a), length(b)}
  end

  defp assert_same_chain(states, field_id) do
    [{base_name, base_html} | rest] = states
    base = chain_signature(base_html, field_id)

    for {name, html} <- rest do
      sig = chain_signature(html, field_id)

      assert sig == base,
             "the ancestors of ##{field_id} gained or lost a preceding sibling in " <>
               "state #{inspect(name)} (vs #{inspect(base_name)}). First difference " <>
               "(ancestor, preceding siblings): #{inspect(first_difference(base, sig))}. " <>
               "Put what comes and goes in an always-rendered slot."
    end
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp login(conn) do
    user =
      Repo.insert!(%User{
        email: "ancestry_#{System.unique_integer([:positive])}@example.com",
        name: "Ancestry User",
        oidc_sub: "oidc-ancestry-#{System.unique_integer([:positive])}"
      })

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp new_space do
    slug = "ancestry-#{System.unique_integer([:positive])}"

    {:ok, space} =
      Chat.create_space(%{name: String.capitalize(slug), slug: slug, kind: "channel"})

    space
  end

  defp join(space, type, id, name) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: type,
        participant_id: id,
        display_name: name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp new_agent do
    Repo.insert!(%Agent{
      slug: "ancestry-agent-#{System.unique_integer([:positive])}",
      name: "Ancestry Agent",
      status: "active",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    })
  end

  defp count(html, selector),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()

  # ── the space composer ────────────────────────────────────────────────────

  describe "#compose_text" do
    test "every ancestor keeps the same preceding siblings in every state that changes while typing",
         %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space()
      me = join(space, "user", user.id, user.name)
      agent = new_agent()
      bot = join(space, "agent", agent.id, agent.name)

      {:ok, msg} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: me.id,
          content_type: "text",
          content: "a message to pin"
        })

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      idle = render(view)

      # Each state is entered, rendered, checked to be REAL (anti-vacuity),
      # and left again, so the next starts from idle.
      send(view.pid, {:agent_typing, %{space_id: space.id, participant_id: bot.id, typing: true}})
      typing = render(view)
      assert count(typing, "#chat-typing-indicator[data-typing=true]") == 1

      send(
        view.pid,
        {:agent_typing, %{space_id: space.id, participant_id: bot.id, typing: false}}
      )

      chunk = %{space_id: space.id, chunk_id: "anc-1", participant_id: bot.id}
      send(view.pid, {:agent_reply_chunk, Map.merge(chunk, %{text: "working", done: false})})
      streaming = render(view)
      assert count(streaming, "#streaming-anc-1") == 1
      send(view.pid, {:agent_reply_chunk, Map.merge(chunk, %{text: "", done: true})})

      render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => true})
      jump = render(view)
      assert count(jump, ".chat-jump-anchor") == 1
      render_hook(view, "jump_to_latest_distance", %{"away" => false, "deep" => false})

      render_hook(view, "mention_query", %{"query" => "", "source" => "compose-form"})
      mention = render(view)
      assert count(mention, "#compose-mention-list [role=option]") > 0
      render_hook(view, "mention_query", %{})

      render_click(view, "attach_menu_open", %{})
      attach = render(view)
      assert count(attach, "[data-role=attach-popover-anchor]") == 1
      render_click(view, "attach_menu_close", %{})

      upload =
        file_input(view, "#compose-form", :attachments, [
          %{name: "shot.png", content: String.duplicate("p", 1000), type: "image/png"}
        ])

      render_upload(upload, "shot.png")
      staged = render(view)
      assert count(staged, "[data-role=staged-tray]") == 1

      render_submit(view, "search_submit", %{"search" => %{"query" => "pin"}})
      search = render(view)
      assert count(search, "#chat-drawers-slot > *") > 0
      render_click(view, "search_clear", %{})

      render_click(view, "canvas_panel_toggle", %{})
      canvases = render(view)
      assert count(canvases, "#chat-drawers-slot > *") > 0
      render_click(view, "canvas_panel_toggle", %{})

      render_click(view, "pin_toggle", %{"message-id" => msg.id, "space-id" => space.id})
      _ = render(view)
      render_click(view, "pin_panel_toggle", %{})
      pins = render(view)
      assert count(pins, "#chat-drawers-slot > *") > 0
      render_click(view, "pin_panel_toggle", %{})

      render_hook(view, "push_permission_state", %{"state" => "prompt"})
      banner = render(view)
      assert count(banner, "#chat-notification-banner-slot > *") == 1

      assert_same_chain(
        [
          {:idle, idle},
          {:typing, typing},
          {:streaming, streaming},
          {:jump_chip, jump},
          {:mention_list, mention},
          {:attach_menu, attach},
          {:staged_tray, staged},
          {:search_drawer, search},
          {:canvases_drawer, canvases},
          {:pins_drawer, pins},
          {:notification_banner, banner}
        ],
        "compose_text"
      )
    end

    # The reviewer's ask in its plainest form: #chat-dock's direct children,
    # by key, are one fixed list whatever is on screen.
    test "#chat-dock's direct children are the same set, in the same order, in every state",
         %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space()
      join(space, "user", user.id, user.name)
      agent = new_agent()
      bot = join(space, "agent", agent.id, agent.name)

      {:ok, view, idle} = live(conn, ~p"/chat/#{space.slug}")

      kids = fn html ->
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#chat-dock > *")
        |> Enum.map(fn node ->
          LazyHTML.attribute(node, "id") |> List.first() ||
            LazyHTML.attribute(node, "data-role") |> List.first() ||
            LazyHTML.attribute(node, "class") |> List.first()
        end)
      end

      jump_on = render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => true})
      send(view.pid, {:agent_typing, %{space_id: space.id, participant_id: bot.id, typing: true}})
      typing_and_jump = render(view)

      send(
        view.pid,
        {:agent_reply_chunk,
         %{space_id: space.id, chunk_id: "dock-k", text: "x", done: false, participant_id: bot.id}}
      )

      all_three = render(view)
      jump_off = render_hook(view, "jump_to_latest_distance", %{"away" => false, "deep" => false})

      base = kids.(idle)

      assert base == [
               "chat-streaming-replies",
               "chat-jump-slot",
               "chat-typing-indicator",
               "flex-shrink-0 compose-input-area safe-area-bottom"
             ]

      for {name, html} <- [
            jump_on: jump_on,
            typing_and_jump: typing_and_jump,
            all_three: all_three,
            jump_off: jump_off
          ] do
        assert kids.(html) == base, "#chat-dock's children changed in state #{name}"
      end

      # Anti-vacuity: the states really showed what they name.
      assert count(jump_on, ".chat-jump-anchor") == 1
      assert count(typing_and_jump, "#chat-typing-indicator[data-typing=true]") == 1
      assert count(all_three, "#streaming-dock-k") == 1
      assert count(jump_off, ".chat-jump-anchor") == 0
    end
  end

  # ── the thread reply field ────────────────────────────────────────────────

  describe "the thread reply field" do
    defp msg(reactions) do
      %{
        id: "msg-1",
        space_id: "space-1",
        participant_id: "p-human",
        content: "root",
        content_type: "text",
        canvas_id: nil,
        inserted_at: ~U[2026-10-23 10:00:00.000000Z],
        day_label: nil,
        reactions: reactions,
        versions_count: 1,
        corrects_message_id: nil
      }
    end

    defp reply(id),
      do: %{
        id: id,
        space_id: "space-1",
        participant_id: "p-human",
        content: "reply #{id}",
        inserted_at: ~U[2026-10-23 10:01:00.000000Z]
      }

    defp row(opts) do
      assigns = %{
        msg: msg(Keyword.get(opts, :reactions, [])),
        replies: Keyword.get(opts, :replies, []),
        refused: Keyword.get(opts, :refused, %{}),
        source: Keyword.get(opts, :source)
      }

      rendered_to_string(~H"""
      <PlatformWeb.Components.ChatMessage.chat_message
        dom_id="row-1"
        msg={@msg}
        current_participant={%{id: "p-human"}}
        agent_participant_ids={MapSet.new()}
        participants_map={%{"p-human" => %{name: "Dana Reed", avatar_url: nil, avatar_seed: "s"}}}
        quick_emojis={[]}
        pinned_message_ids={MapSet.new()}
        canvases_by_id={%{}}
        attachments_map={%{}}
        thread_previews={%{}}
        expanded_threads={MapSet.new(["msg-1"])}
        inline_thread_messages={%{"msg-1" => @replies}}
        refused_summons={@refused}
        mention_suggestions={[
          %{
            participant_type: "agent",
            name: "Builder",
            display_name: "Builder",
            avatar_url: nil,
            avatar_seed: "b",
            not_in_space: false
          }
        ]}
        mention_source={@source}
        mention_query=""
      />
      """)
    end

    test "every ancestor keeps the same preceding siblings in every state that changes while replying" do
      reaction = %{emoji: "ok", count: 1, reacted_by_me: false, reactors: [], extra_count: 0}

      states = [
        idle: row([]),
        reply_arrived: row(replies: [reply("r-1")]),
        two_replies: row(replies: [reply("r-1"), reply("r-2")]),
        reaction_added: row(reactions: [reaction]),
        refused_summon: row(refused: %{"msg-1" => ["Builder"]}),
        mention_list_open: row(source: "inline-thread-compose-form-msg-1")
      ]

      # Anti-vacuity.
      assert count(states[:reaction_added], ".reaction-row") == 1
      assert count(states[:two_replies], ".thread-reply") == 2
      assert count(states[:mention_list_open], "#inline-thread-mention-list-msg-1") == 1
      assert states[:refused_summon] != states[:idle]

      assert_same_chain(states, "inline-thread-compose-msg-1")
    end
  end
end
