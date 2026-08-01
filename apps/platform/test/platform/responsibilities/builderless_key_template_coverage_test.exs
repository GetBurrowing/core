defmodule Platform.Responsibilities.BuilderlessKeyTemplateCoverageTest do
  @moduledoc """
  Tripwire for the keys that depend on the legacy template render path
  (task `019fba51` stage 5).

  ## What this file exists to make impossible

  Stages 2-4 of this task fixed the path: the external dispatcher now
  resolves `default_prompt_template` against a real `prompt_templates`
  row and ABORTS with a named cause — `{:template_missing, slug}` /
  `{:template_blank, slug}` / `:no_prompt_template` — instead of
  shipping the slug literal as the entire user turn.

  That fix is per-path, and the ticket explicitly rejected per-key
  workarounds. The property it actually asked for is this one: **the
  next key added to a builder-less feature must be visible, not
  silent.** A path fix cannot provide that on its own — nothing about
  the dispatcher notices that a twelfth key just joined the set that
  depends on it. This file is that notice.

  Nothing in `lib/` changes for this stage. This is a tripwire, not a
  fix, and deliberately not a per-key fix list.

  ## The derivation is a derivation, not a list

  `builder_less_keys/0` asks the question the Router asks, through the
  same values the Router branches on, over every row in the
  `responsibilities` table. If it were a literal list a new key would
  simply never appear in it and the equality assertion below would be
  decoration. The assertion is on the DERIVED set versus
  `@builder_less_keys`, so adding a key to a builder-less feature is a
  mandatory edit here rather than an optional one.

  ## Why the classification keys off the RETURN VALUE

  `Router.build_prompt_via_provider/2` (router.ex:1420) is private, so
  `classify/2` mirrors its arms. It mirrors them EXACTLY, and the
  reason is a false positive this stage was handed:

  A sweep that asks only "does this provider export `build_prompt/1`?"
  reports THIRTEEN builder-less keys, adding `meetings.summarize` and
  `meetings.action_items`. Both have real builders. On an empty context
  they return `{:error, :no_transcript_text}` and
  `{:error, :no_intent_text}`, and the Router's `{:error, _} = err`
  arm PROPAGATES those — the dispatch aborts, it does not fall back to
  the template render. Only four returns become `:legacy`:

    * the provider does not export `build_prompt/1` (Tasks, Memory)
    * it returns `{:error, :no_build_prompt}` (a multi-key shim whose
      current key has no builder)
    * it returns an unexpected shape
    * it raises

  Module introspection alone would therefore pin a 13-key list, and the
  first honest run would look like tree movement when it was a
  classifier bug. Do not "simplify" `classify/2` back to
  `function_exported?/3`.

  ## Scope: `{:ok, module}` only, and what covers the rest

  A feature whose `Providers.feature_provider/1` returns `{:retired, _}`
  or `:error` resolves to `nil` at `provider_module_for/1`
  (router.ex:1647) and would also take the legacy render — but those
  are a different defect with a different owner, and they already have
  a guard. `Platform.Responsibilities.ProviderCoverageTest` asserts
  `:error` is never acceptable for a built-in, and checks the
  `security.*` retirement against `Sweeper.default_scanner_modules/0`
  rather than a list. Folding the four retired `security.*` keys in
  here would restate that file's job and inflate this set to fifteen
  for a reason that has nothing to do with builders.

  ## Sibling file

  `closed_roster_template_coverage_test.exs` asks whether a slug is
  owned by a SEEDER (a static scan of `default_templates/0` plus the
  migrations). This file asks whether the ROW IS THERE on a migrated
  database, for the narrower set of keys that actually need it. Both
  pin their known gaps by equality; the two `@unseeded*` lists overlap
  in `memory.daily_summary.v1` and disagree about
  `meetings.summarize.v1` for a stated reason — that key has a builder,
  so it never reaches the render path and is not this file's business.

  This is the STORED-column check. A row whose body renders to
  whitespace after `{{placeholder}}` substitution is stage 3's
  `{:template_blank, slug}` and is pinned in `prompt_outcome_test.exs`;
  `PromptTemplate.changeset/2` runs `validate_required([:content])`
  with the default trim, so a blank stored body cannot be written
  through `PromptTemplates` at all. The check is here anyway because
  its cost is one `String.trim/1` and its absence would let a raw SQL
  fixture through.

  ## `memory.daily_summary.v1` is NOT to be seeded

  It is listed, by name, in `@unseeded`. Task `019fb8ed` stage 2 made
  that decision — a named absence that says which row to seed beats
  prompt content nobody authored reaching a live model — and it is not
  this task's to reverse. Its sibling record is
  `closed_roster_template_coverage_test.exs:132`. The list is asserted
  by equality, so seeding the body later is a mandatory REMOVAL here,
  not an optional one.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities
  alias Platform.Responsibilities.BuiltIns
  alias Platform.Responsibilities.Providers
  alias Platform.Responsibilities.Responsibility

  # The eleven keys that take the legacy template render path today.
  # DERIVED and then pinned — see `builder_less_keys/0`. Membership is
  # exactly: every key of a feature whose provider exports no
  # `build_prompt/1` (`tasks.*`, `memory.*`), plus the keys of the
  # multi-key shims that answer `{:error, :no_build_prompt}` for them
  # (`meetings.intent_classify`, `meetings.attendance_followup`, and
  # the three `design.*` keys that are not `design.task_direction`).
  #
  # `architecture.*` is absent because all three of its handlers export
  # a builder; `meetings.summarize` / `meetings.action_items` are
  # absent for the return-value reason in the moduledoc.
  @builder_less_keys [
    "design.brand_check",
    "design.critique",
    "design.spec_writer",
    "meetings.attendance_followup",
    "meetings.intent_classify",
    "memory.daily_summary",
    "memory.dreaming",
    "memory.propose_long_term",
    "tasks.triage",
    "tasks.unblock",
    "tasks.weekly_review"
  ]

  # Slugs among the above that have NO `prompt_templates` row on a
  # migrated database. Exactly one today, and deliberately so — see the
  # moduledoc. EXACT pin, not an allowlist to grow.
  @unseeded ["memory.daily_summary.v1"]

  setup do
    # Registers every built-in provider so the `responsibilities` table
    # carries the rows we sweep. Prompt-template rows are NOT inserted
    # here — they come from the migrations `mix test` runs, which is
    # the whole point of the second assertion.
    Enum.each(BuiltIns.providers(), fn provider_module ->
      {:ok, _rows} = Responsibilities.register(provider_module)
    end)

    :ok
  end

  describe "builder-less key coverage" do
    test "the set of keys that fall back to the template render is exactly the pinned set" do
      classified = classify_all()
      derived = builder_less_keys(classified)

      # A zero-length sweep would satisfy nothing. Belt and braces.
      assert classified != [], "no responsibility rows registered — the sweep saw nothing"

      assert Enum.sort(derived) == Enum.sort(@builder_less_keys),
             """
             the set of builder-less responsibility keys changed.

             Derived just now (#{length(derived)}):
             #{format_keys(derived)}
             Pinned in @builder_less_keys (#{length(@builder_less_keys)}):
             #{format_keys(@builder_less_keys)}

             Full classification:
             #{format_classification(classified)}

             A key appearing here that is not pinned means a new
             responsibility joined a feature whose provider has no
             `build_prompt/1` for it. Every external fire on that key now
             depends on its `default_prompt_template` row existing — which
             is what the assertion below checks. Either give the feature
             provider a builder for the key, or add the key here AND make
             sure its slug is seeded.

             A pinned key NOT appearing here means a builder was added:
             delete it from @builder_less_keys.

             Before concluding the tree moved: `classify/2` mirrors
             `Router.build_prompt_via_provider/2` and a key whose builder
             returns some OTHER `{:error, reason}` is NOT builder-less —
             the Router propagates that and aborts. See the moduledoc.
             """
    end

    test "every builder-less key's template slug has a real row, except the pinned absence" do
      derived = builder_less_keys(classify_all())

      rows =
        Enum.map(derived, fn key ->
          responsibility = Responsibilities.get_by_key(key)

          assert responsibility.default_prompt_template not in [nil, ""],
                 "builder-less key \"#{key}\" has no default_prompt_template slug at all, " <>
                   "so the legacy render has nothing to name: every external fire aborts " <>
                   "with `:no_prompt_template` (dispatcher.ex:315)"

          {key, responsibility.default_prompt_template}
        end)

      missing =
        Enum.filter(rows, fn {_key, slug} ->
          case PromptTemplates.get_template_by_slug(slug) do
            nil -> true
            %{content: content} -> String.trim(to_string(content)) == ""
          end
        end)

      assert Enum.sort(Enum.map(missing, fn {_key, slug} -> slug end)) == Enum.sort(@unseeded),
             """
             builder-less template-row coverage changed.

             Slugs with no non-blank row right now:
             #{format_pairs(missing)}
             Pinned in @unseeded:
               #{Enum.join(@unseeded, "\n  ")}

             A slug appearing here that is not pinned means a key that can
             ONLY get its prompt from the template render has no body to
             render. Post-stage-3 that is an abort, not a silent slug on
             the wire — but it is still a dispatch that never happens. Seed
             the row with a migration (pattern:
             20260703120300_seed_prompt_templates_triage_officer.exs);
             editing `do_default_templates/0` alone is a no-op on every
             already-migrated environment.

             A pinned slug NOT appearing here means it finally got a body:
             delete it from @unseeded. `memory.daily_summary.v1` is pinned
             on purpose (task 019fb8ed stage 2) — do not seed it to make
             this green.
             """
    end

    test "the classifier separates a builder from a builder-less shim (mutation control)" do
      # Drives the SAME `classify/2` the assertions above use, over one
      # key on each side of the line, so a bug in the real classifier
      # reddens here rather than hiding behind a parallel
      # reimplementation.
      #
      # `meetings.action_items` is the specific false positive this
      # stage was warned about: it exports a builder that returns an
      # error on an empty context. A `function_exported?/3` classifier
      # calls it builder-less; the Router does not.
      builder_less = Responsibilities.get_by_key("meetings.intent_classify")
      builder = Responsibilities.get_by_key("meetings.action_items")

      assert classify(builder_less) == :legacy

      refute classify(builder) == :legacy,
             "meetings.action_items classified as builder-less — the classifier is asking " <>
               "`function_exported?` instead of reading the return value, and the pinned " <>
               "set will inflate to thirteen for a reason that is not tree movement"

      # And the two sides really are different, so neither assertion
      # can be satisfied by a classifier that returns one verdict for
      # everything.
      assert classify(builder_less) != classify(builder)
    end
  end

  # ── derivation ────────────────────────────────────────────────────────────

  defp classify_all do
    Responsibilities.list_responsibilities()
    |> Enum.map(fn %Responsibility{} = row -> {row.key, classify(row)} end)
    |> Enum.sort()
  end

  defp builder_less_keys(classified) do
    for {key, :legacy} <- classified, do: key
  end

  # Mirrors `Router.build_prompt_via_provider/2` (router.ex:1420) arm
  # for arm, over the context the Router builds at router.ex:1161 —
  # `Map.put(gathered_ctx, :__responsibility__, responsibility)`. The
  # gathered half is intentionally empty: a provider that needs live
  # context to decide whether it owns a key would be deciding on data
  # the key's OWNER should have settled, and every builder in the tree
  # today refuses on an empty context by returning `{:error, reason}` —
  # which is the not-legacy answer either way.
  defp classify(%Responsibility{} = responsibility) do
    case Providers.feature_provider(responsibility.feature) do
      {:ok, module} ->
        classify(module, %{__responsibility__: responsibility})

      # Out of scope by design — see the moduledoc. `ProviderCoverageTest`
      # owns these.
      {:retired, _reason} ->
        :retired

      :error ->
        :no_provider
    end
  end

  defp classify(module, context) do
    if is_atom(module) and Code.ensure_loaded?(module) and
         function_exported?(module, :build_prompt, 1) do
      invoke_build_prompt(module, context)
    else
      :legacy
    end
  end

  defp invoke_build_prompt(module, context) do
    case module.build_prompt(context) do
      {:ok, %{system: sys, user: user}} when is_binary(sys) and is_binary(user) -> :built
      {:ok, %{user: user}} when is_binary(user) -> :built
      # The provider explicitly asked for the template render.
      {:error, :no_build_prompt} -> :legacy
      # Any OTHER error propagates: the Router aborts the dispatch, it
      # does not fall back. This arm is the whole reason the classifier
      # reads return values.
      {:error, reason} -> {:refused, reason}
      # Unexpected shape falls back to the render, so it IS builder-less.
      _other -> :legacy
    end
  rescue
    # A raising builder falls back to the render too.
    _error -> :legacy
  end

  # ── formatting ────────────────────────────────────────────────────────────

  defp format_keys([]), do: "  (none)\n"
  defp format_keys(keys), do: Enum.map_join(Enum.sort(keys), "", &"  #{&1}\n")

  defp format_pairs([]), do: "  (none)\n"

  defp format_pairs(pairs),
    do: Enum.map_join(pairs, "", fn {key, slug} -> "  #{key} -> #{slug}\n" end)

  defp format_classification(classified),
    do: Enum.map_join(classified, "", fn {key, verdict} -> "  #{key}: #{inspect(verdict)}\n" end)
end
