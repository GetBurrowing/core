defmodule Platform.People.PageGuardTest do
  use ExUnit.Case, async: true

  alias Platform.People.PageGuard

  @private_page """
  ---
  tier: private
  name: Marisol Tennebrook
  aliases: Mari
  user_id: 0193a1b2-0000-7000-8000-000000000001
  relation: colleague
  organisation: the org
  role: platform lead
  last_seen: 2026-10-03
  ---

  ## Role
  Platform lead for the deploy pipeline.

  ## Current projects
  - Deploy pipeline

  ## Interactions
  - 2026-10-02 meeting: Deploy review — she seemed lazy about it [cite: msg-1]
  - 2026-10-03 dm: Said thanks for the review [cite: msg-2]

  ## Perspectives
  - I prefer small PRs — own words [cite: msg-3]
  - She hates meetings
  - I like dogs — own words
  - I think he is arrogant — own words [cite: msg-9]

  ## Agents
  - historian
  """

  test "a character judgement line is dropped while the interaction bullet keeps date, title and cite" do
    {out, counts} = PageGuard.enforce(:private, @private_page)

    assert out =~ "- 2026-10-02 meeting: Deploy review [cite: msg-1]\n"
    refute out =~ "lazy"
    refute out =~ "arrogant"
    assert out =~ "- 2026-10-03 dm: Said thanks for the review [cite: msg-2]"
    # the interaction free text and the trait perspective
    assert counts.dropped_trait_lines == 2
  end

  test "a perspective without own-words marker or cite is dropped" do
    {out, counts} = PageGuard.enforce(:private, @private_page)

    refute out =~ "She hates meetings"
    refute out =~ "I like dogs"
    assert counts.dropped_uncited_perspectives == 2
  end

  test "a cited own-words perspective survives in the private tier" do
    {out, _counts} = PageGuard.enforce(:private, @private_page)
    assert out =~ "## Perspectives\n- I prefer small PRs — own words [cite: msg-3]\n"
  end

  test "a card never carries perspectives, interactions or readers" do
    with_readers =
      String.replace(@private_page, "tier: private\n", "tier: card\nreaders: [subject, admins]\n")

    {out, counts} = PageGuard.enforce(:card, with_readers)

    refute out =~ "## Perspectives"
    refute out =~ "## Interactions"
    refute out =~ "readers:"
    refute out =~ "subject_user_id:"
    refute out =~ "msg-1"
    assert out =~ "tier: card\n"
    assert out =~ "## Role\nPlatform lead for the deploy pipeline.\n"
    assert out =~ "## Agents\n- historian\n"
    assert counts.dropped_card_sections == 2
  end

  test "a private page always carries readers subject and admins" do
    {out, _} = PageGuard.enforce(:private, @private_page)
    assert out =~ "\nreaders: [subject, admins]\n"
    assert out =~ "\nsubject_user_id: 0193a1b2-0000-7000-8000-000000000001\n"

    # Already present: not duplicated.
    {again, _} = PageGuard.enforce(:private, out)
    assert length(Regex.scan(~r/^readers:/m, again)) == 1
    assert length(Regex.scan(~r/^subject_user_id:/m, again)) == 1

    # No frontmatter at all: one is synthesised.
    {bare, _} = PageGuard.enforce(:private, "## Role\nLead.\n")

    assert String.starts_with?(
             bare,
             "---\ntier: private\nreaders: [subject, admins]\nsubject_user_id:"
           )
  end

  test "scrub runs last over the whole page and is counted" do
    page =
      String.replace(@private_page, "Said thanks for the review", "Said call me on 904-555-0100")

    {out, counts} = PageGuard.enforce(:private, page)

    assert out =~ "Said call me on [REDACTED: phone] [cite: msg-2]"
    assert counts.redactions == 1
    # frontmatter UUID and dates are untouched
    assert out =~ "user_id: 0193a1b2-0000-7000-8000-000000000001"
    assert out =~ "last_seen: 2026-10-03"
  end

  test "enforce is idempotent" do
    for tier <- [:private, :card] do
      {once, _} = PageGuard.enforce(tier, @private_page)
      {twice, counts} = PageGuard.enforce(tier, once)
      assert twice == once

      assert counts == %{
               dropped_trait_lines: 0,
               dropped_uncited_perspectives: 0,
               dropped_card_sections: 0,
               redactions: 0
             }
    end
  end
end
