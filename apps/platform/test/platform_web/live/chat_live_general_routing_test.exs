defmodule PlatformWeb.ChatLiveGeneralRoutingTest do
  @moduledoc """
  Regression coverage for the per-tenant "General" channel routing bug
  (task `019edd8e-8a61-7c0a-8cc0-ba5725123347` Stage 1).

  Background:
    * Post-ADR-0042, every tenant org has a chat_space with `slug: "general"`,
      each scoped to that org via `chat_spaces.org_id`. Fabrikam also has its
      own General (`org_id = fabrikam_id`).
    * The previous `Chat.get_space_by_slug/1` returned `order_by inserted_at
      asc, limit 1`, so a Soylent member clicking the Soylent-section
      "General" sidebar entry would always land in Fabrikam's General — the
      oldest matching row.

  The fix narrows the lookup in `chat_live.ex` `handle_params/3` (and its
  embedded twin `bootstrap_embedded_space/2`) to the *user's* org via the
  new `:org_id` opt on `Chat.get_space_by_slug/2`. This test asserts the
  observable behavior on the URL flow: `/chat/general` mounts each
  tenant's own General when navigated by a member of that tenant.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp create_user!(suffix) do
    Repo.insert!(%User{
      email: "general_routing_#{suffix}@example.com",
      name: "General Routing #{suffix}",
      oidc_sub: "oidc-general-routing-#{suffix}"
    })
  end

  defp membership!(user, org) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
    |> Repo.insert!()
  end

  defp ensure_general_for_org(org_slug) do
    org = Tenancy.get_org_by_slug!(org_slug)

    case Chat.list_spaces(kind: "channel")
         |> Enum.find(&(&1.org_id == org.id and &1.slug == "general")) do
      %Chat.Space{} = space ->
        space

      nil ->
        # Each org gets its own slug-scoped "general". The partial unique
        # index `chat_spaces_unique_org_slug` enforces one-per-org so the
        # test seed is collision-safe across reruns within the same DB.
        {:ok, space} =
          Chat.create_space(%{
            name: "General",
            slug: "general",
            kind: "channel",
            org_id: org.id
          })

        space
    end
  end

  describe "GET /chat/general routes to the user's tenant General" do
    test "Soylent member lands on Soylent's General, not Fabrikam's", %{conn: conn} do
      fabrikam_general = ensure_general_for_org("fabrikam")
      soylent_general = ensure_general_for_org("soylent")
      refute fabrikam_general.id == soylent_general.id

      user = create_user!("soylent")
      membership!(user, Tenancy.get_org_by_slug!("soylent"))

      conn = init_test_session(conn, current_user_id: user.id)

      {:ok, _view, html} = live(conn, ~p"/chat/general")

      # The composer's `data-draft-key` is `chat-draft:<space_id>` and is
      # the most precise observable signal that the lookup picked the
      # tenant's row and not Fabrikam's. (Post-ADR-0042 both spaces are named
      # "General", so a title match alone wouldn't distinguish them.)
      assert html =~ "data-draft-key=\"chat-draft:#{soylent_general.id}\""
      refute html =~ "data-draft-key=\"chat-draft:#{fabrikam_general.id}\""
    end

    test "SXI member lands on SXI's General when hitting /chat/general", %{conn: conn} do
      _fabrikam_general = ensure_general_for_org("fabrikam")
      _soylent_general = ensure_general_for_org("soylent")
      sxi_general = ensure_general_for_org("sxi")

      user = create_user!("sxi")
      membership!(user, Tenancy.get_org_by_slug!("sxi"))

      conn = init_test_session(conn, current_user_id: user.id)

      {:ok, _view, html} = live(conn, ~p"/chat/general")

      assert html =~ "data-draft-key=\"chat-draft:#{sxi_general.id}\""
    end

    test "Fabrikam member lands on Fabrikam's General (back-compat with the legacy path)",
         %{conn: conn} do
      fabrikam_general = ensure_general_for_org("fabrikam")
      _soylent_general = ensure_general_for_org("soylent")

      user = create_user!("fabrikam")
      membership!(user, Tenancy.get_org_by_slug!("fabrikam"))

      conn = init_test_session(conn, current_user_id: user.id)

      {:ok, _view, html} = live(conn, ~p"/chat/general")

      assert html =~ "data-draft-key=\"chat-draft:#{fabrikam_general.id}\""
    end
  end
end
