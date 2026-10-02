defmodule PlatformWeb.ChatLiveBootstrapDuplicateTest do
  @moduledoc """
  Regression coverage for the duplicate-channel mint observed by the task
  `01a00910` behavioural gate (stage 5 remediation).

  Two defects combine in production:

    * `NewChannelComponent` creates a channel with NO `org_id` (the dialog had
      no org destination), and
    * `bootstrap_space/2` on ChatLive MOUNT does an ORG-SCOPED
      `Chat.get_space_by_slug(slug, org_id: active_org)`, misses the org-less
      row that was just created, and INSERTS A SECOND channel.

  The reviewer observed both rows 244ms apart, and — worse — a duplicate
  `orion` row minted *merely by navigating to an existing org-less channel*.

  Both cases below assert on the **row count in `chat_spaces`**, never on the
  struct a `Repo.insert` hands back: an insert returns a struct whether or not
  it wrote the row you meant.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp create_user!(suffix) do
    Repo.insert!(%User{
      email: "bootstrap_dup_#{suffix}@example.com",
      name: "Bootstrap Dup #{suffix}",
      oidc_sub: "oidc-bootstrap-dup-#{suffix}"
    })
  end

  defp membership!(user, org) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
    |> Repo.insert!()
  end

  defp rows_for(slug), do: Repo.all(from(s in Space, where: s.slug == ^slug))

  describe "mounting /chat/<slug> for an existing ORG-LESS channel" do
    test "adopts the existing row instead of minting a second one", %{conn: conn} do
      slug = "livechan-one"

      # The row "+ New channel" used to create: no org_id at all.
      {:ok, orgless} = Chat.create_channel(%{name: "Livechan One", slug: slug})
      assert orgless.org_id == nil
      assert length(rows_for(slug)) == 1

      user = create_user!("fabrikam")
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      membership!(user, fabrikam)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, _view, _html} = live(conn, ~p"/chat/#{slug}")

      # THE assertion: still exactly one row, not two.
      assert [%Space{id: id}] = rows_for(slug)
      assert id == orgless.id
    end
  end

  describe "bootstrapping a slug that does not exist yet" do
    test "still mints exactly one row, scoped to the mounting user's org", %{conn: conn} do
      slug = "brand-new-bootstrap-chan"
      assert rows_for(slug) == []

      user = create_user!("fabrikam-new")
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      membership!(user, fabrikam)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, _view, _html} = live(conn, ~p"/chat/#{slug}")

      assert [%Space{org_id: org_id}] = rows_for(slug)
      assert org_id == fabrikam.id
    end

    test "a per-org slug collision is NOT adopted across orgs", %{conn: conn} do
      slug = "org-scoped-dup-chan"

      sxi = Tenancy.get_org_by_slug!("sxi")
      {:ok, sxi_chan} = Chat.create_channel(%{name: "Org Scoped", slug: slug, org_id: sxi.id})

      user = create_user!("fabrikam-collide")
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      membership!(user, fabrikam)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, _view, _html} = live(conn, ~p"/chat/#{slug}")

      # ADR-0042 per-org slug scoping is NOT weakened by the adoption guard:
      # an SXI channel is not handed to a Fabrikam member, so Fabrikam gets its own.
      rows = rows_for(slug)
      assert length(rows) == 2
      assert Enum.sort(Enum.map(rows, & &1.org_id)) == Enum.sort([sxi.id, fabrikam.id])
      assert Enum.any?(rows, &(&1.id == sxi_chan.id))
    end
  end

  # Task 01a0fd62-a7ef-7001-8477-bd17e47bbaca stage 1.
  describe "the user whose navigation bootstraps a channel" do
    test "is stamped as created_by and seated once, as admin", %{conn: conn} do
      slug = "bootstrap-creator-admin-chan"
      assert rows_for(slug) == []

      user = create_user!("fabrikam-creator")
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      membership!(user, fabrikam)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, _view, _html} = live(conn, ~p"/chat/#{slug}")

      assert [%Space{id: space_id, created_by: created_by}] = rows_for(slug)
      assert created_by == user.id

      rows =
        Repo.all(
          from(p in Platform.Chat.Participant,
            where:
              p.space_id == ^space_id and p.participant_type == "user" and
                p.participant_id == ^user.id
          )
        )

      assert [%{role: "admin"}] = rows
    end

    test "adopting an existing org-less channel does not make the navigator its admin",
         %{conn: conn} do
      slug = "adopted-no-admin-chan"
      {:ok, orgless} = Chat.create_channel(%{name: "Adopted", slug: slug})

      user = create_user!("fabrikam-adopter")
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      membership!(user, fabrikam)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, _view, _html} = live(conn, ~p"/chat/#{slug}")

      rows =
        Repo.all(
          from(p in Platform.Chat.Participant,
            where:
              p.space_id == ^orgless.id and p.participant_type == "user" and
                p.participant_id == ^user.id
          )
        )

      assert [%{role: "member"}] = rows
    end
  end
end
