defmodule Platform.Secretary.Submit do
  @moduledoc """
  Takes a model answer for one batch and writes it, or refuses all of it
  (task 01a1b721 stage 3 item 4). Deterministic; the only caller is core's
  own batch pass (`Platform.Secretary.Pass`), never a tool.

  ## Validation, before anything is written

    * the answer is an object with an `evaluations` list (and optional
      `brief`, `todos_suggested`, `todos_done` lists);
    * EVERY `{ref_type, ref_id}` in `evaluations`, `brief` and
      `todos_suggested` is one of `batch.item_refs`, and no ref is evaluated
      twice;
    * every `todos_done` id is a to-do of `batch.user_id` that is IN the
      batch;
    * every tag is in `Platform.Secretary.Evaluation.tags/0`, every brief tag
      in `brief_tags/0` (or null), every `group_key` is one of the person's
      goal keys or `"none"`;
    * the brief has at most `brief_max_lines` lines and each names an
      evaluated ref.

  Any failure rejects the WHOLE answer: the batch is `rejected`, nothing of
  the answer is persisted, and the batch's refs get the fallback with
  `failed_attempts + 1` (`Platform.Secretary.Fallback`).

  ## Then, in one transaction

  Reasons and lines are truncated; evaluations are upserted (the store keeps
  `previous_tag`); the person's brief is replaced (brief fields cleared on
  their other evaluations); the person's feedback is applied
  (`Platform.Secretary.Overrides`); heard to-dos go through
  `Platform.Secretary.Todos.suggest/2`, whose participant rule still holds (a
  refused suggestion is skipped, not an error); done to-dos are marked done
  with their reason. The batch becomes `submitted`, and
  `{:secretary_updated, user_id}` is broadcast on
  `Platform.Secretary.topic/1`.
  """

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Secretary
  alias Platform.Secretary.{Batch, Evaluation, Fallback, Overrides, Settings, Store, Todos}

  @reason_cap 200
  @line_cap 300
  @label_cap 40

  @doc """
  Validates and writes `parsed` (a decoded JSON answer) for `batch`.

  Options: `:goal_keys` (the person's goal keys; default read from
  `Platform.Secretary.Context`), `:brief_max_lines` (default 5),
  `:model_version` (required: the host's `host:<agent_id>:<harness>`),
  `:settings` (default the person's), `:actual_tokens`, `:now`.

  The person's `family_placement` setting is applied last: `list_only`
  keeps family items out of the brief, `off` makes them quiet.

  `{:ok, %{evaluations: n, todos_suggested: n, todos_done: n}}` or
  `{:error, {:rejected, reason}}`.
  """
  @spec apply(Batch.t(), term(), keyword()) ::
          {:ok, map()} | {:error, {:rejected, term()}}
  def apply(%Batch{} = batch, parsed, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, answer} <- validate(batch, parsed, opts),
         {:ok, summary} <- persist(batch, answer, opts, now) do
      finish(batch, "submitted", opts, now)
      Secretary.broadcast_updated(batch.user_id)
      {:ok, summary}
    else
      {:error, reason} ->
        finish(batch, "rejected", opts, now)

        Fallback.apply(batch.user_id, batch.item_refs,
          batch_id: batch.id,
          failed?: true,
          now: now
        )

        Secretary.broadcast_updated(batch.user_id)
        {:error, {:rejected, reason}}
    end
  end

  # ── validation ──────────────────────────────────────────────────────────

  @doc false
  @spec validate(Batch.t(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate(%Batch{} = batch, %{"evaluations" => evals} = parsed, opts) when is_list(evals) do
    refs = Map.new(batch.item_refs, &{ref_key(&1), &1})
    goal_keys = MapSet.new(["none" | goal_keys(batch.user_id, opts)])
    brief_max = Keyword.get(opts, :brief_max_lines, 5)

    with {:ok, brief} <- list(parsed, "brief"),
         {:ok, suggested} <- list(parsed, "todos_suggested"),
         {:ok, done} <- list(parsed, "todos_done"),
         {:ok, evaluations} <- evaluations(evals, refs, goal_keys),
         {:ok, brief} <- brief(brief, refs, evaluations, brief_max),
         {:ok, suggested} <- suggested(suggested, refs),
         {:ok, done} <- done(done, refs, batch.user_id) do
      {:ok, %{evaluations: evaluations, brief: brief, suggested: suggested, done: done}}
    end
  end

  def validate(_batch, _parsed, _opts), do: {:error, :not_an_answer}

  defp list(parsed, key) do
    case Map.get(parsed, key) do
      nil -> {:ok, []}
      list when is_list(list) -> {:ok, list}
      _ -> {:error, {:not_a_list, key}}
    end
  end

  defp evaluations(evals, refs, goal_keys) do
    Enum.reduce_while(evals, {:ok, %{}}, fn e, {:ok, acc} ->
      key = ref_key(e)

      cond do
        not is_map(e) -> {:halt, {:error, :evaluation_not_an_object}}
        not Map.has_key?(refs, key) -> {:halt, {:error, {:ref_outside_batch, key}}}
        Map.has_key?(acc, key) -> {:halt, {:error, {:evaluated_twice, key}}}
        e["tag"] not in Evaluation.tags() -> {:halt, {:error, {:bad_tag, e["tag"]}}}
        not MapSet.member?(goal_keys, e["group_key"] || "none") -> {:halt, {:error, :bad_group}}
        true -> {:cont, {:ok, Map.put(acc, key, e)}}
      end
    end)
  end

  defp brief(lines, _refs, _evals, max) when length(lines) > max,
    do: {:error, {:brief_too_long, length(lines)}}

  defp brief(lines, refs, evals, _max) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      key = ref_key(line)

      cond do
        not is_map(line) -> {:halt, {:error, :brief_not_an_object}}
        not Map.has_key?(refs, key) -> {:halt, {:error, {:ref_outside_batch, key}}}
        not Map.has_key?(evals, key) -> {:halt, {:error, {:brief_not_evaluated, key}}}
        not is_binary(line["line"]) -> {:halt, {:error, :brief_without_line}}
        line["tag"] not in [nil | Evaluation.brief_tags()] -> {:halt, {:error, :bad_brief_tag}}
        true -> {:cont, {:ok, acc ++ [line]}}
      end
    end)
  end

  defp suggested(list, refs) do
    Enum.reduce_while(list, {:ok, []}, fn s, {:ok, acc} ->
      key = ref_key(s)

      cond do
        not is_map(s) ->
          {:halt, {:error, :suggestion_not_an_object}}

        not Map.has_key?(refs, key) ->
          {:halt, {:error, {:ref_outside_batch, key}}}

        not (is_binary(s["title"]) and String.trim(s["title"]) != "") ->
          {:halt, {:error, :untitled}}

        true ->
          {:cont, {:ok, acc ++ [s]}}
      end
    end)
  end

  defp done(list, refs, user_id) do
    Enum.reduce_while(list, {:ok, []}, fn d, {:ok, acc} ->
      id = is_map(d) && d["id"]

      cond do
        not is_binary(id) ->
          {:halt, {:error, :done_without_id}}

        not Map.has_key?(refs, {"todo", id}) ->
          {:halt, {:error, {:todo_outside_batch, id}}}

        Todos.get(user_id, id) == nil ->
          {:halt, {:error, {:not_the_persons_todo, id}}}

        true ->
          {:cont, {:ok, acc ++ [d]}}
      end
    end)
  end

  defp ref_key(%{"ref_type" => type, "ref_id" => id}), do: {type, id}
  defp ref_key(_), do: nil

  defp goal_keys(user_id, opts) do
    Keyword.get_lazy(opts, :goal_keys, fn ->
      case Platform.Accounts.get_user(user_id) do
        nil -> []
        user -> Enum.map(Platform.Secretary.Context.for_user(user).goals, & &1.key)
      end
    end)
  end

  # ── persistence ─────────────────────────────────────────────────────────

  defp persist(batch, answer, opts, now) do
    user_id = batch.user_id
    refs = Map.new(batch.item_refs, &{ref_key(&1), &1})
    model_version = Keyword.fetch!(opts, :model_version)

    brief =
      answer.brief
      |> Enum.with_index(1)
      |> Map.new(fn {line, i} -> {ref_key(line), {i, line}} end)

    rows =
      answer.evaluations
      |> Enum.map(fn {key, e} ->
        ref = Map.fetch!(refs, key)
        {brief_rank, line} = Map.get(brief, key, {nil, %{}})

        %{
          "ref_type" => ref["ref_type"],
          "ref_id" => ref["ref_id"],
          "kind_key" => ref["kind_key"],
          "tag" => e["tag"],
          "group_key" => e["group_key"] || "none",
          "reason" => cap(e["reason"], @reason_cap),
          "rank" => int(e["rank"]),
          "family" => e["family"] == true,
          "needs_you_now" => e["needs_you_now"] == true,
          "deadline_at" => datetime(e["deadline_at"]),
          "brief_rank" => brief_rank,
          "brief_line" => cap(line["line"], @line_cap),
          "brief_action_label" => cap(line["action_label"], @label_cap),
          "brief_tag" => line["tag"],
          "model_version" => model_version,
          "batch_id" => batch.id,
          "failed_attempts" => 0,
          "evaluated_at" => now
        }
      end)
      |> Enum.sort_by(&{&1["rank"] || 1_000_000, &1["ref_id"]})

    rows =
      user_id
      |> Overrides.apply(rows)
      |> family_placement(Keyword.get_lazy(opts, :settings, fn -> Settings.get(user_id) end))

    Repo.transaction(fn ->
      keep = for r <- rows, r["brief_rank"], do: r["ref_id"]

      from(e in Evaluation,
        where: e.user_id == ^user_id and not is_nil(e.brief_rank) and e.ref_id not in ^keep
      )
      |> Repo.update_all(
        set: [brief_rank: nil, brief_line: nil, brief_action_label: nil, brief_tag: nil]
      )

      Enum.each(rows, fn attrs ->
        case Store.upsert_evaluation(user_id, attrs) do
          {:ok, _} -> :ok
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

      suggested =
        Enum.count(answer.suggested, fn s ->
          ref = Map.fetch!(refs, ref_key(s))

          match?(
            {:ok, _},
            Todos.suggest(user_id, %{
              "title" => cap(s["title"], 500),
              "source_ref_type" => ref["ref_type"],
              "source_ref_id" => ref["ref_id"],
              "source_space_id" => ref["space_id"],
              "source_quote" => cap(s["quote"], 2_000)
            })
          )
        end)

      done =
        Enum.count(answer.done, fn d ->
          match?({:ok, _}, Todos.mark_done(user_id, d["id"], cap(d["reason"], 255)))
        end)

      %{evaluations: length(rows), todos_suggested: suggested, todos_done: done}
    end)
  end

  # The person's family placement (Settings): "list_only" keeps family items
  # out of the brief, "off" keeps them quiet. Family items never nudge
  # anyone but the person, so needs_you_now is left to the model.
  defp family_placement(rows, %{"family_placement" => "brief_and_list"}), do: rows

  defp family_placement(rows, %{"family_placement" => placement}) do
    Enum.map(rows, fn
      %{"family" => true} = row ->
        row =
          Map.merge(row, %{
            "brief_rank" => nil,
            "brief_line" => nil,
            "brief_action_label" => nil,
            "brief_tag" => nil
          })

        if placement == "off",
          do: Map.merge(row, %{"tag" => "quiet", "needs_you_now" => false}),
          else: row

      row ->
        row
    end)
  end

  defp family_placement(rows, _settings), do: rows

  defp finish(batch, status, opts, now) do
    attrs = %{status: status, finished_at: now}

    attrs =
      case Keyword.get(opts, :actual_tokens) do
        n when is_integer(n) -> Map.put(attrs, :actual_tokens, n)
        _ -> attrs
      end

    Store.finish_batch(batch.user_id, batch.id, attrs)
  end

  defp cap(nil, _), do: nil
  defp cap(text, max) when is_binary(text), do: String.slice(text, 0, max)
  defp cap(_other, _), do: nil

  defp int(n) when is_integer(n), do: n
  defp int(_), do: nil

  defp datetime(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp datetime(_), do: nil
end
