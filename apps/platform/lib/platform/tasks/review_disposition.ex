defmodule Platform.Tasks.ReviewDisposition do
  @moduledoc """
  The single seam for the one distinction the bounded review loop turns on
  (task 019ff788 stage 3): did the review gate return a verdict about the
  FEATURE, or did it fail to run at all?

  ## Why the distinction rides in `evidence`

  A review verdict has exactly two expressible statuses. Both
  `Platform.Tasks.evaluate_validation/3` (guard clause `when status in
  ~w(passed failed)`) and `Platform.Tasks.PlanEngine.evaluate_validation/2`
  (raises `ArgumentError` otherwise) hard-restrict to `passed | failed`, and
  a third status would ripple through the stage-advance machinery, the
  kanban renderers and every agent-facing tool description — far wider than
  the loop bound this module exists to serve. So the distinction is carried
  as a MARKER INSIDE the existing `evidence` map on a `failed` validation:

      evidence: %{
        "disposition" => "could_not_evaluate",
        "reason" => "dev server would not boot: <detail>",
        ...
      }

  A `failed` validation carrying that marker still fails its stage — the
  work does not silently proceed — but it does NOT spend a round of the
  bound, and it raises a blocker instead.

  ## Why a reason is REQUIRED

  Without it the marker is a free "don't count this" switch: any reviewer
  that reached for it by habit would make the bound unreachable, which is
  the failure mode the bound exists to prevent. A marker with no non-blank
  `reason` is therefore treated as a GENUINE failure (and logged), so the
  cheap path is the honest one.

  `could_not_evaluate` means the run was IMPOSSIBLE — dev server will not
  boot, a fixture cannot be built, a known flake — not "the feature looks
  wrong". Rowan's rule, and the reason it is load-bearing: a broken
  environment must not burn three rounds and re-plan a feature that was
  never wrong.

  Every consumer of this distinction reads it through this module:
  `Platform.Orchestration.TaskRouter`'s review-failure bounce, and the
  `dispatch.review_e2e` prompt (served row + `HeartbeatScheduler`'s
  hardcoded fallback), which quote `marker/0` and `reason_key/0` verbatim.
  """

  require Logger

  @marker "could_not_evaluate"

  # Deliberately names the READ, not the feature — see `classify_all/1`.
  @empty_set_reason "review stage failed but no failed validation was readable " <>
                      "(read outran the writer's commit); refusing to spend a review round"
  @disposition_key "disposition"
  @reason_key "reason"

  @doc "The `evidence[\"disposition\"]` value that means the gate could not be run."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc "The evidence key carrying the marker."
  @spec disposition_key() :: String.t()
  def disposition_key, do: @disposition_key

  @doc "The evidence key carrying the mandatory human-readable reason."
  @spec reason_key() :: String.t()
  def reason_key, do: @reason_key

  @doc """
  Classify one validation's evidence map.

  Returns `{:could_not_evaluate, reason}` only when the marker is present
  AND a non-blank reason accompanies it; `:malformed` when the marker is
  present without one (caller treats this as `:genuine` and logs); and
  `:genuine` otherwise. Accepts atom- or string-keyed maps — an evidence
  map written in the same process still holds atom keys, while one read
  back from Postgres holds strings.
  """
  @spec classify(map() | nil) :: {:could_not_evaluate, String.t()} | :malformed | :genuine
  def classify(evidence) when is_map(evidence) do
    if fetch(evidence, @disposition_key) == @marker do
      case fetch(evidence, @reason_key) do
        reason when is_binary(reason) ->
          if String.trim(reason) == "", do: :malformed, else: {:could_not_evaluate, reason}

        _ ->
          :malformed
      end
    else
      :genuine
    end
  end

  def classify(_), do: :genuine

  @doc """
  Classify a whole set of failed validations for one gate stage.

  Returns `{:could_not_evaluate, reason}` when EVERY failed validation says
  it could not be evaluated — one real "the feature is wrong" verdict in the
  set means the round was informative and must be spent, so a mixed set
  classifies as `:genuine`.

  ## The empty list is NOT `:genuine` (task 019ff788)

  The only caller is `TaskRouter.handle_review_stage_failure/3`, which runs
  because a review stage FAILED. A failed gate stage has, by construction, at
  least one failed validation. So an empty list here does not mean "nothing
  was un-runnable" — it means the caller READ TOO EARLY and saw rows that had
  not committed yet. It returned `:genuine` until this change, which is how a
  read-timing race became a silent policy violation: a correctly-marked
  un-runnable review spent a round of the bound.

  The proximate cause was fixed upstream (`PlanEngine` now defers the
  `{:stage_transitioned, _}` board broadcast until after its transaction
  commits, so no subscriber can observe pre-commit state). This clause is the
  backstop, and it defaults to the SAFE direction: refuse to classify, log
  loudly, and report `:could_not_evaluate` so the round is not spent and a
  blocker is raised. Spending no round on a review that did happen costs one
  extra bounce; spending a round on a review that could not run is the
  outcome the bound exists to prevent.
  """
  @spec classify_all([%{optional(:evidence) => map() | nil}]) ::
          {:could_not_evaluate, String.t()} | :malformed | :genuine
  def classify_all([]) do
    Logger.warning(
      "[ReviewDisposition] asked to classify an EMPTY failed-validation set for a " <>
        "failed review stage. A failed gate stage always has a failed validation, so " <>
        "this is a read that outran the writer's commit — not evidence about the " <>
        "feature. Refusing to classify; reporting could_not_evaluate so no review " <>
        "round is spent."
    )

    {:could_not_evaluate, @empty_set_reason}
  end

  def classify_all(validations) when is_list(validations) do
    results = Enum.map(validations, fn v -> classify(Map.get(v, :evidence)) end)

    cond do
      Enum.any?(results, &(&1 == :genuine)) -> :genuine
      Enum.any?(results, &(&1 == :malformed)) -> :malformed
      true -> Enum.find(results, :genuine, &match?({:could_not_evaluate, _}, &1))
    end
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_existing_atom(key))
    end
  rescue
    ArgumentError -> nil
  end
end
