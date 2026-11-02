defmodule PlatformWeb.FirstRunLiveTest do
  @moduledoc "`/start`, the first-run goal box (task 01a19554-fd07 stage 2)."
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.AgentHost.State
  alias Platform.Agents.NativeAgents
  alias Platform.Chat.{Message, Participant, Space}
  alias Platform.Onboarding.FirstRunGoal
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  defp member!(prefs \\ %{}) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "first-run-#{n}@example.com",
        name: "First Run #{n}",
        oidc_sub: "first-run-#{n}",
        preferences: prefs
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: acme_org_id(), role: "member"})
    |> Repo.insert!()

    user
  end

  defp authed(user), do: build_conn() |> init_test_session(current_user_id: user.id)

  defp running_burrow! do
    {:ok, agent, _runtime} =
      NativeAgents.create(member!().id, %{name: "Burrow", harness: "claude_code"})

    State.init_table()
    State.put(agent.id, :running)

    on_exit(fn ->
      if :ets.whereis(State.table()) != :undefined, do: :ets.delete(State.table(), agent.id)
    end)

    agent
  end

  defp goal_message_count do
    Repo.aggregate(
      from(m in Message, where: fragment("?->>'source' = 'first_run_goal'", m.metadata)),
      :count
    )
  end

  defp goal_channels(user) do
    Repo.all(
      from(s in Space,
        where:
          s.created_by == ^user.id and
            fragment("?->>'origin' = 'first_run_goal'", s.metadata)
      )
    )
  end

  defp dm_count(user) do
    Repo.aggregate(
      from(s in Space,
        join: p in Participant,
        on: p.space_id == s.id,
        where: s.kind == "dm" and p.participant_type == "user" and p.participant_id == ^user.id
      ),
      :count
    )
  end

  defp start!(user) do
    {:ok, view, _html} = live(authed(user), "/start")
    view
  end

  test "renders question, helper, placeholder, three chips and Skip for now" do
    view = start!(member!())
    html = render(view)

    assert view |> element("label[data-role=first-run-question][for=first-run-input]") |> render() =~
             "What do you want to do?"

    assert view |> element("[data-role=first-run-helper]") |> render() =~
             "Describe a goal in your own words. Burrow will take it from there."

    input = view |> element("textarea[data-role=first-run-input]") |> render()
    assert input =~ ~s(placeholder="e.g. Plan our team&#39;s work for this week")
    assert input =~ ~s(rows="3")

    chips =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-role=first-run-chip]")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    assert chips == FirstRunGoal.example_goals()

    assert chips == [
             "Plan this week's work",
             "Start a project with my team",
             "Turn my to-do list into tasks"
           ]

    assert view |> element("button[data-role=first-run-skip]") |> render() =~ "Skip for now"

    # The shell's mobile header names the page, not the module.
    assert html =~ "Get started"
    refute html =~ ~r/>\s*FirstRun\s*</
    refute html =~ "first-run-no-agent"
    refute html =~ "first-run-error"
  end

  test "Send is disabled while the goal is blank" do
    view = start!(member!())

    assert has_element?(view, "button[data-role=first-run-send][disabled]")

    view |> element("#first-run-form") |> render_change(%{"goal" => "   \n "})
    assert has_element?(view, "button[data-role=first-run-send][disabled]")

    view |> element("#first-run-form") |> render_change(%{"goal" => "Plan"})
    refute has_element?(view, "button[data-role=first-run-send][disabled]")
  end

  test "chip click fills the goal and posts nothing" do
    running_burrow!()
    user = member!()
    view = start!(user)
    before = goal_message_count()

    view
    |> element("button[data-role=first-run-chip]", "Start a project with my team")
    |> render_click()

    assert_push_event(view, "first_run:fill", %{goal: "Start a project with my team"})

    assert view |> element("textarea[data-role=first-run-input]") |> render() =~
             "Start a project with my team"

    refute has_element?(view, "button[data-role=first-run-send][disabled]")

    assert goal_message_count() == before
    assert goal_message_count() == 0
    assert FirstRunGoal.pending?(user)
  end

  test "submit navigates to the new channel with Burrow, with the info flash" do
    running_burrow!()
    user = member!()
    view = start!(user)

    view
    |> element("#first-run-form")
    |> render_submit(%{"goal" => "  Help me plan this week's work for my team "})

    {path, flash} = assert_redirect(view)
    assert flash["info"] == "Burrow is on it. This conversation stays in your sidebar."

    assert [channel] = goal_channels(user)
    assert channel.kind == "channel"
    assert path == "/chat/#{PlatformWeb.ChatLive.space_nav_target(channel)}"
    assert path == "/chat/#{channel.id}"
    assert dm_count(user) == 0

    [msg] = Repo.all(from(m in Message, where: m.space_id == ^channel.id))
    assert msg.content == "Help me plan this week's work for my team"
    refute FirstRunGoal.pending?(user)
  end

  test "no running Burrow shows the inline notice and keeps the goal" do
    user = member!()
    view = start!(user)

    html =
      view
      |> element("#first-run-form")
      |> render_submit(%{"goal" => "Start a project with my team"})

    assert view |> element("[data-role=first-run-no-agent]") |> render() =~
             "Burrow isn&#39;t set up on this workspace yet. Your admin can connect it."

    assert view |> element("textarea[data-role=first-run-input]") |> render() =~
             "Start a project with my team"

    assert html =~ "Skip for now"
    refute html =~ "first-run-error"
    assert goal_message_count() == 0
    assert goal_channels(user) == []
    assert dm_count(user) == 0
    assert FirstRunGoal.pending?(user)
  end

  test "a failed send shows the error line and keeps the goal" do
    running_burrow!()
    user = member!()
    view = start!(user)

    # A real non-:no_agent failure: the member turns external after the page
    # mounted, so submit/3 refuses with :not_pending and posts nothing.
    {:ok, _} =
      Platform.Tenancy.mark_membership_external(%{user_id: user.id, org_id: acme_org_id()})

    view |> element("#first-run-form") |> render_submit(%{"goal" => "Plan this week's work"})

    assert view |> element("[data-role=first-run-error]") |> render() =~
             "That didn&#39;t send. Try again."

    assert view |> element("textarea[data-role=first-run-input]") |> render() =~
             "Plan this week&#39;s work"

    assert goal_message_count() == 0
  end

  test "skip marks skipped and navigates to /chat" do
    user = member!()
    view = start!(user)

    view |> element("button[data-role=first-run-skip]") |> render_click()

    assert_redirect(view, "/chat")
    assert Accounts.get_user_preferences(user.id)["first_run_goal"] == "skipped"
    assert goal_message_count() == 0
  end

  test "a non-pending member at /start is sent to /chat" do
    for value <- ["submitted", "skipped", "existing"] do
      user = member!(%{"first_run_goal" => value})

      assert {:error, {:live_redirect, %{to: "/chat"}}} = live(authed(user), "/start")
    end
  end

  test "primary appears only on Send" do
    view = start!(member!())

    # The page's own subtree. The shell around it (sidebar, unread dot) has
    # its own primary uses, which this feature does not own.
    tree = view |> element("[data-role=first-run]") |> render() |> LazyHTML.from_fragment()

    holders =
      tree
      |> LazyHTML.query("[class*=primary]")
      |> Enum.map(&(&1 |> LazyHTML.attribute("data-role") |> List.first()))

    assert holders == ["first-run-send"]

    send_classes =
      tree
      |> LazyHTML.query("[data-role=first-run-send]")
      |> LazyHTML.attribute("class")
      |> List.first()
      |> String.split()
      |> Enum.filter(&(&1 =~ "primary"))

    assert Enum.sort(send_classes) == ["bg-primary", "text-primary-content"]
  end
end
