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
  # The progressive-enhancement contract (ADR-0044): unfilled
  # responsibilities are a valid steady state. When no agent is
  # assigned to the resolved key we return `:ok` — never an error — so
  # call sites can invoke `fire/2` from within lifecycle transitions
  # (plan-submit hook, stage-complete hook) without adding branch
  # handling for the "nobody home" path.
  #
  # `{:error, :unknown_responsibility}` from the Router (no row seeded
  # for the key) is normalised to `:ok` for the same reason — a code
  # site that hooks a responsibility key before its seed migration
  # lands should not stall the caller. The Router already logs
  # `[ResponsibilityRouter] fire/2 no row for key=` so the miss is
  # visible in operator logs.
  #
  # NOTE (ADR-0046 member 1, stage 1): `Router.fire_trigger/3` now returns
  # `{:ok, :dispatched} | {:ok, :unfilled} | {:error, term()}` instead of a
  # flat `:ok`. This function still flattens both ok shapes so its own
  # observable behaviour is unchanged for now; a genuine dispatch failure
  # does surface as `{:error, reason}` (previously impossible). Stage 2 of
  # that task deletes this normalisation entirely and adds
  # `Responsibilities.outcome/1`.

  @doc """
  Fire a responsibility trigger by canonical key.

  Delegates to `Platform.Responsibilities.Router.fire/2`. Accepts either
  the canonical dotted string key (`"architecture.review_plan"`) or an
  atom shorthand (`:architecture_review_plan`) — the Router
  canonicalises atom shorthands by replacing the first underscore with
  a dot.

  ## Return contract

    * `:ok` when the responsibility fires (assignee found + dispatch
      completed) OR when the responsibility is unfilled OR when no
      row is seeded for the key. All three of these are "nothing
      further to do" cases the caller can treat identically.
    * `{:error, term}` when the Router reports a non-lookup failure
      (e.g. a downstream contract violation the Router surfaces). Call
      sites that hook `fire/2` from a lifecycle transition should wrap
      the call in `try/rescue/catch :exit` regardless — Router's
      internal guards catch dispatch crashes, but the belt-and-braces
      wrap protects against future Router-shape changes.
  """
  @spec fire(atom() | binary(), map()) :: :ok | {:error, term()}
  def fire(key, trigger_meta \\ %{}) when is_map(trigger_meta) do
    case Platform.Responsibilities.Router.fire(key, trigger_meta) do
      {:ok, _} ->
        :ok

      {:error, :unknown_responsibility} ->
        # Progressive-enhancement: an unseeded key is functionally
        # identical to an unfilled assignee. Both are "nothing to do".
        :ok

      other ->
        other
    end
  end
end
