defmodule PlatformWeb.SocialLiveQueueDraftsTest do
  @moduledoc """
  The Queue's "Drafts" group (B3): legacy drafts above "Awaiting approval",
  edited (caption, YouTube title, time) and saved or sent for review from the
  card, through `Social.edit_draft/5`. `async: false`: the Fake publisher's
  call log is global.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialFixtures, only: [media_file!: 2]
  import Platform.SocialApprovalFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{ApprovalCard, Post}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    ctx = approval_fixture()
    a = Repo.update!(Ecto.Changeset.change(ctx.a, status: "connected"))

    {:ok, yt} =
      Social.create_account(ctx.org_id, ctx.profile, %{platform: "youtube", handle: "@htc_yt"})

    yt = Repo.update!(Ecto.Changeset.change(yt, status: "connected"))
    Map.merge(ctx, %{a: a, yt: yt})
  end

  defp open(conn, ctx, user) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/m/social?profile=#{ctx.profile.id}&tab=queue")
    find_live_child(view, "ext-page-social")
  end

  defp draft!(ctx, account, attrs) do
    {:ok, post} = Social.create_post(ctx.org_id, account, attrs)
    post
  end

  defp form(post), do: "#queue-draft-form-#{post.id}"
  defp future_local, do: "2031-01-15T09:00"
  defp future_at, do: DateTime.add(DateTime.utc_now(), 3600) |> DateTime.truncate(:second)

  test "no drafts, no Drafts group", %{conn: conn} = ctx do
    view = open(conn, ctx, ctx.h1)
    refute has_element?(view, "#queue-drafts")
  end

  test "Drafts sits above the awaiting-approval list and carries a stable anchor id",
       %{conn: conn} = ctx do
    draft!(ctx, ctx.a, %{body: "Draft caption"})
    pending_post!(ctx, ctx.a, %{scheduled_at: future_at()})
    view = open(conn, ctx, ctx.h1)

    assert has_element?(view, "section#queue-drafts h2", "Drafts")
    html = render(view)
    {drafts_at, _} = :binary.match(html, ~s(id="queue-drafts"))
    {needs_at, _} = :binary.match(html, ~s(id="queue-needs-you"))
    assert drafts_at < needs_at
  end

  test "an approver gets the editor; shows account, caption, time and no extra controls",
       %{conn: conn} = ctx do
    p = draft!(ctx, ctx.a, %{body: "Draft caption"})
    view = open(conn, ctx, ctx.h1)

    assert has_element?(view, "#queue-draft-card-#{p.id} [data-role='draft-account']", "LinkedIn")
    assert has_element?(view, "#{form(p)} textarea[name='body']", "Draft caption")
    assert has_element?(view, "#{form(p)} input[type='datetime-local'][name='at']")
    assert has_element?(view, "#{form(p)} button", "Save draft")
    assert has_element?(view, "#{form(p)} button", "Send for review")
    refute has_element?(view, "#{form(p)} select")
    refute has_element?(view, "#{form(p)} input[type='file']")
    refute has_element?(view, "#{form(p)} input[name='title']")
    refute has_element?(view, "#queue-draft-card-#{p.id} [data-role='draft-read-only']")
  end

  test "a project reader who may not edit sees the draft read only", %{conn: conn} = ctx do
    project = Platform.SocialFixtures.project!(ctx.org_id)
    {:ok, _} = Social.update_profile(ctx.org_id, ctx.profile, %{project_id: project.id})
    p = draft!(ctx, ctx.a, %{body: "Draft caption"})
    view = open(conn, ctx, ctx.n)

    assert has_element?(
             view,
             "#queue-draft-card-#{p.id} [data-role='draft-body']",
             "Draft caption"
           )

    assert has_element?(
             view,
             "#queue-draft-card-#{p.id} [data-role='draft-read-only']",
             "Only an approver for this account can edit or send this draft."
           )

    refute has_element?(view, form(p))
    refute has_element?(view, "[data-role='draft-save']")
    refute has_element?(view, "[data-role='draft-send']")
  end

  test "the title field is YouTube only", %{conn: conn} = ctx do
    video = media_file!(ctx.org_id, "video/mp4")
    li = draft!(ctx, ctx.a, %{body: "x"})
    yt = draft!(ctx, ctx.yt, %{body: "y", media_file_ids: [video.id]})
    view = open(conn, ctx, ctx.h1)

    assert has_element?(view, "#{form(yt)} input[name='title']")
    assert render(view) =~ "Title (sent to YouTube)"
    refute has_element?(view, "#{form(li)} input[name='title']")
    assert has_element?(view, "#queue-draft-card-#{yt.id} [data-role='draft-media'] video")
  end

  test "the time is entered in the brand's zone, which is shown; an empty time is labelled",
       %{conn: conn} = ctx do
    Repo.update!(Ecto.Changeset.change(ctx.profile, timezone: "America/Denver"))
    p = draft!(ctx, ctx.a, %{body: "Caption"})
    view = open(conn, ctx, ctx.h1)

    assert has_element?(
             view,
             "#queue-draft-card-#{p.id} [data-role='draft-time-zone']",
             "America/Denver"
           )

    assert has_element?(
             view,
             "#queue-draft-card-#{p.id} [data-role='draft-time-label']",
             "Choose a publish time"
           )

    view
    |> element(form(p))
    |> render_submit(%{"body" => "Caption", "at" => "2031-01-15T09:00", "intent" => "save"})

    # 09:00 in Denver (MST, UTC-7) on 15 Jan is 16:00Z.
    assert Repo.get!(Post, p.id).scheduled_at == ~U[2031-01-15 16:00:00.000000Z]

    assert has_element?(
             view,
             "#queue-draft-card-#{p.id} [data-role='draft-time-label']",
             "Publish time"
           )

    assert has_element?(view, "#{form(p)} input[name='at'][value='2031-01-15T09:00']")
  end

  test "Save draft stores caption, title and time and stays a draft", %{conn: conn} = ctx do
    video = media_file!(ctx.org_id, "video/mp4")
    yt = draft!(ctx, ctx.yt, %{media_file_ids: [video.id]})
    view = open(conn, ctx, ctx.h1)

    view
    |> element(form(yt))
    |> render_submit(%{"body" => "Half", "title" => "My title", "at" => "", "intent" => "save"})

    saved = Repo.get!(Post, yt.id)
    assert saved.status == "draft"
    assert saved.body == "Half"
    assert saved.platform_options["title"] == "My title"

    assert has_element?(
             view,
             "#queue-draft-card-#{yt.id} [data-role='draft-notice']",
             "Draft saved."
           )

    assert Repo.aggregate(ApprovalCard, :count) == 0
  end

  test "Send for review: 'Sent for review.', the card leaves Drafts and shows in the review list",
       %{conn: conn} = ctx do
    p = draft!(ctx, ctx.a, %{body: "Ready to go"})
    view = open(conn, ctx, ctx.h1)

    view
    |> element(form(p))
    |> render_submit(%{"body" => "Ready to go", "at" => future_local(), "intent" => "submit"})

    assert has_element?(view, "[data-role='drafts-notice']", "Sent for review.")
    refute has_element?(view, "#queue-draft-card-#{p.id}")
    refute has_element?(view, "#queue-drafts")
    assert Repo.get!(Post, p.id).status == "needs_approval"
    assert has_element?(view, "#queue-card-idea-#{p.id}")
    assert %ApprovalCard{} = Social.Approvals.live_card(p.id)
  end

  test "a refusal lists what is missing and keeps every input", %{conn: conn} = ctx do
    video = media_file!(ctx.org_id, "video/mp4")
    yt = draft!(ctx, ctx.yt, %{media_file_ids: [video.id]})
    before = Repo.get!(Post, yt.id)
    view = open(conn, ctx, ctx.h1)

    view
    |> element(form(yt))
    |> render_submit(%{
      "body" => "Typed caption",
      "title" => "Typed title",
      "at" => "",
      "intent" => "submit"
    })

    assert has_element?(
             view,
             "#queue-draft-card-#{yt.id} [data-role='draft-line']",
             "Choose a publish time."
           )

    assert has_element?(view, "#{form(yt)} textarea[name='body']", "Typed caption")
    assert has_element?(view, "#{form(yt)} input[name='title'][value='Typed title']")
    assert has_element?(view, "#queue-draft-card-#{yt.id}")
    refute has_element?(view, "[data-role='drafts-notice']")

    # The Queue re-reading (another card's change, a composer send) must not
    # wipe what was typed.
    send(view.pid, {PlatformWeb.SocialComposer, :saved, Ecto.UUID.generate()})
    render(view)
    assert has_element?(view, "#{form(yt)} textarea[name='body']", "Typed caption")
    assert has_element?(view, "#{form(yt)} input[name='title'][value='Typed title']")

    assert has_element?(
             view,
             "#queue-draft-card-#{yt.id} [data-role='draft-line']",
             "Choose a publish time."
           )

    assert Repo.get!(Post, yt.id) == before
    assert Repo.aggregate(ApprovalCard, :count) == 0
  end

  test "a time that cannot be read is refused and kept", %{conn: conn} = ctx do
    p = draft!(ctx, ctx.a, %{body: "Caption"})
    before = Repo.get!(Post, p.id)
    view = open(conn, ctx, ctx.h1)

    view
    |> element(form(p))
    |> render_submit(%{"body" => "Edited", "at" => "garbage", "intent" => "save"})

    assert has_element?(view, "[data-role='draft-line']", "publish time")
    assert has_element?(view, "#{form(p)} textarea[name='body']", "Edited")
    assert Repo.get!(Post, p.id) == before
  end

  test "an over-long caption is refused on save", %{conn: conn} = ctx do
    p = draft!(ctx, ctx.a, %{body: "Caption"})
    before = Repo.get!(Post, p.id)
    view = open(conn, ctx, ctx.h1)

    view
    |> element(form(p))
    |> render_submit(%{"body" => String.duplicate("a", 10_001), "at" => "", "intent" => "save"})

    assert has_element?(view, "[data-role='draft-line']", "Caption")
    assert Repo.get!(Post, p.id) == before
  end

  describe "what a draft card reveals (presentation and files.read gates)" do
    @caption "Embargoed caption text"
    @yt_title "Embargoed YouTube title"
    @file_name "embargoed-reel.mp4"

    setup ctx do
      project = Platform.SocialFixtures.project!(ctx.org_id)
      media_project = Platform.SocialFixtures.project!(ctx.org_id)
      {:ok, profile} = Social.update_profile(ctx.org_id, ctx.profile, %{project_id: project.id})

      {:ok, file} =
        Platform.Files.create_file(%{
          project_id: media_project.id,
          name: @file_name,
          original_filename: @file_name,
          content_type: "video/mp4",
          byte_size: 1024,
          storage_key: "files/#{media_project.id}/#{System.unique_integer([:positive])}/r.mp4",
          content_hash: String.duplicate("c", 64)
        })

      yt = Repo.update!(Ecto.Changeset.change(ctx.yt, profile_id: profile.id))

      post =
        draft!(%{ctx | profile: profile}, yt, %{
          body: @caption,
          media_file_ids: [file.id],
          scheduled_at: future_at()
        })

      post =
        post
        |> Ecto.Changeset.change(platform_options: %{"title" => @yt_title})
        |> Repo.update!()

      %{
        profile: profile,
        project: project,
        media_project: media_project,
        ypost: post,
        media: file
      }
    end

    defp deny!(user, permission, project) do
      {:ok, _} =
        Platform.Access.Grants.deny(%{
          principal: {:user, user.id},
          permission: permission,
          resource: {:project, project.id}
        })
    end

    defp card_html(view, post),
      do: view |> element("#queue-draft-card-#{post.id}") |> render()

    defp assert_hidden(html) do
      for secret <- [@caption, @yt_title, @file_name, "/files/blob/", "Publish", "2031"] do
        refute html =~ secret
      end

      refute html =~ "datetime"
    end

    test "a viewer denied the project sees only account, platform, Draft and the approver line",
         %{conn: conn} = ctx do
      deny!(ctx.n, "social.use", ctx.project)
      html = conn |> open(ctx, ctx.n) |> card_html(ctx.ypost)

      assert html =~ "YouTube"
      assert html =~ "Draft"
      assert html =~ "Only an approver for this account can edit or send this draft."
      assert_hidden(html)
      refute html =~ "Media unavailable"
    end

    test "a project reader who may not approve sees what the presentation allows",
         %{conn: conn} = ctx do
      view = open(conn, ctx, ctx.n)
      card = "#queue-draft-card-#{ctx.ypost.id}"

      assert has_element?(view, "#{card} [data-role='draft-body']", @caption)
      assert has_element?(view, "#{card} [data-role='draft-title']", @yt_title)
      assert has_element?(view, "#{card} [data-role='draft-time']")
      assert has_element?(view, "#{card} [data-role='draft-read-only']")
      assert has_element?(view, "#{card} [data-role='draft-media'] video")
      refute has_element?(view, "#{card} form")
    end

    test "an approver with files.read sees caption, title, media and time", %{conn: conn} = ctx do
      view = open(conn, ctx, ctx.h1)
      card = "#queue-draft-card-#{ctx.ypost.id}"

      assert has_element?(view, "#{card} textarea[name='body']", @caption)
      assert has_element?(view, "#{card} input[name='title'][value='#{@yt_title}']")
      assert has_element?(view, "#{card} input[type='datetime-local'][name='at']")
      assert has_element?(view, "#{card} [data-role='draft-media'] video")
      assert has_element?(view, "#{card} [data-role='draft-media']", @file_name)
    end

    test "an approver without files.read keeps the text but loses media names and types",
         %{conn: conn} = ctx do
      deny!(ctx.h1, "files.read", ctx.media_project)
      view = open(conn, ctx, ctx.h1)
      card = "#queue-draft-card-#{ctx.ypost.id}"
      html = card_html(view, ctx.ypost)

      assert has_element?(view, "#{card} textarea[name='body']", @caption)
      assert has_element?(view, "#{card} input[name='title'][value='#{@yt_title}']")
      assert has_element?(view, "#{card} input[type='datetime-local'][name='at']")
      assert has_element?(view, "#{card} [data-role='draft-media-unavailable']")
      refute html =~ @file_name
      refute html =~ "/files/blob/#{ctx.media.id}"
      refute html =~ "<video"
    end

    test "a non-approver without files.read also loses the media", %{conn: conn} = ctx do
      deny!(ctx.n, "files.read", ctx.media_project)
      html = conn |> open(ctx, ctx.n) |> card_html(ctx.ypost)

      assert html =~ @caption
      refute html =~ @file_name
      refute html =~ "/files/blob/"
      assert html =~ "Media unavailable"
    end

    # A read-only viewer has no form, but the card still receives events
    # (`draft_change` / `draft_submit` can be pushed to any rendered card). Every
    # such event re-renders the card, so it must re-evaluate the viewer's read
    # authority at that moment, not reuse what the Queue load held.
    defp card_event(view, post, event, params) do
      view |> with_target("#queue-draft-card-#{post.id}") |> render_hook(event, params)
      card_html(view, post)
    end

    for event <- ["draft_change", "draft_submit"] do
      test "#{event}: a reader whose social.use is revoked after load loses caption, title, media and time",
           %{conn: conn} = ctx do
        view = open(conn, ctx, ctx.n)
        card = "#queue-draft-card-#{ctx.ypost.id}"
        assert has_element?(view, "#{card} [data-role='draft-body']", @caption)

        deny!(ctx.n, "social.use", ctx.project)
        html = card_event(view, ctx.ypost, unquote(event), %{"body" => "typed"})

        assert html =~ "Draft"
        assert_hidden(html)
        refute html =~ "typed"
        refute html =~ "Media unavailable"
      end

      test "#{event}: a reader whose files.read is revoked after load loses the media names",
           %{conn: conn} = ctx do
        view = open(conn, ctx, ctx.n)
        card = "#queue-draft-card-#{ctx.ypost.id}"
        assert has_element?(view, "#{card} [data-role='draft-media']", @file_name)

        deny!(ctx.n, "files.read", ctx.media_project)
        html = card_event(view, ctx.ypost, unquote(event), %{"body" => "typed"})

        refute html =~ @file_name
        refute html =~ "/files/blob/"
        assert html =~ "Media unavailable"
      end
    end
  end

  # The card holds `profile` and `account` structs from the Queue load. A change
  # to the approver list or the account owner after render must show in the card
  # on its next event (presentation only: `Social.edit_draft/5` re-checks the
  # locked row by itself).
  describe "edit rights are re-read from the database on every event" do
    defp hook(view, post, event, params),
      do: view |> with_target("#queue-draft-card-#{post.id}") |> render_hook(event, params)

    defp lose_rights!(:approver_list, ctx) do
      {:ok, _} =
        Social.update_profile(ctx.org_id, ctx.profile, %{approver_user_ids: [ctx.h2.id]})
    end

    defp lose_rights!(:account_owner, ctx) do
      {:ok, _} = Social.set_account_owner(ctx.org_id, ctx.a, ctx.h2.id)
    end

    for cause <- [:approver_list, :account_owner], event <- ["draft_change", "draft_submit"] do
      test "#{event}: viewer loses edit rights through the #{cause} after render",
           %{conn: conn} = ctx do
        if unquote(cause) == :account_owner,
          do: {:ok, _} = Social.set_account_owner(ctx.org_id, ctx.a, ctx.h1.id)

        p = draft!(ctx, ctx.a, %{body: "Draft caption"})
        view = open(conn, ctx, ctx.h1)
        assert has_element?(view, form(p))
        before = Repo.get!(Post, p.id)
        events = Repo.aggregate(Platform.Social.PostEvent, :count)

        lose_rights!(unquote(cause), ctx)

        hook(view, p, unquote(event), %{
          "body" => "typed after losing rights",
          "at" => future_local(),
          "intent" => "save"
        })

        refute has_element?(view, form(p))
        refute has_element?(view, "[data-role='draft-save']")
        refute has_element?(view, "[data-role='draft-send']")
        refute render(view) =~ "typed after losing rights"
        assert Repo.get!(Post, p.id) == before
        assert Repo.aggregate(Platform.Social.PostEvent, :count) == events
      end
    end

    for event <- ["draft_change", "draft_submit"] do
      test "#{event}: a reader who loses edit rights sees the stored caption, not typed input",
           %{conn: conn} = ctx do
        project = Platform.SocialFixtures.project!(ctx.org_id)

        {:ok, profile} =
          Social.update_profile(ctx.org_id, ctx.profile, %{project_id: project.id})

        ctx = %{ctx | profile: profile}
        p = draft!(ctx, ctx.a, %{body: "Draft caption"})
        view = open(conn, ctx, ctx.h1)
        assert has_element?(view, form(p))

        lose_rights!(:approver_list, ctx)

        hook(view, p, unquote(event), %{
          "body" => "typed after losing rights",
          "at" => future_local(),
          "intent" => "save"
        })

        html = render(view)
        refute has_element?(view, form(p))
        assert html =~ "Draft caption"
        refute html =~ "typed after losing rights"
        assert Repo.get!(Post, p.id).body == "Draft caption"
      end
    end

    test "rights that are kept: the form is still offered and a save works",
         %{conn: conn} = ctx do
      p = draft!(ctx, ctx.a, %{body: "Draft caption"})
      view = open(conn, ctx, ctx.h1)
      # An unrelated change to the approver list that keeps the viewer on it.
      {:ok, _} =
        Social.update_profile(ctx.org_id, ctx.profile, %{
          approver_user_ids: [ctx.h1.id, ctx.n.id]
        })

      hook(view, p, "draft_change", %{"body" => "kept"})
      assert has_element?(view, form(p))

      view |> element(form(p)) |> render_submit(%{"body" => "Saved body", "intent" => "save"})
      assert Repo.get!(Post, p.id).body == "Saved body"
    end

    test "a deleted post renders a minimal card with no form and no crash", %{conn: conn} = ctx do
      p = draft!(ctx, ctx.a, %{body: "Draft caption"})
      view = open(conn, ctx, ctx.h1)
      Repo.delete!(Repo.get!(Post, p.id))

      hook(view, p, "draft_change", %{"body" => "x"})
      refute has_element?(view, form(p))
      refute render(view) =~ "Draft caption"
    end
  end
end
