defmodule Platform.Responsibilities.ChatTriggerNamesARoleTest do
  @moduledoc """
  The durable guard from task `019fe900`: a chat trigger addresses a ROLE,
  never a person.

  ## The class of defect, not the instance

  The instance was `@vega` hardcoded into two `design.*` stub triggers, and
  `@saru` in `design.critique` — correct only by luck, one reassignment from
  being the same stale name. A handle names a PERSON; a token names the JOB.
  The job is what the trigger means, and the job outlives its holder. An
  agent handle baked into a compiled chat pattern is a bug by construction:
  it goes stale exactly once, silently, and then the responsibility fires
  for the wrong person or for nobody.

  So: for every provider in the CONFIGURED provider list — read the way
  `Platform.Responsibilities.Registry.init/1` reads it, so a newly added
  provider is covered automatically rather than by a list maintained here —
  every registered `chat_pattern` regex must contain no `@<token>` matching
  a live `agents.slug`. Role keys are explicitly allowed; that is the whole
  point of the fix.

  ## The guard is shown to bite

  A guard that passes because it scanned nothing, or because the forbidden
  set was empty, is the exact failure mode this ticket closes. Three
  defences, all load-bearing:

    * the test DB has no agents by default, so the forbidden slug set would
      be EMPTY and the scan would pass over anything — `setup` inserts
      agents with the historical slugs `"vega"` and `"saru"`;
    * `"the predicate detonates on an agent handle"` runs the same
      predicate over a synthetic attrs map carrying `@saru` and asserts it
      IS flagged (technique mirrored from
      `dispatch_template_provider_scan_test.exs`);
    * `"the predicate does not flag a role token"` asserts `@designer` is
      NOT flagged, so the guard is not simply rejecting every `@`.

  And the population is pinned non-empty: at least three chat_pattern
  responsibilities must have been scanned.

  Never assert this with a source grep. `grep '@vega' lib` cannot come back
  empty — the string deliberately survives in `design_critique.ex` prose
  recording why the handle was dropped. Grep finds prose; `register/0`
  finds behaviour.

  Sibling guard on a different axis: `dispatch_template_provider_scan_test.exs`
  asserts no dispatch template names a stub-backed `design.*`/`architecture.*`
  key (reachability); this one asserts no chat trigger names an agent (naming).
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Agents.Agent
  alias Platform.Roles.Role

  @handle_pattern ~r/@([A-Za-z0-9_]+)/

  setup do
    # Anti-vacuity part 1. Without these rows the forbidden set is empty
    # and every assertion below is vacuously true.
    for slug <- ~w(vega saru) do
      %Agent{}
      |> Agent.changeset(%{
        slug: slug,
        name: String.capitalize(slug),
        status: "active",
        kind: "native",
        workspace_id: nil
      })
      |> Repo.insert!()
    end

    slugs = MapSet.new(Repo.all(from(a in Agent, select: a.slug)), &String.downcase/1)

    assert MapSet.member?(slugs, "vega") and MapSet.member?(slugs, "saru"),
           "the agent fixtures did not land — the forbidden slug set is empty and " <>
             "every assertion in this file would pass over anything"

    {:ok, slugs: slugs}
  end

  describe "no chat trigger names an agent handle" do
    test "every registered chat_pattern regex addresses a role, not a person", %{slugs: slugs} do
      chat_patterns = registered_chat_patterns()

      assert length(chat_patterns) >= 3,
             """
             Only #{length(chat_patterns)} chat_pattern responsibilities were scanned.
             A guard that silently scanned zero rows is what lets this whole class
             back in — the provider list or the trigger_kind filter is broken, not
             the tree clean.
             """

      violations = Enum.flat_map(chat_patterns, &violations_for(&1, slugs))

      assert violations == [],
             """
             These chat triggers name an agent handle:

               #{Enum.map_join(violations, "\n  ", fn {key, token} -> "#{key} — @#{token}" end)}

             Rule: a chat trigger addresses a ROLE (one of
             #{Enum.join(Role.valid_keys(), ", ")}), never an agent. A handle names a
             person and the person changes; the role does not. Build the regex with
             `Platform.Responsibilities.RoleTrigger.chat_regex/3`.
             """
    end

    test "the predicate detonates on an agent handle", %{slugs: slugs} do
      # Anti-vacuity part 2: proof the assertion above CAN fail.
      synthetic = %{
        key: "design.synthetic",
        trigger_config: %{"regex" => "(?i)@saru\\s+critique\\b"}
      }

      assert violations_for(synthetic, slugs) == [{"design.synthetic", "saru"}],
             "the predicate did not fire on a known agent handle — the scan above " <>
               "would pass over a real regression"
    end

    test "the predicate does not flag a role token", %{slugs: slugs} do
      # Anti-vacuity part 3: the guard rejects agent handles, not every `@`.
      synthetic = %{
        key: "design.synthetic",
        trigger_config: %{"regex" => "(?i)@designer\\s+spec\\b"}
      }

      assert violations_for(synthetic, slugs) == [],
             "a role token was flagged — the guard is rejecting every @, which would " <>
               "make the fix this task shipped unrepresentable"
    end

    test "a handle-free trigger passes", %{slugs: slugs} do
      # `task_unblock` registers `(?i)\b(blocked|blocker|stuck)\b` — no `@`
      # at all. If this fails the token extractor is over-eager.
      unblock =
        Enum.find(registered_chat_patterns(), &(&1.key == "tasks.unblock"))

      assert unblock, "expected tasks.unblock to register a chat_pattern trigger"
      assert violations_for(unblock, slugs) == []
    end
  end

  # ── Scan internals ────────────────────────────────────────────────────────

  # Read the provider list exactly as `Registry.init/1` does, so a provider
  # added to config is covered here without editing this file.
  defp configured_providers do
    Application.get_env(:platform, Platform.Responsibilities, [])[:providers] || []
  end

  defp registered_chat_patterns do
    configured_providers()
    |> Enum.flat_map(& &1.register())
    |> Enum.filter(&(Map.get(&1, :trigger_kind) == "chat_pattern"))
  end

  # A token is a violation when it matches a live `agents.slug`. Role keys
  # are allowed by construction; the roster is closed and disjoint from
  # responsibility keys.
  defp violations_for(attrs, slugs) do
    regex = get_in(attrs, [Access.key(:trigger_config, %{}), "regex"]) || ""

    @handle_pattern
    |> Regex.scan(regex, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in Role.valid_keys()))
    |> Enum.filter(&MapSet.member?(slugs, &1))
    |> Enum.map(&{attrs.key, &1})
  end
end
