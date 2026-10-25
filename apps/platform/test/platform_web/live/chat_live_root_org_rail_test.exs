defmodule PlatformWeb.ChatLiveRootOrgRailTest do
  @moduledoc """
  Chat names the ROOT org by its own row, never by a compiled org name (task
  01a116de stage 3).

  Burrow redesign 22 stage 2 deleted the desktop channel rail and its
  per-org section headers and dots; the Chat list flattens every sub-org
  channel into one Spaces section. What survives, exercised through the
  rendered page:

    (a) a fresh install whose root is `Root Org` renders no compiled org name,
        an unscoped channel is a Chat list row, and a hidden one is listed in
        the options popover's hidden list instead;
    (b) an install whose root is literally `Legacy` lists the root's, a
        tenant's and an unscoped channel side by side, and the open channel's
        Scope page switch (the header pill until Burrow redesign 22 stage 4)
        is named and keyed from the row;
    (c) a non-root internal member gets the root's fill rule (an unseen
        tenant's is not emitted).

  The test database's root row is the neutral `acme|Acme` fixture (task
  01a116de stage 4). Cases rename it INSIDE the sandbox transaction, which
  rolls back. No real install's rows are touched.
  """

  use PlatformWeb.ConnCase, async: false
  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Section
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.{Org, OrgMembership}

  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "root-rail-#{n}@example.com",
      name: "Root Rail Viewer",
      oidc_sub: "oidc-root-rail-#{n}",
      avatar_url: nil
    })
  end

  defp create_channel(slug, org_id) do
    {:ok, ch} =
      Chat.create_space(%{
        name: String.capitalize(slug),
        slug: slug,
        kind: "channel",
        org_id: org_id
      })

    ch
  end

  defp live_following_redirect(conn, path \\ ~p"/chat") do
    case live(conn, path) do
      {:error, {:live_redirect, %{to: to}}} -> live(conn, to)
      ok -> ok
    end
  end

  defp list_row_selector(space_id),
    do: ~s(#chat-list-scroller a[data-role="chat-list-row"][data-space-id="#{space_id}"])

  # Turn the test database's root row into what a fresh install seeds
  # (`Root Org` / `root`), inside the sandbox. Its section follows the org
  # (`name` nil) and wears the org's own colour token, exactly as
  # `Sidebar.ensure_default_section/1` writes one.
  defp make_fresh_root! do
    root = Tenancy.get_root_org()

    {1, _} =
      Repo.update_all(from(o in Org, where: o.id == ^root.id),
        set: [slug: "root", name: "Root Org"]
      )

    Repo.update_all(from(s in Section, where: s.org_id == ^root.id),
      set: [name: nil, color: "root"]
    )

    # A fresh install configures no ROOT_ORG_SLUG; the slug resolves from
    # the row.
    previous = Application.get_env(:platform, :root_org_slug)
    Application.delete_env(:platform, :root_org_slug)

    on_exit(fn ->
      if previous, do: Application.put_env(:platform, :root_org_slug, previous)
    end)

    Tenancy.get_root_org()
  end

  # Turn the test database's root row into Alex's legacy install shape (a
  # root literally `legacy|Legacy`, pinned by ROOT_ORG_SLUG), inside the
  # sandbox. This is an on-purpose legacy fixture: the rail must render
  # that root from DATA exactly as it renders any other.
  defp make_legacy_legacy_root! do
    root = Tenancy.get_root_org()

    {1, _} =
      Repo.update_all(from(o in Org, where: o.id == ^root.id),
        set: [slug: "legacy", name: "Legacy"]
      )

    Repo.update_all(from(s in Section, where: s.org_id == ^root.id),
      set: [name: nil, color: "legacy"]
    )

    previous = Application.get_env(:platform, :root_org_slug)
    Application.put_env(:platform, :root_org_slug, "legacy")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :root_org_slug, previous),
        else: Application.delete_env(:platform, :root_org_slug)
    end)

    Tenancy.get_root_org()
  end

  describe "(a) a fresh root named Root Org" do
    test "renders no compiled org name, lists an unscoped channel and the hidden one in the popover",
         %{conn: conn} do
      root = make_fresh_root!()
      assert {root.slug, root.name} == {"root", "Root Org"}
      assert Tenancy.root_org_slug() == "root"

      # Two unscoped channels: one stays visible in the rail, the other is
      # hidden so it lands in the hidden drawer, which groups by
      # `channel_sections/5`'s default bucket.
      visible = create_channel("lounge", nil)
      hidden = create_channel("scratch", nil)

      user = insert_user()
      {:ok, _} = Accounts.hide_channel(user.id, hidden.id)

      {:ok, view, html} =
        conn
        |> init_test_session(current_user_id: user.id)
        |> live_following_redirect()

      refute html =~ ~r/#{Platform.Regression.InstallIdentityScanner.published_org_token()}/i,
             "the page carries a compiled org name"

      # The unscoped channel is a list row; the hidden one is not.
      assert has_element?(view, list_row_selector(visible.id))
      refute has_element?(view, list_row_selector(hidden.id))

      # ...and the hidden one is listed in the options popover's hidden list.
      view |> element("#list-more") |> render_click()
      view |> element(~s([data-role="chat-list-pop-option-hidden"])) |> render_click()

      assert has_element?(
               view,
               ~s(#chat-list-pop-hidden [data-role="chat-list-pop-hidden-row"][data-space-id="#{hidden.id}"])
             )

      refute has_element?(
               view,
               ~s(#chat-list-pop-hidden [data-role="chat-list-pop-hidden-row"][data-space-id="#{visible.id}"])
             )
    end

    test "the default bucket is the root's name, and `Channels` with no root row" do
      assert PlatformWeb.ChatLive.default_bucket([
               %{parent_org_id: "tenant-parent", name: "Initech"},
               %{parent_org_id: nil, name: "Root Org"}
             ]) == "Root Org"

      assert PlatformWeb.ChatLive.default_bucket([
               %{parent_org_id: "tenant-parent", name: "Initech"}
             ]) == "Channels"

      assert PlatformWeb.ChatLive.default_bucket([]) == "Channels"
    end
  end

  describe "(b) a root that is literally Legacy, from data" do
    test "lists the Legacy, Initech and unscoped channels, and pills the open one from the row",
         %{conn: conn} do
      legacy = make_legacy_legacy_root!()
      initech = Tenancy.get_org_by_slug!("initech")
      assert {legacy.slug, legacy.name} == {"legacy", "Legacy"}

      legacy_channel = create_channel("legacy-general", legacy.id)
      initech_channel = create_channel("initech-general", initech.id)
      unscoped = create_channel("unscoped-thing", nil)

      user = insert_user()

      {:ok, view, html} =
        conn
        |> init_test_session(current_user_id: user.id)
        |> live_following_redirect(
          "/chat/" <> PlatformWeb.ChatLive.space_nav_target(legacy_channel)
        )

      for space <- [legacy_channel, initech_channel, unscoped] do
        assert has_element?(view, list_row_selector(space.id)),
               "#{space.name} is missing from the Chat list"
      end

      refute html =~ "bg-legacy-dot"

      # The open Legacy channel's scope is named and keyed from the row. The
      # header pill that said so left in Burrow redesign 22 stage 4; the
      # details panel's Scope page carries the same name and slug.
      switch =
        view
        |> render_click("details_open", %{"page" => "scope"})
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(
          ~s(#details-panel [data-role="details-scope-switch"][phx-value-scope="legacy"])
        )
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert ["Filter to Legacy scope"] = switch
    end
  end

  describe "(c) a non-root internal member gets the root's colour rule" do
    # Gate case 01a116e6-cd0e-700a, measured at 4c221b7d0: an internal
    # (external=false) initech member saw the root section dot with no fill,
    # because the per-viewer `org-scope-colors` block emitted rules only for
    # orgs that viewer could see, and stage 3 had moved the root onto that
    # var path. The root's rule is now emitted for every viewer; other
    # tenants' rules still are not.
    test "the root's data-scope has a fill rule, and an unseen tenant has none",
         %{conn: conn} do
      root = make_fresh_root!()

      {1, _} =
        Repo.update_all(from(o in Org, where: o.id == ^root.id),
          set: [color_hue: 50, color_chroma: 0.16]
        )

      initech = Tenancy.get_org_by_slug!("initech")
      globex = Tenancy.get_org_by_slug!("globex")
      root_channel = create_channel("root-general", root.id)
      _initech_channel = create_channel("initech-general", initech.id)

      user = insert_user()

      membership =
        %OrgMembership{}
        |> OrgMembership.changeset(%{user_id: user.id, org_id: initech.id, role: "member"})
        |> Repo.insert!()

      refute membership.external
      refute Tenancy.root_member?(user)
      assert Tenancy.visibility(user) == {:orgs, [initech.id]}

      # A participant row keeps the root channel inside the user's org fence
      # (ticket 01a14721: a sub-org-only member lists only their orgs' spaces
      # and the spaces they participate in), so the root section renders.
      {:ok, _} =
        Chat.add_participant(root_channel.id, %{
          participant_type: "user",
          participant_id: user.id,
          joined_at: DateTime.utc_now()
        })

      {:ok, view, html} =
        conn
        |> init_test_session(current_user_id: user.id)
        |> live_following_redirect()

      # Positive control: the root channel is inside this viewer's fence.
      assert has_element?(view, list_row_selector(root_channel.id))

      [styles] =
        Regex.run(~r/<style[^>]*data-role="org-scope-colors"[^>]*>(.*?)<\/style>/s, html,
          capture: :all_but_first
        )

      assert styles =~ ~s([data-scope="#{root.slug}"]{--scope-fill:),
             "the root's data-scope has no fill rule for this viewer"

      assert styles =~ ~s([data-scope="#{initech.slug}"]{)

      refute styles =~ ~s([data-scope="#{globex.slug}"]),
             "a tenant this viewer cannot see was emitted"
    end
  end
end
