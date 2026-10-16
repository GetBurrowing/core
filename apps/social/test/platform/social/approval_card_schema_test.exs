defmodule Platform.Social.ApprovalCardSchemaTest do
  @moduledoc """
  Social 3/7 stage 1: the approval card table and the profile's channel.
  Every DB refusal is driven with `insert_all` / `update_all`, so no
  changeset is in the path and the test goes red if the constraint is
  dropped.
  """
  use Platform.DataCase, async: true

  import Platform.SocialFixtures

  alias Platform.Social
  alias Platform.Social.{ApprovalCard, Profile}

  setup do
    org_id = org_id!()
    space = channel!(org_id)
    human = user!()
    participant = join!(space.id, :user, human.id)
    {:ok, profile} = Social.create_profile(org_id, %{name: "Cards", space_id: space.id})
    {:ok, account} = Social.create_account(org_id, profile, %{platform: "linkedin"})
    {:ok, post} = Social.create_post(org_id, account, %{body: "draft"})

    %{
      org_id: org_id,
      space: space,
      human: human,
      participant: participant,
      profile: profile,
      post: post
    }
  end

  defp canvas!(ctx) do
    {:ok, canvas} =
      Platform.Chat.create_canvas(%{
        space_id: ctx.space.id,
        created_by: ctx.participant.id,
        title: "card"
      })

    canvas
  end

  defp row(ctx, overrides) do
    now = DateTime.utc_now()

    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        post_id: ctx.post.id,
        canvas_id: canvas!(ctx).id,
        card_digest: "digest",
        state: "pending",
        inserted_at: now,
        updated_at: now
      },
      overrides
    )
  end

  defp insert_raw(row) do
    Repo.transaction(fn -> Repo.insert_all(ApprovalCard, [row]) end)
  end

  defp pg_error(fun) do
    error = assert_raise Postgrex.Error, fun
    error.postgres
  end

  test "a pending card inserts; create_changeset casts no decision field", ctx do
    canvas = canvas!(ctx)

    assert {:ok, card} =
             %ApprovalCard{}
             |> ApprovalCard.create_changeset(%{
               post_id: ctx.post.id,
               canvas_id: canvas.id,
               card_digest: "d",
               state: "decided",
               decision: "approve",
               decided_by_user_id: ctx.human.id,
               decided_at: DateTime.utc_now(),
               edited_by_user_id: ctx.human.id
             })
             |> Repo.insert()

    assert card.state == "pending"
    assert card.decision == nil
    assert card.decided_by_user_id == nil
    assert card.decided_at == nil
    assert card.edited_by_user_id == nil
  end

  test "a decided card without a decider, decision or time is refused by the CHECK", ctx do
    for missing <- [:decision, :decided_by_user_id, :decided_at] do
      full = %{
        state: "decided",
        decision: "approve",
        decided_by_user_id: ctx.human.id,
        decided_at: DateTime.utc_now()
      }

      pg = pg_error(fn -> insert_raw(row(ctx, Map.delete(full, missing))) end)
      assert pg.constraint == "social_approval_cards_decided_complete_check", inspect(missing)
    end
  end

  test "a second live card for one post is refused; a decided one beside it is fine", ctx do
    {:ok, _} = insert_raw(row(ctx, %{}))

    pg = pg_error(fn -> insert_raw(row(ctx, %{state: "deciding"})) end)
    assert pg.constraint == "social_approval_cards_one_live_card_per_post"

    assert {:ok, _} = insert_raw(row(ctx, %{state: "superseded"}))
  end

  test "an agent id as decided_by is refused by the FK to users", ctx do
    agent = agent!()

    pg =
      pg_error(fn ->
        insert_raw(
          row(ctx, %{
            state: "decided",
            decision: "approve",
            decided_by_user_id: agent.id,
            decided_at: DateTime.utc_now()
          })
        )
      end)

    assert pg.code == :foreign_key_violation
    assert pg.constraint == "social_approval_cards_decided_by_user_id_fkey"
  end

  test "a bad state or decision is refused by its CHECK", ctx do
    pg = pg_error(fn -> insert_raw(row(ctx, %{state: "approved"})) end)
    assert pg.constraint == "social_approval_cards_state_check"

    pg = pg_error(fn -> insert_raw(row(ctx, %{decision: "publish"})) end)
    assert pg.constraint == "social_approval_cards_decision_check"
  end

  test "one card per canvas", ctx do
    canvas = canvas!(ctx)
    {:ok, _} = insert_raw(row(ctx, %{canvas_id: canvas.id, state: "superseded"}))
    pg = pg_error(fn -> insert_raw(row(ctx, %{canvas_id: canvas.id, state: "superseded"})) end)
    assert pg.constraint == "social_approval_cards_canvas_id_index"
  end

  test "deleting the space nils the profile's space_id and keeps the profile", ctx do
    Repo.delete!(ctx.space)
    assert %Profile{space_id: nil} = Repo.get!(Profile, ctx.profile.id)
  end

  test "a space from another org is refused; one from the profile's org is accepted", ctx do
    other = channel!(org_id!())

    assert {:error, cs} = Social.update_profile(ctx.org_id, ctx.profile, %{space_id: other.id})
    assert errors_on(cs)[:space_id] == ["must be a space in the profile's org"]

    assert {:error, cs} =
             Social.create_profile(ctx.org_id, %{name: "Elsewhere", space_id: other.id})

    assert errors_on(cs)[:space_id] == ["must be a space in the profile's org"]

    assert {:error, cs} =
             Social.update_profile(ctx.org_id, ctx.profile, %{space_id: Ecto.UUID.generate()})

    assert errors_on(cs)[:space_id]

    mine = channel!(ctx.org_id)

    assert {:ok, %Profile{space_id: id}} =
             Social.update_profile(ctx.org_id, ctx.profile, %{space_id: mine.id})

    assert id == mine.id
  end
end
