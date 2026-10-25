defmodule PlatformWeb.SettingsLiveTest do
  @moduledoc """
  `/settings` (task 01a1557a-807f stage 1; re-skinned with the Admin sheet,
  the Mask names switch and the Sign out confirm by task 01a1557a-e538 stage
  3).

  Gated rows are checked against REAL mounts, not against a restatement of
  the rules: for each actor, a row is present exactly when `live/2` of its
  path succeeds for that actor.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Platform.MaskAssertions
  import Platform.TenancyFixtures

  alias Platform.Access.{Grants, Scope}
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks, Tenancy}
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.{ModuleGate, SettingsLive}

  @settings_path "lib/platform_web/live/settings_live.ex"

  defp user!(role, org_id, external? \\ false) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "settings-#{n}@example.com",
        name: "Settings User #{n}",
        oidc_sub: "settings-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: role,
      external: external?
    })
    |> Repo.insert!()

    user
  end

  defp member!, do: user!("member", acme_org_id())
  defp root!, do: user!("admin", acme_org_id())
  defp guest!, do: user!("member", tenant_org_id("settings-guest"), true)

  # A child-org member holding a project-scoped prompts.manage grant: the
  # nearest thing to a "prompts module admin" short of root.
  defp prompts_grantee! do
    child = tenant_org_id("settings-prompts-#{System.unique_integer([:positive])}")
    user = user!("member", child)
    {:ok, project} = Tasks.create_project(%{name: "Settings prompts scope", org_id: child})
    {:ok, _} = Grants.grant(%{principal: user, permission: "prompts.manage", resource: project})
    user
  end

  # A member of every org (admin in Acme): what Tasks' viewer-scoped rail needs.
  defp everywhere! do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "settings-all-#{n}@example.com",
        name: "Settings All #{n}",
        oidc_sub: "settings-all-#{n}"
      })

    Enum.each(Tenancy.list_orgs(), fn org ->
      role = if org.slug == "acme", do: "admin", else: "member"

      %OrgMembership{}
      |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
      |> Repo.insert!()
    end)

    user
  end

  defp authed(user), do: build_conn() |> init_test_session(current_user_id: user.id)

  defp scope(user), do: Scope.for_user(Accounts.get_user(user.id))

  defp query(html, selector), do: html |> LazyHTML.from_document() |> LazyHTML.query(selector)

  defp roles(html), do: html |> query("[data-role^=settings-]") |> LazyHTML.attribute("data-role")

  defp admin_labels(html) do
    html
    |> query("#settings-admin-sheet [data-role=settings-admin-row]")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  # A page mounts when its GET answers 200 AND the connected mount does not
  # redirect. A plug that answers 404 or redirects (an external user fenced
  # off a route, the sign-in switch off) is "does not mount".
  defp mounts?(user, path) do
    conn = get(authed(user), path)

    conn.status == 200 and
      match?({:ok, _view, _html}, live(conn))
  end

  # `/settings` for any actor. A guest's direct GET is fenced by the external
  # scope plug, so a guest reaches it in-app from /chat, as a guest would.
  defp settings(user) do
    conn = authed(user)

    if get(conn, "/settings").status == 200 do
      live(conn, "/settings")
    else
      {:ok, chat, _} = live(conn, "/chat")
      live_redirect(chat, to: "/settings")
    end
  end

  defp open_admin(view), do: view |> element("[data-role=settings-admin]") |> render_click()

  describe "layout" do
    test "#settings is on base-200 with one h1 'Settings', a back button and an xl avatar" do
      {:ok, _view, html} = live(authed(member!()), "/settings")
      [root] = query(html, "#settings") |> Enum.to_list()
      assert LazyHTML.attribute(root, "class") |> hd() =~ "bg-base-200"

      assert [h1] = query(html, "#settings h1") |> Enum.to_list()
      assert LazyHTML.text(h1) |> String.trim() == "Settings"

      assert query(html, "[data-role=settings-back]") |> LazyHTML.attribute("phx-click") ==
               ["open_more_sheet"]

      assert query(html, "[data-role=settings-profile] .size-\\[72px\\]") |> Enum.count() == 1
    end

    test "the back button opens the More sheet on /settings" do
      {:ok, view, _html} = live(authed(member!()), "/settings")
      refute :sys.get_state(view.pid).socket.assigns.more_sheet_open
      view |> element("[data-role=settings-back]") |> render_click()
      assert :sys.get_state(view.pid).socket.assigns.more_sheet_open
    end

    test "the profile head shows the name and the email in text-subtle" do
      member = member!()
      {:ok, view, _html} = live(authed(member), "/settings")

      assert view |> element("[data-role=settings-profile]") |> render() =~ member.name
      assert has_element?(view, "[data-role=settings-profile] p.text-subtle", member.email)
    end

    test "a root admin sees the rows in order, Sign out last" do
      {:ok, _view, html} = live(authed(root!()), "/settings")

      top_level =
        html
        |> roles()
        |> Enum.filter(
          &(&1 in ~w(settings-back settings-profile settings-theme settings-notifications
                     settings-mask-names settings-usage settings-admin settings-sign-out))
        )

      assert top_level ==
               ~w(settings-back settings-profile settings-theme settings-notifications
               settings-mask-names settings-usage settings-admin settings-sign-out)
    end

    # Burrow redesign 22 stage 1: the account menu is gone (the sidebar's
    # user row links here, where Sign out lives) and the theme picker's lg
    # popover lives in the sidebar, still hidden below lg.
    test "no account menu; the theme picker's lg popover is hidden below lg" do
      {:ok, _view, html} = live(authed(member!()), "/settings")

      assert query(html, "#account-menu") |> Enum.to_list() == []
      [el] = query(html, "#sidebar #theme-picker") |> Enum.to_list()
      assert LazyHTML.attribute(el, "class") |> hd() =~ "max-lg:hidden"
    end
  end

  describe "theme" do
    test "clicking Theme opens the existing theme picker sheet" do
      {:ok, view, _html} = live(authed(member!()), "/settings")

      refute has_element?(view, "#theme-picker-sheet[data-open=true]")
      view |> element("[data-role=settings-theme]") |> render_click()

      assert has_element?(view, "#theme-picker-sheet[data-open=true]")
      assert :sys.get_state(view.pid).socket.assigns.theme_picker_open == true
    end

    test "the value reads the stored preference and follows set_theme without a remount" do
      member = member!()

      {:ok, _} =
        Accounts.put_theme_preference(member.id, %{"preset" => "burrow-sand", "mode" => "light"})

      {:ok, view, html} = live(authed(member), "/settings")

      assert query(html, "[data-role=settings-theme-value]") |> LazyHTML.text() ==
               "Burrow sand · Light"

      pid = view.pid
      render_hook(view, "set_theme", %{"preset" => "burrow-forest", "mode" => "dark"})

      assert view |> element("[data-role=settings-theme-value]") |> render() =~
               "Burrow forest · Dark"

      assert view.pid == pid
    end

    test "theme_value/1 names the preset and capitalises the mode" do
      assert SettingsLive.theme_value(%{"preset" => "burrow", "mode" => "system"}) ==
               "Burrow · System"
    end
  end

  describe "mask names" do
    test "aria-checked follows the stored state, and a click writes it and flips" do
      member = member!()
      {:ok, view, _html} = live(authed(member), "/settings")

      assert has_element?(view, "[data-role=settings-mask-names][aria-checked=false]")
      refute has_element?(view, "[data-role=settings-mask-until]")

      view |> element("[data-role=settings-mask-names]") |> render_click()

      assert Accounts.mask_names?(Accounts.get_user(member.id))
      assert has_element?(view, "[data-role=settings-mask-names][aria-checked=true]")
      assert has_element?(view, "[data-role=settings-mask-until]", "On until")

      {:ok, fresh, _} = live(authed(member), "/settings")
      assert has_element?(fresh, "[data-role=settings-mask-names][aria-checked=true]")

      fresh |> element("[data-role=settings-mask-names]") |> render_click()
      refute Accounts.mask_names?(Accounts.get_user(member.id))
      assert has_element?(fresh, "[data-role=settings-mask-names][aria-checked=false]")
    end

    test "the helper names when masking ends, in the viewer's zone" do
      user = member!()
      now = ~U[2026-10-21 14:41:00Z]
      {:ok, _} = Accounts.put_mask_names(user.id, true, now)
      user = Accounts.get_user(user.id)

      # 02:41Z next day is 9:41 pm in Chicago (CDT, UTC-5).
      assert SettingsLive.mask_until_label(user, "America/Chicago", now) == "On until 9:41 pm"
      assert SettingsLive.mask_until_label(user, nil, now) == "On until 2:41 am UTC"
      # Past the expiry, or off, there is no line.
      assert SettingsLive.mask_until_label(user, "America/Chicago", DateTime.add(now, 13, :hour)) ==
               nil

      {:ok, _} = Accounts.put_mask_names(user.id, false, now)
      assert SettingsLive.mask_until_label(Accounts.get_user(user.id), nil, now) == nil
    end

    test "turning it on in Settings masks a fresh /chat and /tasks; B is unaffected" do
      {:ok, _} = Platform.Chat.create_space(%{name: "General", slug: "general", kind: "channel"})

      for {slug, name} <- [{"initech", "Initech Storefront"}, {"globex", "Globex Onboarding"}] do
        {:ok, _} =
          Tasks.create_project(%{
            name: name,
            slug: name |> String.downcase() |> String.replace(" ", "-"),
            org_id: Tenancy.get_org_by_slug!(slug).id
          })
      end

      a = everywhere!()
      b = everywhere!()
      names = ["Initech", "Globex", "Initech Storefront", "Globex Onboarding"]

      {:ok, settings, _} = live(authed(a), "/settings")
      settings |> element("[data-role=settings-mask-names]") |> render_click()

      for path <- ["/chat", "/tasks"] do
        {:ok, _, masked} = follow(authed(a), path)
        {:ok, _, unmasked} = follow(authed(b), path)
        masked = strip_scope_stylesheet(masked)

        for name <- names, path == "/tasks" or name in ["Initech", "Globex"] do
          assert_name_anywhere(unmasked, name)
          refute_name_anywhere(masked, name, ~w(value))
        end
      end
    end
  end

  defp follow(conn, path) do
    case live(conn, path) do
      {:error, {:live_redirect, %{to: to}}} -> live(conn, to)
      ok -> ok
    end
  end

  # The shell's `<style id="org-scope-colors">` keys CSS selectors on real org
  # slugs and renders nothing (see mask_names_shared_test.exs).
  defp strip_scope_stylesheet(html),
    do: Regex.replace(~r/<style id="org-scope-colors"[^>]*>.*?<\/style>/s, html, "")

  describe "admin" do
    test "each admin row and Usage are present exactly when their page mounts" do
      refute Platform.SignInAdmin.Config.enabled?()

      actors = %{
        member: member!(),
        guest: guest!(),
        prompts_grantee: prompts_grantee!(),
        root_admin: root!()
      }

      checked =
        [{"Usage", "/control/usage"}] ++
          for row <- SettingsLive.admin_rows(),
              not Map.get(row, :sign_in, false),
              do: {row.label, row.path}

      results =
        for {name, user} <- actors do
          {:ok, view, html} = settings(user)
          usage? = "settings-usage" in roles(html)

          labels =
            if has_element?(view, "[data-role=settings-admin]"),
              do: view |> open_admin() |> admin_labels(),
              else: []

          for {label, path} <- checked do
            shown? = if label == "Usage", do: usage?, else: label in labels
            {name, label, shown?, mounts?(user, path)}
          end
        end
        |> List.flatten()

      disagreements = for {n, l, shown?, mounts?} <- results, shown? != mounts?, do: {n, l}

      # ONE known disagreement, pinned (01a15be9): ModuleGate admits a
      # project-scoped prompts.manage grantee to AdminPromptsLive, whose own
      # `PromptTemplates.list_templates/1` re-check then sends them to
      # /access-denied. The row follows ModuleGate by design. When the split is
      # closed this becomes [] and this assertion must be updated.
      assert disagreements == [{:prompts_grantee, "Prompts"}], inspect(results)

      assert Enum.any?(results, fn {_, _, _, m} -> m end)
      refute Enum.all?(results, fn {_, _, _, m} -> m end)
    end

    test "rows are alphabetical; Users is absent while the sign-in switch is off" do
      refute Platform.SignInAdmin.Config.enabled?()
      {:ok, view, _html} = live(authed(root!()), "/settings")
      labels = view |> open_admin() |> admin_labels()

      assert labels == Enum.sort(labels)
      assert "Access" in labels
      refute "Users" in labels

      # The value is the first three labels, lower-case.
      assert view |> element("[data-role=settings-admin]") |> render() =~
               labels |> Enum.take(3) |> Enum.map_join(", ", &String.downcase/1)
    end

    test "Users is listed for a root admin while the sign-in switch is on" do
      keys = [:sign_in_admin_enabled, :sign_in_admin_url, :sign_in_admin_api_key]
      saved = for k <- keys, do: {k, Application.fetch_env(:platform, k)}

      on_exit(fn ->
        for {k, v} <- saved do
          case v do
            {:ok, value} -> Application.put_env(:platform, k, value)
            :error -> Application.delete_env(:platform, k)
          end
        end
      end)

      Application.put_env(:platform, :sign_in_admin_enabled, true)
      Application.put_env(:platform, :sign_in_admin_url, "http://pocket-id.test")
      Application.put_env(:platform, :sign_in_admin_api_key, "settings-test-key")
      assert Platform.SignInAdmin.Config.enabled?()

      root = root!()
      {:ok, view, _html} = live(authed(root), "/settings")
      assert "Users" in (view |> open_admin() |> admin_labels())

      member = member!()
      {:ok, mview, _} = live(authed(member), "/settings")
      refute has_element?(mview, "[data-role=settings-admin]")
    end

    test "the Admin row is absent when no admin page mounts" do
      member = member!()
      assert SettingsLive.visible_admin_rows(scope(member)) == []
      {:ok, _view, html} = live(authed(member), "/settings")
      refute "settings-admin" in roles(html)
      refute mounts?(member, "/admin/orgs")
    end

    test "a guest Scope passes the page gate and is shown no gated row" do
      guest_scope = scope(guest!())
      assert Scope.guest?(guest_scope)
      assert ModuleGate.mounts?(guest_scope, PlatformWeb.SettingsLive)
      assert SettingsLive.visible_admin_rows(guest_scope) == []
    end

    test "a guest navigating in-app from /chat mounts /settings with no gated row" do
      guest = guest!()
      {:ok, chat, _} = live(authed(guest), "/chat")
      {:ok, _view, html} = live_redirect(chat, to: "/settings")

      roles = roles(html)
      assert "settings-sign-out" in roles
      refute "settings-usage" in roles
      refute "settings-admin" in roles
    end
  end

  describe "sign out" do
    test "the row opens a confirm sheet and does not sign out; Cancel closes it" do
      member = member!()
      conn = authed(member)
      {:ok, view, _html} = live(conn, "/settings")

      refute has_element?(view, "#settings-sign-out-sheet[data-open=true]")
      view |> element("[data-role=settings-sign-out]") |> render_click()
      assert has_element?(view, "#settings-sign-out-sheet[data-open=true]")

      assert view |> element("#settings-sign-out-sheet-title") |> render() =~
               "Sign out of #{Platform.Branding.app_name()} on this device?"

      # Still signed in: the page mounts again for the same session.
      assert {:ok, _, _} = live(conn, "/settings")

      view |> element("[data-role=settings-sign-out-cancel]") |> render_click()
      refute has_element?(view, "#settings-sign-out-sheet[data-open=true]")
    end

    test "the row is a button, not a link to /auth/logout" do
      {:ok, _view, html} = live(authed(member!()), "/settings")
      [row] = query(html, "[data-role=settings-sign-out]") |> Enum.to_list()
      assert row |> LazyHTML.tag() == ["button"]
      assert LazyHTML.attribute(row, "href") == []
    end

    test "the confirm is a plain GET link to a real logout route, with no phx-click" do
      {:ok, _view, html} = live(authed(member!()), "/settings")
      [confirm] = query(html, "[data-role=settings-sign-out-confirm]") |> Enum.to_list()

      assert LazyHTML.tag(confirm) == ["a"]
      assert LazyHTML.attribute(confirm, "phx-click") == []
      [href] = LazyHTML.attribute(confirm, "href")

      assert %{plug: PlatformWeb.AuthController, plug_opts: :logout} =
               Phoenix.Router.route_info(PlatformWeb.Router, "GET", href, "localhost")

      assert href == "/auth/logout"
    end

    test "GET /auth/logout drops the session" do
      member = member!()
      conn = get(authed(member), "/auth/logout")
      assert conn.status in [302, 303]
      # `configure_session(drop: true)`: the cookie store deletes the session
      # when the response is sent. The in-memory map still holds the id until
      # then, so the drop instruction is what is asserted.
      assert conn.private[:plug_session_info] == :drop
    end

    test "the title never hard-codes Burrow: it follows the install's app name" do
      {:ok, _} = Platform.Branding.update_identity(root!(), %{app_name: "Kiwi Works"})
      {:ok, view, _} = live(authed(member!()), "/settings")
      view |> element("[data-role=settings-sign-out]") |> render_click()
      title = view |> element("#settings-sign-out-sheet-title") |> render()
      assert title =~ "Sign out of Kiwi Works on this device?"
      refute title =~ "Burrow"
    end
  end

  # ── Notifications (task 01a1557a-e538 stage 4) ─────────────────────────────

  defp channel_with!(user) do
    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Settings Push",
        slug: "settings-push-#{System.unique_integer([:positive])}",
        kind: "channel",
        org_id: acme_org_id()
      })

    {:ok, participant} =
      Platform.Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp notifications(user) do
    {:ok, view, _html} = live(authed(user), "/settings")
    view |> element("[data-role=settings-notifications]") |> render_click()
    view
  end

  defp switch(view) do
    [el] =
      view
      |> render()
      |> query("[data-role=settings-push-switch]")
      |> Enum.to_list()

    %{
      checked: LazyHTML.attribute(el, "aria-checked"),
      disabled: LazyHTML.attribute(el, "aria-disabled"),
      click: LazyHTML.attribute(el, "phx-click")
    }
  end

  defp push_line(view) do
    view
    |> render()
    |> query("[data-role=settings-push-line]")
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp error_count(view), do: view |> render() |> query("#settings .text-error") |> Enum.count()

  @subs %{"p256dh" => "p256dh-settings", "auth" => "auth-settings"}

  describe "notifications: push on this device" do
    test "unknown and unsupported render no push row; prompt renders it" do
      view = notifications(member!())
      refute has_element?(view, "[data-role=settings-push]")

      render_hook(view, "push_unsupported", %{})
      refute has_element?(view, "[data-role=settings-push]")

      render_hook(view, "push_permission_state", %{"state" => "prompt"})
      assert has_element?(view, "[data-role=settings-push]")
    end

    test "prompt: off, enabled, no line, tap asks for permission" do
      view = notifications(member!())
      render_hook(view, "push_permission_state", %{"state" => "prompt"})

      assert switch(view) == %{checked: ["false"], disabled: [], click: ["enable_notifications"]}
      assert push_line(view) == ""

      view |> element("[data-role=settings-push-switch]") |> render_click()
      assert_push_event(view, "request_push_permission", %{})
    end

    test "granted and registered: on, tap turns it off" do
      user = member!()
      channel_with!(user)
      view = notifications(user)
      render_hook(view, "push_permission_state", %{"state" => "granted"})

      render_hook(view, "push_subscribed", %{
        "endpoint" => "https://push.example.com/s/on",
        "keys" => @subs
      })

      assert switch(view) == %{checked: ["true"], disabled: [], click: ["disable_notifications"]}
      assert push_line(view) == ""

      assert view |> element("[data-role=settings-notifications-value]") |> render() =~
               "mentions and DMs · push on"

      view |> element("[data-role=settings-push-switch]") |> render_click()
      assert_push_event(view, "disable_push", %{})
    end

    test "granted and opted out: off, enabled, tap asks again" do
      view = notifications(member!())
      render_hook(view, "push_permission_state", %{"state" => "granted", "opted_out" => true})

      assert switch(view) == %{checked: ["false"], disabled: [], click: ["enable_notifications"]}

      assert view |> element("[data-role=settings-notifications-value]") |> render() =~
               "push off"

      view |> element("[data-role=settings-push-switch]") |> render_click()
      assert_push_event(view, "request_push_permission", %{})
    end

    test "denied: off, aria-disabled, the blocked line and a How to allow disclosure" do
      view = notifications(member!())
      render_hook(view, "push_permission_state", %{"state" => "denied"})

      assert switch(view) == %{checked: ["false"], disabled: ["true"], click: []}
      assert push_line(view) == "Blocked in your browser settings."

      html = render(view)
      [how] = html |> query("[data-role=settings-push-how]") |> Enum.to_list()
      assert LazyHTML.tag(how) == ["details"]

      assert LazyHTML.text(how) =~
               PlatformWeb.Components.NotificationState.denied_instruction(:other)

      # NOT a link: no anchor anywhere in the push row.
      assert html |> query("[data-role=settings-push] a") |> Enum.count() == 0
      assert error_count(view) == 0
    end

    test "denied without asking: off, disabled, NotificationState's auto-denied copy" do
      view = notifications(member!())
      render_hook(view, "push_permission_state", %{"state" => "denied", "auto_denied" => true})

      assert %{checked: ["false"], disabled: ["true"], click: []} = switch(view)
      {headline, detail} = PlatformWeb.Components.NotificationState.auto_denied_copy()
      assert push_line(view) == headline <> " " <> detail
    end

    test "granted + subscribe_failed: off, the failed line in error text and Try again" do
      view = notifications(member!())
      render_hook(view, "push_permission_state", %{"state" => "granted"})
      render_hook(view, "push_subscribe_failed", %{"name" => "AbortError", "message" => "x"})

      assert switch(view) == %{checked: ["false"], disabled: [], click: ["enable_notifications"]}
      assert push_line(view) == "Couldn't turn on notifications on this device."

      # A failed action the person just took is error text (task 01a160c4
      # retuned --color-error so it clears 4.5:1 in all ten variants;
      # error_token_contrast_guard_test.exs holds that).
      [line] =
        view |> render() |> query("[data-role=settings-push-line]") |> Enum.to_list()

      assert LazyHTML.attribute(line, "class") |> hd() =~ "text-error"
      assert error_count(view) == 1

      view |> element("[data-role=settings-push-retry]") |> render_click()
      assert_push_event(view, "request_push_permission", %{})

      assert view |> element("[data-role=settings-notifications-value]") |> render() =~
               "push failed"
    end

    test "granted + no_participant: off, the subtle start-a-conversation copy, no button" do
      user = member!()
      view = notifications(user)
      render_hook(view, "push_permission_state", %{"state" => "granted"})

      render_hook(view, "push_subscribed", %{
        "endpoint" => "https://push.example.com/s/none",
        "keys" => @subs
      })

      assert %{checked: ["false"], disabled: ["true"], click: []} = switch(view)
      {headline, detail} = PlatformWeb.Components.NotificationState.no_participant_copy()
      assert push_line(view) == headline <> " " <> detail
      refute has_element?(view, "[data-role=settings-push-retry]")
      assert error_count(view) == 0
    end

    test "android, prompt or denied: off, NotificationState's Android copy, tap re-asks" do
      for state <- ["prompt", "denied"] do
        view = notifications(member!())

        render_hook(view, "push_permission_state", %{
          "state" => state,
          "native_platform" => "android"
        })

        assert switch(view) == %{
                 checked: ["false"],
                 disabled: [],
                 click: ["enable_notifications"]
               }

        {headline, detail} = PlatformWeb.Components.NotificationState.android_off_copy()
        assert push_line(view) == headline <> " " <> detail
      end
    end

    test "native and granted: on, display-only, 'Turn off in your phone's settings.'" do
      view = notifications(member!())

      render_hook(view, "push_permission_state", %{
        "state" => "granted",
        "native_platform" => "android"
      })

      assert switch(view) == %{checked: ["true"], disabled: ["true"], click: []}
      assert push_line(view) == "Turn off in your phone's settings."
    end

    test "push_unsubscribed forgets only the caller's endpoint and turns the switch off" do
      a = member!()
      b = member!()
      endpoint = "https://push.example.com/s/shared-browser"

      for user <- [a, b] do
        p = channel_with!(user)

        {:ok, _} =
          Platform.Push.subscribe(p.id, %{
            endpoint: endpoint,
            keys: %{p256dh: "k", auth: "a"}
          })
      end

      count = fn user ->
        Repo.aggregate(
          from(s in Platform.Push.Subscription,
            join: p in Platform.Chat.Participant,
            on: p.id == s.participant_id,
            where: s.endpoint == ^endpoint and p.participant_id == ^user.id
          ),
          :count
        )
      end

      assert count.(a) == 1 and count.(b) == 1

      view = notifications(a)
      render_hook(view, "push_permission_state", %{"state" => "granted"})
      render_hook(view, "push_unsubscribed", %{"endpoint" => endpoint})

      assert count.(a) == 0
      assert count.(b) == 1
      assert %{checked: ["false"], click: ["enable_notifications"]} = switch(view)
    end
  end

  describe "notifications: level" do
    test "aria-checked follows the stored level, a click writes it, one helper renders" do
      user = member!()
      view = notifications(user)

      assert has_element?(
               view,
               "[data-role=settings-level][data-level=mentions][aria-checked=true]"
             )

      assert view |> render() |> query("[data-role=settings-level-helper]") |> Enum.count() == 1

      view
      |> element("[data-role=settings-level][data-level=direct]")
      |> render_click()

      assert Accounts.notification_level(user.id) == "direct"

      assert has_element?(
               view,
               "[data-role=settings-level][data-level=direct][aria-checked=true]"
             )

      assert has_element?(
               view,
               "[data-role=settings-level][data-level=mentions][aria-checked=false]"
             )

      [helper] = view |> render() |> query("[data-role=settings-level-helper]") |> Enum.to_list()

      assert LazyHTML.text(helper) =~
               "You'll still get a push when someone mentions you directly."

      # A reload keeps it.
      reloaded = notifications(user)

      assert has_element?(
               reloaded,
               "[data-role=settings-level][data-level=direct][aria-checked=true]"
             )
    end

    test "the three labels, in order, and no 'None' anywhere" do
      view = notifications(member!())
      html = render(view)

      labels =
        html
        |> query("[data-role=settings-level] > span.min-w-0 > span:first-child")
        |> Enum.map(&String.trim(LazyHTML.text(&1)))

      assert labels == ["All messages", "Mentions and direct messages", "Only direct mentions"]
      refute html |> query("#settings-notifications-sheet") |> LazyHTML.text() =~ "None"
    end

    test "the radios are buttons in a radiogroup" do
      html = render(notifications(member!()))
      assert html |> query("#settings [role=radiogroup]") |> Enum.count() == 1

      for r <- html |> query("#settings [role=radio]") |> Enum.to_list(),
          do: assert(LazyHTML.tag(r) == ["button"])
    end
  end

  describe "sheet handles (touch swipe-down)" do
    # A bare `.sheet-handle` div is `touch-action: auto`, so a touch drag on it
    # is claimed by the browser (pointercancel) and swipe_dismiss never fires.
    # `handle_close` renders `.sheet-handle-button` (`touch-action: none`).
    test "every Settings sheet renders the handle as .sheet-handle-button" do
      {:ok, _view, html} = live(authed(root!()), "/settings")

      for id <- ~w(settings-notifications-sheet settings-admin-sheet settings-sign-out-sheet) do
        assert html |> query("##{id}[data-swipe-dismiss=true]") |> Enum.count() == 1, id
        assert html |> query("##{id} .sheet-handle-button") |> Enum.count() == 1, id
        assert html |> query("##{id} div.sheet-handle") |> Enum.count() == 0, id
      end
    end

    test "the sign-out title stays visible text, and the accessible title is kept" do
      {:ok, view, _} = live(authed(member!()), "/settings")
      html = view |> element("[data-role=settings-sign-out]") |> render_click()
      title = "Sign out of #{Platform.Branding.app_name()} on this device?"

      [visible] = html |> query("[data-role=settings-sign-out-title]") |> Enum.to_list()
      assert visible |> LazyHTML.text() |> String.trim() == title
      assert LazyHTML.attribute(visible, "aria-hidden") == ["true"]
      refute LazyHTML.attribute(visible, "class") |> hd() =~ "sr-only"

      [accessible] = html |> query("#settings-sign-out-sheet-title") |> Enum.to_list()
      assert accessible |> LazyHTML.text() |> String.trim() == title
    end
  end

  describe "guards" do
    test "no live link in #settings or its sheets carries a phx-click" do
      {:ok, view, _html} = live(authed(root!()), "/settings")
      html = open_admin(view)
      links = query(html, "#settings [data-phx-link]") |> Enum.to_list()

      # Positive control: the Admin sheet is open and holds live links.
      assert length(links) > 0
      assert query(html, "#settings-admin-sheet[data-open=true]") |> Enum.count() == 1

      for link <- links, do: assert(LazyHTML.attribute(link, "phx-click") == [], inspect(link))
    end

    test "every switch is a <button role=switch>" do
      {:ok, _view, html} = live(authed(member!()), "/settings")
      switches = query(html, "#settings [role=switch]") |> Enum.to_list()
      assert switches != []
      for s <- switches, do: assert(LazyHTML.tag(s) == ["button"])
    end

    test "the source this page authors has no hover:, no base-content alpha, nothing under 12px" do
      source = File.read!(@settings_path)
      assert source =~ ~s(id="settings")

      refute source =~ "hover:"
      refute source =~ "text-base-content/"

      for [_, px] <- Regex.scan(~r/text-\[(\d+)px\]/, source),
          do: assert(String.to_integer(px) >= 12, "text-[#{px}px]")
    end

    test "no hover: in #settings" do
      {:ok, view, _html} = live(authed(root!()), "/settings")
      html = open_admin(view)

      classes =
        html
        |> query("#settings [class]")
        |> LazyHTML.attribute("class")

      # Anti-vacuity: the scan sees the rows.
      assert Enum.any?(classes, &(&1 =~ "active:bg-base-100"))

      for c <- classes do
        refute c =~ "hover:", c
        refute c =~ "text-base-content/", c
      end
    end
  end

  test "the shell names the module Settings" do
    {:ok, view, _html} = live(authed(member!()), "/settings")
    assert :sys.get_state(view.pid).socket.assigns.active_module == "Settings"
    assert page_title(view) =~ "Settings"
  end
end
