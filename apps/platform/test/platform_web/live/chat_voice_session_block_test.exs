defmodule PlatformWeb.ChatVoiceSessionBlockTest do
  @moduledoc """
  The Voice chat session bracket in the user<->agent DM (task 01a1b6c3
  stage 3, design canvas 01a1b6c4 nodes `layout`, `pal`, `type`, `crit`).

  Sessions are seeded through `VoiceSession.record_turn/5` and
  `VoiceSession.finish/1`, the same writers the Voice tab uses, against a
  session map built from the DM directly (no LiveKit, no worker).

  Named mutations (each must red a case here): drop the header from the
  turn row; break the "over 10 turns" collapse threshold; swap the label's
  `--color-info` for another token.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.SpaceAccess
  alias Platform.Meetings.VoiceSession
  alias Platform.Repo

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "voice-block-#{n}@example.com",
      name: "Test User #{n}",
      oidc_sub: "oidc-voice-block-#{n}",
      preferences: %{"first_run_goal" => "existing"}
    })
  end

  defp agent! do
    n = System.unique_integer([:positive])

    %Agent{}
    |> Agent.changeset(%{slug: "helper-#{n}", name: "Helper Agent", status: "active"})
    |> Repo.insert!()
  end

  defp channel!(user, name) do
    {:ok, space} =
      Chat.create_space(%{
        name: name,
        slug: "#{name}-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    space
  end

  # A session map as `VoiceSession.start/3` returns it, minus the room.
  defp session!(user, agent, started_at \\ nil) do
    {:ok, dm} = Chat.find_or_create_dm(user.id, "agent", agent.id)
    {:ok, up} = SpaceAccess.authorize_writer(dm.id, user)
    {:ok, ap} = SpaceAccess.authorize_writer(dm.id, {:agent, agent.id})

    %{
      id: Platform.Types.UUIDv7.generate(),
      started_at: started_at || DateTime.add(DateTime.utc_now(), -12 * 60, :second),
      space_id: dm.id,
      agent_id: agent.id,
      user_participant_id: up.id,
      agent_participant_id: ap.id
    }
  end

  defp turns!(session, user, n, opts \\ []) do
    Enum.reduce(1..n//1, session, fn i, acc ->
      who = if rem(i, 2) == 1, do: :me, else: :agent
      {:ok, acc, _} = VoiceSession.record_turn(acc, user, who, "line #{i}", opts)
      acc
    end)
  end

  defp finished!(user, agent, n) do
    session = user |> session!(agent) |> turns!(user, n)
    {:ok, _summary} = VoiceSession.finish(session)
    session
  end

  defp open_dm(conn, user, session) do
    {:ok, view, _html} =
      conn |> init_test_session(current_user_id: user.id) |> live(~p"/chat/#{session.space_id}")

    view
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()
  defp q(doc, sel), do: LazyHTML.query(doc, sel)
  defp count(doc, sel), do: doc |> q(sel) |> Enum.count()
  defp text(doc, sel), do: doc |> q(sel) |> LazyHTML.text() |> String.trim()
  defp classes(doc, sel), do: doc |> q(sel) |> LazyHTML.attribute("class") |> Enum.join(" ")

  defp rows(doc, session), do: q(doc, "#message-list [data-voice-session='#{session.id}']")

  defp hidden_turns(doc, session) do
    count(doc, "#message-list [data-voice-session='#{session.id}'][data-voice-middle]")
  end

  describe "a finished 18-turn session" do
    setup %{conn: conn} do
      user = user!()
      agent = agent!()
      session = finished!(user, agent, 18)
      %{view: open_dm(conn, user, session), session: session}
    end

    test "opens with the header band on its first turn", %{view: view, session: session} do
      doc = doc(view)
      assert count(doc, "[data-role='voice-session-header']") == 1

      head_row = q(doc, "#message-list [data-voice-head]")
      assert Enum.count(head_row) == 1
      assert head_row |> LazyHTML.attribute("data-voice-session") == [session.id]
      assert head_row |> LazyHTML.query("[data-role='voice-session-header']") |> Enum.count() == 1
      assert head_row |> LazyHTML.text() =~ "line 1"

      header = text(doc, "[data-role='voice-session-header']")
      assert header =~ "Voice chat"
      assert header =~ ~r/\d{1,2} [A-Z][a-z]{2} \d{2}:\d{2}/
      assert header =~ "12 min"
      assert header =~ "18 turns"
    end

    test "starts collapsed to the first two and last two turns", %{view: view, session: session} do
      doc = doc(view)
      # 18 turns + 1 summary row in the bracket; 14 middle turns hidden.
      assert Enum.count(rows(doc, session)) == 19
      assert hidden_turns(doc, session) == 14

      shown =
        doc
        |> q("#message-list [data-voice-session='#{session.id}'][data-message-id]:not(.hidden)")
        |> LazyHTML.text()

      for i <- [1, 2, 17, 18], do: assert(shown =~ ~r/\bline #{i}\b/)
      for i <- 3..16, do: refute(shown =~ ~r/\bline #{i}\b/)

      hidden =
        doc
        |> q("#message-list [data-voice-middle]")
        |> Enum.map(&LazyHTML.text/1)
        |> Enum.join(" ")

      for i <- 3..16, do: assert(hidden =~ ~r/\bline #{i}\b/)

      assert doc
             |> q("#message-list [data-voice-middle]")
             |> LazyHTML.attribute("class")
             |> Enum.all?(&(&1 =~ ~r/\bhidden\b/))

      assert text(doc, "[data-role='voice-show-all']") == "Show all 18 turns"
      # The band sits on the SECOND turn, which stays on screen.
      second =
        q(
          doc,
          "#message-list [data-voice-session='#{session.id}']:not(.hidden) [data-role='voice-show-all']"
        )

      assert Enum.count(second) == 1
    end

    test "Show all and Collapse are JS toggles over the session's middle rows", %{
      view: view,
      session: session
    } do
      doc = doc(view)
      target = "[data-voice-session='#{session.id}'][data-voice-middle]"

      [show_click] = doc |> q("[data-role='voice-show-all']") |> LazyHTML.attribute("phx-click")
      assert show_click =~ "remove_class"
      assert show_click =~ Jason.encode!(target) |> String.trim("\"")
      assert show_click =~ "chat:regroup"

      [collapse] = doc |> q("[data-role='voice-collapse']") |> LazyHTML.attribute("phx-click")
      assert collapse =~ "add_class"
      assert collapse =~ "chat:regroup"
      assert text(doc, "[data-role='voice-collapse']") == "Collapse"
      # Collapsed is the starting state, so Collapse starts hidden.
      assert classes(doc, "[data-role='voice-collapse']") =~ ~r/\bhidden\b/
    end

    test "ends with the summary card and the footer", %{view: view} do
      doc = doc(view)
      assert text(doc, "[data-role='voice-summary-card']") == "Voice chat · 18 turns · 12 min"
      footer = text(doc, "[data-role='voice-footer']")
      assert footer =~ "End of voice chat"
      assert footer =~ "Open on Voice tab"
      assert doc |> q("[data-role='voice-footer'] a") |> LazyHTML.attribute("href") == ["/voice"]
      # The summary row is its own run: an empty participant id for grouping.
      assert doc
             |> q("#message-list [data-voice-kind='summary']")
             |> LazyHTML.attribute("data-participant-id") == [""]
    end

    test "uses the palette tokens only", %{view: view} do
      doc = doc(view)
      assert classes(doc, "[data-role='voice-session-header']") =~ "bg-base-200"
      assert classes(doc, "[data-role='voice-show-all']") =~ "bg-base-200"
      assert classes(doc, "[data-role='voice-summary']") =~ "bg-base-200"
      assert classes(doc, "[data-role='voice-label']") =~ ~r/\btext-info\b/

      meta = doc |> q("[data-role='voice-meta']") |> LazyHTML.attribute("class")
      assert length(meta) == 3
      assert Enum.all?(meta, &(&1 =~ "font-mono" and &1 =~ ~r/\btext-neutral\b/))

      mics = doc |> q("[data-role='voice-mic']") |> LazyHTML.attribute("class")
      assert length(mics) == 18
      assert Enum.all?(mics, &(&1 =~ ~r/\btext-neutral\b/))

      bracket =
        Enum.join(
          [
            classes(
              doc,
              "[data-role='voice-session-header'], [data-role='voice-session-header'] *"
            ),
            classes(doc, "[data-role='voice-show-all']"),
            classes(doc, "[data-role='voice-summary'], [data-role='voice-summary'] *")
          ],
          " "
        )

      refute bracket =~ ~r/primary|warning|orange|accent/
      # "Voice chat" is the ONE info-coloured element.
      assert count(doc, "[data-role='voice-session-header'] .text-info") == 1
    end

    test "never words the record as a file, an ingest or an id", %{view: view} do
      html = view |> render() |> String.downcase()
      refute html =~ "transcript.txt"
      refute html =~ "transcript ingest"
      refute html =~ "session id"
    end
  end

  describe "the collapse threshold" do
    test "10 turns stay open; 11 collapse", %{conn: conn} do
      user = user!()
      agent = agent!()
      ten = finished!(user, agent, 10)
      eleven = finished!(user, agent, 11)
      doc = conn |> open_dm(user, eleven) |> doc()

      assert hidden_turns(doc, ten) == 0
      assert count(doc, "#voice-show-all-#{ten.id}") == 0
      assert count(doc, "#voice-collapse-#{ten.id}") == 0

      assert hidden_turns(doc, eleven) == 7
      assert text(doc, "#voice-show-all-#{eleven.id}") == "Show all 11 turns"
    end
  end

  describe "a session in progress" do
    test "shows the date only, and is completed live by its summary", %{conn: conn} do
      user = user!()
      agent = agent!()
      session = user |> session!(agent) |> turns!(user, 12)
      view = open_dm(conn, user, session)

      doc = doc(view)
      header = text(doc, "[data-role='voice-session-header']")
      assert header =~ "Voice chat"
      refute header =~ "min"
      refute header =~ "turns"
      assert count(doc, "[data-role='voice-meta']") == 1
      assert hidden_turns(doc, session) == 0
      assert count(doc, "[data-role='voice-footer']") == 0

      # The summary lands while the DM is open: the header learns its length
      # and count, and the long session collapses, without a reload.
      {:ok, _} = VoiceSession.finish(session)
      _ = render(view)
      doc = doc(view)

      assert text(doc, "[data-role='voice-session-header']") =~ "12 turns"
      assert hidden_turns(doc, session) == 8
      assert text(doc, "[data-role='voice-show-all']") == "Show all 12 turns"
      assert count(doc, "[data-role='voice-footer']") == 1
    end
  end

  describe "a session with a context" do
    test "the DM shows one pointer line linking to the context", %{conn: conn} do
      user = user!()
      agent = agent!()
      ctx = channel!(user, "general-test")
      context = %{id: ctx.id, name: "general-test"}
      session = session!(user, agent)

      session =
        Enum.reduce(1..4, session, fn i, acc ->
          who = if rem(i, 2) == 1, do: :me, else: :agent
          {:ok, acc, _} = VoiceSession.record_turn(acc, user, who, "said #{i}", context: context)
          acc
        end)

      {:ok, _} = VoiceSession.finish(session)
      doc = conn |> open_dm(user, session) |> doc()

      assert text(doc, "[data-role='voice-pointer']") == "Your side was posted to #general-test"

      assert doc |> q("[data-role='voice-pointer'] a") |> LazyHTML.attribute("href") ==
               ["/chat/#{Chat.space_path_segment(ctx)}"]

      # The pointer is the session's first DM row, so it carries the header.
      assert count(
               doc,
               "#message-list [data-voice-kind='context_pointer'] [data-role='voice-session-header']"
             ) == 1

      assert count(doc, "[data-role='voice-session-header']") == 1
      # The user's lines are not in the DM.
      refute doc |> q("#message-list") |> LazyHTML.text() =~ "said 1"
      assert doc |> q("#message-list") |> LazyHTML.text() =~ "said 2"
    end
  end
end
