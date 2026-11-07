defmodule Platform.Secretary.SubmitTest do
  @moduledoc """
  `Platform.Secretary.Submit.apply/3` (task 01a1b721 stage 3): the whole
  answer is refused when any ref is outside the batch, and a valid answer is
  written with the person's feedback applied.

  Mutant this names: drop the batch-membership check (M14) -> "a ref outside
  the batch rejects the whole answer" goes red.
  """
  use Platform.DataCase, async: false

  import Platform.SecretaryFixtures

  alias Platform.Repo
  alias Platform.Secretary
  alias Platform.Secretary.{Evaluation, Store, Submit, Todos}

  setup do
    user = person!()
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()

    refs = [
      %{
        "ref_type" => "inbox_item",
        "ref_id" => a,
        "kind" => "inbox:task_plan_review",
        "kind_key" => "inbox:task_plan_review",
        "space_id" => nil,
        "mentioned" => false
      },
      %{
        "ref_type" => "inbox_item",
        "ref_id" => b,
        "kind" => "inbox:briefing",
        "kind_key" => "inbox:briefing",
        "space_id" => nil,
        "mentioned" => false
      }
    ]

    {:ok, batch} = Store.create_batch(user.id, %{item_refs: refs, reserved_tokens: 10})
    Secretary.topic(user.id) |> then(&Phoenix.PubSub.subscribe(Platform.PubSub, &1))
    %{user: user, batch: batch, a: a, b: b}
  end

  defp eval(ref_id, tag, rank, extra \\ %{}) do
    Map.merge(
      %{
        "ref_type" => "inbox_item",
        "ref_id" => ref_id,
        "tag" => tag,
        "group_key" => "none",
        "reason" => "because #{tag}",
        "rank" => rank
      },
      extra
    )
  end

  defp apply!(batch, answer),
    do:
      Submit.apply(batch, answer,
        model_version: "host:test:claude_code",
        goal_keys: [],
        brief_max_lines: 3
      )

  defp model_rows(user_id),
    do:
      Repo.all(
        from(e in Evaluation, where: e.user_id == ^user_id and e.model_version != "fallback")
      )

  test "a ref outside the batch rejects the whole answer", ctx do
    outside = Ecto.UUID.generate()

    answer = %{
      "evaluations" => [eval(ctx.a, "decide", 1), eval(outside, "decide", 2)],
      "brief" => []
    }

    assert {:error, {:rejected, {:ref_outside_batch, _}}} = apply!(ctx.batch, answer)
    assert model_rows(ctx.user.id) == []
    assert Store.get_evaluation(ctx.user.id, "inbox_item", outside) == nil
    assert %{status: "rejected"} = Store.get_batch(ctx.user.id, ctx.batch.id)
    # The batch's own refs fall back, one failed attempt each.
    assert %{model_version: "fallback", failed_attempts: 1} =
             Store.get_evaluation(ctx.user.id, "inbox_item", ctx.a)
  end

  test "a brief line or a suggestion outside the batch also rejects", ctx do
    outside = Ecto.UUID.generate()

    for answer <- [
          %{
            "evaluations" => [eval(ctx.a, "decide", 1)],
            "brief" => [%{"ref_type" => "inbox_item", "ref_id" => outside, "line" => "x"}]
          },
          %{
            "evaluations" => [eval(ctx.a, "decide", 1)],
            "todos_suggested" => [
              %{"ref_type" => "inbox_item", "ref_id" => outside, "title" => "x"}
            ]
          },
          %{"evaluations" => [eval(ctx.a, "decide", 1)], "todos_done" => [%{"id" => outside}]}
        ] do
      assert {:error, {:rejected, _}} = apply!(ctx.batch, answer)
    end

    assert model_rows(ctx.user.id) == []
  end

  test "schema violations reject: bad tag, unknown goal, too long a brief, not an object", ctx do
    lines =
      for id <- [ctx.a, ctx.b, ctx.a, ctx.b],
          do: %{"ref_type" => "inbox_item", "ref_id" => id, "line" => "l"}

    for answer <- [
          %{"evaluations" => [eval(ctx.a, "urgent", 1)]},
          %{"evaluations" => [eval(ctx.a, "decide", 1, %{"group_key" => "space_goal:x:0"})]},
          %{"evaluations" => [eval(ctx.a, "decide", 1), eval(ctx.b, "fyi", 2)], "brief" => lines},
          "not json",
          nil
        ] do
      assert {:error, {:rejected, _}} = apply!(ctx.batch, answer)
    end

    assert model_rows(ctx.user.id) == []
  end

  test "a valid answer is written, the brief replaced, and the view told", ctx do
    answer = %{
      "evaluations" => [
        eval(ctx.a, "decide", 1, %{
          "needs_you_now" => true,
          "reason" => String.duplicate("r", 400)
        }),
        eval(ctx.b, "fyi", 2)
      ],
      "brief" => [
        %{
          "ref_type" => "inbox_item",
          "ref_id" => ctx.a,
          "line" => "Say yes to the plan",
          "action_label" => "Review",
          "tag" => "risk"
        }
      ]
    }

    assert {:ok, %{evaluations: 2}} = apply!(ctx.batch, answer)
    user_id = ctx.user.id
    assert_receive {:secretary_updated, ^user_id}

    a = Store.get_evaluation(user_id, "inbox_item", ctx.a)

    assert %{
             tag: "decide",
             brief_rank: 1,
             brief_line: "Say yes to the plan",
             brief_tag: "risk",
             needs_you_now: true,
             model_version: "host:test:claude_code"
           } = a

    assert String.length(a.reason) == 200
    assert %{tag: "fyi", brief_rank: nil} = Store.get_evaluation(user_id, "inbox_item", ctx.b)
    assert %{status: "submitted"} = Store.get_batch(user_id, ctx.batch.id)

    # A second answer re-tags and keeps the old tag; the brief moves.
    {:ok, batch2} = Store.create_batch(user_id, %{item_refs: ctx.batch.item_refs})

    assert {:ok, _} =
             apply!(batch2, %{
               "evaluations" => [eval(ctx.a, "waiting", 2), eval(ctx.b, "decide", 1)],
               "brief" => [%{"ref_type" => "inbox_item", "ref_id" => ctx.b, "line" => "Now this"}]
             })

    assert %{tag: "waiting", previous_tag: "decide", brief_rank: nil} =
             Store.get_evaluation(user_id, "inbox_item", ctx.a)
  end

  test "feedback is applied after the model: hide_kind -> quiet, this_matters -> waiting above FYI",
       ctx do
    {:ok, _} =
      Store.record_feedback(ctx.user.id, %{
        kind_key: "inbox:task_plan_review",
        action: "hide_kind"
      })

    {:ok, _} =
      Store.record_feedback(ctx.user.id, %{kind_key: "inbox:briefing", action: "this_matters"})

    answer = %{
      "evaluations" => [eval(ctx.a, "decide", 1), eval(ctx.b, "fyi", 2)],
      "brief" => [%{"ref_type" => "inbox_item", "ref_id" => ctx.a, "line" => "x"}]
    }

    assert {:ok, _} = apply!(ctx.batch, answer)

    assert %{tag: "quiet", brief_rank: nil} =
             Store.get_evaluation(ctx.user.id, "inbox_item", ctx.a)

    assert %{tag: "waiting", rank: 1} = Store.get_evaluation(ctx.user.id, "inbox_item", ctx.b)
  end

  test "todos_done must name the person's own to-do in the batch", ctx do
    {:ok, todo} = Todos.add_own(ctx.user.id, "Send the deck")

    ref = %{
      "ref_type" => "todo",
      "ref_id" => todo.id,
      "kind" => "todo:kept",
      "kind_key" => "todo:kept"
    }

    {:ok, batch} = Store.create_batch(ctx.user.id, %{item_refs: [ref]})

    answer = %{
      "evaluations" => [
        %{"ref_type" => "todo", "ref_id" => todo.id, "tag" => "todo", "group_key" => "none"}
      ],
      "todos_done" => [%{"id" => todo.id, "reason" => "the deck went out on Tuesday"}]
    }

    assert {:ok, %{todos_done: 1}} = apply!(batch, answer)

    assert %{status: "done", done_reason: "the deck went out on Tuesday"} =
             Todos.get(ctx.user.id, todo.id)
  end
end
