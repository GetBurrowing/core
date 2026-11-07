defmodule Platform.Habits do
  @moduledoc """
  The learned-defaults substrate (`0061-learned-defaults.md`, task 01a1b6a1
  stage 2). Every consumer goes through this module; nothing else reads
  `habit_signals` or `habit_patterns`.

  ## The contract

    * `record/1` stores one learnable choice and moves the pattern's ladder
      state in the same transaction.
    * `suggest/3` ranks, pre-fills and (rarely) acts, from decayed signals.
    * `stop/4` says "never pre-fill or act on this again here".
    * `forget/2`, `list_patterns/1` and `set_enabled/2` are the Settings
      surface: see what was learned, delete it, or turn learning off.
    * `emit_choice/1` is the one emission seam (§ 7): a consumer emits a
      `[:platform, :interaction, :choice]` telemetry event and
      `Platform.Habits.TelemetryHandler` records it.
    * `prune_signals/1` is the retention sweep (§ 8), run daily by
      `Platform.Habits.Pruner`.

  ## Isolation is structural

  Every signal and pattern query that feeds a suggestion goes through
  `scoped/3`, a private builder whose user id and space id are both required
  arguments. A nil space id matches only org-level rows (`space_id IS NULL`);
  it never means "any room". The two owner-wide reads (`list_patterns/1`,
  `forget/2`) are the Settings surface for the owner's own rows and go
  through `owned/2`, which still requires the user id.

  ## Targets

  A target is a map `%{target_type: "user" | "agent", target_id: uuid}`.
  """

  import Ecto.Query

  alias Platform.Accounts
  alias Platform.Experiments.Subject
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.LearnedDefaults
  alias Platform.Habits.Actions
  alias Platform.Habits.Pattern
  alias Platform.Habits.Signal
  alias Platform.Repo

  @preference_key "learned_defaults"
  @choice_event [:platform, :interaction, :choice]
  @signal_keys ~w(actor_user_id space_id action target_type target_id outcome rung source_message_id)a

  # Tolerance for the decayed comparisons (score > 0, confidence >=
  # prefill_threshold). min_signals is a number of times and is compared
  # with the raw count, never a decayed weight.
  @epsilon 1.0e-6
  @seconds_per_day 86_400
  # § 8: signals older than this many half-lives are pruned.
  @retention_half_lives 6

  @type target :: %{target_type: String.t(), target_id: Ecto.UUID.t()}
  @type ranked :: %{target_type: String.t(), target_id: Ecto.UUID.t(), score: float()}
  @type suggestion :: %{
          ranked: [ranked()],
          prefill: target() | nil,
          act: target() | nil,
          variant: map()
        }

  # ── Opt-out ────────────────────────────────────────────────────────────────

  @doc "The `users.preferences` key of the per-user opt-out."
  @spec preference_key() :: String.t()
  def preference_key, do: @preference_key

  @doc """
  Is learning on for `user_id`? On by default; off only when
  `users.preferences["learned_defaults"]` is literally `false`.
  """
  @spec enabled?(binary()) :: boolean()
  def enabled?(user_id) when is_binary(user_id),
    do: Map.get(Accounts.get_user_preferences(user_id), @preference_key) != false

  def enabled?(_user_id), do: false

  @doc """
  Writes the opt-out preference. Turning learning off does NOT delete
  history; `forget/2` does. Returns `{:ok, user}` or `{:error, reason}`.
  """
  @spec set_enabled(binary(), boolean()) :: {:ok, term()} | {:error, term()}
  def set_enabled(user_id, enabled) when is_binary(user_id) and is_boolean(enabled),
    do: Accounts.update_user_preference(user_id, @preference_key, enabled)

  # ── Thresholds ─────────────────────────────────────────────────────────────

  @doc """
  The `habits.learned_defaults` payload in force for `user_id`, string keys:
  `prefill_threshold`, `min_signals`, `act_after_accepts`, `half_life_days`.

  Resolved through `Surfaces.resolve/4` at target `chat.message_attention`
  with `Subject.new("user", user_id)`. A variant or promoted default is
  validated (missing keys take the control's value). Never raises: on any
  error, or an invalid payload, the control payload applies.
  """
  @spec variant(binary()) :: map()
  def variant(user_id) do
    resolved =
      Surfaces.resolve(
        LearnedDefaults.key(),
        LearnedDefaults.target(),
        Subject.new("user", user_id)
      )

    raw =
      case resolved do
        {:variant, _experiment, _slug, payload} -> payload
        {:default, payload} -> payload
        _ -> nil
      end

    case raw && LearnedDefaults.validate_payload(raw) do
      {:ok, payload} -> payload
      _ -> LearnedDefaults.control()
    end
  rescue
    _ -> LearnedDefaults.control()
  catch
    _, _ -> LearnedDefaults.control()
  end

  # ── Emission seam ──────────────────────────────────────────────────────────

  @doc "The telemetry event every learnable interaction emits (§ 7)."
  @spec choice_event() :: [atom()]
  def choice_event, do: @choice_event

  @doc """
  Emits one `[:platform, :interaction, :choice]` event. `metadata` carries
  the `record/1` keys. This is the call a consumer makes; it does not write
  anything itself — `Platform.Habits.TelemetryHandler` does, synchronously,
  in the emitting process.
  """
  @spec emit_choice(map()) :: :ok
  def emit_choice(metadata) when is_map(metadata) do
    :telemetry.execute(@choice_event, %{count: 1}, Map.new(metadata))
  end

  # ── record/1 ───────────────────────────────────────────────────────────────

  @doc """
  Records one learnable choice.

  `attrs` (atom or string keys): `actor_user_id`, `space_id` (nil for an
  org-level action), `action`, `target_type`, `target_id`, `outcome`
  (`accepted | overridden | ignored | chosen`), `rung` (`none | rank |
  prefill | act`, the rung in force when the choice was made) and
  `source_message_id` (nullable).

  Returns:

    * `{:ok, :disabled}` and writes NOTHING when the actor has opted out
      (`users.preferences["learned_defaults"] == false`).
    * `{:ok, %Signal{}}` otherwise.
    * `{:error, changeset}` for an invalid signal, or a pattern update the
      ladder refuses; the transaction rolls back and nothing is stored.

  For an action with a consumer (max rung above `none`) the matching
  `habit_patterns` row is created if absent and updated in the same
  transaction:

    * `accepted` at rung `prefill`: `accepted_prefills += 1`, and the
      pattern's rung rises to at least `prefill`.
    * `accepted` at rung `act`: the rung is `act`.
    * `overridden` at rung `act` (an undo): the rung drops to `prefill` and
      `accepted_prefills` resets to 0.
    * anything else: the row exists, nothing else changes.

  Capture-only actions store the signal and touch no pattern row.
  """
  @spec record(map()) :: {:ok, Signal.t()} | {:ok, :disabled} | {:error, Ecto.Changeset.t()}
  def record(attrs) when is_map(attrs) do
    attrs = normalize(attrs)

    if enabled?(attrs[:actor_user_id]) do
      Repo.transaction(fn ->
        with {:ok, signal} <- insert_signal(attrs),
             {:ok, _pattern} <- apply_to_pattern(signal) do
          signal
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    else
      {:ok, :disabled}
    end
  end

  defp insert_signal(attrs), do: %Signal{} |> Signal.changeset(attrs) |> Repo.insert()

  defp apply_to_pattern(%Signal{action: action} = signal) do
    if action in Actions.consumer_keys() do
      pattern = lock_pattern!(signal.actor_user_id, signal.space_id, action, target_of(signal))

      case transition(pattern, signal.outcome, signal.rung) do
        :unchanged -> {:ok, pattern}
        changes -> pattern |> Pattern.changeset(changes) |> Repo.update()
      end
    else
      {:ok, :capture_only}
    end
  end

  defp transition(%Pattern{} = p, "accepted", "prefill"),
    do: %{accepted_prefills: p.accepted_prefills + 1, rung: max_rung(p.rung, "prefill")}

  defp transition(%Pattern{}, "accepted", "act"), do: %{rung: "act"}

  defp transition(%Pattern{}, "overridden", "act"),
    do: %{rung: "prefill", accepted_prefills: 0}

  defp transition(_pattern, _outcome, _rung), do: :unchanged

  defp max_rung(current, floor) do
    if Actions.rung_at_least?(String.to_existing_atom(current), String.to_existing_atom(floor)),
      do: current,
      else: floor
  end

  # ── suggest/3 ──────────────────────────────────────────────────────────────

  @doc """
  What to suggest to `user_id` for `action` in `space_id` (nil = org-level).

  Returns `%{ranked: [%{target_type, target_id, score}], prefill: target |
  nil, act: target | nil, variant: payload}`:

    * **score** of a target = the exponentially decayed weight (half-life
      `half_life_days`) of its `accepted` and `chosen` signals in THIS space,
      minus the decayed weight of its `overridden` signals. Only targets with
      a positive score rank, highest first (ties by target id). `ignored`
      signals count on neither side.
    * **confidence** of a target = its score / the total decayed weight of
      every `accepted`, `chosen` and `overridden` signal for the action in
      the space.
    * **prefill** is the top target only when its confidence >=
      `prefill_threshold`, its RAW (undecayed) count of `accepted` and
      `chosen` signals inside the lookback window (`#{@retention_half_lives}`
      half-lives) >= `min_signals`, and its pattern is not stopped.
      `min_signals` is a number of times: three picks spread over days are
      three, however much each has decayed.
    * **act** is the prefill target only when, in addition, the pattern's
      `accepted_prefills >= act_after_accepts` and
      `Actions.reversible?(action, target)` is true. An agent target never
      acts on `chat.message_attention`.
    * **variant** is the payload in force (`variant/1`).

  Empty (`ranked: []`, both nil) when the user opted out, the action has
  no consumer, or `user_id` / `space_id` is not a UUID (a picker param
  reaches here). A stopped pattern still ranks.

  Options: `:now` (a `DateTime`, default now) for tests.
  """
  @spec suggest(binary(), binary() | nil, String.t(), keyword()) :: suggestion()
  def suggest(user_id, space_id, action, opts \\ []) do
    payload = variant(user_id)
    empty = %{ranked: [], prefill: nil, act: nil, variant: payload}

    if valid_ids?([user_id, space_id]) and enabled?(user_id) and
         action in Actions.consumer_keys() do
      now = Keyword.get(opts, :now, DateTime.utc_now())
      do_suggest(user_id, space_id, action, payload, now, empty)
    else
      empty
    end
  end

  defp do_suggest(user_id, space_id, action, payload, now, empty) do
    half_life = payload["half_life_days"]
    horizon = DateTime.add(now, -@retention_half_lives * half_life * @seconds_per_day, :second)

    signals =
      scoped(:signals, user_id, space_id)
      |> where([s], s.action == ^action and s.outcome in ["accepted", "chosen", "overridden"])
      |> where([s], s.inserted_at >= ^horizon)
      |> select([s], {s.target_type, s.target_id, s.outcome, s.inserted_at})
      |> Repo.all()

    tallies =
      Enum.reduce(signals, %{}, fn {type, id, outcome, at}, acc ->
        w = decayed_weight(at, now, half_life)
        {pos, neg, times} = Map.get(acc, {type, id}, {0.0, 0.0, 0})

        tally =
          if outcome == "overridden", do: {pos, neg + w, times}, else: {pos + w, neg, times + 1}

        Map.put(acc, {type, id}, tally)
      end)

    total = tallies |> Map.values() |> Enum.reduce(0.0, fn {p, n, _}, sum -> sum + p + n end)

    ranked =
      tallies
      |> Enum.map(fn {{type, id}, {pos, neg, times}} ->
        %{target_type: type, target_id: id, score: pos - neg, times: times}
      end)
      |> Enum.filter(&(&1.score > @epsilon))
      |> Enum.sort_by(&{-&1.score, &1.target_id})

    case ranked do
      [] ->
        empty

      [top | _] ->
        pattern = get_pattern(user_id, space_id, action, top)
        prefill = prefill_target(top, total, pattern, payload)
        act = prefill && act_target(action, prefill, pattern, payload)

        %{
          empty
          | ranked: Enum.map(ranked, &Map.delete(&1, :times)),
            prefill: prefill,
            act: act
        }
    end
  end

  defp prefill_target(top, total, pattern, payload) do
    confidence = if total > 0, do: top.score / total, else: 0.0

    if confidence + @epsilon >= payload["prefill_threshold"] and
         top.times >= payload["min_signals"] and
         not stopped?(pattern) do
      %{target_type: top.target_type, target_id: top.target_id}
    end
  end

  defp act_target(action, target, %Pattern{} = pattern, payload) do
    if pattern.accepted_prefills >= payload["act_after_accepts"] and
         Actions.reversible?(action, target) and
         not stopped?(pattern) do
      target
    end
  end

  defp act_target(_action, _target, nil, _payload), do: nil

  defp stopped?(%Pattern{stopped_at: %DateTime{}}), do: true
  defp stopped?(_pattern), do: false

  @doc """
  The weight of a signal inserted at `inserted_at`, seen at `now`, with a
  half-life of `half_life_days`: `0.5 ^ (age_days / half_life_days)`. A
  future timestamp weighs 1.0.
  """
  @spec decayed_weight(DateTime.t(), DateTime.t(), pos_integer()) :: float()
  def decayed_weight(inserted_at, now, half_life_days) do
    age_days = max(DateTime.diff(now, inserted_at, :microsecond), 0) / (@seconds_per_day * 1.0e6)
    :math.pow(0.5, age_days / half_life_days)
  end

  # ── stop/4 ─────────────────────────────────────────────────────────────────

  @doc """
  Stops a pattern: sets `stopped_at`, drops its rung to `rank`, and records
  an `overridden` signal at rung `act`. A stopped pattern still ranks, but
  never pre-fills or acts again until `forget/2` deletes it.

  When the user has opted out, the stop is still written to the pattern
  (it only ever makes the ladder more cautious) but no signal is stored.

  Returns `{:ok, %Pattern{}}` or `{:error, changeset}`.
  """
  @spec stop(binary(), binary() | nil, String.t(), target() | map()) ::
          {:ok, Pattern.t()} | {:error, Ecto.Changeset.t()}
  def stop(user_id, space_id, action, target) do
    target = normalize_target(target)

    Repo.transaction(fn ->
      if enabled?(user_id) do
        attrs =
          Map.merge(target, %{
            actor_user_id: user_id,
            space_id: space_id,
            action: action,
            outcome: "overridden",
            rung: "act"
          })

        case insert_signal(attrs) do
          {:ok, _signal} -> :ok
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end

      pattern = lock_pattern!(user_id, space_id, action, target)

      case pattern
           |> Pattern.changeset(%{stopped_at: DateTime.utc_now(), rung: "rank"})
           |> Repo.update() do
        {:ok, pattern} -> pattern
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # ── Act: the cheap pre-check and the notice ────────────────────────────────

  @doc """
  Could `suggest/3` possibly return `act` for `user_id` in `space_id`? A
  cheap pre-check for the post path (task 01a1b6a1 stage 3), which runs on
  every top-level message: true only when a pattern for `action` in this
  space has at least one accepted pre-fill. It deliberately ignores
  `stopped_at` and the thresholds; `suggest/3` is the gate, this only skips
  the variant resolution and the signal read when no gate could open.
  """
  @spec act_possible?(binary(), binary(), String.t()) :: boolean()
  def act_possible?(user_id, space_id, action) do
    if valid_ids?([user_id, space_id]) and is_binary(user_id) and is_binary(space_id) do
      scoped(:patterns, user_id, space_id)
      |> where([p], p.action == ^action and p.accepted_prefills > 0)
      |> Repo.exists?()
    else
      false
    end
  end

  @doc """
  The notices of automatic actions `user_id`'s habits took on `message_ids`
  (§ 5: an action leaves a persistent notice rendered from the signal row):
  `%{message_id => notice}` with

      %{action, space_id, target_type, target_id, undone?: boolean,
        stopped?: boolean, signal_id}

  built from the act-rung signals carrying `source_message_id`. `undone?`
  is true once an `overridden` act signal for the same message and target
  exists (the undo); `stopped?` when the pattern behind it is stopped.
  Messages with no automatic action are omitted. Malformed ids are dropped.
  """
  @spec act_notices(binary(), [binary()]) :: %{binary() => map()}
  def act_notices(user_id, message_ids) when is_list(message_ids) do
    ids = Enum.filter(message_ids, &Platform.UUID.valid?/1)

    if valid_ids?([user_id]) and is_binary(user_id) and ids != [] do
      owned(:signals, user_id)
      |> where([s], s.rung == "act" and s.source_message_id in ^ids)
      |> where([s], s.outcome in ["accepted", "overridden"])
      |> order_by([s], asc: s.inserted_at, asc: s.id)
      |> Repo.all()
      |> Enum.group_by(& &1.source_message_id)
      |> Enum.flat_map(fn {message_id, signals} -> notice(user_id, message_id, signals) end)
      |> Map.new()
    else
      %{}
    end
  end

  def act_notices(_user_id, _message_ids), do: %{}

  defp notice(user_id, message_id, signals) do
    case Enum.find(signals, &(&1.outcome == "accepted")) do
      nil ->
        []

      %Signal{} = act ->
        undone? =
          Enum.any?(signals, fn s ->
            s.outcome == "overridden" and s.target_type == act.target_type and
              s.target_id == act.target_id
          end)

        pattern = get_pattern(user_id, act.space_id, act.action, target_of(act))

        [
          {message_id,
           %{
             action: act.action,
             space_id: act.space_id,
             target_type: act.target_type,
             target_id: act.target_id,
             undone?: undone?,
             stopped?: stopped?(pattern),
             signal_id: act.id
           }}
        ]
    end
  end

  # ── Settings: list_patterns/1, forget/2 ────────────────────────────────────

  @doc """
  The owner's patterns, grouped by space: `%{space_id | nil => [%Pattern{}]}`,
  each list newest-updated first. `nil` holds the org-level patterns.
  """
  @spec list_patterns(binary()) :: %{(binary() | nil) => [Pattern.t()]}
  def list_patterns(user_id) when is_binary(user_id) do
    owned(:patterns, user_id)
    |> order_by([p], desc: p.updated_at, desc: p.id)
    |> Repo.all()
    |> Enum.group_by(& &1.space_id)
  end

  @doc """
  Deletes one pattern and every signal behind it (same user, space, action
  and target). Owner only: another user's pattern id is `{:error,
  :not_found}`, exactly as a missing one or a malformed id is.

  Returns `{:ok, %{signals: deleted_count}}`.
  """
  @spec forget(term(), term()) :: {:ok, %{signals: non_neg_integer()}} | {:error, :not_found}
  def forget(user_id, pattern_id) do
    if valid_ids?([user_id, pattern_id]),
      do: do_forget(user_id, pattern_id),
      else: {:error, :not_found}
  end

  defp do_forget(user_id, pattern_id) do
    Repo.transaction(fn ->
      case owned(:patterns, user_id) |> where([p], p.id == ^pattern_id) |> Repo.one() do
        nil ->
          Repo.rollback(:not_found)

        %Pattern{} = p ->
          {deleted, _} =
            scoped(:signals, user_id, p.space_id)
            |> where([s], s.action == ^p.action)
            |> where([s], s.target_type == ^p.target_type and s.target_id == ^p.target_id)
            |> Repo.delete_all()

          Repo.delete!(p)
          %{signals: deleted}
      end
    end)
  end

  # ── Retention ──────────────────────────────────────────────────────────────

  @doc """
  Deletes signals older than #{@retention_half_lives} × `half_life_days`
  (§ 8), per user, with the half-life of the variant in force for that
  user. Pattern rows (the ladder state) are kept.

  Options: `:now` (a `DateTime`, default now). Returns `{:ok, deleted}`.
  """
  @spec prune_signals(keyword()) :: {:ok, non_neg_integer()}
  def prune_signals(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    # No variant can prune younger than the minimum half-life (1 day).
    earliest = DateTime.add(now, -@retention_half_lives * @seconds_per_day, :second)

    users =
      from(s in Signal,
        where: s.inserted_at < ^earliest,
        distinct: true,
        select: s.actor_user_id
      )
      |> Repo.all()

    deleted =
      Enum.reduce(users, 0, fn user_id, sum ->
        half_life = variant(user_id)["half_life_days"]
        cutoff = DateTime.add(now, -@retention_half_lives * half_life * @seconds_per_day, :second)

        {n, _} =
          owned(:signals, user_id)
          |> where([s], s.inserted_at < ^cutoff)
          |> Repo.delete_all()

        sum + n
      end)

    {:ok, deleted}
  end

  # ── Query builders ─────────────────────────────────────────────────────────

  # The ONE builder for suggestion-facing reads. Both ids are required; a nil
  # space id matches org-level rows only.
  defp scoped(:signals, user_id, space_id) when is_binary(user_id),
    do: owned(:signals, user_id) |> where_space(space_id)

  defp scoped(:patterns, user_id, space_id) when is_binary(user_id),
    do: owned(:patterns, user_id) |> where_space(space_id)

  defp owned(:signals, user_id) when is_binary(user_id),
    do: from(s in Signal, where: s.actor_user_id == ^user_id)

  defp owned(:patterns, user_id) when is_binary(user_id),
    do: from(p in Pattern, where: p.user_id == ^user_id)

  defp where_space(query, nil), do: where(query, [r], is_nil(r.space_id))
  defp where_space(query, space_id), do: where(query, [r], r.space_id == ^space_id)

  defp get_pattern(user_id, space_id, action, target) do
    scoped(:patterns, user_id, space_id)
    |> where([p], p.action == ^action)
    |> where([p], p.target_type == ^target.target_type and p.target_id == ^target.target_id)
    |> Repo.one()
  end

  # Inserts the pattern row if absent (racing inserts meet on the NULLS NOT
  # DISTINCT tuple index), then reads it back FOR UPDATE.
  defp lock_pattern!(user_id, space_id, action, target) do
    %Pattern{}
    |> Pattern.changeset(
      Map.merge(target, %{user_id: user_id, space_id: space_id, action: action})
    )
    |> Repo.insert!(
      on_conflict: :nothing,
      conflict_target: [:user_id, :space_id, :action, :target_type, :target_id]
    )

    scoped(:patterns, user_id, space_id)
    |> where([p], p.action == ^action)
    |> where([p], p.target_type == ^target.target_type and p.target_id == ^target.target_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  # nil is a legal space id (org-level); anything else must be a UUID, because
  # `where: x.id == ^value` raises Ecto.Query.CastError on a malformed one.
  defp valid_ids?(ids), do: Enum.all?(ids, &(is_nil(&1) or Platform.UUID.valid?(&1)))

  # ── Normalisation ──────────────────────────────────────────────────────────

  defp normalize(attrs) do
    Map.new(@signal_keys, fn key ->
      {key, Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))}
    end)
    |> Map.update!(:rung, &stringify/1)
    |> Map.update!(:outcome, &stringify/1)
  end

  defp normalize_target(target) do
    %{
      target_type: stringify(Map.get(target, :target_type, Map.get(target, "target_type"))),
      target_id: Map.get(target, :target_id, Map.get(target, "target_id"))
    }
  end

  defp target_of(%Signal{target_type: type, target_id: id}),
    do: %{target_type: type, target_id: id}

  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
