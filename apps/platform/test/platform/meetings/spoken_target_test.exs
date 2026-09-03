defmodule Platform.Meetings.SpokenTargetTest do
  @moduledoc """
  Who a push-to-talk utterance is addressed to (task 01a03f4e stage 4).

  ## Every positive case asserts a REAL agent id it seeded

  `target_agent_id`'s default is `nil`, so asserting `nil` cannot tell
  "the lookup ran and found nothing" from "the lookup never ran" from
  "the field was dropped on the way to the row" — the same
  can't-distinguish-a-default trap this task already hit in stage 2 with
  `source`. So every attaching case below names a specific seeded agent
  and asserts THAT id.

  ## And the fixture always holds more than one agent

  A single-agent fixture cannot distinguish "resolved the right agent"
  from "returned the only agent", which is exactly the mutation this
  stage has to detonate. Every test here seeds at least two, with the
  one that would sort first deliberately NOT being the expected answer.

  ## No slug is hardcoded in the implementation

  `spoken_agent/1` reads the roster from the database on every call. The
  slugs below are generated per-test, so an implementation that matched
  a literal name would fail every case rather than passing the ones it
  was written against.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Meetings.SpokenTarget
  alias Platform.Repo
  alias Platform.Roles

  # Slugs are generated, but their ORDER is pinned: `aaa-...` sorts and
  # inserts before `zzz-...`, so "the first agent" is never the agent a
  # test expects. That is what gives the mutation something to fail on.
  defp first_agent!, do: create_agent!("aaa-first")
  defp other_agent!, do: create_agent!("zzz-other")

  defp create_agent!(prefix, name \\ nil) do
    n = System.unique_integer([:positive])
    slug = "#{prefix}-#{n}"

    %Agent{}
    |> Agent.changeset(%{slug: slug, name: name || "Agent #{n}", status: "active"})
    |> Repo.insert!()
  end

  defp assign_default!(agent) do
    :ok = Roles.clear_override(SpokenTarget.default_responsibility_key())
    {:ok, _} = Roles.set_override(SpokenTarget.default_responsibility_key(), agent.id)
    :ok
  end

  setup do
    # No default assignment leaks in from another case.
    :ok = Roles.clear_override(SpokenTarget.default_responsibility_key())
    :ok
  end

  # ── 1. A non-name word attaches the CONFIGURED default ───────────────────

  describe "a non-name word" do
    test "attaches the configured default — not nobody, and not the spoken word" do
      first = first_agent!()
      configured = other_agent!()
      assign_default!(configured)

      assert {:ok, agent_id, agent_slug, via} =
               SpokenTarget.resolve("rotate the staging secrets before friday")

      # The CONFIGURED agent, by id. Not nil, and not the agent that
      # sorts or inserts first.
      assert agent_id == configured.id
      assert agent_slug == configured.slug
      assert via == :default
      refute agent_id == first.id
    end

    test "a word that merely LOOKS like a name still takes the default" do
      first = first_agent!()
      configured = other_agent!()
      assign_default!(configured)

      # "designer" is a role word, not any agent's slug or name here.
      assert {:ok, agent_id, _slug, :default} =
               SpokenTarget.resolve("the designer should look at this")

      assert agent_id == configured.id
      refute agent_id == first.id
    end
  end

  # ── 2. A spoken name attaches THAT agent ─────────────────────────────────

  describe "a spoken agent name" do
    test "attaches the named agent, over the configured default" do
      configured = first_agent!()
      assign_default!(configured)
      named = other_agent!()

      assert {:ok, agent_id, agent_slug, via} =
               SpokenTarget.resolve("#{named.slug} rotate the staging secrets")

      assert agent_id == named.id
      assert agent_slug == named.slug
      assert via == :spoken
      # The default exists and is a DIFFERENT agent, so this is the
      # name winning rather than the default being returned by luck.
      refute agent_id == configured.id
    end

    test "is found through surrounding punctuation and capitalisation" do
      configured = first_agent!()
      assign_default!(configured)
      named = other_agent!()

      assert {:ok, agent_id, _slug, :spoken} =
               SpokenTarget.resolve("#{String.upcase(named.slug)}, can you take this?")

      assert agent_id == named.id
    end

    test "matches a display NAME of two words, adjacent" do
      configured = first_agent!()
      assign_default!(configured)
      named = create_agent!("zzz-named", "Meeting Scribe")

      assert {:ok, agent_id, _slug, :spoken} =
               SpokenTarget.resolve("meeting scribe please write that down")

      assert agent_id == named.id

      # Scattered, not adjacent — a coincidence, not an address. Falls
      # back to the default, which proves the fallback is reachable and
      # this is not simply "no agent found either way".
      assert {:ok, fallback_id, _slug, :default} =
               SpokenTarget.resolve("the meeting was long, so take a scribe with you")

      assert fallback_id == configured.id
    end

    test "prefers the longer name when a shorter one is also present" do
      assign_default!(first_agent!())
      short = create_agent!("zzz-short", "Scribe")
      long = create_agent!("zzz-long", "Meeting Scribe")

      assert {:ok, agent_id, _slug, :spoken} =
               SpokenTarget.resolve("meeting scribe take this down")

      assert agent_id == long.id
      refute agent_id == short.id
    end

    test "an archived agent's name is not an address" do
      configured = first_agent!()
      assign_default!(configured)

      retired = create_agent!("zzz-retired")
      {:ok, _} = retired |> Agent.changeset(%{status: "archived"}) |> Repo.update()

      assert {:ok, agent_id, _slug, :default} =
               SpokenTarget.resolve("#{retired.slug} take this down")

      assert agent_id == configured.id
    end
  end

  # ── 3. No assignment fails LOUDLY ────────────────────────────────────────

  describe "with no default-target override" do
    test "returns an explicit error rather than attaching whichever agent sorts first" do
      # Two agents exist and are perfectly attachable. Nothing is
      # missing except the operator's decision.
      first = first_agent!()
      other = other_agent!()

      assert Roles.assignee_for(SpokenTarget.default_responsibility_key()) == nil

      assert SpokenTarget.resolve("rotate the staging secrets") ==
               {:error, :no_default_target}

      # Reachability: with an assignment, the very same sentence DOES
      # attach — so the error above is the missing assignment and not
      # the sentence being unroutable.
      assign_default!(other)

      assert {:ok, agent_id, _slug, :default} =
               SpokenTarget.resolve("rotate the staging secrets")

      assert agent_id == other.id
      refute agent_id == first.id
    end

    test "a SPOKEN name still attaches — the missing default gates only the default" do
      named = other_agent!()
      _first = first_agent!()

      assert Roles.assignee_for(SpokenTarget.default_responsibility_key()) == nil

      assert {:ok, agent_id, _slug, :spoken} =
               SpokenTarget.resolve("#{named.slug} take this down")

      assert agent_id == named.id
    end
  end

  # ── The key respects the namespace contract ──────────────────────────────

  describe "the default-target key" do
    test "is a DOTTED responsibility key and is not a role key" do
      # `Platform.Roles.ResolverNamespaceTest` pins — in a test its own
      # moduledoc marks load-bearing — that role keys are the undotted
      # closed roster and responsibility keys are dotted, and that the
      # disjointness of the two is what makes `agent_id_for_role/1` and
      # `assignee_for/1` provably safe as separate accessors.
      #
      # Plan v2 asked for a ROLE key here. That broke ten tests: the
      # roster is asserted to be exactly seven entries, every one of
      # which must carry a non-empty responsibility bundle, and this key
      # names a destination that fulfils no responsibility. Pinned here
      # so a future change back to a role key fails on purpose rather
      # than by surprise.
      key = SpokenTarget.default_responsibility_key()

      assert String.contains?(key, ".")
      refute key in Platform.Roles.Role.valid_keys()
    end

    test "an override for it is assignable and readable back" do
      agent = other_agent!()
      key = SpokenTarget.default_responsibility_key()

      assert {:ok, _} = Roles.set_override(key, agent.id)
      assert %{id: id} = Roles.assignee_for(key)
      assert id == agent.id
    end

    test "nothing bundles it, so the override is the only route to it" do
      # `assignee_for/1` falls back to role-bundle resolution when there
      # is no override. If some role ever bundles this key, that
      # fallback becomes a second, silent way to answer the same
      # question — the exact hazard the gate's finding is about.
      agent = other_agent!()
      key = SpokenTarget.default_responsibility_key()

      :ok = Roles.clear_override(key)
      assert Roles.assignee_for(key) == nil

      {:ok, _} = Roles.set_override(key, agent.id)
      assert %{id: _} = Roles.assignee_for(key)
    end
  end
end
