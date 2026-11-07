defmodule PlatformWeb.SupportAccessUITest do
  @moduledoc """
  Task 01a1b362 stage 2: the owner-facing UI of vendor support access
  (design canvas 01a1b362-e9b9): Settings → Support, the active-session
  banner in the shell, and the member-list marker.

  Mutations each block here must catch:

    * the banner rendered with NO live session ("no banner without a live
      session", on two routes);
    * the marker dropped ("marker renders only for support users", both
      lists);
    * a non-admin allowed to toggle ("a non-admin cannot see or flip the
      switch", a forged event included).
  """
  # async: false: flips :platform :support_access app env.
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SupportAccessFixtures

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.SupportAccess
  alias Platform.SupportAccess.Session
  alias Platform.SupportAccess.Settings
  alias Platform.Tenancy
  alias PlatformWeb.SupportAccessCopy, as: Copy

  @vendor "Testvendor"

  setup ctx do
    ctx = setup_support_access(ctx)
    put_vendor_name(@vendor)
    set_enabled!(true)

    admin = user!("owner")
    {:ok, _} = Tenancy.promote_to_admin(admin)
    assert Tenancy.root_admin?(admin)

    Map.put(ctx, :admin, admin)
  end

  # -- fixtures -------------------------------------------------------------

  defp put_vendor_name(name) do
    env = Application.get_env(:platform, :support_access, [])
    Application.put_env(:platform, :support_access, Keyword.put(env, :vendor_name, name))
  end

  defp user!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "#{label}-#{n}@example.test",
      name: "#{String.capitalize(label)} #{n}",
      oidc_sub: "#{label}-#{n}",
      preferences: %{"first_run_goal" => "existing"}
    })
  end

  defp support_user!(name \\ "Pat Operator (#{@vendor} support)") do
    n = System.unique_integer([:positive])

    %User{}
    |> User.support_changeset(%{
      email: "support-#{n}@support.test",
      name: name,
      oidc_sub: "support-vendor:test-#{n}"
    })
    |> Repo.insert!()
  end

  defp session!(kind, opts \\ []) do
    now = DateTime.utc_now()
    minutes = Keyword.get(opts, :minutes, 90)

    {:ok, session} =
      Session.create_changeset(%{
        kind: kind,
        operator_name: Keyword.get(opts, :operator, "Pat"),
        operator_email: "pat@support.test",
        user_id: Keyword.get(opts, :user_id),
        not_before: now,
        not_after: DateTime.add(now, minutes * 60, :second)
      })
      |> Repo.insert()

    session
  end

  defp authed(user), do: build_conn() |> init_test_session(current_user_id: user.id)

  defp settings!(user) do
    {:ok, view, _html} = live(authed(user), "/settings")
    view
  end

  defp sentence(view),
    do: view |> element("[data-role=settings-support-sentence]") |> render() |> text()

  defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> squish()

  defp squish(s), do: s |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp banner?(view), do: has_element?(view, "[data-role=support-banner]")

  # -- the three state sentences --------------------------------------------

  describe "state sentence" do
    test "on, idle", %{admin: admin} do
      view = settings!(admin)
      assert has_element?(view, "#support[data-state=idle]")
      assert sentence(view) == Copy.idle_sentence()

      assert sentence(view) ==
               "#{@vendor} can sign in as an admin or open a repair session on your server " <>
                 "for a few hours, to help you. Every visit is recorded below. Turn this off " <>
                 "and #{@vendor} can't get in at all."

      refute has_element?(view, "[data-role=settings-support-end]")
    end

    test "on, session active: who, until when, and End session", %{admin: admin} do
      s = session!("admin", operator: "Dalton")
      view = settings!(admin)

      assert has_element?(view, "#support[data-state=active]")
      until = PlatformWeb.Components.SupportAccessComponents.clock(s.not_after, nil)

      assert sentence(view) == "#{@vendor} (Dalton) is helping right now, until #{until}."
      assert has_element?(view, "[data-role=settings-support-until].font-mono", until)
      assert has_element?(view, "[data-role=settings-support-end]", "End session")
    end

    test "off", %{admin: admin} do
      set_enabled!(false)
      view = settings!(admin)

      assert has_element?(view, "#support[data-state=off]")

      assert sentence(view) ==
               "Off. #{@vendor} can't sign in or open a repair session. " <>
                 "Turn it back on any time if you need help."
    end

    test "with no vendor name configured, the copy says Vendor support", %{admin: admin} do
      put_vendor_name(nil)
      session!("admin")
      view = settings!(admin)

      assert has_element?(view, "[data-role=settings-support-title]", "Vendor support access")
      assert sentence(view) =~ "Vendor support (Pat) is helping right now"

      assert view |> element("[data-role=support-banner]") |> render() =~
               "Vendor support is signed in"
    end
  end

  # -- the switch -----------------------------------------------------------

  describe "switch" do
    test "turns off and back on with one click each, no confirm", %{admin: admin} do
      view = settings!(admin)
      switch = "[data-role=settings-support-switch]"

      refute render(view) =~ "data-confirm"
      assert has_element?(view, ~s(#{switch}[aria-checked="true"]))

      view |> element(switch) |> render_click()
      refute Settings.enabled?()
      assert has_element?(view, "#support[data-state=off]")
      assert has_element?(view, ~s(#{switch}[aria-checked="false"]))

      view |> element(switch) |> render_click()
      assert Settings.enabled?()
      assert has_element?(view, "#support[data-state=idle]")
    end

    test "turning it off during a session ends the session and the row says so",
         %{admin: admin} do
      s = session!("repair")
      view = settings!(admin)
      assert has_element?(view, "#support-visit-session-#{s.id}[data-state=active]")

      view |> element("[data-role=settings-support-switch]") |> render_click()

      assert %Session{end_reason: "access_turned_off"} = Repo.get(Session, s.id)

      assert view |> element("#support-visit-session-#{s.id}") |> render() |> text() =~
               "ended when support access was turned off"

      refute banner?(view)
    end

    test "the history stays visible when off and lists a refused request with its reason",
         %{admin: admin} do
      set_enabled!(false)

      SupportAccess.audit("support.grant_refused", %{
        action: "grant_refused",
        metadata: %{
          "kind" => "admin",
          "operator_name" => "Dalton",
          "reason" => "support_access_off"
        }
      })

      view = settings!(admin)
      assert has_element?(view, "[data-role=settings-support-history-label]")

      assert has_element?(
               view,
               "[data-role=support-visit][data-state=refused]",
               "refused: support access was off"
             )
    end

    test "the all-activity list opens from the card", %{admin: admin} do
      s = session!("admin")
      {:ok, _} = SupportAccess.end_session(admin, s.id)
      view = settings!(admin)

      view |> element("[data-role=settings-support-all]") |> render_click()
      assert has_element?(view, "[data-role=support-activity]", "Admin sign-in ended early")
    end
  end

  # -- End session and the banner -------------------------------------------

  describe "banner" do
    test "End session ends it and the banner leaves over PubSub, on another page too",
         %{admin: admin} do
      s = session!("admin")
      settings = settings!(admin)
      {:ok, chat, _} = live(authed(admin), "/chat")

      assert banner?(settings)
      assert banner?(chat)

      settings |> element("[data-role=settings-support-end]") |> render_click()

      assert %Session{end_reason: "ended_by_owner"} = Repo.get(Session, s.id)
      refute banner?(settings)
      # /chat never got an event of its own: only the PubSub message.
      refute banner?(chat)
    end

    test "a session started elsewhere shows the banner without a reload", %{admin: admin} do
      {:ok, view, _} = live(authed(admin), "/tasks")
      refute banner?(view)

      session!("admin")
      SupportAccess.broadcast_changed()

      assert banner?(view)
    end

    test "is on two different routes, for a member too, and has no dismiss control",
         %{admin: admin} do
      s = session!("admin")
      member = user!("member")
      until = PlatformWeb.Components.SupportAccessComponents.clock(s.not_after, nil)

      for {user, path} <- [{admin, "/settings"}, {admin, "/tasks"}, {member, "/tasks"}] do
        {:ok, view, _} = live(authed(user), path)
        banner = view |> element("[data-role=support-banner]") |> render()

        assert text(banner) =~ "#{@vendor} support is signed in to help, until #{until}."
        refute banner =~ "<button"
        refute banner =~ ~r/dismiss|close/i
        refute banner =~ ~r/bg-(warning|primary)/
        assert banner =~ "bg-info"
      end

      {:ok, view, _} = live(authed(member), "/tasks")
      refute has_element?(view, "[data-role=support-banner-details]")
      {:ok, view, _} = live(authed(admin), "/tasks")
      assert has_element?(view, ~s([data-role=support-banner-details][href="/settings#support"]))
    end

    test "a repair-only session says working on your server", %{admin: admin} do
      session!("repair")
      {:ok, view, _} = live(authed(admin), "/tasks")

      assert view |> element("[data-role=support-banner]") |> render() =~
               "support is working on your server to help"
    end

    test "no banner without a live session, on two routes", %{admin: admin} do
      ended = session!("admin")
      {:ok, _} = SupportAccess.end_session(admin, ended.id)

      for path <- ["/settings", "/tasks"] do
        {:ok, view, html} = live(authed(admin), path)
        refute banner?(view)
        refute html =~ "support-banner"
      end
    end
  end

  # -- member-list marker ---------------------------------------------------

  describe "marker" do
    test "Chat members: only the support user's row has the marker and its leave time",
         %{admin: admin} do
      support = support_user!()
      s = session!("admin", user_id: support.id)

      {:ok, space} =
        Chat.create_space(%{
          name: "support-marker",
          slug: "sm-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      for u <- [admin, support] do
        {:ok, _} =
          Chat.add_participant(space.id, %{
            participant_type: "user",
            participant_id: u.id,
            display_name: u.name,
            joined_at: DateTime.utc_now()
          })
      end

      html =
        render_component(PlatformWeb.ChatLive.MembersComponent,
          id: "chat-members-popover",
          surface: :popover,
          open: true,
          space: space,
          current_user_id: admin.id,
          viewer: admin
        )

      doc = LazyHTML.from_fragment(html)
      rows = LazyHTML.query(doc, "[data-role=members-person-row]")
      assert Enum.count(rows) == 2

      for row <- rows do
        [id] = LazyHTML.attribute(row, "data-user-id")
        markers = LazyHTML.query(row, "[data-role=support-marker]") |> Enum.count()

        if id == support.id do
          assert markers == 1
          assert LazyHTML.text(row) =~ @vendor
          until = PlatformWeb.Components.SupportAccessComponents.clock(s.not_after, nil)
          assert squish(LazyHTML.text(row)) =~ "leaves at #{until}"
          # The marker is never cut: it does not shrink, the name does.
          [marker] = LazyHTML.query(row, "[data-role=support-marker]") |> Enum.to_list()
          assert hd(LazyHTML.attribute(marker, "class")) =~ "shrink-0"
        else
          assert markers == 0
          refute LazyHTML.text(row) =~ "leaves at"
        end
      end
    end

    test "Sign-in users: only the support user's row has the marker", %{admin: admin} do
      keys = [:sign_in_admin_enabled, :sign_in_admin_url, :sign_in_admin_api_key]
      saved = for key <- keys, do: {key, Application.fetch_env(:platform, key)}

      on_exit(fn ->
        for {key, value} <- saved do
          case value do
            {:ok, v} -> Application.put_env(:platform, key, v)
            :error -> Application.delete_env(:platform, key)
          end
        end
      end)

      Application.put_env(:platform, :sign_in_admin_enabled, true)
      Application.put_env(:platform, :sign_in_admin_url, "http://pocket-id.test")
      Application.put_env(:platform, :sign_in_admin_api_key, "test-key")

      support = support_user!()
      session!("admin", user_id: support.id)
      plain = user!("plain")

      html = authed(admin) |> get("/admin/sign-in-users") |> html_response(200)
      doc = LazyHTML.from_document(html)

      for {user, expected} <- [{support, 2}, {plain, 0}, {admin, 0}] do
        rows = LazyHTML.query(doc, ~s([data-user-id="#{user.id}"]))
        # One table row and one phone list item per user.
        assert Enum.count(rows) == 2
        markers = LazyHTML.query(rows, "[data-role=support-marker]") |> Enum.count()
        assert markers == expected, "#{user.name}: #{markers} markers"
      end
    end
  end

  # -- authorization --------------------------------------------------------

  describe "a non-admin" do
    test "cannot see or flip the switch, even with a forged event", %{admin: _admin} do
      member = user!("member")
      view = settings!(member)

      refute has_element?(view, "#support")
      refute has_element?(view, "[data-role=settings-support-switch]")

      render_click(view, "set_support_access", %{"enabled" => "false"})
      assert Settings.enabled?()

      s = session!("admin")
      render_click(view, "end_support_session", %{})
      assert Session.active?(Repo.get(Session, s.id), DateTime.utc_now())

      render_click(view, "open_support_activity", %{})
      refute has_element?(view, "[data-role=support-activity-list]")
    end

    test "a vendor support user holding install admin cannot either" do
      support = support_user!()
      {:ok, _} = Tenancy.promote_to_admin(support, reason: "support_session")
      s = session!("admin", user_id: support.id)

      conn =
        build_conn()
        |> init_test_session(current_user_id: support.id, support_session_id: s.id)

      {:ok, view, _} = live(conn, "/settings")
      refute has_element?(view, "#support")

      render_click(view, "set_support_access", %{"enabled" => "false"})
      assert Settings.enabled?()
    end

    test "an admin on an install with no vendor key sees no card", %{admin: admin} do
      env = Application.get_env(:platform, :support_access)
      Application.put_env(:platform, :support_access, Keyword.put(env, :vendor_keys, %{}))

      view = settings!(admin)
      refute has_element?(view, "#support")
    end
  end

  # -- copy -----------------------------------------------------------------

  describe "copy" do
    test "no owner-facing string contains an excluded word", %{admin: admin} do
      excluded = Copy.excluded_words()
      assert excluded == ~w(ssh certificate grant impersonation)

      reasons = ~w(support_access_off grant_expired replayed_nonce duration_too_long
                   wrong_install operator_email_taken malformed_grant bad_signature)

      events =
        for type <- ~w(access_changed grant_requested grant_issued grant_refused session_ended
                       action shell_opened shell_command shell_closed shell_unmatched other),
            reason <- reasons ++ ~w(expired ended_by_owner access_turned_off) do
          %{
            event_type: "support." <> type,
            metadata: %{"kind" => "repair", "reason" => reason, "to" => true}
          }
        end

      strings =
        [
          Copy.section_label(),
          Copy.card_title(),
          Copy.idle_sentence(),
          Copy.off_sentence(),
          Copy.end_session(),
          Copy.save_failed(),
          Copy.end_failed(),
          Copy.state_file_pending(),
          Copy.history_heading(),
          Copy.history_empty(),
          Copy.view_all(),
          Copy.activity_title(),
          Copy.activity_empty(),
          Copy.status_active(),
          Copy.banner_details(),
          Copy.marker(),
          Copy.leaves_at()
        ] ++
          Tuple.to_list(Copy.active_sentence(["Pat"])) ++
          Tuple.to_list(Copy.banner_admin()) ++
          Tuple.to_list(Copy.banner_repair()) ++
          Enum.map(~w(admin repair other), &Copy.kind_label/1) ++
          Enum.map(~w(expired ended_by_owner access_turned_off other), &Copy.end_reason_label/1) ++
          Enum.map(reasons, &Copy.refused_label/1) ++
          Enum.map(events, &Copy.activity_line/1)

      # And what the pages actually render, in every card state.
      session!("admin")
      session!("repair")

      SupportAccess.audit("support.grant_refused", %{
        action: "grant_refused",
        metadata: %{"kind" => "admin", "operator_name" => "Pat", "reason" => "grant_expired"}
      })

      active = settings!(admin)
      active |> element("[data-role=settings-support-all]") |> render_click()
      rendered_active = active |> element("#settings") |> render() |> text()
      set_enabled!(false)

      Repo.update_all(Session,
        set: [ended_at: DateTime.utc_now(), end_reason: "access_turned_off"]
      )

      rendered_off = settings!(admin) |> element("#support") |> render() |> text()

      for s <- strings ++ [rendered_active, rendered_off], word <- excluded do
        refute s =~ ~r/\b#{word}\b/i, "#{inspect(word)} in #{inspect(s)}"
      end
    end
  end

  test "Accounts.get_user keeps the support flag the views read" do
    support = support_user!()
    assert %User{support_vendor: true} = Accounts.get_user(support.id)
  end
end
