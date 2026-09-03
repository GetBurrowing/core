defmodule Platform.Meetings.SpokenTarget do
  @moduledoc """
  Who a push-to-talk utterance is addressed to (task 01a03f4e stage 4).

  Two questions, in order:

    1. **Did the speaker name an agent?** If the utterance contains an
       agent's slug or name, that agent is the target. Holding the key
       and saying "octavius, rotate the staging secrets" should reach
       Octavius whatever the classifier later decides the sentence was
       about.

    2. **If not, who is the default?** Resolved through
       `Platform.Roles.assignee_for/1` under the responsibility key
       `meetings.push_to_talk_default_target`.

  ## Why the default lives in `Platform.Roles`, and why it is a
  ## RESPONSIBILITY key rather than a role key

  The architecture gate rejected a new workspace-level default-agent
  setting for this, and it was right to: `Platform.Roles` is already the
  "which agent does this job" system at this scope, with an existing
  operator surface, and two stores answering one question can disagree
  with nothing to reconcile them.

  Plan v2 specified a ROLE key (`meeting_default_target`) resolved via
  `agent_id_for_role/1`. Built that way it broke TEN tests, because
  `roles.key` is not merely a closed roster — it is a roster the suite
  actively pins:

    * `Platform.Roles.CoverageTest` — `list_roles/0` returns **exactly
      the 7 canonical rows**, and **every** role has a NON-EMPTY
      responsibility bundle.
    * `Platform.Roles.RoleTest` — `valid_keys/0` exposes **seven** roles
      in a stable order.
    * `Platform.Roles.SeedsTest` — every seeded role has 1+ bundled
      responsibility keys.
    * `PlatformWeb.ControlCenterLiveTest` — the panel renders **7 role
      rows**.
    * `Platform.Roles.ResolverNamespaceTest` — pinned in a test its own
      moduledoc marks LOAD-BEARING and says "do not prune": role keys
      are the undotted 7-element roster, responsibility keys are dotted,
      and their **disjointness** is what makes the two accessors
      provably safe rather than one broken one.

  A role, in this codebase, is a PERSONA that fulfils responsibilities.
  This key is a DESTINATION and fulfils none, so it cannot satisfy the
  non-empty-bundle invariant without inventing a fake responsibility to
  hang on it. Making it fit would have meant weakening five guardrails
  that exist precisely to keep that roster coherent — which is a much
  larger decision than this stage, and not one to take by editing the
  tests that noticed.

  A dotted responsibility key needs none of it: `responsibility_key` is
  a plain string with no `validate_inclusion/3` and no CHECK, it keeps
  the disjointness contract intact, and it needs no migration at all. It
  is also the pattern this subsystem already uses — the meeting
  classifier resolves its own agent through `meetings.intent_classify`,
  an override, not a role.

  ## Scope of the lookup

  `responsibility_overrides` is unique on `responsibility_key`, so at
  most one row exists for this key platform-wide. The default target is
  therefore necessarily GLOBAL, not per-workspace. Worth stating rather
  than discovering later: neither this design nor the role-key one the
  plan proposed can express a per-workspace default. (`agent_id_for_role/1`
  has the same property for the same reason — its `Repo.one()` carries
  no workspace filter and is safe only because `role_assignments` is
  unique on `role_key`.)

  `assignee_for/1` falls back to role-bundle resolution when no override
  exists. Nothing bundles this key, so that fallback is inert and the
  answer is "the override, or nobody" — and the disjointness test above
  is what stops such a key being bundled by accident.

  ## No agent is ever guessed

  With no assignment, `resolve/1` returns `{:error, :no_default_target}`.
  It does not fall back to the first agent, the oldest agent, or the
  only agent. Silently attaching an arbitrary agent to a card is how
  somebody's push-to-talk ends up in a stranger's queue, and it is
  indistinguishable from correct behaviour until it is very much not.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Roles

  @default_responsibility_key "meetings.push_to_talk_default_target"

  @typedoc "How the target was arrived at — carried so the caller can log which rule fired."
  @type via :: :spoken | :default

  @doc """
  The responsibility key the default target is assigned under.

  Dotted, deliberately — see the namespace note above.
  """
  @spec default_responsibility_key() :: String.t()
  def default_responsibility_key, do: @default_responsibility_key

  @doc """
  Resolve the agent a push-to-talk utterance is addressed to.

  Returns `{:ok, agent_id, agent_slug, via}` or
  `{:error, :no_default_target}`.

  `text` may be nil — a press whose words have not arrived yet names
  nobody, so it takes the default like any other unnamed utterance.
  """
  @spec resolve(String.t() | nil) ::
          {:ok, binary(), String.t() | nil, via()} | {:error, :no_default_target}
  def resolve(text) do
    case spoken_agent(text) do
      %Agent{} = agent -> {:ok, agent.id, agent.slug, :spoken}
      nil -> default_target()
    end
  end

  @doc """
  The agent named in `text`, or nil.

  Matches on the agent's SLUG and on its name, tokenised the same way
  both sides — so "Octavius," with the comma, and "octavius" both find
  the agent whose slug is `octavius`, and a name of two words is
  matched as those two words in sequence rather than as a single token
  that could never appear.

  Nothing here knows any particular agent: the roster is read from the
  database every call. A hardcoded slug would make this function pass
  its tests and route one specific name in production.
  """
  @spec spoken_agent(String.t() | nil) :: Agent.t() | nil
  def spoken_agent(text) when is_binary(text) do
    case tokenize(text) do
      [] ->
        nil

      tokens ->
        agents = active_agents()

        # Longest name first, so an agent called "meeting scribe" wins
        # over one called "scribe" when both are present in the
        # sentence. Ties break on slug for a stable answer.
        agents
        |> Enum.sort_by(fn agent -> {-longest_term_length(agent), agent.slug} end)
        |> Enum.find(fn agent -> named?(agent, tokens) end)
    end
  end

  def spoken_agent(_), do: nil

  # ── Internal ──────────────────────────────────────────────────────────────

  defp default_target do
    case Roles.assignee_for(@default_responsibility_key) do
      %Agent{} = agent -> {:ok, agent.id, agent.slug, :default}
      _ -> {:error, :no_default_target}
    end
  end

  defp active_agents do
    Repo.all(from(a in Agent, where: a.status == "active"))
  end

  # Every token sequence this agent answers to: its slug, and its name.
  # A slug like `meeting-scribe` tokenises to two words, which is what
  # makes it findable in speech — a transcriber writes "meeting scribe",
  # never "meeting-scribe".
  defp agent_terms(agent) do
    [agent.slug, agent.name]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&tokenize/1)
    |> Enum.reject(&(&1 == []))
    |> Enum.uniq()
  end

  # The longest term, for ordering: an agent called "meeting scribe"
  # must be preferred over one merely called "scribe" when the sentence
  # contains both.
  defp longest_term_length(agent) do
    agent |> agent_terms() |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)
  end

  defp named?(agent, tokens) do
    agent |> agent_terms() |> Enum.any?(&subsequence?(tokens, &1))
  end

  # Contiguous run, not "all these words appear somewhere". A name is a
  # name because its words are adjacent; scattering them across a
  # sentence is a coincidence, not an address.
  defp subsequence?(tokens, term) do
    len = length(term)

    tokens
    |> Enum.chunk_every(len, 1, :discard)
    |> Enum.any?(&(&1 == term))
  end

  # Same normalisation both sides. Lowercase, fold curly apostrophes,
  # split on anything that is not a letter, digit or apostrophe — so
  # punctuation around a name ("octavius,") never hides it, and a
  # hyphenated slug splits into the words a transcriber would write.
  defp tokenize(nil), do: []

  defp tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[\x{2018}\x{2019}]/u, "'")
    |> String.replace(~r/[^\p{L}\p{N}']+/u, " ")
    |> String.split(" ", trim: true)
    |> Enum.map(&String.trim(&1, "'"))
    |> Enum.reject(&(&1 == ""))
  end

  defp tokenize(_), do: []
end
