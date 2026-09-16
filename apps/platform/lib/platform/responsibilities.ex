defmodule Platform.Responsibilities do
  @moduledoc """
  Context module for the responsibilities registry (ADR-0041 M1 stage 2).

  A "responsibility" is a declarative record of something the platform
  fulfills automatically — a cron job, an event-topic subscription, a
  chat-pattern reaction, or a webhook endpoint — bound to a feature
  (e.g. `meetings.summarize`).

  This module is the CRUD + lookup surface around `Platform.Responsibilities.Responsibility`.
  Later milestones add:

    * the `Provider` behaviour (M1 stage 3) — feature modules implement
      `register/0` returning the attribute maps they want persisted;
    * the `Registry` GenServer (M1 stage 4) — runs `register_all/1` at
      boot to idempotently upsert each provider's declared rows;
    * the M6 router — queries this table via `get_by_trigger/1` /
      `get_by_key/1` to dispatch events to the right provider.

  ## `upsert_by_key/1` contract — declared content vs operator state

  `upsert_by_key/1` is the workhorse for boot-time idempotent
  registration. It replaces the **declared content** fields (everything
  a provider can sensibly redeclare in source) on conflict, but
  deliberately **preserves** two operator-territory fields across
  upserts:

    * `enabled` — operators toggle this via the M7 admin UI to kill or
      revive a responsibility without a code change. Declared rows
      always come back enabled-by-default at first insert; on
      subsequent upserts the operator's value wins.
    * `id` — the upserted row keeps its original UUIDv7 so foreign-key
      references from later milestones stay intact.

  Mutable-via-upsert fields (replaced on conflict, declared rows win):
  `feature`, `trigger_kind`, `trigger_config`, `scope`,
  `context_provided`, `output_contract`, `default_prompt_template`,
  `cost_profile`, `metadata`, `updated_at`.
  """

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Responsibilities.Responsibility

  @typedoc "One of the `trigger_kind` atoms accepted by `get_by_trigger/1`."
  @type trigger_kind :: :cron | :event_topic | :chat_pattern | :webhook

  # Mutable-on-upsert: everything a provider can declare in source.
  # NOT in this list: `:id`, `:key` (conflict_target), `:enabled`
  # (operator-set), `:inserted_at` (only set on first insert).
  @upsert_replace_fields ~w(feature trigger_kind trigger_config scope
                            context_provided output_contract
                            default_prompt_template cost_profile metadata
                            updated_at)a

  @doc "List all responsibilities ordered ascending by key."
  @spec list_responsibilities() :: [Responsibility.t()]
  def list_responsibilities do
    Repo.all(from(r in Responsibility, order_by: [asc: r.key]))
  end

  @doc """
  List responsibilities scoped to a single feature, ordered ascending
  by key. Empty list when no rows match — feature filters that miss
  are not an error.
  """
  @spec list_by_feature(String.t()) :: [Responsibility.t()]
  def list_by_feature(feature) when is_binary(feature) do
    Repo.all(from(r in Responsibility, where: r.feature == ^feature, order_by: [asc: r.key]))
  end

  @doc "Get a responsibility by id. Returns `nil` if not found."
  @spec get(String.t()) :: Responsibility.t() | nil
  def get(id) when is_binary(id) do
    Repo.get(Responsibility, id)
  end

  @doc """
  Primary lookup the M6 router uses to resolve a `<feature>.<verb>`
  key to its responsibility row. Returns `nil` if no row matches.
  """
  @spec get_by_key(String.t()) :: Responsibility.t() | nil
  def get_by_key(key) when is_binary(key) do
    Repo.get_by(Responsibility, key: key)
  end

  @doc """
  Return every enabled responsibility whose `trigger_kind` matches the
  supplied atom. Pre-filter used by the M6 router so it never even
  considers disabled rows. Ordered by key for deterministic dispatch
  ordering (matters for chat_pattern collisions).
  """
  @spec get_by_trigger(trigger_kind()) :: [Responsibility.t()]
  def get_by_trigger(kind) when kind in [:cron, :event_topic, :chat_pattern, :webhook] do
    kind_str = Atom.to_string(kind)

    Repo.all(
      from(r in Responsibility,
        where: r.trigger_kind == ^kind_str and r.enabled == true,
        order_by: [asc: r.key]
      )
    )
  end

  @doc "Create a new responsibility. Validates via `Responsibility.changeset/2`."
  @spec create_responsibility(map()) ::
          {:ok, Responsibility.t()} | {:error, Ecto.Changeset.t()}
  def create_responsibility(attrs) do
    %Responsibility{}
    |> Responsibility.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update an existing responsibility."
  @spec update_responsibility(Responsibility.t(), map()) ::
          {:ok, Responsibility.t()} | {:error, Ecto.Changeset.t()}
  def update_responsibility(%Responsibility{} = responsibility, attrs) do
    responsibility
    |> Responsibility.changeset(attrs)
    |> Repo.update()
  end

  @doc "Delete a responsibility."
  @spec delete_responsibility(Responsibility.t()) ::
          {:ok, Responsibility.t()} | {:error, Ecto.Changeset.t()}
  def delete_responsibility(%Responsibility{} = responsibility) do
    Repo.delete(responsibility)
  end

  @doc """
  Idempotently insert-or-update a responsibility row keyed on `:key`.

  Used by the boot-time provider registration path (M1 stage 3+). On
  conflict with an existing row's `key`, replaces every declared
  content field listed in `@upsert_replace_fields` but **preserves**
  the operator-set `enabled` flag and the original `id`. See the
  moduledoc for the full rationale.

  Returns `{:ok, %Responsibility{}}` on success or
  `{:error, %Ecto.Changeset{}}` if the attrs failed validation. The
  returned struct carries the post-write field values (Postgres
  `RETURNING *` via `returning: true`), so callers can rely on `id`
  being the persisted UUIDv7 whether the row was inserted fresh or
  found by conflict.
  """
  @spec upsert_by_key(map()) :: {:ok, Responsibility.t()} | {:error, Ecto.Changeset.t()}
  def upsert_by_key(attrs) when is_map(attrs) do
    changeset = Responsibility.changeset(%Responsibility{}, attrs)

    if changeset.valid? do
      Repo.insert(changeset,
        on_conflict: {:replace, @upsert_replace_fields},
        conflict_target: :key,
        returning: true
      )
    else
      # Surface the validation error without round-tripping to Postgres.
      {:error, %{changeset | action: :insert}}
    end
  end

  @doc """
  Register every responsibility declared by `provider_module` (M1 stage 3).

  Validates that the supplied module is loaded and implements the
  `Platform.Responsibilities.Provider` `register/0` callback, then calls
  it and pipes each returned attribute map through `upsert_by_key/1`.

  Fail-fast: the first upsert failure short-circuits and returns
  `{:error, {provider_module, reason}}`. `register_all/1` is the
  caller you want at boot when "one bad provider must not poison the
  others" — this single-module variant is the building block.

  Failure tags:

    * `:module_not_loaded` — `Code.ensure_loaded?/1` returned false;
    * `:not_a_provider` — module exists but doesn't export `register/0`;
    * `{:invalid_attrs, %Ecto.Changeset{}}` — `register/0` returned a
      map that failed validation;
    * `{:bad_return, term}` — `register/0` returned something other than
      a list.
  """
  @spec register(module()) ::
          {:ok, [Responsibility.t()]} | {:error, {module(), term()}}
  def register(provider_module) when is_atom(provider_module) do
    with :ok <- ensure_provider(provider_module),
         attrs_list when is_list(attrs_list) <- safe_register(provider_module) do
      upsert_each(provider_module, attrs_list, [])
    else
      {:error, reason} -> {:error, {provider_module, reason}}
      other -> {:error, {provider_module, {:bad_return, other}}}
    end
  end

  @doc """
  Register every provider in `provider_modules`, aggregating results.

  Per-provider failures are **collected into `:errors`** rather than
  short-circuiting — a single bad provider must not prevent the rest
  from registering (ADR-0041 M1 boot-safety requirement). The return is
  always `{:ok, %{ok: [...], errors: [...]}}`; this function never
  raises and never returns `{:error, _}`.

    * `:ok` — flat list of `%Responsibility{}` rows successfully
      upserted across every provider, in input order.
    * `:errors` — list of `{provider_module, reason}` tuples for every
      provider that failed, using the same tags `register/1` returns.

  Duplicate-key semantics: when two providers declare the same `key`,
  the second writer wins because each call goes through
  `upsert_by_key/1`'s `ON CONFLICT (key) DO UPDATE` path.
  """
  @spec register_all([module()]) ::
          {:ok, %{ok: [Responsibility.t()], errors: [{module(), term()}]}}
  def register_all(provider_modules) when is_list(provider_modules) do
    {oks, errors} =
      Enum.reduce(provider_modules, {[], []}, fn mod, {ok_acc, err_acc} ->
        case register(mod) do
          {:ok, rows} -> {ok_acc ++ rows, err_acc}
          {:error, {^mod, _reason} = err} -> {ok_acc, [err | err_acc]}
        end
      end)

    {:ok, %{ok: oks, errors: Enum.reverse(errors)}}
  end

  # ── prompt-template audit (task 01a0a74d stage 3) ──────────────────────────

  @typedoc """
  Verdict for one responsibility's declared `default_prompt_template`.

  Mirrors the taxonomy `Router.render_default_template/2` already produces
  per fire, minus the context: `:none` is the router's `{:absent, :legacy}`
  (the key never named a template), `{:missing, slug}` is
  `{:absent, {:template_missing, slug}}`, `{:blank, slug}` is
  `{:absent, {:template_blank, slug}}`. Deliberately the SAME words, so a
  boot-time verdict and a per-fire log line about the same key read as the
  same finding rather than as two problems.

  `{:blank, slug}` is decided on the STORED body here, where the router
  decides it on the RENDERED body. A row whose content is non-blank but
  renders blank for some particular context cannot be known before the
  fire, so this is the strictly weaker check — it catches the row that is
  empty for everyone, which is the one knowable with zero fires.
  """
  @type prompt_template_verdict ::
          :resolved | :none | {:missing, String.t()} | {:blank, String.t()}

  @typedoc "One `prompt_template_audit/0` row."
  @type prompt_template_audit_entry :: %{
          key: String.t(),
          trigger_kind: String.t() | nil,
          slug: String.t() | nil,
          status: prompt_template_verdict()
        }

  @doc """
  Audit every persisted responsibility's `default_prompt_template` against
  the `prompt_templates` table (task `01a0a74d` stage 3, acceptance item 5).

  Returns one entry per responsibility key, sorted by key. This is the
  single read that `Registry`'s boot-time audit, the
  `mix responsibilities.prompt_audit` task and the `/admin/prompts`
  declared-but-unbacked row all go through — it is public precisely so
  those three cannot drift into three different definitions of "orphan".

  The gap this closes: everything the router knows about a missing template
  it learns per FIRE and writes to a log. A cron key that fires once a day
  at 23:00 UTC announces its own breakage once a day, into a container log,
  after the agent has already received an empty prompt. The same fact is
  knowable at registration time with zero fires, because the slug is
  declared in source.

  Never raises: a caller may be a boot path running against a database whose
  `prompt_templates` rows are not seeded yet (every fresh test database
  before `seed_defaults/0`), and an audit that took the app down would be a
  worse defect than the one it reports.
  """
  @spec prompt_template_audit() :: [prompt_template_audit_entry()]
  def prompt_template_audit do
    prompt_template_audit(list_responsibilities())
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc """
  Audit an explicit list of responsibilities.

  Same contract as `prompt_template_audit/0`; takes the rows rather than
  reading them so `Registry.do_register/1` can audit exactly what it just
  registered instead of issuing a second query whose answer could differ.
  """
  @spec prompt_template_audit([Responsibility.t()]) :: [prompt_template_audit_entry()]
  def prompt_template_audit(responsibilities) when is_list(responsibilities) do
    responsibilities
    |> Enum.map(fn %Responsibility{} = r ->
      %{
        key: r.key,
        trigger_kind: r.trigger_kind,
        slug: r.default_prompt_template,
        status: prompt_template_status(r.default_prompt_template)
      }
    end)
    |> Enum.sort_by(& &1.key)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc """
  The subset of `prompt_template_audit/1` whose verdict is a defect —
  `{:missing, slug}` or `{:blank, slug}`.

  `:none` is NOT a defect and is excluded: a responsibility that names no
  template is a legacy-path key, which is a different (and deliberate)
  state. Folding it in here would make the orphan list permanently
  non-empty and therefore permanently ignored.
  """
  @spec prompt_template_orphans([prompt_template_audit_entry()]) ::
          [prompt_template_audit_entry()]
  def prompt_template_orphans(entries) when is_list(entries) do
    Enum.filter(entries, fn
      %{status: {:missing, _}} -> true
      %{status: {:blank, _}} -> true
      _ -> false
    end)
  end

  defp prompt_template_status(slug) when is_binary(slug) do
    case String.trim(slug) do
      "" ->
        :none

      slug ->
        case Platform.Orchestration.PromptTemplates.get_template_by_slug(slug) do
          nil -> {:missing, slug}
          %{content: content} when is_binary(content) -> blank_or_resolved(content, slug)
          _ -> {:blank, slug}
        end
    end
  end

  defp prompt_template_status(_), do: :none

  defp blank_or_resolved(content, slug) do
    if String.trim(content) == "", do: {:blank, slug}, else: :resolved
  end

  # ── register/1 helpers ─────────────────────────────────────────────────────

  defp ensure_provider(mod) do
    cond do
      not Code.ensure_loaded?(mod) -> {:error, :module_not_loaded}
      not function_exported?(mod, :register, 0) -> {:error, :not_a_provider}
      true -> :ok
    end
  end

  defp safe_register(mod) do
    mod.register()
  end

  defp upsert_each(_mod, [], acc), do: {:ok, Enum.reverse(acc)}

  defp upsert_each(mod, [attrs | rest], acc) do
    case upsert_by_key(attrs) do
      {:ok, row} -> upsert_each(mod, rest, [row | acc])
      {:error, %Ecto.Changeset{} = cs} -> {:error, {mod, {:invalid_attrs, cs}}}
    end
  end

  # ── Runtime dispatch surface (ADR-0044 stage 2) ────────────────────────────
  #
  # `fire/2` is the one-shot dispatch API call sites use to hand an event
  # off to whichever agent currently holds the responsibility. It is a
  # thin delegate to `Platform.Responsibilities.Router.fire/2` — the
  # canonical runtime dispatch surface stood up in ADR-0041 M6.
  #
  # The progressive-enhancement contract (ADR-0044) is unchanged:
  # unfilled responsibilities and unseeded keys are valid steady
  # states, not failures, and call sites may invoke `fire/2` from
  # within lifecycle transitions (plan-submit hook, stage-complete
  # hook) without treating either as an error.
  #
  # What changed (ADR-0046 member 1, stage 2): this function used to
  # express that contract by *laundering* every Router outcome into a
  # flat `:ok`. That made a genuine dispatch failure indistinguishable
  # from "nobody home" at every call site — the bug ADR-0046 line 79-83
  # names explicitly. The normalisation is gone. `fire/2` now returns
  # the Router result verbatim and callers decide, with `outcome/1`
  # below as the single shared mapping onto the ADR's
  # `complete | not_applicable | failed` vocabulary.
  #
  # The progressive-enhancement guarantee is preserved by the *shape*
  # instead: both "nothing to do" states stay in the ok channel
  # (`{:ok, :unfilled}`, `{:ok, :unknown_responsibility}`), so a caller
  # that only cares about "did this blow up" can still match `{:ok, _}`.

  @typedoc """
  Every value `fire/2` can return.

  The `Router.fire_trigger/3` union plus `{:ok, :unknown_responsibility}`,
  which only the key-lookup layer (`Router.fire/2`) can produce.
  """
  @type fire_result ::
          Platform.Responsibilities.Router.fire_outcome() | {:ok, :unknown_responsibility}

  @doc """
  Fire a responsibility trigger by canonical key.

  Delegates to `Platform.Responsibilities.Router.fire/2`. Accepts either
  the canonical dotted string key (`"architecture.review_plan"`) or an
  atom shorthand (`:architecture_review_plan`) — the Router
  canonicalises atom shorthands by replacing the first underscore with
  a dot.

  ## Return contract

  The Router result, verbatim — see `t:fire_result/0`:

    * `{:ok, :dispatched}` — an assignee was resolved and the dispatch
      was handed off. On the native path this means the handoff was
      accepted, not that the agent responded (see
      `Platform.Responsibilities.Router` moduledoc, "Honesty limit").
    * `{:ok, :unfilled}` — the row exists but no agent holds it.
    * `{:ok, :placeholder}` — the row declares
      `metadata["dispatch"] == "inert"` and is deliberately not
      dispatchable yet; nothing was attempted.
    * `{:ok, :unknown_responsibility}` — no row is seeded for the key.
    * `{:error, term}` — an assignee existed and the dispatch failed.

  The three middle values are progressive-enhancement states, NOT
  failures; `{:error, _}` is a real failure. Use `outcome/1` to collapse
  them onto the ADR-0046 vocabulary rather than re-deriving the mapping.

  Before ADR-0046 member 1 stage 2 this function returned a flat `:ok`
  for the first three cases, so a failed dispatch was invisible to every
  caller. Call sites that only need "did this blow up" can match
  `{:ok, _}`.

  `fire/2` still never raises — the Router's internal
  `try/rescue/catch :exit` envelope converts dispatch crashes into
  `{:error, _}`. Call sites hooking `fire/2` from a lifecycle transition
  (`Platform.Tasks.submit_plan_for_review/1`,
  `Platform.Tasks.PlanEngine.after_stage_completed/1`) should keep their
  belt-and-braces wrap regardless: those run inside Ecto transactions
  where a raise rolls back a validation update.
  """
  @spec fire(atom() | binary(), map()) :: fire_result()
  def fire(key, trigger_meta \\ %{}) when is_map(trigger_meta) do
    Platform.Responsibilities.Router.fire(key, trigger_meta)
  end

  @doc """
  Map a `fire/2` result onto the ADR-0046 per-step outcome vocabulary.

  `docs/decisions/0046-design-and-architecture-phases-in-planning.md:77-83`
  defines three per-step outcomes and requires that `not_applicable` and
  `failed` are never conflated:

      iex> Platform.Responsibilities.outcome({:ok, :dispatched})
      :complete
      iex> Platform.Responsibilities.outcome({:ok, :unfilled})
      :not_applicable
      iex> Platform.Responsibilities.outcome({:ok, :placeholder})
      :not_applicable
      iex> Platform.Responsibilities.outcome({:ok, :unknown_responsibility})
      :not_applicable
      iex> Platform.Responsibilities.outcome({:error, {:dispatch_failed, :timeout}})
      :failed

  ## Why this lives here

  Every member of the ADR-0046 stack needs this mapping. If each derives
  it independently, one of them will eventually map `:unfilled` onto
  `:failed` (or the reverse) and re-open the bug this contract closes.
  This is the single shared surface — import it, do not re-implement it.

  ## No catch-all clause, on purpose

  There is deliberately no `def outcome(_), do: :failed`. An unrecognised
  shape means the fire contract grew a value this mapping has not
  considered, and a `FunctionClauseError` at the call site is the correct,
  loud answer — a silent mis-map into `:failed` would report a failure for
  a step that may have succeeded.

  **Consequence for transaction call sites:** because this function CAN
  raise, do not invoke it unguarded from inside an Ecto transaction. The
  hooks at `Platform.Tasks.fire_architecture_review_plan/1` and
  `Platform.Tasks.PlanEngine.after_stage_completed/1` run inside
  `evaluate_validation/2`'s transaction, where a raise rolls back the
  validation update. Call `outcome/1` outside the transaction, or wrap it
  in the same `try/rescue` envelope those hooks already use for `fire/2`.
  """
  @spec outcome(term()) :: :complete | :not_applicable | :failed
  def outcome({:ok, :dispatched}), do: :complete
  def outcome({:ok, :unfilled}), do: :not_applicable
  # A declared-inert row (`metadata["dispatch"] == "inert"`) never
  # reached a dispatch, so the step did not fail — there was nothing
  # applicable to do. Mapping it to `:failed` would report a broken step
  # for a key the codebase deliberately has not finished.
  def outcome({:ok, :placeholder}), do: :not_applicable
  def outcome({:ok, :unknown_responsibility}), do: :not_applicable
  def outcome({:error, _reason}), do: :failed
end
