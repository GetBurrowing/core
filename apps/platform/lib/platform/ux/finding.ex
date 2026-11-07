defmodule Platform.Ux.Finding do
  @moduledoc """
  One question the UX friction watch (`ux.friction_watch`, which joins the designer bundle with its handler in stage 2)
  puts to one human. Task `01a1af00-86ac-7000-94ba-a121d5cb8116` stage 1.

  ## Fields

    * `org_id` / `workspace_id` — the scope the friction was seen in.
    * `recipient_user_id` — the one human asked.
    * `question` — the ask, a single question ending in `?`.
    * `kind` — `decision` (pick an option) or `fyi` (no choice owed).
    * `evidence` — `%{"count" => n, "quotes" => [..], "citations" => [..]}`:
      how many times the friction was seen (`n >= 1`), at most two verbatim
      quotes, and source citations of the form `chat:<space_id>:<message_id>`.
    * `options` — at most three `%{"label", "recommended", "detail"}` maps,
      EXACTLY one with `"recommended" => true`. A `decision` needs at least
      one option; an `fyi` may carry none, but if it carries any, the
      one-recommended rule still holds.
    * `mockup_refs` — `%{"before" => ref, "after" => ref}`, either nil.
    * `status` — `open | answered | dismissed`; `answer` is required once
      `answered`.
    * `task_id` — the filed task this finding asks about, nullable.
    * `group_key` — the friction cluster; one OPEN finding per recipient and
      group (partial unique index `ux_findings_open_group_index`).
    * `variant` — the `ux.friction_detection` experiment arm that produced it,
      nil for the control. `Platform.Experiments.Metrics.UxFindingKeepRate`
      reads it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(decision fyi)
  @statuses ~w(open answered dismissed)
  @max_options 3
  @max_quotes 2
  @citation ~r/\Achat:[0-9a-fA-F-]{36}:[0-9a-fA-F-]{36}\z/

  @type t :: %__MODULE__{}

  schema "ux_findings" do
    field(:org_id, :binary_id)
    field(:workspace_id, :binary_id)
    field(:recipient_user_id, :binary_id)
    field(:question, :string)
    field(:kind, :string)
    field(:evidence, :map, default: %{})
    field(:options, {:array, :map}, default: [])
    field(:mockup_refs, :map, default: %{})
    field(:status, :string, default: "open")
    field(:answer, :string)
    field(:task_id, :binary_id)
    field(:group_key, :string)
    field(:variant, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The finding kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The finding statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The most options a finding may offer."
  @spec max_options() :: pos_integer()
  def max_options, do: @max_options

  @doc "Builds the source citation for one chat message."
  @spec citation(String.t(), String.t()) :: String.t()
  def citation(space_id, message_id), do: "chat:#{space_id}:#{message_id}"

  @cast ~w(org_id workspace_id recipient_user_id question kind evidence options
           mockup_refs status answer task_id group_key variant)a
  @required ~w(recipient_user_id question kind group_key)a

  @doc "Changeset for a new or updated finding. Enforces every shape rule."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = finding, attrs) do
    finding
    |> cast(attrs, @cast)
    |> update_change(:evidence, &stringify/1)
    |> update_change(:mockup_refs, &stringify/1)
    |> update_change(:options, fn opts -> Enum.map(opts, &stringify/1) end)
    |> validate_required(@required)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_question()
    |> validate_evidence()
    |> validate_options()
    |> validate_mockup_refs()
    |> validate_answer()
    |> check_constraint(:kind, name: :ux_findings_kind_check)
    |> check_constraint(:status, name: :ux_findings_status_check)
    |> unique_constraint([:recipient_user_id, :group_key],
      name: :ux_findings_open_group_index,
      message: "already has an open finding for this group"
    )
    |> foreign_key_constraint(:recipient_user_id)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:org_id)
  end

  @doc "Changeset recording a human's answer or dismissal."
  @spec resolve_changeset(t(), String.t(), String.t() | nil) :: Ecto.Changeset.t()
  def resolve_changeset(%__MODULE__{} = finding, status, answer \\ nil)
      when status in ["answered", "dismissed"] do
    changeset(finding, %{status: status, answer: answer})
  end

  # Elixir callers pass atom keys; every rule and every reader uses strings.
  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp validate_question(changeset) do
    validate_change(changeset, :question, fn :question, q ->
      if String.ends_with?(String.trim(q), "?"),
        do: [],
        else: [question: "must be a question ending in \"?\""]
    end)
  end

  defp validate_evidence(changeset) do
    evidence = get_field(changeset, :evidence) || %{}
    count = evidence["count"]
    quotes = Map.get(evidence, "quotes", [])
    citations = Map.get(evidence, "citations", [])

    [
      not (is_integer(count) and count >= 1) && "count must be a positive integer",
      not (is_list(quotes) and Enum.all?(quotes, &is_binary/1)) && "quotes must be strings",
      (is_list(quotes) and length(quotes) > @max_quotes) && "at most #{@max_quotes} quotes",
      not (is_list(citations) and Enum.all?(citations, &valid_citation?/1)) &&
        "citations must be chat:<space_id>:<message_id>"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.reduce(changeset, &add_error(&2, :evidence, &1))
  end

  defp valid_citation?(c), do: is_binary(c) and Regex.match?(@citation, c)

  defp validate_options(changeset) do
    options = get_field(changeset, :options) || []
    kind = get_field(changeset, :kind)
    recommended = Enum.count(options, &(Map.get(&1, "recommended") == true))

    [
      length(options) > @max_options && "at most #{@max_options} options",
      not Enum.all?(options, &valid_option?/1) && "each option needs a non-blank label",
      (kind == "decision" and options == []) && "a decision needs at least one option",
      (options != [] and recommended != 1) && "exactly one option must be recommended"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.reduce(changeset, &add_error(&2, :options, &1))
  end

  defp valid_option?(%{"label" => label}) when is_binary(label), do: String.trim(label) != ""
  defp valid_option?(_), do: false

  defp validate_mockup_refs(changeset) do
    refs = get_field(changeset, :mockup_refs) || %{}
    unknown = refs |> Map.keys() |> Enum.reject(&(&1 in ["before", "after"]))
    bad = Enum.reject(Map.values(refs), &(is_nil(&1) or is_binary(&1)))

    cond do
      unknown != [] -> add_error(changeset, :mockup_refs, "only before and after are allowed")
      bad != [] -> add_error(changeset, :mockup_refs, "refs must be strings or nil")
      true -> changeset
    end
  end

  defp validate_answer(changeset) do
    if get_field(changeset, :status) == "answered" do
      validate_required(changeset, [:answer])
    else
      changeset
    end
  end
end
