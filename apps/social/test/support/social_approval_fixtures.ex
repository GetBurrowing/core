defmodule Platform.SocialApprovalFixtures do
  @moduledoc """
  The approval-flow fixture (Social 3/7), shared by the context, LiveView
  and acceptance tests: org O with channel S; approvers H1 and H2 (real
  users, org members, participants of S); human N (member and participant,
  not an approver); agent G (a real agents row, participant of S); profile
  P on S with approvers [H1, H2]; account A (linkedin, approve_first) and
  account D (linkedin, draft_only).
  """

  import Platform.SocialFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{ApprovalCard, Post}

  def approval_fixture(opts \\ []) do
    org_id = org_id!()
    space = channel!(org_id, Keyword.get(opts, :space_attrs, %{}))

    [h1, h2, n] =
      for label <- ["Hana One", "Hugo Two", "Nina Viewer"] do
        user = named_user!(label)
        member!(user, org_id)
        join!(space.id, :user, user.id)
        user
      end

    g = agent!()
    join!(space.id, :agent, g.id)

    {:ok, profile} =
      Social.create_profile(org_id, %{
        name: "HTC #{unique()}",
        space_id: space.id,
        approver_user_ids: [h1.id, h2.id],
        default_hashtags: ["#htc"]
      })

    {:ok, a} =
      Social.create_account(org_id, profile, %{platform: "linkedin", handle: "@htc_official"})

    {:ok, d} =
      Social.create_account(org_id, profile, %{
        platform: "linkedin",
        handle: "@htc_drafts",
        approval_mode: "draft_only"
      })

    %{org_id: org_id, space: space, h1: h1, h2: h2, n: n, g: g, profile: profile, a: a, d: d}
  end

  def named_user!(name) do
    n = unique()

    %Platform.Accounts.User{}
    |> Platform.Accounts.User.changeset(%{
      email: "social-approver-#{n}@example.com",
      name: name,
      oidc_sub: "social-approver-#{n}"
    })
    |> Repo.insert!()
  end

  @doc "A needs_approval post on `account` and its live card."
  def pending_post!(ctx, account, attrs \\ %{}) do
    {:ok, post} =
      Social.create_post(
        ctx.org_id,
        account,
        Map.merge(%{body: "Episode 12 is live: listen now", status: "needs_approval"}, attrs)
      )

    {post, live_card!(post)}
  end

  def live_card!(%Post{id: post_id}) do
    import Ecto.Query
    Repo.one!(from(c in ApprovalCard, where: c.post_id == ^post_id and c.state == "pending"))
  end

  def row_snapshot(%Post{id: id}) do
    p = Repo.get!(Post, id)
    Map.take(p, [:status, :body, :approved_by_user_id, :approved_at, :updated_at, :rejected_at])
  end

  def card_snapshot(%ApprovalCard{id: id}) do
    c = Repo.get!(ApprovalCard, id)
    Map.take(c, [:state, :decision, :decided_by_user_id, :decided_at, :card_digest, :updated_at])
  end
end
