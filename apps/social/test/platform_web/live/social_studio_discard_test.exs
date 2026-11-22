defmodule PlatformWeb.SocialStudioDiscardTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Platform.Social.Studio

  defp open(conn, user, profile) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, parent, _} = live(conn, "/m/social?profile=#{profile.id}&tab=today")
    find_live_child(parent, "ext-page-social")
  end

  test "recovery distinguishes shared captions by platform even when restore is unavailable", %{
    conn: conn
  } do
    w = studio_world!()

    {:ok, instagram} =
      Platform.Social.create_account(w.org_id, w.profile, %{
        platform: "instagram",
        handle: "@same"
      })

    {:ok, youtube} =
      Platform.Social.create_account(w.org_id, w.profile, %{platform: "youtube", handle: "@same"})

    ig_post = studio_post!(w, instagram, "draft", %{body: "Same caption. More detail."})
    yt_post = studio_post!(w, youtube, "draft", %{body: "Same caption. More detail."})
    {:ok, _} = Studio.discard_draft(w.org_id, ig_post.id, w.approver.id, expect(ig_post))
    {:ok, _} = Studio.discard_draft(w.org_id, yt_post.id, w.approver.id, expect(yt_post))
    {:ok, _} = Platform.Social.archive_account(w.org_id, youtube)
    view = open(conn, w.approver, w.profile)
    view |> element("[data-role='studio-recovery-open']") |> render_click()

    for {post, platform} <- [{ig_post, "Instagram"}, {yt_post, "YouTube"}] do
      row = "[data-role='studio-discarded'][data-post-id='#{post.id}']"
      assert has_element?(view, row <> " [data-role='studio-recovery-title']", "Same caption.")

      assert has_element?(
               view,
               row <> " [data-role='studio-recovery-context']",
               "#{platform} · @same · #{w.profile.name}"
             )

      assert has_element?(view, row, "Same caption. More detail.")
    end

    assert has_element?(
             view,
             "[data-role='studio-discarded'][data-post-id='#{yt_post.id}']",
             "Restore unavailable while the account is archived."
           )

    refute has_element?(view, "[data-role='studio-restore'][data-post-id='#{yt_post.id}']")
  end

  test "Today and recovery omit an absent account handle from context", %{conn: conn} do
    w = studio_world!()
    {:ok, account} = Platform.Social.create_account(w.org_id, w.profile, %{platform: "youtube"})
    post = studio_post!(w, account, "draft", %{body: "No handle caption"})
    view = open(conn, w.approver, w.profile)
    row = "[data-role='studio-post'][data-post-id='#{post.id}']"

    assert has_element?(
             view,
             row <> " [data-role='studio-post-context']",
             "YouTube · #{w.profile.name}"
           )

    render_click(view, "studio_open_post", %{"id" => post.id})
    view |> element("[data-role='studio-discard']") |> render_click()
    view |> element("[data-role='studio-recovery-open']") |> render_click()
    row = "[data-role='studio-discarded'][data-post-id='#{post.id}']"

    assert has_element?(
             view,
             row <> " [data-role='studio-recovery-context']",
             "YouTube · #{w.profile.name}"
           )
  end

  test "recovery identity does not expose another owner's discarded draft", %{conn: conn} do
    w = studio_world!()

    {:ok, other} =
      Platform.Social.create_account(w.org_id, w.profile, %{
        platform: "youtube",
        handle: "@private-handle"
      })

    visible = studio_post!(w, w.x, "draft", %{body: "Visible draft"})
    hidden = studio_post!(w, other, "draft", %{body: "Private recovery title"})
    {:ok, _} = Studio.discard_draft(w.org_id, visible.id, w.approver.id, expect(visible))
    {:ok, _} = Studio.discard_draft(w.org_id, hidden.id, w.approver.id, expect(hidden))
    owner = user!() |> member!(w.org_id)
    {:ok, _} = Platform.Social.set_account_owner(w.org_id, other, owner.id)
    view = open(conn, w.approver, w.profile)
    view |> element("[data-role='studio-recovery-open']") |> render_click()
    assert has_element?(view, "[data-role='studio-discarded'][data-post-id='#{visible.id}']")
    refute has_element?(view, "[data-role='studio-discarded'][data-post-id='#{hidden.id}']")
    refute render(view) =~ "Private recovery title"
    refute has_element?(view, "section[aria-label='Discarded drafts']", "@private-handle")
  end

  test "discard removes a draft from Today and recovery restores it", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.x, "draft", %{body: "recovery test draft"})
    view = open(conn, w.approver, w.profile)
    assert has_element?(view, "[data-role='studio-post'][data-post-id='#{post.id}']")
    render_click(view, "studio_open_post", %{"id" => post.id})
    assert has_element?(view, "[data-role='studio-discard'][class~='min-h-[44px]']")
    view |> element("[data-role='studio-discard']") |> render_click()
    refute has_element?(view, "[data-role='studio-post'][data-post-id='#{post.id}']")

    assert has_element?(
             view,
             "[data-role='studio-action-status'][role='status'][tabindex='-1'][phx-mounted]",
             "Draft discarded. It is retained in Discarded drafts."
           )

    render_click(view, "studio_open_post", %{"id" => post.id})
    refute has_element?(view, "[data-role='studio-post-detail']")
    view |> element("[data-role='studio-recovery-open']") |> render_click()
    assert has_element?(view, "[data-role='studio-discarded'][data-post-id='#{post.id}']")

    assert has_element?(
             view,
             "[data-role='studio-restore'][data-post-id='#{post.id}'][class~='min-h-[44px]']"
           )

    view |> element("[data-role='studio-restore'][data-post-id='#{post.id}']") |> render_click()
    assert has_element?(view, "[data-role='studio-post'][data-post-id='#{post.id}']")

    assert has_element?(
             view,
             "[data-role='studio-action-status'][role='status'][tabindex='-1'][phx-mounted]",
             "Draft restored."
           )

    assert {:ok, restored} = Studio.get_post(w.org_id, post.id)
    assert restored.body == post.body
    render_click(view, "studio_open_post", %{"id" => post.id})
    view |> element("[data-role='studio-discard']") |> render_click()
    assert has_element?(view, "#studio-action-status-3[phx-mounted]", "Draft discarded.")
  end

  test "recovery entry has a target class and All brands explains its scope", %{conn: conn} do
    w = studio_world!()
    view = open(conn, w.approver, w.profile)
    assert has_element?(view, "[data-role='studio-recovery-open'][class~='min-h-[44px]']")
    render_click(view, "switch_profile", %{"profile_id" => "all"})
    refute has_element?(view, "[data-role='studio-recovery-open']")
    assert render(view) =~ "Choose a brand to view its discarded drafts."
  end

  test "discard from All brands changes only the bound draft and restores in its brand", %{
    conn: conn
  } do
    w = studio_world!()

    {:ok, second} =
      Platform.Social.create_profile(w.org_id, %{
        name: "Other brand",
        project_id: w.project.id,
        approver_user_ids: [w.approver.id]
      })

    {:ok, second} = Studio.set_enabled(w.org_id, second.id, w.approver.id, true)
    {:ok, account} = Platform.Social.create_account(w.org_id, second, %{platform: "youtube"})
    first_post = studio_post!(w, w.x, "draft", %{body: "First brand draft"})

    other_post =
      studio_post!(%{w | profile: second}, account, "draft", %{body: "Other brand draft"})

    view = open(conn, w.approver, w.profile)

    view |> form("#social-profile-switcher", %{profile_id: "all"}) |> render_change()
    assert has_element?(view, "[data-role='studio-post'][data-post-id='#{first_post.id}']")
    assert has_element?(view, "[data-role='studio-post'][data-post-id='#{other_post.id}']")

    view
    |> element("[data-role='studio-post-open'][data-post-id='#{first_post.id}']")
    |> render_click()

    view |> element("[data-role='studio-discard']") |> render_click()
    refute has_element?(view, "[data-role='studio-post'][data-post-id='#{first_post.id}']")
    assert has_element?(view, "[data-role='studio-post'][data-post-id='#{other_post.id}']")
    assert {:error, :not_found} = Studio.get_post(w.org_id, first_post.id)
    assert {:ok, unchanged} = Studio.get_post(w.org_id, other_post.id)
    assert unchanged.state_rev == other_post.state_rev
    assert unchanged.body == other_post.body

    view |> form("#social-profile-switcher", %{profile_id: w.profile.id}) |> render_change()
    view |> element("[data-role='studio-recovery-open']") |> render_click()

    view
    |> element("[data-role='studio-restore'][data-post-id='#{first_post.id}']")
    |> render_click()

    assert has_element?(view, "[data-role='studio-post'][data-post-id='#{first_post.id}']")
    assert {:ok, restored} = Studio.get_post(w.org_id, first_post.id)
    assert restored.body == first_post.body
    assert {:ok, unchanged_again} = Studio.get_post(w.org_id, other_post.id)
    assert unchanged_again.state_rev == other_post.state_rev
  end

  test "successive restores mount a fresh focusable confirmation each time", %{conn: conn} do
    w = studio_world!()

    posts =
      for n <- 1..2 do
        post = studio_post!(w, w.x, "draft", %{body: "restore #{n}"})
        {:ok, discarded} = Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))
        discarded
      end

    view = open(conn, w.approver, w.profile)
    view |> element("[data-role='studio-recovery-open']") |> render_click()

    for {post, sequence} <- Enum.zip(posts, 1..2) do
      view |> element("[data-role='studio-restore'][data-post-id='#{post.id}']") |> render_click()

      assert has_element?(
               view,
               "#studio-action-status-#{sequence}[role='status'][phx-mounted]",
               "Draft restored."
             )
    end
  end

  test "a discarded draft in another session cannot be submitted from a stale detail", %{
    conn: conn
  } do
    w = studio_world!()
    post = studio_post!(w, w.x, "draft", %{body: "stale draft"})
    view = open(conn, w.approver, w.profile)
    render_click(view, "studio_open_post", %{"id" => post.id})
    assert has_element?(view, "[data-role='studio-post-detail']", "stale draft")
    assert {:ok, _} = Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))
    render_click(view, "studio_submit_post", %{})
    refute has_element?(view, "[data-role='studio-post-detail']")
    refute has_element?(view, "[data-role='studio-post'][data-post-id='#{post.id}']")
    assert render(view) =~ "This draft is no longer available."
  end

  test "a discarded render destination is marked reserved on its clip", %{conn: conn} do
    w = studio_world!()
    clip = w |> pending_clip!() |> make_studio_clip!()
    attrs = %{render_id: render_id!(clip), account_ids: [w.x.id]}
    {:ok, %{posts: [post]}} = Studio.accept_render(w.org_id, clip.id, w.approver.id, attrs)

    {:ok, draft} =
      Studio.request_changes(w.org_id, post.id, w.approver.id, expect(post), "revise")

    {:ok, _} = Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(draft))
    view = open(conn, w.approver, w.profile)

    assert has_element?(
             view,
             "[data-role='studio-clip'][data-clip-id='#{clip.id}'] [data-role='studio-clip-discarded']",
             "Discarded"
           )

    refute has_element?(view, "#studio-clip-#{clip.id} option[value='#{w.x.id}']")
  end

  test "older discarded drafts remain reachable through recovery pages", %{conn: conn} do
    w = studio_world!()

    posts =
      for n <- 1..21 do
        post = studio_post!(w, w.x, "draft", %{body: "page draft #{n}"})
        {:ok, discarded} = Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))
        discarded
      end

    oldest = hd(posts)
    view = open(conn, w.approver, w.profile)
    view |> element("[data-role='studio-recovery-open']") |> render_click()
    refute has_element?(view, "[data-role='studio-discarded'][data-post-id='#{oldest.id}']")

    render_click(view, "studio_restore_post", %{
      "id" => oldest.id,
      "rev" => to_string(oldest.state_rev),
      "version" => to_string(oldest.version)
    })

    assert {:error, :not_found} = Studio.get_post(w.org_id, oldest.id)
    assert render(view) =~ "The draft could not be restored."

    view
    |> element("button[phx-click='studio_recovery_page'][phx-value-direction='next']")
    |> render_click()

    assert has_element?(view, "[data-role='studio-discarded'][data-post-id='#{oldest.id}']")
    view |> element("[data-role='studio-restore'][data-post-id='#{oldest.id}']") |> render_click()
    assert {:ok, _} = Studio.get_post(w.org_id, oldest.id)
  end

  test "an approver can discard a draft on an archived account through Today", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.x, "draft")
    {:ok, _} = Platform.Social.archive_account(w.org_id, w.x)
    view = open(conn, w.approver, w.profile)
    render_click(view, "studio_open_post", %{"id" => post.id})
    assert has_element?(view, "[data-role='studio-discard']")
    view |> element("[data-role='studio-discard']") |> render_click()
    assert {:error, :not_found} = Studio.get_post(w.org_id, post.id)

    assert has_element?(
             view,
             "[data-role='studio-action-status']",
             "Draft discarded. It is retained in Discarded drafts."
           )

    view |> element("[data-role='studio-recovery-open']") |> render_click()

    assert has_element?(
             view,
             "[data-role='studio-discarded'][data-post-id='#{post.id}']",
             "account is archived"
           )

    assert has_element?(
             view,
             "[data-role='studio-discarded'][data-post-id='#{post.id}'] [aria-label='Draft history']",
             "created"
           )

    assert has_element?(
             view,
             "[data-role='studio-discarded'][data-post-id='#{post.id}'] [aria-label='Draft history']",
             "discarded"
           )

    refute has_element?(view, "[data-role='studio-restore'][data-post-id='#{post.id}']")
  end

  test "a viewer without rejecter authority gets no discard control and a forged action changes nothing",
       %{conn: conn} do
    w = studio_world!()
    viewer = user!() |> member!(w.org_id)
    post = studio_post!(w, w.x, "draft")
    view = open(conn, viewer, w.profile)
    render_click(view, "studio_open_post", %{"id" => post.id})
    assert has_element?(view, "[data-role='studio-post-detail']")
    refute has_element?(view, "[data-role='studio-discard']")
    render_click(view, "studio_discard_post", %{})
    assert {:ok, unchanged} = Studio.get_post(w.org_id, post.id)
    assert unchanged.state_rev == post.state_rev
  end

  test "a rejecter can see an archived owner's draft but cannot restore it", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.x, "draft")
    owner = user!() |> member!(w.org_id)
    {:ok, _} = Platform.Social.set_account_owner(w.org_id, w.x, owner.id)
    {:ok, _} = Platform.Accounts.archive_user(owner)
    {:ok, discarded} = Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))
    view = open(conn, w.approver, w.profile)
    view |> element("[data-role='studio-recovery-open']") |> render_click()

    assert has_element?(
             view,
             "[data-role='studio-discarded'][data-post-id='#{post.id}']",
             "authorized approver"
           )

    refute has_element?(view, "[data-role='studio-restore'][data-post-id='#{post.id}']")

    render_click(view, "studio_restore_post", %{
      "id" => post.id,
      "rev" => to_string(discarded.state_rev),
      "version" => to_string(discarded.version)
    })

    assert render(view) =~ "The draft could not be restored."
    assert {:error, :not_found} = Studio.get_post(w.org_id, post.id)
    render_click(view, "studio_open_post", %{"id" => post.id})
    refute has_element?(view, "[data-role='studio-post-detail']")
  end

  test "revoking project access removes recovery content on the next event", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.x, "draft", %{body: "synthetic recovery secret"})
    {:ok, _} = Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))
    view = open(conn, w.approver, w.profile)
    view |> element("[data-role='studio-recovery-open']") |> render_click()
    assert render(view) =~ post.body

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, w.approver.id},
        permission: "social.use",
        resource: {:project, w.profile.project_id}
      })

    render_click(view, "studio_recovery_open", %{})
    refute render(view) =~ post.body
    refute has_element?(view, "[data-role='studio-restore']")
  end

  test "recovery attributes a deleted discarder to a former user", %{conn: conn} do
    w = studio_world!()
    actor = user!() |> member!(w.org_id)

    {:ok, _} =
      Platform.Social.update_profile(w.org_id, w.profile, %{
        approver_user_ids: [w.approver.id, actor.id]
      })

    post = studio_post!(w, w.x, "draft")
    {:ok, _} = Studio.discard_draft(w.org_id, post.id, actor.id, expect(post))
    Platform.Repo.delete!(actor)
    view = open(conn, w.approver, w.profile)
    view |> element("[data-role='studio-recovery-open']") |> render_click()

    assert has_element?(
             view,
             "[data-role='studio-discarded'][data-post-id='#{post.id}']",
             "Former user"
           )
  end

  test "restoring an agent draft keeps its label and original request replay", %{conn: conn} do
    w = studio_world!()
    attrs = %{"request_id" => "restore-#{unique()}", "body" => "Agent original"}
    {:ok, post, :created} = Studio.create_agent_draft(w.org_id, w.x.id, w.agent.id, attrs)
    {:ok, discarded} = Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))
    {:ok, restored} = Studio.restore_draft(w.org_id, post.id, w.approver.id, expect(discarded))

    assert {:ok, replayed, :replayed} =
             Studio.create_agent_draft(w.org_id, w.x.id, w.agent.id, attrs)

    assert replayed.id == restored.id
    view = open(conn, w.approver, w.profile)

    assert has_element?(
             view,
             "[data-role='studio-post'][data-post-id='#{post.id}'] [data-role='studio-agent-drafted']",
             "Drafted by an agent · not reviewed"
           )
  end

  test "a forged restore for another profile returns the same generic refusal as a missing id", %{
    conn: conn
  } do
    w = studio_world!()

    {:ok, other_profile} =
      Platform.Social.create_profile(w.org_id, %{
        name: "Other profile",
        project_id: w.project.id,
        home_url: "https://www.youtube.com/@otherprofile",
        approver_user_ids: [w.approver.id]
      })

    {:ok, other_profile} = Studio.set_enabled(w.org_id, other_profile.id, w.approver.id, true)

    {:ok, other_account} =
      Platform.Social.create_account(w.org_id, other_profile, %{platform: "x", handle: "@other"})

    {:ok, post} =
      Studio.create_post(w.org_id, other_account.id, w.approver.id, %{
        body: "other profile draft",
        status: "draft"
      })

    {:ok, discarded} = Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))

    view = open(conn, w.approver, w.profile)
    view |> element("[data-role='studio-recovery-open']") |> render_click()

    args = %{
      "id" => post.id,
      "rev" => to_string(discarded.state_rev),
      "version" => to_string(discarded.version)
    }

    foreign = render_click(view, "studio_restore_post", args)
    missing = render_click(view, "studio_restore_post", Map.put(args, "id", Ecto.UUID.generate()))
    assert foreign =~ "The draft could not be restored."
    assert missing =~ "The draft could not be restored."
    refute foreign =~ post.body
    assert {:error, :not_found} = Studio.get_post(w.org_id, post.id)
  end
end
