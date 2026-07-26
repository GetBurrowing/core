defmodule Platform.Design.UiSurface do
  @moduledoc """
  Decides, **before a plan exists**, whether a task touches user-visible surface
  and therefore warrants a design step (ADR 0046).

  ## Why this is not `PlanEngine.ui_touching?/1` on its own

  `Platform.Tasks.PlanEngine.ui_touching?/1` matches nine file-path / module
  tokens against a **stage description**. The design step runs *pre-plan* — there
  are no stages yet, only a task title and description. Run against a task
  title+description, that token list under-triggers catastrophically: real UI
  tasks in this repo are written in prose and name no files at all
  (`Build /org_memory mobile surface — segmented tabs, path chip, drawer`,
  `Add an epic-create FAB above the board`, `Badges render as a mobile card`).
  The corpus in `test/platform/design/ui_surface_test.exs` records that: every
  path-token-free `:ui` entry is observed failing against a layer-A-only build.

  So this module is **two layers, neither of them invented here**:

    * **Layer A — path tokens.** Delegates to `PlanEngine.ui_touching?/1`
      verbatim over `"\#{title}\\n\#{description}"`. The token list is *not*
      copied — there is exactly one authoritative copy of it and it lives in
      `PlanEngine`. Rare pre-plan, authoritative when it hits.

    * **Layer B — prose.** The rule that has shipped in production since task
      019f4f1d, lifted out of the planning dispatch template
      (`Platform.Orchestration.PromptTemplates`, "Design involvement (UI/UX
      tasks)") into code: a task touches UI if it *"concerns screens, layout,
      styling, navigation, user-visible copy, or user flows"* or changes *"how
      any feature looks, feels, moves, or is interacted with"*. Every planner has
      been applying that rule by hand for weeks. This module compiles it.

  Layer B uses two vocabularies so that one incidental word cannot fire it: a
  single `@strong_tokens`/`@strong_phrases` hit fires; `@weak_tokens` needs two
  **distinct** hits. Matching is case-insensitive and word-boundary anchored
  (with an optional plural `s`), so `"cardinality"` does not match `card`,
  `"discard"` does not match `card`, and `"scoreboard"` does not match `board`.

  ## Why this is not in `PlanEngine`

  `PlanEngine` operates on plans. This operates on a task that has no plan. Same
  tokens are involved but the subject differs; co-locating them would invite the
  next reader to run the wrong one.

  ## Why this is not an LLM classifier

  An LLM call here would add a second inference round-trip in front of the one
  this feature exists to add, would be unauditable after the fact, and could not
  be regression-tested against a corpus. A deterministic list is inspectable and
  its misses are fixable by a one-line diff.

  ## Error budget — stated so it can be rejected

    * **False negatives: target ZERO.** A design step that silently does not fire
      on a UI task is invisible — it records the same `not_applicable` as "no
      designer assigned", which is exactly the `not_applicable`/`failed`
      conflation ADR 0046 forbids, arriving through a different door. A false
      negative is a **defect**, never a tuning outcome.

    * **False positives: acceptable up to 25%** of non-UI tasks. The cost is one
      designer round-trip plus a canvas the planner may ignore. Nothing blocks.
      The bias is deliberate and asymmetric.

    * **Firing on everything is not acceptable.** The 25% cap is asserted, and so
      is a named positive control (`ui_task?/1` must return exactly `false` for
      "Fix fire_trigger/3 return contract to distinguish unfilled from failed"),
      so `def ui_task?(_), do: {true, ...}` cannot pass. The ratio alone would
      not kill it — the corpus is majority `:ui`-adjacent prose and a cap can
      always be met by shrinking the denominator.

  ## The vocabulary is the tunable part. The corpus and the bounds are NOT.

  If a future change cannot satisfy zero-FN and ≤25%-FP, the correct move is to
  change the vocabulary below — **not** to widen the bounds or drop a corpus
  entry. This codebase already carries three instances of a safety net amended to
  accommodate the very failure it was built to detect: a regression test encoding
  a seed/handler key mismatch as `@known_seed_key_aliases` with a moduledoc
  telling readers not to fix it; an audit whitelist justified by a test-only
  config value; and a `config/test.exs` `async: false` flag hiding a production
  crash on the stack-deploy path. ADR 0046 catalogues that as an established
  habit of this repo. Loosening these bounds to make a red corpus go green would
  be the fourth instance.

  The corpus deliberately keeps a known-hard `:not_ui` entry — ADR 0046's own
  "Add planning_step field and per-step outcome persistence" task, whose real
  description says "the UI and the gates both read" and "pure render concern" —
  and lets it count against the cap rather than substituting a flattering
  fixture.

  ## Deviations from the ADR-0046 stage sketch, and why

    * `mock` was dropped from `@strong_tokens` (`mockup` retained). In this
      codebase "mock" overwhelmingly means *test double* — a strong token there
      would fire on adapter and stub work with no user-visible surface at all.

    * Tokens were **added**, never removed to make a test pass. Two of the stage
      sketch's own minimum `:ui` corpus entries — "External-grant multiselect"
      and the intents-collapse bar — were false negatives against the sketched
      vocabulary. Since a false negative is a defect and the vocabulary is the
      tunable part, the vocabulary grew: named UI widgets (`multiselect`,
      `dropdown`, `checkbox`, `breadcrumb`, …) as strong, and
      interaction/affordance words (`collapse`, `expand`, `strip`, `bar`,
      `toggle`, …) as weak.

    * Matching allows an optional trailing `s`. Without it `\\btab\\b` misses
      "tabs" and `\\bbreadcrumb\\b` misses "breadcrumbs" — plural-form misses are
      false negatives, and false negatives are defects. The word-boundary
      guarantees are unaffected (see the negative controls in the test).

  ## The `matched` payload

  `matched` is not decoration: the design step persists it as its `reason`, which
  is how a human later audits whether a fire was justified. For `:path_token`
  fires it is deliberately `["PlanEngine.ui_touching?/1"]` rather than the
  matched token — naming the token would mean holding a second copy of the token
  list, and there is exactly one copy. The auditor is pointed at it instead.
  """

  alias Platform.Tasks.PlanEngine

  @layer_a_source "PlanEngine.ui_touching?/1"

  # A single hit fires. Words that in practice only appear when someone is
  # talking about user-visible surface.
  @strong_tokens ~w(
    ui ux screen wireframe mockup palette typography responsive viewport
    mobile desktop fab stylesheet css tailwind favicon
    multiselect dropdown checkbox datepicker breadcrumb carousel accordion
    lightbox snackbar
    dark-mode light-mode empty-state loading-state bottom-sheet safe-area
    layout styling
  )

  # Multiword strong signals. Matched with the same word-boundary rule.
  @strong_phrases [
    "design direction",
    "dark mode",
    "light mode",
    "empty state",
    "loading state",
    "user flow",
    "safe area",
    "look and feel",
    "looks and feels",
    "visual design",
    "design system",
    "screen reader",
    "tap target",
    "brand token",
    "semantic token"
  ]

  # Two DISTINCT hits fire. Individually each of these appears often enough in
  # non-UI prose that a single occurrence proves nothing.
  @weak_tokens ~w(
    render card badge button nav menu tab icon copy label colour color
    click tap hover scroll panel board surface banner toast modal drawer
    chip sheet form placeholder tooltip avatar sidebar header footer
    breakpoint contrast accessibility a11y
    bar collapse expand strip toggle segmented overlay popover dialog
    spinner skeleton thumbnail padding spacing animation
  )

  @typedoc """
  `false`, or `{true, evidence}` where `evidence` names the layer that fired and
  the tokens that fired it.
  """
  @type verdict ::
          {true, %{layer: :path_token | :strong_prose | :weak_prose, matched: [String.t()]}}
          | false

  @doc """
  Classify a task as UI-touching or not, from its title and description alone.

  Accepts a `Platform.Tasks.Task` struct or any map carrying `:title` and
  `:description`. A `nil`, empty, or absent description is fine — a title-only
  UI task still classifies.

      iex> Platform.Design.UiSurface.ui_task?(%{title: "Add an epic-create FAB above the board", description: nil})
      {true, %{layer: :strong_prose, matched: ["fab"]}}

      iex> Platform.Design.UiSurface.ui_task?(%{title: "Add Providers.Architecture shim", description: nil})
      false
  """
  @spec ui_task?(map()) :: verdict()
  def ui_task?(task) when is_map(task) do
    text = classification_text(task)

    cond do
      # Layer A — authoritative, delegated, never copied.
      PlanEngine.ui_touching?(text) ->
        {true, %{layer: :path_token, matched: [@layer_a_source]}}

      # Layer B — prose. One strong hit.
      (strong = matches(text, @strong_tokens ++ @strong_phrases)) != [] ->
        {true, %{layer: :strong_prose, matched: strong}}

      # Layer B — prose. Two distinct weak hits.
      length(weak = matches(text, @weak_tokens)) >= 2 ->
        {true, %{layer: :weak_prose, matched: weak}}

      true ->
        false
    end
  end

  @doc """
  The exact text `ui_task?/1` classifies: title and description, newline-joined.

  Exposed so callers persisting a `reason` can quote the same subject the
  heuristic saw.
  """
  @spec classification_text(map()) :: String.t()
  def classification_text(task) when is_map(task) do
    title = task |> Map.get(:title) |> to_text()
    description = task |> Map.get(:description) |> to_text()

    title <> "\n" <> description
  end

  @doc """
  The vocabularies, for inspection and for tests that want to reason about
  coverage without reaching into module attributes.
  """
  @spec vocabulary() :: %{strong: [String.t()], weak: [String.t()]}
  def vocabulary, do: %{strong: @strong_tokens ++ @strong_phrases, weak: @weak_tokens}

  defp to_text(value) when is_binary(value), do: value
  defp to_text(_), do: ""

  defp matches(text, tokens) do
    tokens
    |> Enum.filter(&Regex.match?(token_regex(&1), text))
    |> Enum.uniq()
  end

  # Case-insensitive, word-boundary anchored, optional plural. `\b` on both ends
  # is what keeps `cardinality`/`discard` off `card` and `scoreboard` off
  # `board`; the optional `s` is what keeps `tabs`/`breadcrumbs` from becoming
  # false negatives.
  defp token_regex(token), do: Regex.compile!("\\b" <> Regex.escape(token) <> "s?\\b", "i")
end
