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

  Burrow redesign 22 stage 2 deleted the desktop channel rail and the
  hidden-channels drawer at its foot, whose org group label carried the
  drawer chip. The drawer assertions are deleted; the header pill and the
  space sheet's Scope switch keep theirs.

  Burrow redesign 22 stage 4 deleted the desktop header pill (coverage row
  49). Its job, the filter labelled from the org ROW with the stored slug as
  the `scope_filter` payload, is the details panel's Scope row and switch,
  which these tests now read. The panel draws no coloured chip, so the
  chip-byte and colour-rule assertions left with the pill.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Chat, Repo, Tenancy}
  alias Platform.Tenancy.{Org, OrgMembership}

  # The desktop filter: the details panel's Scope row and switch.
  @scope_row ~s(#details-panel [data-role="details-scope"])
  @scope_switch ~s(#details-panel [data-role="details-scope-switch"])

  defp panel_scope(view) do
    row = extract(render_click(view, "details_open", %{"page" => "space"}), @scope_row)
    switch = extract(render_click(view, "details_open", %{"page" => "scope"}), @scope_switch)
    {row, switch}
  end

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

  describe "a runtime-created org" do
    test "the panel's Scope row and switch are named from the org row", %{conn: conn} do
      {conn, user} = member_conn(conn)
      org = insert_newclient()
      visible = org_fixture(org, user, "newclient")

      {:ok, view, html} = live(conn, ~p"/chat/#{visible.id}")
      refute html =~ "chat-header-scope-pill"

      {row, switch} = panel_scope(view)
      assert row =~ "Newclient · filter off", "the Scope row is not labelled from the org name"
      assert switch =~ "Filter to Newclient scope"
      assert switch =~ ~s(phx-value-scope="new_client")
      refute row <> switch =~ "New Client"
    end

    test "the runtime org's switch applies the filter to that org", %{conn: conn} do
      {conn, user} = member_conn(conn)
      org = insert_newclient()
      visible = org_fixture(org, user, "newclient")

      {:ok, view, _html} = live(conn, ~p"/chat/#{visible.id}")

      # Since task 01a14dd9 stage 2 `parse_scope/2` accepts any slug in the
      # loaded org index, so a runtime org filters like any other.
      {_row, _switch} = panel_scope(view)
      view |> element(@scope_switch) |> render_click()

      switch = extract(render(view), @scope_switch)
      assert switch =~ ~s(phx-value-scope="new_client")
      assert switch =~ ~s(aria-checked="true")
    end

    test "a rename reaches the Scope row and switch, with the slug unchanged", %{conn: conn} do
      {conn, user} = member_conn(conn)
      org = insert_newclient()
      visible = org_fixture(org, user, "newclient")

      {:ok, view, _before} = live(conn, ~p"/chat/#{visible.id}")
      {row, _switch} = panel_scope(view)
      assert row =~ "Newclient"

      # A name that does not CONTAIN the old one, so the absence check below
      # can fail ("Newclient Labs" would satisfy it vacuously).
      {:ok, _} = org |> Org.changeset(%{name: "Brightwater"}) |> Repo.update()

      {:ok, view, _html} = live(conn, ~p"/chat/#{visible.id}")
      {row, switch} = panel_scope(view)
      assert row =~ "Brightwater", "the Scope row kept the old name"
      assert switch =~ "Filter to Brightwater scope"
      assert switch =~ ~s(phx-value-scope="new_client")
      refute render(view) =~ "Newclient"
    end
  end

  describe "the six shipped orgs (regression)" do
    test "Vandelay-Ind keeps its spelling and slug on the panel and the phone sheet",
         %{conn: conn} do
      {conn, user} = member_conn(conn)
      vandelay_ind = Tenancy.get_org_by_slug!("vandelay_ind")

      # The contract labels from the org row, so the shipped spelling survives
      # only if the row carries the compiled label. Assert that rather than
      # assume it.
      assert vandelay_ind.name == "Vandelay-Ind"

      visible = org_fixture(vandelay_ind, user, "pt")
      {:ok, view, _html} = live(conn, ~p"/chat/#{visible.id}")

      {row, switch} = panel_scope(view)
      assert row =~ "Vandelay-Ind · filter off"
      assert switch =~ ~s(phx-value-scope="vandelay_ind")
      assert switch =~ "Filter to Vandelay-Ind scope"

      # The phone's scope control is the space sheet's Scope switch: the
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
