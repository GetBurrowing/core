defmodule PlatformWeb.SettingsLearnedDefaultsTest do
  @moduledoc """
  Settings → Learned defaults (task 01a1b6a1 stage 4): the learning switch
  writes the per-user preference through `Platform.Habits.set_enabled/2`,
  the list shows only the viewer's own habits, one row per space and person,
  and Forget removes the row from the stream and the habit from the store.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Habits
  alias Platform.Habits.{Pattern, Signal}
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  @action "chat.message_attention"
  @sheet "#settings-learned-defaults-sheet"

  setup do
    n = System.unique_integer([:positive])
    one = user!("Member One", n)
    two = user!("Member Two", n)
    three = user!("Member Three", n)

    {:ok, room} =
      Chat.create_space(%{name: "room-x #{n}", slug: "room-x-ld-#{n}", kind: "channel"})

    for u <- [one, two, three] do
      {:ok, _} =
        Chat.add_participant(room.id, %{
          participant_type: "user",
          participant_id: u.id,
          display_name: u.name,
          joined_at: DateTime.utc_now()
        })
    end

    %{one: one, two: two, three: three, room: room}
  end

  defp user!(name, n) do
    slug = name |> String.downcase() |> String.replace(" ", "-")

    user =
      Repo.insert!(%User{
        email: "#{slug}-ld-#{n}@example.com",
        name: "#{name} #{n}",
        oidc_sub: "oidc-#{slug}-ld-#{n}",
        preferences: %{"first_run_goal" => "existing"}
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: acme_org_id(), role: "member"})
    |> Repo.insert!()

    user
  end

  defp record!(actor, room, target, n) do
    for _ <- 1..n do
      {:ok, %Signal{}} =
        Habits.record(%{
          actor_user_id: actor.id,
          space_id: room.id,
          action: @action,
          target_type: "user",
          target_id: target.id,
          outcome: "chosen",
          rung: "none"
        })
    end
  end

  defp open(user) do
    {:ok, view, _html} =
      live(
        build_conn() |> init_test_session(current_user_id: user.id),
        "/settings?sheet=learned_defaults"
      )

    view
  end

  test "the Settings row opens the sheet", %{one: one} do
    {:ok, view, _html} =
      live(build_conn() |> init_test_session(current_user_id: one.id), "/settings")

    refute has_element?(view, "#{@sheet} [data-role=learned-defaults]")
    view |> element("[data-role=settings-learned-defaults]") |> render_click()
    assert has_element?(view, "#{@sheet} [data-role=learned-defaults-title]", "Learned defaults")
    assert has_element?(view, "#{@sheet} [data-role=learned-defaults]")
  end

  test "empty: the switch is on by default and the list says nothing is learned", %{one: one} do
    view = open(one)

    assert has_element?(
             view,
             "#{@sheet} [data-role=learned-defaults-switch][aria-checked=true]",
             "Learn from what I do"
           )

    assert has_element?(view, "#{@sheet} [data-role=learned-defaults-empty]")
    refute has_element?(view, "#{@sheet} [data-role=learned-defaults-pattern]")
  end

  test "the switch writes the preference, and back", %{one: one} do
    view = open(one)

    view |> element("#{@sheet} [data-role=learned-defaults-switch]") |> render_click()

    assert has_element?(view, "#{@sheet} [data-role=learned-defaults-switch][aria-checked=false]")
    assert Accounts.get_user_preferences(one.id)[Habits.preference_key()] == false
    refute Habits.enabled?(one.id)

    view |> element("#{@sheet} [data-role=learned-defaults-switch]") |> render_click()

    assert has_element?(view, "#{@sheet} [data-role=learned-defaults-switch][aria-checked=true]")
    assert Habits.enabled?(one.id)
  end

  test "populated: one row per space and person, only the viewer's own, then Forget removes it",
       %{one: one, two: two, three: three, room: room} do
    record!(one, room, two, 4)
    record!(two, room, three, 4)

    view = open(one)
    [pattern] = Repo.all(from(p in Pattern, where: p.user_id == ^one.id))

    row = "#{@sheet} #learned-pattern-#{pattern.id}[data-role=learned-defaults-pattern]"
    assert has_element?(view, row, "Ask #{two.name} for attention")
    assert has_element?(view, "#{row} [data-role=learned-defaults-space]", "#" <> room.name)
    assert has_element?(view, "#{row} [data-role=learned-defaults-rung]", "Fill it in")
    assert has_element?(view, "#{row} [data-role=learned-defaults-forget]", "Forget")
    refute has_element?(view, "#{@sheet} [data-role=learned-defaults-empty]")

    # Member Two's habit is Member Two's alone.
    body =
      view
      |> element("#{@sheet} [data-role=learned-defaults]")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()

    refute body =~ three.name
    refute body =~ ~r/\d+\s*%/

    view |> element("#{row} [data-role=learned-defaults-forget]") |> render_click()

    refute has_element?(view, "#{@sheet} [data-role=learned-defaults-pattern]")
    assert has_element?(view, "#{@sheet} [data-role=learned-defaults-empty]")
    refute Repo.exists?(from(p in Pattern, where: p.id == ^pattern.id))
    refute Repo.exists?(from(s in Signal, where: s.actor_user_id == ^one.id))
    assert Repo.exists?(from(s in Signal, where: s.actor_user_id == ^two.id))
  end

  test "Forget on another user's pattern id does nothing", %{
    one: one,
    two: two,
    three: three,
    room: room
  } do
    record!(two, room, three, 4)
    [theirs] = Repo.all(from(p in Pattern, where: p.user_id == ^two.id))
    view = open(one)

    view
    |> with_target("#learned-defaults")
    |> render_click("forget_learned_default", %{"id" => theirs.id})

    assert Repo.exists?(from(p in Pattern, where: p.id == ^theirs.id))
  end
end
