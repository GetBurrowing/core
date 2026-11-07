defmodule Platform.Secretary.Store do
  @moduledoc """
  The triage agent's store for evaluations, feedback, batches and reach-outs
  (task 01a1b721 stage 1). The person's own list is `Platform.Secretary.Todos`.

  ## Every read is the viewer's own

  Every public function takes the VIEWER's `user_id` first and filters on it.
  There is no function here that lists, or fetches by id, a row belonging to
  someone else: an id owned by another person reads as missing. A malformed
  id reads as missing too, never as a cast error.
  """

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Secretary.{Batch, Evaluation, Feedback, Reachout}

  # ── Batches ─────────────────────────────────────────────────────────────

  @doc "Records a dispatched batch for `user_id`."
  @spec create_batch(binary(), map()) :: {:ok, Batch.t()} | {:error, Ecto.Changeset.t()}
  def create_batch(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("user_id", user_id)
      |> Map.put_new("dispatched_at", DateTime.utc_now())

    %Batch{} |> Batch.changeset(attrs) |> Repo.insert()
  end

  @doc "Sets a batch's outcome. `{:error, :not_found}` for another person's batch."
  @spec finish_batch(binary(), binary(), map()) ::
          {:ok, Batch.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def finish_batch(user_id, batch_id, attrs) when is_map(attrs) do
    case get_batch(user_id, batch_id) do
      nil ->
        {:error, :not_found}

      %Batch{} = batch ->
        attrs =
          attrs
          |> Map.new(fn {k, v} -> {to_string(k), v} end)
          |> Map.take(~w(status actual_tokens finished_at))
          |> Map.put_new("finished_at", DateTime.utc_now())

        batch |> Batch.changeset(attrs) |> Repo.update()
    end
  end

  @doc "One of the viewer's batches, or nil."
  @spec get_batch(binary(), binary()) :: Batch.t() | nil
  def get_batch(user_id, batch_id) do
    if ids_valid?([user_id, batch_id]),
      do: Repo.one(from(b in Batch, where: b.id == ^batch_id and b.user_id == ^user_id))
  end

  @doc "The viewer's batches, newest first. Options: `:status`, `:limit` (default 50)."
  @spec list_batches(binary(), keyword()) :: [Batch.t()]
  def list_batches(user_id, opts \\ []) do
    if ids_valid?([user_id]) do
      from(b in Batch, where: b.user_id == ^user_id, order_by: [desc: b.inserted_at, desc: b.id])
      |> maybe_where(:status, Keyword.get(opts, :status))
      |> limit(^Keyword.get(opts, :limit, 50))
      |> Repo.all()
    else
      []
    end
  end

  # ── Evaluations ─────────────────────────────────────────────────────────

  @doc """
  Writes the viewer's verdict on one item, replacing any earlier one for the
  same `(ref_type, ref_id)` and keeping its tag as `previous_tag`.
  """
  @spec upsert_evaluation(binary(), map()) ::
          {:ok, Evaluation.t()} | {:error, Ecto.Changeset.t()}
  def upsert_evaluation(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("user_id", user_id)
      |> Map.put_new("evaluated_at", DateTime.utc_now())

    Repo.transaction(fn ->
      existing =
        case attrs do
          %{"ref_type" => type, "ref_id" => id} when is_binary(type) and is_binary(id) ->
            if ids_valid?([id]),
              do:
                Repo.one(
                  from(e in Evaluation,
                    where: e.user_id == ^user_id and e.ref_type == ^type and e.ref_id == ^id,
                    lock: "FOR UPDATE"
                  )
                )

          _ ->
            nil
        end

      result =
        case existing do
          nil ->
            %Evaluation{} |> Evaluation.changeset(attrs) |> Repo.insert()

          %Evaluation{tag: old_tag} = row ->
            attrs = Map.put_new(attrs, "previous_tag", old_tag)
            row |> Evaluation.changeset(attrs) |> Repo.update()
        end

      case result do
        {:ok, evaluation} -> evaluation
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc "The viewer's evaluation of one item, or nil."
  @spec get_evaluation(binary(), String.t(), binary()) :: Evaluation.t() | nil
  def get_evaluation(user_id, ref_type, ref_id) when is_binary(ref_type) do
    if ids_valid?([user_id, ref_id]),
      do:
        Repo.one(
          from(e in Evaluation,
            where: e.user_id == ^user_id and e.ref_type == ^ref_type and e.ref_id == ^ref_id
          )
        )
  end

  @doc """
  The viewer's evaluations, best rank first then newest. Options: `:tag`,
  `:limit` (default 200).
  """
  @spec list_evaluations(binary(), keyword()) :: [Evaluation.t()]
  def list_evaluations(user_id, opts \\ []) do
    if ids_valid?([user_id]) do
      from(e in Evaluation,
        where: e.user_id == ^user_id,
        order_by: [asc_nulls_last: e.rank, desc: e.evaluated_at, desc: e.id]
      )
      |> maybe_where(:tag, Keyword.get(opts, :tag))
      |> limit(^Keyword.get(opts, :limit, 200))
      |> Repo.all()
    else
      []
    end
  end

  # ── Feedback ────────────────────────────────────────────────────────────

  @doc "Records a piece of the viewer's feedback."
  @spec record_feedback(binary(), map()) :: {:ok, Feedback.t()} | {:error, Ecto.Changeset.t()}
  def record_feedback(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    attrs = attrs |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.put("user_id", user_id)
    %Feedback{} |> Feedback.changeset(attrs) |> Repo.insert()
  end

  @doc "The viewer's feedback, newest first. Options: `:kind_key`, `:action`, `:limit` (200)."
  @spec list_feedback(binary(), keyword()) :: [Feedback.t()]
  def list_feedback(user_id, opts \\ []) do
    if ids_valid?([user_id]) do
      from(f in Feedback,
        where: f.user_id == ^user_id,
        order_by: [desc: f.inserted_at, desc: f.id]
      )
      |> maybe_where(:kind_key, Keyword.get(opts, :kind_key))
      |> maybe_where(:action, Keyword.get(opts, :action))
      |> limit(^Keyword.get(opts, :limit, 200))
      |> Repo.all()
    else
      []
    end
  end

  @doc """
  Has the viewer asked to hide `kind_key`? True when their latest
  `hide_kind` or `undo` for that kind is a `hide_kind`.
  """
  @spec hidden_kind?(binary(), String.t()) :: boolean()
  def hidden_kind?(user_id, kind_key) when is_binary(kind_key) do
    ids_valid?([user_id]) and
      Repo.one(
        from(f in Feedback,
          where:
            f.user_id == ^user_id and f.kind_key == ^kind_key and
              f.action in ["hide_kind", "undo"],
          order_by: [desc: f.inserted_at, desc: f.id],
          limit: 1,
          select: f.action
        )
      ) == "hide_kind"
  end

  # ── Reach-outs ──────────────────────────────────────────────────────────

  @doc """
  Records a reach-out (or a hold) on one of the viewer's evaluations. A
  second record of the same kind is a no-op returning `{:ok, :duplicate}`;
  an evaluation that is not the viewer's is `{:error, :not_found}`.
  """
  @spec record_reachout(binary(), binary(), String.t(), map()) ::
          {:ok, Reachout.t() | :duplicate} | {:error, :not_found | Ecto.Changeset.t()}
  def record_reachout(user_id, evaluation_id, kind, attrs \\ %{}) when is_binary(kind) do
    if owns_evaluation?(user_id, evaluation_id) do
      attrs =
        attrs
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.merge(%{"user_id" => user_id, "evaluation_id" => evaluation_id, "kind" => kind})
        |> Map.put_new("at", DateTime.utc_now())

      changeset = Reachout.changeset(%Reachout{}, attrs)

      case Repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: [:user_id, :evaluation_id, :kind]
           ) do
        # The id is generated client-side, so a skipped insert still carries
        # one: the stored row decides whether this call wrote it.
        {:ok, %Reachout{id: id}} ->
          stored =
            Repo.one!(
              from(r in Reachout,
                where:
                  r.user_id == ^user_id and r.evaluation_id == ^evaluation_id and
                    r.kind == ^kind
              )
            )

          if stored.id == id, do: {:ok, stored}, else: {:ok, :duplicate}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      {:error, :not_found}
    end
  end

  @doc "The viewer's reach-outs, newest first. Options: `:evaluation_id`, `:kind`, `:since`, `:limit` (200)."
  @spec list_reachouts(binary(), keyword()) :: [Reachout.t()]
  def list_reachouts(user_id, opts \\ []) do
    if ids_valid?([user_id]) do
      query =
        from(r in Reachout, where: r.user_id == ^user_id, order_by: [desc: r.at, desc: r.id])
        |> maybe_where(:kind, Keyword.get(opts, :kind))

      query =
        case Keyword.get(opts, :evaluation_id) do
          nil ->
            query

          id ->
            if ids_valid?([id]),
              do: where(query, [r], r.evaluation_id == ^id),
              else: where(query, false)
        end

      query =
        case Keyword.get(opts, :since) do
          %DateTime{} = since -> where(query, [r], r.at >= ^since)
          _ -> query
        end

      query |> limit(^Keyword.get(opts, :limit, 200)) |> Repo.all()
    else
      []
    end
  end

  defp owns_evaluation?(user_id, evaluation_id) do
    ids_valid?([user_id, evaluation_id]) and
      Repo.exists?(from(e in Evaluation, where: e.id == ^evaluation_id and e.user_id == ^user_id))
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp maybe_where(query, _field, nil), do: query
  defp maybe_where(query, field, value), do: where(query, [r], field(r, ^field) == ^value)

  defp ids_valid?(ids), do: Enum.all?(ids, &(is_binary(&1) and Platform.UUID.valid?(&1)))
end
