defmodule Platform.Memory.Insights.TierTest do
  @moduledoc """
  Task 01a13867 stage 2: `Tier.classify/1` is default-deny.

  Every `:needs_call` assertion is preceded, on the same fixture, by the
  `:reversible` control it differs from in one field, so a classifier that
  answers `:needs_call` for everything cannot pass. Mutation probe (b)
  (`classify/1` always `:reversible`) turns the external-addressee and
  empty-page tests red.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights.Tier
  alias Platform.Org.Wiki
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp n, do: System.unique_integer([:positive])

  defp user!(org, opts \\ []) do
    i = n()

    u =
      Repo.insert!(%User{
        email: "tier-#{i}@example.com",
        name: "Tier #{i}",
        oidc_sub: "tier-#{i}"
      })

    if org do
      if Keyword.get(opts, :external, false) do
        {:ok, _} = Tenancy.mark_membership_external(%{user_id: u.id, org_id: org})
      else
        %OrgMembership{}
        |> OrgMembership.changeset(%{user_id: u.id, org_id: org, role: "member"})
        |> Repo.insert!()
      end
    end

    u
  end

  defp insight(attrs) do
    struct(
      Insight,
      Map.merge(
        %{
          action_type: "briefing",
          confidence: "high",
          body: "b",
          action: %{},
          workspace_id: nil,
          org_id: acme_org_id()
        },
        attrs
      )
    )
  end

  setup do
    %{org: acme_org_id()}
  end

  test "an external, guest or unresolved addressee is needs_call", %{org: org} do
    member = user!(org)
    assert Tier.classify(insight(%{addressee_user_id: member.id})) == :reversible
    assert Tier.classify(insight(%{})) == :reversible

    guest = user!(org, external: true)
    assert Tier.classify(insight(%{addressee_user_id: guest.id})) == :needs_call

    # A user with no membership in the insight's org is not a member of it.
    outsider = user!(tenant_org_id("tier_other_#{n()}"))
    assert Tier.classify(insight(%{addressee_user_id: outsider.id})) == :needs_call

    # An email address that resolved to nobody (an outside party) stays needs_call.
    assert Tier.classify(insight(%{action: %{"addressee" => "someone@example.com"}})) ==
             :needs_call

    # An internal member named by email routes like one named by id: the
    # addressee is judged by who it resolves to, not by how it was written.
    assert Tier.classify(
             insight(%{addressee_user_id: member.id, action: %{"addressee" => member.email}})
           ) == :reversible

    # A guest named by email is still judged by the membership it resolved to.
    assert Tier.classify(
             insight(%{addressee_user_id: guest.id, action: %{"addressee" => guest.email}})
           ) == :needs_call

    # A named addressee that resolved to nobody is not established as a member.
    assert Tier.classify(insight(%{action: %{"addressee" => "nobody-slug"}})) == :needs_call
  end

  describe "page_edit" do
    setup do
      key = "org/page/tier-#{n()}.md"
      {:ok, _} = Wiki.upsert_page(key, %{content: "only line"})
      %{key: key}
    end

    test "a page_edit that empties a page is needs_call", %{key: key} do
      edit = fn new ->
        insight(%{
          action_type: "page_edit",
          action: %{"target" => key, "hunks" => [%{"old" => "only line", "new" => new}]}
        })
      end

      assert Tier.classify(edit.("a better line")) == :reversible
      assert Tier.classify(edit.("")) == :needs_call
      assert Tier.classify(edit.("  \n ")) == :needs_call
    end

    test "a delete-shaped hunk is needs_call even when the page stays non-empty" do
      key = "org/page/tier-del-#{n()}.md"
      {:ok, _} = Wiki.upsert_page(key, %{content: "keep this. drop this."})

      keep = %{"old" => "keep this.", "new" => "keep that."}
      drop = %{"old" => " drop this.", "new" => ""}

      ok = insight(%{action_type: "page_edit", action: %{"target" => key, "hunks" => [keep]}})
      assert Tier.classify(ok) == :reversible

      del =
        insight(%{action_type: "page_edit", action: %{"target" => key, "hunks" => [keep, drop]}})

      assert Tier.classify(del) == :needs_call
    end

    test "a missing target page is needs_call", %{key: key} do
      hunks = [%{"old" => "only line", "new" => "x"}]
      ok = insight(%{action_type: "page_edit", action: %{"target" => key, "hunks" => hunks}})
      assert Tier.classify(ok) == :reversible

      gone = put_in(ok.action["target"], "org/page/gone-#{n()}.md")
      assert Tier.classify(gone) == :needs_call
    end
  end

  test "an unknown shape defaults to needs_call" do
    assert Tier.classify(insight(%{action_type: "question"})) == :reversible

    assert Tier.classify(insight(%{action_type: "mail"})) == :needs_call
    assert Tier.classify(insight(%{action_type: "permission_change"})) == :needs_call
    assert Tier.classify(insight(%{action_type: nil})) == :needs_call
    assert Tier.classify(insight(%{action: nil})) == :needs_call
    assert Tier.classify(insight(%{action: "page"})) == :needs_call
    assert Tier.classify(%{}) == :needs_call
    assert Tier.classify(nil) == :needs_call
    assert Tier.classify(insight(%{action_type: "page_edit", action: %{}})) == :needs_call

    assert Tier.classify(
             insight(%{
               action_type: "page_edit",
               action: %{"target" => "org/page/x.md", "hunks" => "x"}
             })
           ) == :needs_call
  end
end
