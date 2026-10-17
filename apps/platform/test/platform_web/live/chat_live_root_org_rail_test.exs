defmodule PlatformWeb.ChatLiveRootOrgRailTest do
  @moduledoc """
  The channels rail names the ROOT org by its own row, never by a compiled
  org name (task 01a116de stage 3).

  The rail's section headers render from `Platform.Chat.Sidebar`'s resolved
  sections (`@sidebar_sections`), whose header text is the org row's `name`.
  `ChatLive.channel_sections/5` feeds the hidden-channels drawer, and its
  default bucket (where an `org_id: nil` channel lands) is the root org's
  `name` too. Both are exercised here through the rendered page:

    (a) a fresh install whose root is `Root Org` renders no /fabrikam/i anywhere,
        and an unscoped channel sits under `Root Org` (visible in the rail,
        and in the hidden drawer when hidden);
    (b) an install whose root is literally `Fabrikam` (Rowan's install shape) still
        renders a `Fabrikam` section from DATA, beside the tenant sections, each
        holding its own channels, with the root's dot and header pill.

  The test database's root row is the neutral `acme|Acme` fixture (task
  01a116de stage 4). Both cases rename it INSIDE the sandbox transaction,
  which rolls back: (a) to a fresh install's `root|Root Org`, (b) to the
  legacy `fabrikam|Fabrikam` shape Rowan's installs carry, on purpose. No real
  install's rows are touched.
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

  defp desktop_sidebar(html) do
    case Regex.run(~r/<aside[^>]*id="chat-sidebar".*?<\/aside>/s, html) do
      [match] -> match
      _ -> ""
    end
  end

  # The rendered `<section>` for one org-default section, by its header name.
  defp section_html(html, name) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(section[aria-label="#{name} channels"]))
    |> LazyHTML.to_html()
  end

  # Every section header label in rail order.
  defp section_labels(html) do
    html
    |> desktop_sidebar()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("section.channel-section .channel-section-label")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

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

  # Turn the test database's root row into Rowan's legacy install shape (a
  # root literally `fabrikam|Fabrikam`, pinned by ROOT_ORG_SLUG), inside the
  # sandbox. This is an on-purpose legacy fixture: the rail must render
  # that root from DATA exactly as it renders any other.
  defp make_legacy_fabrikam_root! do
    root = Tenancy.get_root_org()

    {1, _} =
      Repo.update_all(from(o in Org, where: o.id == ^root.id),
        set: [slug: "fabrikam", name: "Fabrikam"]
      )

    Repo.update_all(from(s in Section, where: s.org_id == ^root.id),
      set: [name: nil, color: "fabrikam"]
    )

    previous = Application.get_env(:platform, :root_org_slug)
    Application.put_env(:platform, :root_org_slug, "fabrikam")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :root_org_slug, previous),
        else: Application.delete_env(:platform, :root_org_slug)
    end)

    Tenancy.get_root_org()
  end

  describe "(a) a fresh root named Root Org" do
    test "renders the rail with no /fabrikam/i anywhere and files an unscoped channel under Root Org",
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

      {:ok, _view, html} =
        conn
        |> init_test_session(current_user_id: user.id)
        |> live_following_redirect()

      refute html =~ ~r/fabrikam/i, "the page carries a compiled org name"

      assert "Root Org" in section_labels(html)

      root_section = section_html(desktop_sidebar(html), "Root Org")
      assert root_section =~ ~s(data-space-id="#{visible.id}")

      drawer =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#hidden-drawer-panel .channel-hidden-drawer-group")
        |> Enum.map(&LazyHTML.to_html/1)

      assert [group] = drawer
      assert group =~ "Root Org"
      assert group =~ "Scratch"
    end

    test "the default bucket is the root's name, and `Channels` with no root row" do
      assert PlatformWeb.ChatLive.default_bucket([
               %{parent_org_id: "tenant-parent", name: "Soylent"},
               %{parent_org_id: nil, name: "Root Org"}
             ]) == "Root Org"

      assert PlatformWeb.ChatLive.default_bucket([
               %{parent_org_id: "tenant-parent", name: "Soylent"}
             ]) == "Channels"

      assert PlatformWeb.ChatLive.default_bucket([]) == "Channels"
    end
  end

  describe "(b) a root that is literally Fabrikam, from data" do
    test "renders Soylent and Fabrikam sections, each with its own channels", %{conn: conn} do
      fabrikam = make_legacy_fabrikam_root!()
      soylent = Tenancy.get_org_by_slug!("soylent")
      assert {fabrikam.slug, fabrikam.name} == {"fabrikam", "Fabrikam"}

      fabrikam_channel = create_channel("fabrikam-general", fabrikam.id)
      soylent_channel = create_channel("soylent-general", soylent.id)
      unscoped = create_channel("unscoped-thing", nil)

      user = insert_user()

      {:ok, _view, html} =
        conn
        |> init_test_session(current_user_id: user.id)
        |> live_following_redirect(
          "/chat/" <> PlatformWeb.ChatLive.space_nav_target(fabrikam_channel)
        )

      labels = section_labels(html)
      assert "Fabrikam" in labels
      assert "Soylent" in labels

      sidebar = desktop_sidebar(html)
      fabrikam_section = section_html(sidebar, "Fabrikam")
      soylent_section = section_html(sidebar, "Soylent")

      assert fabrikam_section =~ ~s(data-space-id="#{fabrikam_channel.id}")
      assert fabrikam_section =~ ~s(data-space-id="#{unscoped.id}")
      refute fabrikam_section =~ ~s(data-space-id="#{soylent_channel.id}")

      assert soylent_section =~ ~s(data-space-id="#{soylent_channel.id}")
      refute soylent_section =~ ~s(data-space-id="#{fabrikam_channel.id}")

      # The root's dot is coloured from its row through `data-scope`, with
      # no compiled class.
      assert fabrikam_section =~
               ~r/class="channel-section-color-dot channel-section-color-dot--unassigned"\s+data-scope="fabrikam"/

      refute html =~ "bg-fabrikam-dot"

      # The chat header pill for the open Fabrikam channel still renders, named
      # and keyed from the row.
      pill =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-scope="fabrikam"] .scope-pill-label))
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert "Fabrikam" in pill
    end
  end

  describe "(c) a non-root internal member sees the root coloured" do
    # Gate case 01a116e6-cd0e-700a, measured at 4c221b7d0: an internal
    # (external=false) soylent member saw the root section dot with no fill,
    # because the per-viewer `org-scope-colors` block emitted rules only for
    # orgs that viewer could see, and stage 3 had moved the root onto that
    # var path. The root's rule is now emitted for every viewer; other
    # tenants' rules still are not.
    test "the root dot's data-scope has a fill rule, and an unseen tenant has none",
         %{conn: conn} do
      root = make_fresh_root!()

      {1, _} =
        Repo.update_all(from(o in Org, where: o.id == ^root.id),
          set: [color_hue: 50, color_chroma: 0.16]
        )

      soylent = Tenancy.get_org_by_slug!("soylent")
      sxi = Tenancy.get_org_by_slug!("sxi")
      root_channel = create_channel("root-general", root.id)
      _soylent_channel = create_channel("soylent-general", soylent.id)

      user = insert_user()

      membership =
        %OrgMembership{}
        |> OrgMembership.changeset(%{user_id: user.id, org_id: soylent.id, role: "member"})
        |> Repo.insert!()

      refute membership.external
      refute Tenancy.root_member?(user)
      assert Tenancy.visibility(user) == {:orgs, [soylent.id]}

      # A participant row keeps the root channel inside the user's org fence
      # (ticket 01a14721: a sub-org-only member lists only their orgs' spaces
      # and the spaces they participate in), so the root section renders.
      {:ok, _} =
        Chat.add_participant(root_channel.id, %{
          participant_type: "user",
          participant_id: user.id,
          joined_at: DateTime.utc_now()
        })

      {:ok, _view, html} =
        conn
        |> init_test_session(current_user_id: user.id)
        |> live_following_redirect()

      root_section = section_html(desktop_sidebar(html), "Root Org")
      assert root_section =~ ~s(data-space-id="#{root_channel.id}")

      [dot_scope] =
        root_section
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(".channel-section-color-dot")
        |> LazyHTML.attribute("data-scope")

      assert dot_scope == root.slug

      [styles] =
        Regex.run(~r/<style[^>]*data-role="org-scope-colors"[^>]*>(.*?)<\/style>/s, html,
          capture: :all_but_first
        )

      assert styles =~ ~s([data-scope="#{dot_scope}"]{--scope-fill:),
             "the root dot's data-scope has no fill rule for this viewer"

      assert styles =~ ~s([data-scope="#{soylent.slug}"]{)

      refute styles =~ ~s([data-scope="#{sxi.slug}"]),
             "a tenant this viewer cannot see was emitted"
    end
  end
end
