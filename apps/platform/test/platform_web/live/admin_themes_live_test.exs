defmodule PlatformWeb.AdminThemesLiveTest do
  @moduledoc """
  `/admin/themes`, the theme editor (task 01a1557a-fe9b stage 2).

  Named mutation, recorded in the stage commit: (c) drop Apply's `disabled`
  attribute, and "Apply is disabled with its reason on a failing fixture"
  goes red.

  Stage 6 mutation: count only the editing mode in `apply_block/1`'s reason,
  and "the Apply reason names the mode that fails" goes red (editing dark,
  the light-only fixture shows no reason).
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.ExternalUserFixtures, as: X
  alias Platform.Repo
  alias Platform.Theming
  alias Platform.Theming.OrgTheme
  alias Platform.Theming.Presets
  alias Platform.Theming.Tokens
  alias PlatformWeb.AdminThemesLive

  setup %{conn: conn} do
    root = Platform.Tenancy.get_org!(acme_org_id())
    admin = root_admin!()
    %{conn: conn, root: root, admin: admin}
  end

  defp signed_in(conn, user),
    do: Plug.Test.init_test_session(conn, %{"current_user_id" => user.id})

  defp mount!(ctx) do
    {:ok, view, _html} = ctx.conn |> signed_in(ctx.admin) |> live(~p"/admin/themes")
    view
  end

  defp has?(view, selector), do: has_element?(view, selector)
  defp has?(view, selector, text), do: has_element?(view, selector, text)

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp draft!(ctx, name, dark \\ nil) do
    attrs = %{name: name}
    attrs = if dark, do: Map.put(attrs, :dark, dark), else: attrs
    {:ok, theme} = Theming.create_draft(ctx.admin, ctx.root.id, attrs)
    theme
  end

  describe "access" do
    test "an admin mounts the editor", ctx do
      view = mount!(ctx)

      assert has?(view, "[data-role=theme-editor]")
      assert has?(view, "h1", "Theme admin")
      # Chrome-less: no shell sidebar on the page.
      refute has?(view, "[data-role=desktop-sidebar]")
      # The five presets, first, in order.
      chips = view |> render() |> query("[data-role=theme-chip]") |> Enum.map(&LazyHTML.text/1)
      names = Enum.map(Presets.all(), & &1.name)
      assert chips |> Enum.take(5) |> Enum.map(&String.trim/1) == names
    end

    test "a member is redirected to /access-denied?module=admin", ctx do
      member = X.create_user!()
      X.plain_member!(member, ctx.root)

      assert {:error, {:redirect, %{to: "/access-denied?module=admin"}}} =
               ctx.conn |> signed_in(member) |> live(~p"/admin/themes")
    end

    # The spec says "redirected"; measured, an external user never reaches
    # the mount: the router's external-scope fence answers 403 first, as it
    # does for every internal-only page.
    test "an external user is refused before the mount", ctx do
      guest = X.external_user!(ctx.root, allowlist: false)

      conn = ctx.conn |> signed_in(guest) |> get(~p"/admin/themes")
      assert conn.status == 403
      refute conn.resp_body =~ "theme-editor"
    end
  end

  describe "live preview" do
    test "a token change pushes theme-preview with sanitised vars", ctx do
      view = mount!(ctx)

      view
      |> element("form#tok-dark-ground")
      |> render_change(%{"key" => "ground", "value" => "#123", "_target" => ["value"]})

      assert_push_event(view, "theme-preview", %{
        mode: "dark",
        vars: %{"--color-base-200" => "#112233"} = vars
      })

      allowed =
        Tokens.declarations(Presets.base(), "dark")
        |> String.split("\n", trim: true)
        |> Enum.map(&(&1 |> String.split(":") |> hd()))

      assert Enum.sort(Map.keys(vars)) == Enum.sort(allowed)

      for {name, value} <- vars do
        refute value =~ ~r/[;{}<>\\]|url\(/i, "#{name}: #{inspect(value)}"
      end

      # The editor wrapper previews the same draft.
      assert has?(
               view,
               ~s([data-role=theme-editor][data-theme-preview][style*="--color-base-200: #112233"])
             )

      assert has?(view, "[data-role=theme-dirty]", "unsaved edits")
    end

    test "an invalid hex keeps the last good value and shows an inline error", ctx do
      view = mount!(ctx)
      good = Presets.base().dark["ground"]

      html =
        view
        |> element("form#tok-dark-ground")
        |> render_change(%{"key" => "ground", "value" => "#12345g", "_target" => ["value"]})

      assert has?(view, "form#tok-dark-ground [data-role=theme-token-error]")
      [input] = html |> query("#tok-ground-text") |> Enum.to_list()
      assert LazyHTML.attribute(input, "value") == [good]
      assert has?(view, ~s([data-role=theme-editor][style*="--color-base-200: #{good}"]))
      refute has?(view, "[data-role=theme-dirty]")
    end

    test "oklch input is redisplayed as the painted hex", ctx do
      view = mount!(ctx)

      html =
        view
        |> element("form#tok-dark-ground")
        |> render_change(%{
          "key" => "ground",
          "value" => "oklch(20% 0 0)",
          "_target" => ["value"]
        })

      [input] = html |> query("#tok-ground-text") |> Enum.to_list()
      [value] = LazyHTML.attribute(input, "value")
      assert value =~ ~r/^#[0-9a-f]{6}$/
    end
  end

  describe "apply" do
    test "Apply is disabled with its reason on a failing fixture", ctx do
      base = Presets.base()
      failing = draft!(ctx, "Unreadable", Map.put(base.dark, "ink", base.dark["ground"]))
      view = mount!(ctx)

      view |> element(~s(button[phx-value-id="org:#{failing.id}"])) |> render_click()

      assert has?(view, "[data-role=theme-apply][disabled]")

      assert view |> element("[data-role=theme-apply-reason]") |> render() =~
               ~r/\d+ pairs below AA/
    end

    test "Apply on a preset asks for Save as… first", ctx do
      view = mount!(ctx)

      assert has?(view, "[data-role=theme-apply][disabled]")
      assert has?(view, "[data-role=theme-apply-reason]", "Save as… first")
      assert has?(view, "[data-role=theme-rename][disabled]")
      assert has?(view, "[data-role=theme-delete][disabled]")
    end

    test "confirming Apply publishes and toasts", ctx do
      theme = draft!(ctx, "Passing")
      view = mount!(ctx)

      view |> element(~s(button[phx-value-id="org:#{theme.id}"])) |> render_click()
      refute has?(view, "[data-role=theme-apply][disabled]")

      view |> element("[data-role=theme-apply]") |> render_click()

      assert has?(
               view,
               "[data-role=theme-apply-confirm]",
               "Members of #{ctx.root.name} can choose Passing in Appearance."
             )

      view |> form("#theme-apply-form") |> render_submit()

      assert Repo.get!(OrgTheme, theme.id).status == "published"

      assert has?(
               view,
               "[data-role=theme-toast]",
               "Applied · members of #{ctx.root.name} can choose Passing in Appearance"
             )
    end
  end

  describe "summary and Apply name the failing mode (stage 6)" do
    # Fails in light only: light ink on its own ground.
    defp light_only_failing!(ctx) do
      base = Presets.base()

      {:ok, theme} =
        Theming.create_draft(ctx.admin, ctx.root.id, %{
          name: "Light unreadable",
          light: Map.put(base.light, "ink", base.light["ground"])
        })

      fails = Enum.count(Theming.ledger(theme, "light"), &(not &1.pass?))
      assert fails > 0
      assert Enum.all?(Theming.ledger(theme, "dark"), & &1.pass?)
      {theme, fails}
    end

    test "the Apply reason names the mode that fails", ctx do
      {theme, fails} = light_only_failing!(ctx)
      view = mount!(ctx)
      view |> element(~s(button[phx-value-id="org:#{theme.id}"])) |> render_click()

      # Editing dark, where every pair passes: the reason still counts light.
      assert has?(view, "[data-role=theme-apply][disabled]")
      assert has?(view, "[data-role=theme-apply-reason]", "#{fails} pairs below AA (light)")
    end

    test "the summary shows the other mode's fails when non-zero", ctx do
      {theme, fails} = light_only_failing!(ctx)
      view = mount!(ctx)
      view |> element(~s(button[phx-value-id="org:#{theme.id}"])) |> render_click()

      # Dark: the editing mode's own text is unchanged, the light count added.
      summary = view |> element("[data-role=theme-summary]") |> render()
      assert summary =~ ~r/\d+\/\d+ AA pass \(dark\)/
      assert summary =~ "all pass"
      assert has?(view, "[data-role=theme-summary-other]", "light: #{fails} fail")

      # Light: its own count, and nothing for dark, which passes.
      view |> element(~s(button[phx-click=ed_mode][phx-value-mode=light])) |> render_click()
      summary = view |> element("[data-role=theme-summary]") |> render()
      assert summary =~ ~r/\d+\/\d+ AA pass \(light\)/
      assert summary =~ "#{fails} fail"
      refute has?(view, "[data-role=theme-summary-other]")
    end

    test "a failing both-mode theme names both counts", ctx do
      base = Presets.base()

      {:ok, theme} =
        Theming.create_draft(ctx.admin, ctx.root.id, %{
          name: "Both unreadable",
          light: Map.put(base.light, "ink", base.light["ground"]),
          dark: Map.put(base.dark, "ink", base.dark["ground"])
        })

      [d, l] =
        for m <- ["dark", "light"], do: Enum.count(Theming.ledger(theme, m), &(not &1.pass?))

      view = mount!(ctx)
      view |> element(~s(button[phx-value-id="org:#{theme.id}"])) |> render_click()

      assert has?(
               view,
               "[data-role=theme-apply-reason]",
               "#{d + l} pairs below AA (dark #{d} · light #{l})"
             )
    end

    test "Duplicate of Burrow sand can be applied unmodified", ctx do
      view = mount!(ctx)
      view |> element(~s(button[phx-value-id="preset:burrow-sand"])) |> render_click()
      view |> element("[data-role=theme-duplicate]") |> render_click()

      copy = Repo.get_by!(OrgTheme, org_id: ctx.root.id, name: "Burrow sand (copy)")
      refute has?(view, "[data-role=theme-apply][disabled]")
      refute has?(view, "[data-role=theme-apply-reason]")
      refute has?(view, "[data-role=theme-summary-other]")

      view |> element("[data-role=theme-apply]") |> render_click()
      view |> form("#theme-apply-form") |> render_submit()
      assert Repo.get!(OrgTheme, copy.id).status == "published"
    end

    test "editing an agent colour drops the text colour carried from the preset", ctx do
      sand = Presets.get("burrow-sand")

      {:ok, theme} =
        Theming.create_draft(ctx.admin, ctx.root.id, %{
          name: "Sand copy",
          light: sand.light,
          dark: sand.dark,
          shape: sand.shape
        })

      view = mount!(ctx)
      view |> element(~s(button[phx-value-id="org:#{theme.id}"])) |> render_click()
      view |> element(~s(button[phx-click=ed_mode][phx-value-mode=light])) |> render_click()
      render_click(view, "pv_mode", %{"mode" => "light"})

      view
      |> element("form#tok-light-agPurple")
      |> render_change(%{"key" => "agPurple", "value" => "#5a3d8a", "_target" => ["value"]})

      assert_push_event(view, "theme-preview", %{
        mode: "light",
        vars: %{"--ag-purple" => "#5a3d8a", "--ag-purple-text" => "#5a3d8a"}
      })
    end
  end

  describe "library writes" do
    test "Delete needs DELETE typed", ctx do
      theme = draft!(ctx, "Doomed")
      view = mount!(ctx)

      view |> element(~s(button[phx-value-id="org:#{theme.id}"])) |> render_click()
      view |> element("[data-role=theme-delete]") |> render_click()

      view |> form("#theme-delete", %{"confirm" => "delete"}) |> render_submit()
      assert Repo.get(OrgTheme, theme.id)
      assert has?(view, "[data-role=theme-modal-error]", "Type DELETE to confirm")

      view |> form("#theme-delete", %{"confirm" => "DELETE"}) |> render_submit()
      refute Repo.get(OrgTheme, theme.id)
      assert has?(view, "[data-role=theme-toast]", "Deleted")
    end

    test "Duplicate names a collision '(copy 2)'", ctx do
      theme = draft!(ctx, "Ocean")
      _copy = draft!(ctx, "Ocean (copy)")
      view = mount!(ctx)

      view |> element(~s(button[phx-value-id="org:#{theme.id}"])) |> render_click()
      view |> element("[data-role=theme-duplicate]") |> render_click()

      assert Repo.get_by(OrgTheme, org_id: ctx.root.id, name: "Ocean (copy 2)")
      assert has?(view, "[data-role=theme-toast]", "Duplicated")
    end

    test "copy_name/2 counts up past every taken name" do
      assert AdminThemesLive.copy_name("A", []) == "A (copy)"
      assert AdminThemesLive.copy_name("A", ["A (copy)"]) == "A (copy 2)"
      assert AdminThemesLive.copy_name("A", ["A (copy)", "A (copy 2)"]) == "A (copy 3)"
      assert String.length(AdminThemesLive.copy_name(String.duplicate("x", 80), [])) == 80
    end

    test "Save as… saves a draft in the chosen org", ctx do
      view = mount!(ctx)

      view |> element("button[phx-value-modal=save_as]") |> render_click()

      view
      |> form("#theme-save-as", %{"name" => "Mine", "org_id" => ctx.root.id})
      |> render_submit()

      assert %OrgTheme{status: "draft"} = Repo.get_by(OrgTheme, org_id: ctx.root.id, name: "Mine")
      assert has?(view, "[data-role=theme-toast]", "Saved · Mine")
    end

    test "Import JSON refuses an unknown key with 'Invalid JSON: <reason>'", ctx do
      view = mount!(ctx)

      view |> element("button[phx-value-modal=import]") |> render_click()

      view
      |> form("#theme-import", %{"json" => ~s({"name": "Bad", "dark": {"nope": "#fff"}})})
      |> render_submit()

      assert has?(view, "[data-role=theme-toast]", "Invalid JSON: ")
      refute Repo.get_by(OrgTheme, name: "Bad")

      view |> element("button[phx-value-modal=import]") |> render_click()
      view |> form("#theme-import", %{"json" => "{not json"}) |> render_submit()
      assert has?(view, "[data-role=theme-toast]", "Invalid JSON: ")
    end
  end

  test "the catch-all handle_info keeps the view alive on a stray message", ctx do
    view = mount!(ctx)
    send(view.pid, {:something_unexpected, make_ref()})
    assert has?(view, "[data-role=theme-editor]")
    assert Process.alive?(view.pid)
  end
end
