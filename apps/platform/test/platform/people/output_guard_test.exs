defmodule Platform.People.OutputGuardTest do
  use ExUnit.Case, async: true

  alias Platform.People.OutputGuard

  @profile %{
    "slug" => "oskar-vellinghausen",
    "name" => "Oskar Vellinghausen",
    "aliases" => ["Oskar V"],
    "user_id" => "0193a1b2-0000-7000-8000-000000000002",
    "relation" => "colleague",
    "organisation" => "the org",
    "role" => "data engineer",
    "current_projects" => ["Warehouse migration"],
    "interactions" => [
      %{
        "date" => "2026-10-02",
        "kind" => "meeting",
        "title" => "Warehouse sync",
        "citation" => "msg-1"
      }
    ],
    "perspectives" => [
      %{
        "statement" => "I want the migration done by Q1",
        "said_by_subject" => true,
        "citation" => "msg-2"
      },
      %{
        "statement" => "He is the kind of person who stalls",
        "said_by_subject" => false,
        "citation" => "msg-3"
      },
      %{
        "statement" => "Priya says he prefers mornings",
        "said_by_subject" => "yes",
        "citation" => "msg-4"
      }
    ],
    "agents" => ["historian"]
  }

  test "an others-said perspective never reaches either tier" do
    %{card: card, private: private} = OutputGuard.render(@profile)

    refute card =~ "stalls"
    refute card =~ "prefers mornings"
    refute private =~ "stalls"
    refute private =~ "prefers mornings"
    refute private =~ "msg-3"
    refute private =~ "msg-4"

    assert private =~ "- I want the migration done by Q1 — own words [cite: msg-2]"
    assert private =~ "- 2026-10-02 meeting: Warehouse sync [cite: msg-1]"
    assert private =~ "readers: [subject, admins]"
    assert private =~ "subject_user_id: 0193a1b2-0000-7000-8000-000000000002"

    refute card =~ "## Perspectives"
    refute card =~ "## Interactions"
    refute card =~ "readers:"
    assert card =~ "## Role\ndata engineer\n"
    assert card =~ "aliases: Oskar V\n"
  end

  test "counts name what was dropped" do
    %{counts: counts} = OutputGuard.render(@profile)

    assert counts.dropped_others_said == 2
    assert counts.card.dropped_card_sections == 2
    assert counts.private.dropped_card_sections == 0
    # The one own-words perspective is cited, so nothing else is dropped.
    assert counts.private.dropped_uncited_perspectives == 0
    assert counts.private.dropped_trait_lines == 0
    assert counts.private.redactions == 0
  end

  test "an own-words perspective without a citation is still dropped by the page guard" do
    profile =
      put_in(@profile, ["perspectives"], [
        %{"statement" => "I like Mondays", "said_by_subject" => true}
      ])

    %{private: private, counts: counts} = OutputGuard.render(profile)

    refute private =~ "Mondays"
    assert counts.dropped_others_said == 0
    assert counts.private.dropped_uncited_perspectives == 1
  end
end
