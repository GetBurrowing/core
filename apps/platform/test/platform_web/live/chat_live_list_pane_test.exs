defmodule PlatformWeb.ChatLiveListPaneTest do
  @moduledoc """
  The desktop list pane (Burrow redesign 22 stage 2, master-desktop.html
  `#list` L594): the Chat list beside the conversation at lg, replacing the
  desktop channel rail and the external rail.

  LiveViewTest has no viewport, so "at lg" and "on the phone" are read off
  the classes the breakpoint keys on: the pane is `hidden lg:flex` on
  `/chat/:slug` (the phone sees only the conversation) and plain `flex` on
  `/chat` (the phone list, unchanged).

  Every refute sits beside a positive control on the same render.

  `async: false`: the Agents block reads a feature flag from application env.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.ExternalUserFixtures
  import Platform.TenancyFixtures

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  @flag_key :agents_goal_surface

  setup do
    previous = Application.get_env(:platform, @flag_key)
    on_exit(fn -> Application.put_env(:platform, @flag_key, previous) end)
    Application.put_env(:platform, @flag_key, false)
    :ok
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp acme, do: Tenancy.get_org!(acme_org_id())

  defp member! do
    user = create_user!()
    plain_member!(user, acme())
    user
  end

  defp channel_in(org, name) do
    n = System.unique_integer([:positive])
    channel!(%{name: name, slug: "pane-#{n}-#{String.downcase(name)}", org_id: org.id})
  end

  defp join!(space, user_id, display_name) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user_id,
        display_name: display_name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp dm!(user, other_name) do
    {:ok, space} = Chat.create_space(%{kind: "dm", is_direct: true})
    join!(space, user.id, user.name)
    join!(space, Ecto.UUID.generate(), other_name)
    space
  end

  defp world(conn) do
    user = member!()
    alpha = channel_in(acme(), "Alpha")
    beta = channel_in(acme(), "Beta")
    dm = dm!(user, "Moore")
    %{conn: login(conn, user.id), user: user, alpha: alpha, beta: beta, dm: dm}
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()
  defp q(view, selector), do: view |> doc() |> LazyHTML.query(selector)
  defp count(view, selector), do: view |> q(selector) |> Enum.count()

  defp classes(view, selector) do
    view |> q(selector) |> LazyHTML.attribute("class") |> List.first("") |> String.split()
  end

  # ── layout ──────────────────────────────────────────────────────────────

  describe "/chat/:slug at lg" do
    test "#chat-list renders beside the conversation, the open row aria-current", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat/#{w.alpha.slug}")

      # The pane and the conversation are both in the DOM.
      assert count(view, "#chat-list") == 1
      assert count(view, "#chat-drop-zone") == 1

      list = classes(view, "#chat-list")
      assert "lg:flex" in list
      assert "lg:w-[280px]" in list
      assert "lg:max-[1100px]:w-[240px]" in list
      assert "lg:border-r" in list
      assert "lg:border-edge" in list
      assert "bg-base-200" in list

      # The open channel's row is current; the other channel's is not.
      assert count(
               view,
               ~s(#chat-list a[data-role="chat-list-row"][data-space-id="#{w.alpha.id}"][aria-current="page"])
             ) == 1

      assert count(
               view,
               ~s(#chat-list a[data-role="chat-list-row"][data-space-id="#{w.beta.id}"])
             ) == 1

      assert count(
               view,
               ~s(#chat-list a[data-space-id="#{w.beta.id}"][aria-current])
             ) == 0

      current = classes(view, ~s(#chat-list a[data-space-id="#{w.alpha.id}"]))
      assert "bg-base-300" in current
      assert "lg:hover:bg-base-300" in current
    end

    test "on the phone the pane is hidden on :show, so only the conversation shows",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat/#{w.alpha.slug}")

      list = classes(view, "#chat-list")
      assert "hidden" in list
      assert "lg:flex" in list
      refute "flex" in list
    end

    test "/chat keeps the full-width phone list: plain flex, not lg:hidden", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      list = classes(view, "#chat-list")
      assert "flex" in list
      refute "hidden" in list
      refute "lg:hidden" in list
    end

    test "the header line counts spaces and direct, and reads names masked while masked",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat/#{w.alpha.slug}")

      line =
        view
        |> q(~s(#chat-list [data-role="chat-list-counts"]))
        |> LazyHTML.text()
        |> String.trim()

      assert line =~ ~r/^\d+ spaces? · 1 direct$/

      render_click(view, "toggle_mask_names", %{"masked" => "true"})

      line =
        view
        |> q(~s(#chat-list [data-role="chat-list-counts"]))
        |> LazyHTML.text()
        |> String.trim()

      assert line == "names masked"
    end

    test "no desktop channel rail and no external rail anywhere", %{conn: conn} do
      w = world(conn)

      for path <- [~p"/chat", ~p"/chat/#{w.alpha.slug}"] do
        {:ok, view, html} = live(w.conn, path)
        assert count(view, "#chat-list") == 1
        refute html =~ ~s(id="chat-sidebar")
        refute html =~ ~s(data-role="external-rail")
        refute html =~ ~s(id="chat-external-rail")
        refute html =~ ~s(phx-hook="SectionReorder")
        refute html =~ ~s(phx-hook="ResizableSidebar")
      end
    end
  end

  # ── popovers ────────────────────────────────────────────────────────────

  describe "the header popover at lg" do
    test "each header button opens the same @list_sheet as a popover; the sheet stays lg:hidden",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat/#{w.alpha.slug}")

      assert count(view, "#chat-list-popover") == 0
      assert count(view, ~s(#list-search[aria-expanded="false"])) == 1

      view |> element("#list-search") |> render_click()
      assert count(view, ~s(#chat-list-popover[data-sheet="search"].lg\\:flex)) == 1
      assert count(view, ~s(#list-search[aria-expanded="true"])) == 1
      assert count(view, "#chat-list-pop-search-input") == 1
      assert count(view, ~s(#chat-list-search-sheet.lg\\:hidden)) == 1

      view |> element("#list-new") |> render_click()
      assert count(view, ~s(#chat-list-popover[data-sheet="new"])) == 1
      assert count(view, ~s([data-role="chat-list-pop-new-channel"])) == 1
      assert count(view, ~s([data-role="chat-list-pop-new-conversation"])) == 1

      view |> element("#list-more") |> render_click()
      assert count(view, ~s(#chat-list-popover[data-sheet="options"])) == 1

      for role <-
            ~w(chat-list-pop-option-mask chat-list-pop-option-archived chat-list-pop-option-hidden chat-list-pop-mark-all-read chat-list-pop-appearance) do
        assert count(view, ~s([data-role="#{role}"])) == 1, role
      end

      render_click(view, "close_list_sheet", %{})
      assert count(view, "#chat-list-popover") == 0
    end

    test "the search popover finds a channel through list_search", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat/#{w.alpha.slug}")

      view |> element("#list-search") |> render_click()
      view |> element("#chat-list-popover form") |> render_change(%{"value" => "Beta"})

      assert count(
               view,
               ~s(#chat-list-pop-search-results a[data-role="chat-list-row"][data-space-id="#{w.beta.id}"])
             ) == 1

      assert count(
               view,
               ~s(#chat-list-pop-search-results a[data-space-id="#{w.alpha.id}"])
             ) == 0
    end

    test "Show hidden lists a hidden channel and Unhide restores it to the list",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat/#{w.alpha.slug}")

      beta_row =
        ~s(#chat-list-scroller a[data-role="chat-list-row"][data-space-id="#{w.beta.id}"])

      assert count(view, beta_row) == 1

      render_click(view, "hide_channel", %{"id" => w.beta.id})
      assert count(view, beta_row) == 0

      view |> element("#list-more") |> render_click()
      assert count(view, "#chat-list-pop-hidden") == 0

      view |> element(~s([data-role="chat-list-pop-option-hidden"])) |> render_click()

      assert count(
               view,
               ~s(#chat-list-pop-hidden [data-role="chat-list-pop-hidden-row"][data-space-id="#{w.beta.id}"])
             ) == 1

      view
      |> element(~s([data-role="chat-list-pop-unhide"][data-space-id="#{w.beta.id}"]))
      |> render_click()

      assert count(view, beta_row) == 1
      refute MapSet.member?(Accounts.get_hidden_channel_ids(w.user.id), w.beta.id)

      assert count(view, ~s([data-role="chat-list-pop-hidden-row"][data-space-id="#{w.beta.id}"])) ==
               0
    end

    test "Mark all read fires the existing handler and clears the list's unread", %{conn: conn} do
      w = world(conn)
      join!(w.beta, w.user.id, w.user.name)
      poster = join!(w.beta, Ecto.UUID.generate(), "Priya")

      {:ok, _} =
        Chat.post_message(%{
          space_id: w.beta.id,
          participant_id: poster.id,
          content_type: "text",
          content: "unread in beta"
        })

      {:ok, view, _} = live(w.conn, ~p"/chat/#{w.alpha.slug}")

      unread = ~s(#chat-list-scroller a[data-space-id="#{w.beta.id}"][data-unread="true"])
      assert count(view, unread) == 1

      view |> element("#list-more") |> render_click()
      view |> element(~s([data-role="chat-list-pop-mark-all-read"])) |> render_click()

      assert count(view, unread) == 0

      assert count(
               view,
               ~s(#chat-list-scroller a[data-space-id="#{w.beta.id}"][data-unread="false"])
             ) == 1
    end
  end

  # ── right-click ─────────────────────────────────────────────────────────

  describe "right-click a row at lg" do
    test "the list carries RowContextMenu and the push opens row_actions_dialog for that row",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat/#{w.alpha.slug}")

      assert count(
               view,
               ~s(#chat-list[phx-hook="RowContextMenu"][data-context-event="open_row_actions"])
             ) ==
               1

      # The hook reads the row's `data-long-press-space-id`.
      assert count(view, ~s(#chat-list a[data-long-press-space-id="#{w.beta.id}"])) == 1
      assert count(view, "#chat-row-actions-dialog") == 0

      render_hook(view, "open_row_actions", %{"space_id" => w.beta.id})

      assert count(view, "#chat-row-actions-dialog") == 1

      assert count(
               view,
               ~s(#chat-row-actions-dialog [data-role="pin-control"][data-space-id="#{w.beta.id}"])
             ) == 1

      hide = q(view, ~s(#chat-row-actions-dialog [data-role="rail-row-actions-hide"]))
      assert LazyHTML.text(hide) =~ "Hide channel"

      render_hook(view, "open_row_actions", %{"space_id" => w.dm.id})

      assert count(
               view,
               ~s(#chat-row-actions-dialog [data-role="rail-row-actions-close"][data-space-id="#{w.dm.id}"])
             ) == 1
    end
  end

  # ── external ────────────────────────────────────────────────────────────

  defp tenant_org! do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "Tenant #{n}",
      slug: "tenant_pane_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("acme").id
    })
    |> Repo.insert!()
  end

  defp ext_user!(org) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "pane-#{n}@example.com",
        name: "Xena External",
        oidc_sub: "oidc-pane-#{n}"
      })
      |> Repo.insert!()

    {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})
    Tenancy.allow_dm(user, org)
    user
  end

  describe "an external user at lg" do
    setup %{conn: conn} do
      org = tenant_org!()
      ext = ext_user!(org)
      n = System.unique_integer([:positive])

      {:ok, allowed} =
        Chat.create_space(%{
          name: "Allowed Channel",
          slug: "pane-ext-#{n}",
          kind: "channel",
          org_id: org.id
        })

      join!(allowed, ext.id, ext.name)

      {:ok, secret} =
        Chat.create_space(%{name: "Secret Ops Room", slug: "pane-sec-#{n}", kind: "channel"})

      %{
        conn: %{conn | host: "chat.localhost"} |> init_test_session(current_user_id: ext.id),
        ext: ext,
        allowed: allowed,
        secret: secret
      }
    end

    test "sees their own list, no New channel, no Agents row, no Options", ctx do
      {:ok, view, html} = live(ctx.conn, "/chat/#{ctx.allowed.slug}")

      list = classes(view, "#chat-list")
      assert "hidden" in list
      assert "lg:flex" in list

      assert count(view, ~s(#chat-list a[data-space-id="#{ctx.allowed.id}"])) == 1
      refute html =~ ctx.secret.name

      assert count(view, ~s(#chat-list a[data-row-kind="agents"])) == 0
      assert count(view, "#list-more") == 0
      assert count(view, "#list-search") == 1
      assert count(view, "#list-new") == 1

      view |> element("#list-new") |> render_click()
      assert count(view, ~s([data-role="chat-list-pop-new-conversation"])) == 1
      assert count(view, ~s([data-role="chat-list-pop-new-channel"])) == 0
      refute render(view) =~ ~s(phx-click="new_channel_open")

      # The way out the external rail carried.
      assert count(view, ~s(#chat-list [data-role="external-logout"][href="/auth/logout"])) == 1
      assert count(view, ~s(#chat-list [data-role="external-identity"])) == 1

      # Below lg the external switcher is still the phone surface.
      assert count(view, ~s([data-role="external-rail"])) == 0
    end

    test "an Options open forged by the client opens nothing", ctx do
      {:ok, view, _} = live(ctx.conn, "/chat/#{ctx.allowed.slug}")
      render_click(view, "open_list_sheet", %{"sheet" => "options"})
      assert count(view, ~s(#chat-list-popover[data-sheet="options"])) == 0
    end

    test "search returns only their own spaces and never the Agents space", ctx do
      {:ok, view, _} = live(ctx.conn, "/chat/#{ctx.allowed.slug}")
      view |> element("#list-search") |> render_click()
      view |> element("#chat-list-popover form") |> render_change(%{"value" => "o"})

      html = view |> element("#chat-list-pop-search-results") |> render()
      refute html =~ ctx.secret.name
      refute html =~ ~s(data-row-kind="agents")
    end
  end
end
