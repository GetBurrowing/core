defmodule Platform.Goals.BriefPrivacyTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  import Platform.Goals.BriefFixtures
  alias Platform.Goals
  alias Platform.Goals.Ask
  setup do: setup_brief()

  test "only the owner receives reports and only addressed viewers receive a shared ask", c do
    b = member!(c.org)
    other = member!(c.org)
    stranger = member!(c.org)
    admin = root_admin!()
    for user <- [b, other], do: Goals.open_goal(c.owner, c.goal.id, {:user, user.id})
    ask = queued(c, %{addressed_user_ids: [b.id], body: "Only B should read this"})
    action(c)
    for user <- [c.owner, b, other, stranger, admin], do: Goals.prepare_brief(user, date())
    assert {:ok, [%{kind: :report}]} = Goals.brief_items(c.owner, date())
    assert {:ok, [%{ask: %{id: id}}]} = Goals.brief_items(b, date())
    assert id == ask.id
    for user <- [other, stranger, admin], do: assert(Goals.brief_items(user, date()) == {:ok, []})
    {:ok, _} = Goals.close_goal(c.owner, c.goal.id, {:user, b.id})
    assert {:ok, []} = Goals.brief_items(b, date())
    assert {:ok, %{total: 0}} = Goals.brief_summary(b, date())
    assert Goals.get_ask(b, ask.id) == {:error, :not_found}
    assert Goals.answer_ask(b, ask.id, "used") == {:error, :not_found}
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, b.id})
    assert {:ok, [_]} = Goals.brief_items(b, date())
  end

  test "addressing is rechecked after an item was prepared", c do
    b = member!(c.org)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, b.id})
    ask = queued(c, %{addressed_user_ids: [b.id]})
    assert {:ok, %{new: 1}} = Goals.prepare_brief(b, date())

    Repo.update_all(from(a in Ask, where: a.id == ^ask.id),
      set: [addressed_user_ids: [c.owner.id]]
    )

    assert {:ok, []} = Goals.brief_items(b, date())
    assert {:ok, %{total: 0}} = Goals.brief_summary(b, date())
  end
end
