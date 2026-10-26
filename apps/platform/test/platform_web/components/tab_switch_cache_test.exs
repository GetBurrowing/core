defmodule PlatformWeb.Components.TabSwitchCacheTest do
  @moduledoc """
  The markup `assets/js/hooks/tab_switch_cache.js` reads: the hook element
  (`#tab-switch-cache`, `phx-hook="TabSwitchCache"`), its `data-current`,
  `data-user` and `data-masked`, and one skeleton `<template>` per shape. The
  hook's selector names are read out of the module itself, so the two cannot
  drift apart. One LiveView render pins that the shell mounts it on a real
  page.
  """
  use PlatformWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.TabSwitchCache

  alias Platform.Accounts.User
  alias Platform.Repo

  @hook_path Path.expand("../../../assets/js/hooks/tab_switch_cache.js", __DIR__)

  defp render_cache(attrs) do
    assigns = Map.merge(%{current_path: "/", user: nil, masked?: false}, attrs)

    rendered_to_string(~H"""
    <.tab_switch_cache current_path={@current_path} user={@user} masked?={@masked?} />
    """)
  end

  defp js_const(name) do
    [_, value] = Regex.run(~r/export const #{name} =\s*"([^"]+)"/, File.read!(@hook_path))
    value
  end

  # LazyHTML parses a template's children as its content, which `query/2`
  # does not descend into; read each template's inner HTML on its own.
  defp template_html(html, kind) do
    [_, inner] =
      Regex.run(~r/<template data-skeleton="#{kind}">(.*?)<\/template>/s, html)

    LazyHTML.from_fragment(inner)
  end

  describe "tab_switch_cache/1" do
    test "renders the hook element the module looks up" do
      html = render_cache(%{current_path: "/tasks"}) |> LazyHTML.from_fragment()

      hook = LazyHTML.query(html, "##{js_const("HOOK_ID")}")
      assert LazyHTML.attribute(hook, "phx-hook") == ["TabSwitchCache"]
      assert LazyHTML.attribute(hook, "class") == ["hidden"]
    end

    test "data-current is the destination key of the page on screen" do
      for {path, key} <- [
            {"/chat", "chat"},
            {"/chat/general", "chat"},
            {"/tasks", "tasks"},
            {"/meetings", "meetings"},
            {"/inbox", "inbox"},
            {"/settings", "settings"},
            {"/control/usage", "settings"}
          ] do
        html = render_cache(%{current_path: path}) |> LazyHTML.from_fragment()

        assert LazyHTML.attribute(LazyHTML.query(html, "#tab-switch-cache"), "data-current") ==
                 [key],
               "expected #{path} to file under #{key}"
      end
    end

    test "carries the viewer's id and the mask state" do
      html =
        render_cache(%{user: %{id: "0199-user"}, masked?: true}) |> LazyHTML.from_fragment()

      hook = LazyHTML.query(html, "#tab-switch-cache")
      assert LazyHTML.attribute(hook, "data-user") == ["0199-user"]
      assert LazyHTML.attribute(hook, "data-masked") == ["true"]

      plain = render_cache(%{}) |> LazyHTML.from_fragment() |> LazyHTML.query("#tab-switch-cache")
      assert LazyHTML.attribute(plain, "data-user") == [""]
      assert LazyHTML.attribute(plain, "data-masked") == ["false"]
    end

    test "renders one skeleton template per shape, with rows shaped like the destination" do
      html = render_cache(%{})
      frag = LazyHTML.from_fragment(html)

      kinds =
        frag
        |> LazyHTML.query("#tab-switch-cache template[data-skeleton]")
        |> LazyHTML.attribute("data-skeleton")

      assert Enum.sort(kinds) == ["chat", "generic", "inbox", "tasks"]

      chat = template_html(html, "chat")
      assert chat |> LazyHTML.query("[data-skeleton-row] .rounded-full") |> Enum.count() == 7
      assert chat |> LazyHTML.query("[data-skeleton-section]") |> Enum.count() == 3

      tasks = template_html(html, "tasks")
      assert tasks |> LazyHTML.query("[data-skeleton-row]") |> Enum.count() == 9

      # Inbox cards sit on the raised surface.
      inbox = template_html(html, "inbox")
      cards = LazyHTML.query(inbox, "[data-skeleton-row]")
      assert Enum.count(cards) == 4
      assert Enum.all?(LazyHTML.attribute(cards, "class"), &(&1 =~ "bg-base-200"))

      generic = template_html(html, "generic")
      assert generic |> LazyHTML.query("[data-skeleton-row]") |> Enum.count() == 7
    end

    test "every tab the module catches names its destination" do
      assigns = %{}

      tabs =
        rendered_to_string(~H"""
        <PlatformWeb.Components.IconRail.bottom_rail current_path="/chat" root_user={false} />
        """)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(js_const("CONTROL_SELECTOR"))

      assert Enum.count(tabs) >= 3
      keys = LazyHTML.attribute(tabs, "data-destination")
      assert length(keys) == Enum.count(tabs)
      assert "chat" in keys and "tasks" in keys
    end

    test "skeleton fills use semantic tokens only" do
      html = render_cache(%{})
      refute html =~ ~r/#[0-9a-fA-F]{3,8}\b/
      refute html =~ ~r/text-base-content\/\d/
      refute html =~ "hover:"
    end
  end

  describe "in the shell" do
    setup %{conn: conn} do
      n = System.unique_integer([:positive])

      user =
        Repo.insert!(%User{
          email: "tab-switch-#{n}@example.com",
          name: "Tab Switch #{n}",
          oidc_sub: "oidc-tab-switch-#{n}"
        })
        |> Platform.TenancyFixtures.member_of_all_orgs!()

      %{conn: init_test_session(conn, current_user_id: user.id), user: user}
    end

    test "the page mounts the hook element and its skeleton templates", %{conn: conn, user: user} do
      {:ok, view, html} = live(conn, "/tasks")

      assert has_element?(view, "#tab-switch-cache[phx-hook=TabSwitchCache]")
      assert has_element?(view, ~s(#tab-switch-cache[data-current="tasks"]))
      assert has_element?(view, ~s(#tab-switch-cache[data-user="#{user.id}"]))
      assert has_element?(view, ~s(#tab-switch-cache[data-masked="false"]))

      for kind <- ~w(chat tasks inbox generic) do
        assert has_element?(view, ~s(#tab-switch-cache template[data-skeleton="#{kind}"]))
      end

      # The pane the layer is appended to.
      assert has_element?(view, js_const("MAIN_SELECTOR"))
      assert html =~ ~s(data-skeleton-row)
    end
  end
end
