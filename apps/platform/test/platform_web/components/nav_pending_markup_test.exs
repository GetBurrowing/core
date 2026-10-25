defmodule PlatformWeb.Components.NavPendingMarkupTest do
  @moduledoc """
  The markup the optimistic-navigation module keys on (task 01a166be-b5b9
  stage 2; `assets/js/lib/nav_pending.js`, canvas 01a167b0 m2 and rules 3, 7).

  The module reads `NAV_CONTROL_SELECTOR` to find a tapped control, the group
  (`.bottom-nav`, `[data-sidebar]`) to find the control that yields, the
  current classes (`bottom-nav-tab--active`, `sidebar-row--current`), the
  More tab (`.bottom-nav-tab[data-destination="more"]`) for a More row's
  pending cue, and `data-nav-label` for the rollback toast's wording. Each of
  those is asserted against the rendered components here, and the selector is
  read out of the module itself so the two cannot drift apart.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.IconRail
  import PlatformWeb.Components.Sidebar
  import PlatformWeb.Components.MoreSheet

  @nav_pending_path Path.expand("../../../assets/js/lib/nav_pending.js", __DIR__)

  defp bottom(current_path) do
    assigns = %{current_path: current_path}

    rendered_to_string(~H"""
    <.bottom_rail current_path={@current_path} root_user={false} more_open={false} />
    """)
    |> LazyHTML.from_fragment()
  end

  defp rail(current_path) do
    assigns = %{current_path: current_path}

    rendered_to_string(~H"""
    <.sidebar current_path={@current_path} root_user={false} brand_name="Acme" />
    """)
    |> LazyHTML.from_fragment()
  end

  defp sheet(current_path) do
    assigns = %{current_path: current_path}

    rendered_to_string(~H"""
    <.more_sheet open={true} root_user={false} current_path={@current_path} />
    """)
    |> LazyHTML.from_fragment()
  end

  defp attr_of(node, name), do: node |> LazyHTML.attribute(name) |> List.first()
  defp nodes(doc, sel), do: doc |> LazyHTML.query(sel) |> Enum.to_list()

  defp control_selector do
    [_, sel] =
      Regex.run(
        ~r/export const NAV_CONTROL_SELECTOR =\s*"([^"]+)"/,
        File.read!(@nav_pending_path)
      )

    sel
  end

  test "every control the module selects is in the rendered shell" do
    shell = [bottom("/chat"), rail("/chat"), sheet("/files")]

    for part <- String.split(control_selector(), ",", trim: true),
        part = String.trim(part),
        # chat rows live in the chat list partial (asserted by chat list tests)
        not String.starts_with?(part, ".chat-list-row") do
      assert Enum.any?(shell, &(nodes(&1, part) != [])), "#{part} matches nothing"
    end
  end

  test "bottom tabs: live navigate links with a destination and a toast label" do
    doc = bottom("/chat")
    assert [_] = nodes(doc, "nav.bottom-nav")
    tabs = nodes(doc, ".bottom-nav-tab[href]")
    assert length(tabs) >= 3

    for tab <- tabs do
      assert attr_of(tab, "data-phx-link") == "redirect"
      assert attr_of(tab, "data-destination") not in [nil, ""]
      assert attr_of(tab, "data-nav-label") == attr_of(tab, "aria-label")
    end

    assert [current] = nodes(doc, ".bottom-nav-tab--active[href]")
    assert attr_of(current, "data-destination") == "chat"
  end

  test "the More tab is the pending cue's target and not itself a nav link" do
    doc = bottom("/chat")
    assert [more] = nodes(doc, ~s(.bottom-nav-tab[data-destination="more"]))
    assert attr_of(more, "href") == nil
    assert nodes(more, "svg, .bottom-nav-icon") != []
  end

  test "sidebar rows: destination, toast label (the visible label), current class" do
    doc = rail("/chat")
    assert [_] = nodes(doc, "[data-sidebar]")
    rows = nodes(doc, ".sidebar-row[href]")
    assert length(rows) > 4

    for row <- rows do
      assert attr_of(row, "data-phx-link") == "redirect"
      assert attr_of(row, "data-destination") not in [nil, ""]
      label = row |> LazyHTML.query("span.truncate") |> LazyHTML.text() |> String.trim()
      assert attr_of(row, "data-nav-label") == label
    end

    assert [current] = nodes(doc, ".sidebar-row--current[href]")
    assert attr_of(current, "data-destination") == "chat"
  end

  test "More rows and Settings: live links inside .more-sheet with a toast label" do
    doc = sheet("/files")
    assert [_] = nodes(doc, ".more-sheet")
    rows = nodes(doc, ".more-sheet .more-sheet-row[href]")
    assert rows != []

    for row <- rows do
      assert attr_of(row, "data-phx-link") == "redirect"
      assert attr_of(row, "data-destination") not in [nil, ""]
      assert attr_of(row, "data-nav-label") not in [nil, ""]
    end

    files = Enum.find(rows, &(attr_of(&1, "data-destination") == "files"))
    assert attr_of(files, "data-nav-label") == "Files"

    assert [settings] = nodes(doc, ".more-sheet .more-sheet-settings[href]")
    assert attr_of(settings, "data-nav-label") == "Settings"
  end
end
