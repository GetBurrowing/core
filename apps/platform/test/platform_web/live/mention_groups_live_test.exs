defmodule PlatformWeb.MentionGroupsLiveTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Chat.MentionGroups
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  defp user!(role, org_id, external \\ false) do
    n = System.unique_integer([:positive])
    user = Repo.insert!(%User{name: "Group admin #{n}", email: "group-#{n}@example.com",
      oidc_sub: "group-#{n}", preferences: %{"first_run_goal" => "existing"}})
    Repo.insert!(OrgMembership.changeset(%OrgMembership{}, %{user_id: user.id,
      org_id: org_id, role: role, external: external}))
    user
  end

  defp authed(user), do: build_conn() |> init_test_session(current_user_id: user.id)

  test "an exact-org internal admin creates, renames, changes membership and archives a group" do
    org_id = acme_org_id()
    admin = user!("admin", org_id)
    target = user!("member", org_id)
    {:ok, view, html} = live(authed(admin), "/settings/mention-groups")
    assert html =~ "Mention groups"
    view |> element("#new-mention-group") |> render_click()
    view |> form("#mention-group-form", %{"group" => %{"name" => "Design team",
      "members" => ["user:#{target.id}"]}}) |> render_submit()
    assert {:ok, [group]} = MentionGroups.list_groups(admin, org_id)
    assert group.name == "Design team"
    view |> element("#edit-group-#{group.id}") |> render_click()
    view |> form("#mention-group-form", %{"group" => %{"name" => "Review team", "members" => []}})
      |> render_submit()
    assert {:ok, renamed} = MentionGroups.get_group(admin, group.id)
    assert renamed.name == "Review team"
    assert renamed.members == []
    view |> element("#archive-group-#{group.id}") |> render_click()
    assert {:ok, []} = MentionGroups.list_groups(admin, org_id)
  end

  test "members and external actors cannot discover the management directory" do
    org_id = acme_org_id()
    for actor <- [user!("member", org_id), user!("admin", org_id, true)] do
      assert {:error, {:redirect, _}} = live(authed(actor), "/settings/mention-groups")
    end
  end

  test "a child-org admin can manage only that org and finds the page in Settings" do
    org_id = tenant_org_id("mention-group-child")
    admin = user!("admin", org_id)
    {:ok, view, _} = live(authed(admin), "/settings/mention-groups")
    view |> element("#new-mention-group") |> render_click()
    view |> form("#mention-group-form", %{"group" => %{"name" => "Child team"}})
      |> render_submit()
    assert {:ok, [group]} = MentionGroups.list_groups(admin, org_id)
    assert group.org_id == org_id
    render_click(view, "select_org", %{"org_id" => acme_org_id()})
    assert render(view) =~ "Could not open that organization."
    {:ok, settings, _} = live(authed(admin), "/settings")
    render_click(settings, "open_admin_sheet")
    assert has_element?(settings, "a[href='/settings/mention-groups']", "Mention groups")
  end

  test "a stale admin form cannot mutate groups after admin rights are revoked" do
    org_id = acme_org_id()
    admin = user!("admin", org_id)
    {:ok, view, _} = live(authed(admin), "/settings/mention-groups")
    view |> element("#new-mention-group") |> render_click()
    membership = Repo.get_by!(OrgMembership, user_id: admin.id, org_id: org_id)
    membership |> Ecto.Changeset.change(role: "member") |> Repo.update!()
    view |> form("#mention-group-form", %{"group" => %{"name" => "Forbidden"}})
      |> render_submit()
    assert render(view) =~ "Could not save this group."
  end

  test "the main and thread composers offer groups with stable insertion tokens" do
    org_id = acme_org_id()
    admin = user!("admin", org_id)
    {:ok, group} = MentionGroups.create_group(admin, org_id, %{name: "Design Team"})
    {:ok, space} = Platform.Chat.create_space(%{name: "Groups", slug: "groups-#{System.unique_integer([:positive])}", kind: "channel", org_id: org_id})
    {:ok, participant} = Platform.Chat.add_participant(space.id, %{participant_type: "user", participant_id: admin.id, display_name: admin.name})
    {:ok, message} = Platform.Chat.post_message(%{space_id: space.id, participant_id: participant.id, content_type: "text", content: "Thread parent"})
    {:ok, view, _} = live(authed(admin), "/chat/#{space.slug}")
    render_hook(view, "mention_query", %{query: "Design", source: "compose-form"})
    assert has_element?(view, "#compose-mention-list [data-kind=group]", "Design Team")
    assert render(view) =~ "group:#{group.id}|Design Team"
    render_hook(view, "open_inline_thread", %{"message-id" => message.id})
    render_hook(view, "mention_query", %{query: "Design", source: "inline-thread-compose-form-#{message.id}"})
    assert has_element?(view, "#inline-thread-mention-list-#{message.id} [data-kind=group]", "Design Team")
  end
end
