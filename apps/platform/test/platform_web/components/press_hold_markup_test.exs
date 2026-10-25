defmodule PlatformWeb.Components.PressHoldMarkupTest do
  @moduledoc """
  Rule 5 of the press-feedback canvas (01a167b0; task 01a166be-b5b9 stage 3):
  a `phx-click` button in the nav shell or a menu trigger holds its pressed
  look while LiveView's round trip runs and carries `aria-busy` after 100ms.

  The contract has three halves and each is pinned here against what renders:

    * markup: every in-scope button carries `press-hold` (the class
      `installPressHold` in hooks/button_loading.js selects, read from the
      module so the two cannot drift) and, where it is utility-painted, the
      `phx-click-loading:` fill that holds the pressed look;
    * CSS: the More tab's held icon/ink/60% label, the daisyUI button hold,
      and `press-hold` excluded from the width-neutral-breaking spinner;
    * app.js installs the press-hold controller and the top bar module, and
      no longer names a literal bar colour.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.IconRail
  import PlatformWeb.Components.Sheet

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @assets Path.expand("../../../assets", __DIR__)

  defp read_asset(rel), do: File.read!(Path.join(@assets, rel))

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp nodes(doc, sel), do: doc |> LazyHTML.query(sel) |> Enum.to_list()

  defp classes(node) do
    node |> LazyHTML.attribute("class") |> List.first() |> to_string() |> String.split()
  end

  defp only!(doc, sel) do
    case nodes(doc, sel) do
      [node] -> node
      other -> flunk("expected one #{sel}, got #{length(other)}")
    end
  end

  defp assert_hold(node, utilities) do
    cls = classes(node)
    assert "press-hold" in cls, "missing press-hold in #{inspect(cls)}"

    for u <- utilities do
      assert u in cls, "missing #{u} in #{inspect(cls)}"
    end
  end

  test "the press-hold controller selects the class the markup carries" do
    js = read_asset("js/hooks/button_loading.js")
    assert js =~ ~s(export const PRESS_HOLD_SELECTOR = ".press-hold")
    assert js =~ ~s(export const DEFAULT_DELAY_MS = 100)
    assert js =~ ~s{setAttribute("aria-busy", "true")}
  end

  describe "nav shell" do
    test "the More tab holds its press" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.bottom_rail current_path="/chat" root_user={false} more_open={false} />
        """)

      more = only!(doc(html), ~s(button.bottom-nav-tab[data-destination="more"]))
      assert_hold(more, [])
      assert LazyHTML.attribute(more, "phx-click") == ["open_more_sheet"]
    end

    test "the sheet's close controls hold" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.sheet id="s" open={true} on_close="close">
          <:title>T</:title>
          body
        </.sheet>
        """)

      close = only!(doc(html), "button.sheet-close-button")
      assert_hold(close, ["active:bg-base-200", "phx-click-loading:bg-base-200"])

      html =
        rendered_to_string(~H"""
        <.sheet id="h" open={true} on_close="close" handle_close>
          <:title>T</:title>
          body
        </.sheet>
        """)

      assert_hold(only!(doc(html), "button.sheet-handle-button"), [])
    end
  end

  describe "tasks header menus" do
    defp admin_conn(conn) do
      n = System.unique_integer([:positive])

      user =
        Repo.insert!(%User{
          email: "press-hold-admin-#{n}@example.com",
          name: "Press Hold Admin",
          oidc_sub: "oidc-press-hold-admin-#{n}"
        })

      org = Tenancy.get_org_by_slug!("acme")

      %OrgMembership{}
      |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "admin"})
      |> Repo.insert!()

      init_test_session(conn, current_user_id: user.id)
    end

    test "settings and create-menu triggers hold their press", %{conn: conn} do
      {:ok, _view, html} = live(admin_conn(conn), ~p"/tasks")
      page = doc(html)

      assert_hold(only!(page, ~s(button[data-role="tasks-settings-menu-trigger"])), [
        "phx-click-loading:bg-base-300!",
        "phx-click-loading:text-base-content"
      ])

      assert_hold(only!(page, ~s(button[data-role="header-create-menu-trigger"])), ["btn"])
    end
  end

  describe "stylesheet and app.js" do
    setup do
      %{css: read_asset("css/app.css"), app: read_asset("js/app.js")}
    end

    # Since the sliding pill (prototype t1) the press scales the whole cell,
    # so the held press does too.
    test "the More tab keeps the pressed cell and ink and dims its label to 60%", %{css: css} do
      assert css =~
               ~r/\.bottom-nav-tab\.press-hold\.phx-click-loading:not\(\.bottom-nav-tab--active\) \{\s*color: var\(--color-base-content\);/

      assert css =~
               ~r/\.bottom-nav-tab\.press-hold\.phx-click-loading \{\s*transform: scale\(0\.92\);/

      assert css =~
               ~r/\.bottom-nav-tab\.press-hold\.phx-click-loading \.bottom-nav-label \{\s*opacity: 0\.6;/

      assert css =~
               ~r/@media \(prefers-reduced-motion: reduce\) \{\s*\.bottom-nav-tab\.press-hold\.phx-click-loading \{\s*transform: none;/
    end

    test "a daisyUI press-hold button holds daisyUI's pressed fill", %{css: css} do
      assert css =~ ~r/\.btn\.press-hold\.phx-click-loading:not\(\.btn-active\) \{\s*--btn-bg:/
    end

    test "press-hold buttons never get the width-neutral-breaking spinner or 50% dim", %{css: css} do
      for sel <- [
            ~S|.btn[aria-busy="true"]:not(.press-hold) {|,
            ~S|.btn[aria-busy="true"]:not(.press-hold) > * {|,
            ~S|.btn[aria-busy="true"]:not(.press-hold)::after {|
          ] do
        assert String.contains?(css, sel), "missing #{sel}"
      end

      refute css =~ ~r/\.btn\[aria-busy="true"\] \{/
    end

    test "the top bar sits below the safe area", %{css: css} do
      assert css =~ ~r/\.topbar-progress \{\s*top: env\(safe-area-inset-top, 0px\) !important;/
    end

    test "app.js installs press-hold and the top bar module, with no literal bar colour",
         %{app: app} do
      assert app =~ "installPressHold()"
      assert app =~ ~r/installTopBar\(\{topbar, reconnecting: \(\) => reconnecting\(\)\}\)/
      refute app =~ "#29d"
      refute app =~ ~r/topbar\.show\(\d+\)/
    end
  end
end
