defmodule PlatformWeb.ChatLive.ScopeChipColourReachTest do
  @moduledoc """
  The chat header's scope chip is coloured for an Acme member who is not an
  admin (task 01a09333-d374 stage 5).

  Since stage 5 a chip's colour comes only from the `<style>` block's rule
  for its `data-scope`. Chat shows every root member every org's channels,
  so the block has to carry every org such a member can see, not just the
  orgs they belong to. Built from the Tasks rail's narrower list, the block
  left this member's Globex chip with no fill, no dot and a text-coloured ring,
  while an admin (Robin, on every dev server) saw it coloured.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Chat, Repo, Tenancy}
  alias Platform.Tenancy.OrgMembership

  defp acme_member_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "scope-reach-#{n}@example.com",
        name: "Scope Reach #{n}",
        oidc_sub: "oidc-scope-reach-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: "member"
    })
    |> Repo.insert!()

    refute Tenancy.root_admin?(user)
    {init_test_session(conn, current_user_id: user.id), user}
  end

  test "an Globex channel's header chip has a colour rule for an Acme member", %{conn: conn} do
    {conn, user} = acme_member_conn(conn)

    {:ok, channel} =
      Chat.create_space(%{
        name: "Globex reach",
        slug: "globex-reach",
        kind: "channel",
        org_id: Tenancy.get_org_by_slug!("globex").id
      })

    {:ok, _} =
      Chat.add_participant(channel.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    # By id: a slug is looked up in the VIEWER's active org (Acme here), and
    # would miss this Globex channel and mint an Acme one with the same slug.
    {:ok, view, _html} = live(conn, ~p"/chat/#{channel.id}")
    html = render(view)

    # The chip: the header pill carries the stored slug.
    assert html =~ ~s(data-scope="globex" class=), "no header chip for the Globex channel"

    # The rule it needs, at Globex's shipped fill. Without it the chip above is
    # uncoloured, and nothing errors.
    assert html =~ ~s|[data-scope="globex"]{--scope-fill:oklch(70% 0.15 162);|
  end
end
