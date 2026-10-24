defmodule PlatformWeb.SocialVoiceSettingsTest do
  @moduledoc """
  Social authoring 4/11 (task 01a16c4f-9041): voice, timezone, notify,
  drafting agent and posting slots in Settings. An approver edits and
  saves; a non-approver gets no write controls and a forged event writes
  nothing; the zero-data path (create a profile, add a slot, save, reload)
  keeps the slot.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Account, Profile, Voice, VoiceLearning}
  alias PlatformWeb.SocialVoiceSettings

  defp login(conn, user), do: Plug.Test.init_test_session(conn, current_user_id: user.id)

  defp open(conn, user) do
    {:ok, view, _html} = live(login(conn, user), "/m/social")
    child = find_live_child(view, "ext-page-social")
    child |> element("[data-role='social-tab-button'][data-tab='settings']") |> render_click()
    child
  end

  defp world do
    org_id = org_id!()
    approver = member!(user!(), org_id)
    viewer = member!(user!(), org_id)

    {:ok, profile} =
      Social.create_profile(org_id, %{
        name: "Brand #{unique()}",
        approver_user_ids: [approver.id]
      })

    {:ok, account} = Social.create_account(org_id, profile, %{platform: "x", handle: "brand"})
    %{org_id: org_id, approver: approver, viewer: viewer, profile: profile, account: account}
  end

  defp slot_card(id), do: "[data-role='social-slot-card'][data-account-id='#{id}']"

  defp add_slot!(child, account_id, day, time) do
    child
    |> element("#{slot_card(account_id)} [data-role='social-slot-day'][data-day='#{day}']")
    |> render_click()

    child
    |> form("#social-slot-form-#{account_id}", slot: %{time: time})
    |> render_change()

    child |> element("#{slot_card(account_id)} [data-role='social-slot-add']") |> render_click()
  end

  test "zero data: create a profile, add a slot, save, reload, and the slot is still there",
       %{conn: conn} do
    org_id = org_id!()
    human = member!(user!(), org_id)

    {:ok, view, _html} = live(login(conn, human), "/m/social")
    child = find_live_child(view, "ext-page-social")

    child
    |> form("#social-create-form", profile: %{name: "Fresh brand", home_url: ""})
    |> render_submit()

    [profile] = Social.list_profiles(org_id)

    {:ok, account} =
      Social.create_account(org_id, profile, %{platform: "linkedin", handle: "fresh"})

    child = open(conn, human)

    assert has_element?(
             child,
             "#{slot_card(account.id)} [data-role='social-slots-empty']",
             SocialVoiceSettings.empty_slots_text()
           )

    add_slot!(child, account.id, 1, "09:00")
    assert has_element?(child, "#{slot_card(account.id)} [data-slot='1-09:00']")

    child
    |> form("#social-slot-form-#{account.id}", slot: %{time: "09:00", weekly_goal: "3"})
    |> render_submit()

    assert [%{weekday: 1, time: "09:00"}] = Repo.get!(Account, account.id).posting_slots
    assert Repo.get!(Account, account.id).weekly_goal == 3

    # Reload: a fresh mount reads it back.
    reloaded = open(conn, human)
    assert has_element?(reloaded, "#{slot_card(account.id)} [data-slot='1-09:00']", "Mon 09:00")
    refute has_element?(reloaded, "#{slot_card(account.id)} [data-role='social-slots-empty']")
    assert has_element?(reloaded, "#{slot_card(account.id)} [data-role='social-slot-next']")

    assert has_element?(
             reloaded,
             "#{slot_card(account.id)} [data-role='social-slot-goal'][value='3']"
           )
  end

  test "an approver edits timezone, samples, banned phrases, notify and agent, and saves",
       %{conn: conn} do
    w = world()
    agent = pinned_agent!(w.org_id)
    child = open(conn, w.approver)

    assert has_element?(child, "#social-voice-form")
    child |> element("[data-role='social-voice-sample-add']") |> render_click()

    child
    |> form("#social-voice-form",
      voice: %{
        timezone: "America/Denver",
        samples: ["Short and plain."],
        banned_new: "game changer, Synergy",
        notify_user_ids: [w.approver.id],
        drafting_agent_id: agent.id
      }
    )
    |> render_change()

    child |> element("[data-role='social-voice-banned-add']") |> render_click()
    assert has_element?(child, "[data-role='social-voice-banned-chip']", "game changer")
    assert has_element?(child, "[data-role='social-voice-banned-chip']", "Synergy")

    child
    |> element(
      "[data-role='social-voice-banned-chip']:last-child [data-role='social-voice-banned-remove']"
    )
    |> render_click()

    child |> form("#social-voice-form") |> render_submit()

    profile = Repo.get!(Profile, w.profile.id)
    assert profile.timezone == "America/Denver"
    assert Voice.of(profile).samples == ["Short and plain."]
    assert Voice.of(profile).banned == ["game changer"]
    assert profile.notify_user_ids == [w.approver.id]
    assert profile.drafting_agent_id == agent.id
    assert has_element?(child, "[data-role='social-slots']", "America/Denver")
  end

  test "an approver removes a learning; a removed slot is gone after save", %{conn: conn} do
    w = world()

    learning = %VoiceLearning{id: Ecto.UUID.generate(), text: "Lead with the result"}

    w.profile
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_embed(:voice, %{learnings: [learning]})
    |> Repo.update!()

    {:ok, _} =
      Social.update_account_schedule(w.org_id, w.account, %{
        posting_slots: [%{weekday: 2, time: "10:00"}, %{weekday: 4, time: "15:30"}]
      })

    child = open(conn, w.approver)
    assert has_element?(child, "[data-role='social-voice-learning']", "Lead with the result")
    child |> element("[data-role='social-voice-learning-remove']") |> render_click()
    refute has_element?(child, "[data-role='social-voice-learning']")
    assert Voice.of(Repo.get!(Profile, w.profile.id)).learnings == []

    child
    |> element(
      "#{slot_card(w.account.id)} [data-slot='2-10:00'] [data-role='social-slot-remove']"
    )
    |> render_click()

    child |> form("#social-slot-form-#{w.account.id}") |> render_submit()

    assert [%{weekday: 4, time: "15:30"}] = Repo.get!(Account, w.account.id).posting_slots
  end

  test "a non-approver gets no write controls, and forged events write nothing",
       %{conn: conn} do
    w = world()

    {:ok, _} =
      Social.update_account_schedule(w.org_id, w.account, %{
        posting_slots: [%{weekday: 1, time: "09:00"}]
      })

    child = open(conn, w.viewer)

    assert has_element?(child, "[data-role='social-voice-readonly']")
    assert has_element?(child, "[data-role='social-voice-readonly']", "Mon 09:00")
    refute has_element?(child, "#social-voice-form")
    refute has_element?(child, "[data-role='social-slot-form']")
    refute has_element?(child, "[data-role='social-voice-readonly'] button")
    refute has_element?(child, "[data-role='social-voice-readonly'] input")

    before_profile = Repo.get!(Profile, w.profile.id)
    before_account = Repo.get!(Account, w.account.id)

    render_hook(child, "voice_save", %{
      "voice" => %{"timezone" => "Asia/Tokyo", "samples" => ["forged"]}
    })

    render_hook(child, "slot_toggle_day", %{"account_id" => w.account.id, "day" => "3"})
    render_hook(child, "slot_add", %{"account_id" => w.account.id})

    render_hook(child, "slot_save", %{
      "account_id" => w.account.id,
      "slot" => %{"weekly_goal" => "9"}
    })

    render_hook(child, "voice_remove_learning", %{"id" => Ecto.UUID.generate()})

    assert has_element?(child, "[data-role='social-notice']", "Only an approver")
    assert Repo.get!(Profile, w.profile.id) == before_profile
    assert Repo.get!(Account, w.account.id) == before_account
  end

  test "a forged slot save for another profile's account writes nothing", %{conn: conn} do
    w = world()
    other = world()
    child = open(conn, w.approver)

    before = Repo.get!(Account, other.account.id)

    render_hook(child, "slot_save", %{
      "account_id" => other.account.id,
      "slot" => %{"weekly_goal" => "5"}
    })

    assert Repo.get!(Account, other.account.id) == before
  end

  test "a forged timezone or agent outside the offered options is not written", %{conn: conn} do
    w = world()
    foreign_agent = pinned_agent!(org_id!())
    child = open(conn, w.approver)

    render_hook(child, "voice_save", %{
      "voice" => %{
        "timezone" => "Not/AZone",
        "drafting_agent_id" => foreign_agent.id,
        "notify_user_ids" => [w.viewer.id]
      }
    })

    profile = Repo.get!(Profile, w.profile.id)

    assert {profile.timezone, profile.drafting_agent_id, profile.notify_user_ids} ==
             {"Etc/UTC", nil, []}
  end
end
