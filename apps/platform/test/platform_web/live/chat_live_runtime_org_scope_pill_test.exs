defmodule PlatformWeb.ChatLiveRuntimeOrgScopePillTest do
  @moduledoc """
  A runtime-created org renders a coloured scope pill on the chat rail's
  hidden-channels drawer and on both chat header pills (task 01a0938b
  stage 2).

  Before this task the drawer resolved its pill through a closed map keyed on
  six display names and the header through a closed map keyed on six slugs,
  so an org created at runtime got no pill on either surface. Both now read
  the org ROW: `scope` from `ChatLive.org_scope/1`, `label` from the org's
  name and `value` from its slug.

  The fixture org is named "Newclient" with slug "new_client" on purpose: the
  name is NOT the title-cased slug ("New Client"), so a pill that fell back to
  `scope_label/1` instead of reading the row's name renders the wrong text and
  fails here.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Chat, Repo, Tenancy}
  alias Platform.Tenancy.{Org, OrgMembership}
  alias PlatformWeb.Components.ScopePill

  @drawer_label ".channel-hidden-drawer-group-label"
  # The compact mobile header pill was deleted in task 01a1557a-8a6d stage 3
  # (its place is the space sheet's Scope row, asserted in the shipped-org
  # regression below).
  @header_pills [".chat-header-scope-pill"]

  # An Acme member: `ScopeColorStyles` emits a rule for every org the VIEWER
  # can see, and a user with no membership sees none, which would leave the
  # colour-rule assertion below with nothing to find for a reason unrelated
  # to this task.
  defp member_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "runtime-org-pill-#{n}@example.com",
        name: "Runtime Org Pill #{n}",
        oidc_sub: "oidc-runtime-org-pill-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: "member"
    })
    |> Repo.insert!()

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp insert_newclient do
    Repo.insert!(
      Org.changeset(%Org{}, %{
        name: "Newclient",
        slug: "new_client",
        parent_org_id: Tenancy.get_org_by_slug!("acme").id,
        color_hue: 200
      })
    )
  end

  defp channel_on(org, slug, user) do
    {:ok, channel} =
      Chat.create_space(%{name: slug, slug: slug, kind: "channel", org_id: org.id})

    {:ok, _} =
      Chat.add_participant(channel.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    channel
  end

  # One visible channel (the one the header describes) and one hidden
  # channel (so the drawer renders a group for the org).
  defp org_fixture(org, user, prefix) do
    visible = channel_on(org, "#{prefix}-general", user)
    hidden = channel_on(org, "#{prefix}-archive", user)
    {:ok, _} = Platform.Accounts.hide_channel(user.id, hidden.id)
    visible
  end

  defp extract(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.to_html()
  end

  # The chip element alone, with inter-tag whitespace collapsed on BOTH sides
  # of the comparison. `render_component/2` keeps the template's whitespace
  # text nodes (outside the chip and between its child spans), while the
  # `live/2` document arrives with them already stripped. Whitespace-only
  # text between the children of an `inline-flex` chip is not rendered, so it
  # is not part of what "the same bytes" is protecting. Attributes, element
  # order and text content are still compared exactly.
  defp chip(html), do: html |> extract("[data-scope]") |> squeeze()

  defp squeeze(html), do: String.replace(html, ~r/>\s+</, "><")

  describe "a runtime-created org" do
    test "renders a coloured pill named from the org row on the drawer and both headers",
         %{conn: conn} do
      {conn, user} = member_conn(conn)
      org = insert_newclient()
      visible = org_fixture(org, user, "newclient")

      {:ok, _view, html} = live(conn, ~p"/chat/#{visible.id}")

      drawer = extract(html, @drawer_label)
      assert drawer =~ ~s(data-scope="new_client"), "drawer chip has no data-scope"
      assert drawer =~ ">Newclient</span>"
      assert drawer =~ ~s(aria-label="Newclient scope")
      assert drawer =~ "scope-tint-200"
      refute drawer =~ "New Client"

      for selector <- @header_pills do
        pill = extract(html, selector)
        assert pill =~ ~s(data-scope="new_client"), "#{selector} has no data-scope"
        assert pill =~ ">Newclient</span>", "#{selector} is not labelled from the org name"
        assert pill =~ ~s(aria-label="Filter by Newclient scope")
        assert pill =~ ~s(phx-value-scope="new_client")
        assert pill =~ ~r/class="[^"]*\bscope-tint\b/
        refute pill =~ "New Client"
      end

      # The rule the chip's colour comes from. Without it every assertion
      # above passes on an uncoloured chip.
      assert html =~ ~s|[data-scope="new_client"]{|
    end

    test "clicking the runtime org's header pill applies the filter to that org", %{conn: conn} do
      {conn, user} = member_conn(conn)
      org = insert_newclient()
      visible = org_fixture(org, user, "newclient")

      {:ok, view, _html} = live(conn, ~p"/chat/#{visible.id}")

      # Stage 1 named a limitation here: `parse_scope/1` knew only five
      # compiled slugs, so this click CLEARED the filter. Since task 01a14dd9
      # stage 2 `parse_scope/2` accepts any slug in the loaded org index, so
      # a runtime org filters like any other.
      view
      |> element(~s(.chat-header-scope-pill button[phx-click="scope_filter"]))
      |> render_click()

      pill = extract(render(view), ".chat-header-scope-pill")
      assert pill =~ ~s(data-scope="new_client")
      assert pill =~ ~s(aria-pressed="true")
    end

    test "a rename reaches every pill, with the slug and colour unchanged", %{conn: conn} do
      {conn, user} = member_conn(conn)
      org = insert_newclient()
      visible = org_fixture(org, user, "newclient")

      {:ok, _view, before} = live(conn, ~p"/chat/#{visible.id}")
      assert extract(before, @drawer_label) =~ ">Newclient</span>"

      # A name that does not CONTAIN the old one, so the absence check below
      # can fail ("Newclient Labs" would satisfy it vacuously).
      {:ok, _} = org |> Org.changeset(%{name: "Brightwater"}) |> Repo.update()

      {:ok, _view, html} = live(conn, ~p"/chat/#{visible.id}")

      for selector <- [@drawer_label | @header_pills] do
        pill = extract(html, selector)
        assert pill =~ ">Brightwater</span>", "#{selector} kept the old name"
        assert pill =~ ~s(data-scope="new_client")
        refute pill =~ "Newclient"
      end

      assert html =~ ~s|[data-scope="new_client"]{|
      refute html =~ "Newclient"
    end
  end

  describe "the six shipped orgs (regression)" do
    test "Vandelay-Ind's header pills and drawer chip keep their spelling and bytes",
         %{conn: conn} do
      {conn, user} = member_conn(conn)
      vandelay_ind = Tenancy.get_org_by_slug!("vandelay_ind")

      # The contract labels from the org row, so the shipped bytes survive
      # only if the row carries the compiled label. Assert that rather than
      # assume it.
      assert vandelay_ind.name == "Vandelay-Ind"

      visible = org_fixture(vandelay_ind, user, "pt")
      {:ok, view, html} = live(conn, ~p"/chat/#{visible.id}")

      drawer = extract(html, @drawer_label)
      assert drawer =~ ~s(data-scope="vandelay_ind")
      assert drawer =~ ">Vandelay-Ind</span>"
      assert drawer =~ ~s(aria-label="Vandelay-Ind scope")

      for selector <- @header_pills do
        pill = extract(html, selector)
        assert pill =~ ~s(data-scope="vandelay_ind")
        assert pill =~ ~s(phx-value-scope="vandelay_ind")
        assert pill =~ ">Vandelay-Ind</span>"
        assert pill =~ ~s(aria-label="Filter by Vandelay-Ind scope")
      end

      # Byte-for-byte against the chip the org-row contract renders from the
      # bare component: the stored slug as `scope` and `value`, the row's name
      # as `label` (task 01a14dd9 stage 2 removed the compiled atom the bare
      # call used to take).
      %{slug: shipped_slug, name: shipped_name} = vandelay_ind

      expected = fn attrs ->
        (&ScopePill.scope_pill/1)
        |> render_component(
          Map.merge(
            %{scope: shipped_slug, value: shipped_slug, label: shipped_name, active: false},
            attrs
          )
        )
        |> chip()
      end

      assert squeeze(extract(html, "#{@drawer_label} > [data-scope]")) ==
               expected.(%{surface: :base_200, clickable: false})

      assert squeeze(extract(html, ".chat-header-scope-pill > [data-scope]")) ==
               expected.(%{surface: :base_100, clickable: true})

      # The phone's scope control is now the space sheet's Scope switch: the
      # org's name on the label, its stored slug as the `scope_filter` payload.
      view |> element(~s(button[data-role="space-title"])) |> render_click()
      # The title opens on the All segment; the Scope row is on Space.
      view |> element(~s(#space-sheet button[data-seg="space"])) |> render_click()
      view |> element(~s(#space-sheet button[data-role="space-sheet-scope"])) |> render_click()
      switch = extract(render(view), ~s(#space-sheet [data-role="space-sheet-scope-switch"]))
      assert switch =~ ~s(phx-value-scope="vandelay_ind")
      assert switch =~ "Filter to Vandelay-Ind scope"
    end
  end
end
