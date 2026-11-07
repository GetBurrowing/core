defmodule Platform.Secretary.Todos do
  @moduledoc """
  A person's own list (task 01a1b721 stage 1, folding task 01a1b714).

    * `add_own/3` — something they added themselves (`origin: "self"`,
      straight to `kept`).
    * `suggest/2` — something heard in a room (`origin: "heard"`, status
      `suggested`). Deduplicated on `sha256(normalised title + source ref)`
      with an `on_conflict: :nothing` insert on `(user_id, dedupe_key)`, so a
      re-run that hears the same thing again adds nothing.
    * `keep/2`, `edit/3`, `dismiss/2` (records `not_a_todo` feedback),
      `mark_done/3` (with a reason), `undo/2`.

  ## Only rooms you are in

  `suggest/2` refuses a source space the person is not a PARTICIPANT of.
  That is stricter than readable: an open channel they can read but never
  joined is not where their to-dos come from.

  ## Private

  Every function takes the viewer's `user_id` and filters on it. Another
  person's entry reads as `{:error, :not_found}`; there is no way to list
  someone else's list.
  """

  import Ecto.Query

  alias Platform.Chat.Participant
  alias Platform.Repo
  alias Platform.Secretary.{Store, Todo}

  @editable ~w(title due_on goal_key)
  @open_statuses ~w(suggested kept)

  @doc "Adds an entry the viewer wrote. Options: `:due_on`, `:goal_key`."
  @spec add_own(binary(), String.t(), keyword()) :: {:ok, Todo.t()} | {:error, term()}
  def add_own(user_id, title, opts \\ []) when is_binary(title) do
    if valid_id?(user_id) do
      %Todo{}
      |> Todo.changeset(%{
        user_id: user_id,
        title: title,
        origin: "self",
        status: "kept",
        due_on: Keyword.get(opts, :due_on),
        goal_key: Keyword.get(opts, :goal_key),
        dedupe_key: "self:" <> Ecto.UUID.generate()
      })
      |> Repo.insert()
    else
      {:error, :not_found}
    end
  end

  @doc """
  Suggests an entry heard in a room. `attrs`: `title`, `source_space_id`
  (required), `source_ref_type`, `source_ref_id`, `source_quote`,
  `goal_key`, `due_on`.

  `{:error, :not_a_participant}` unless the viewer is a participant of the
  source space. A duplicate returns the existing row.
  """
  @spec suggest(binary(), map()) :: {:ok, Todo.t()} | {:error, term()}
  def suggest(user_id, attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    space_id = attrs["source_space_id"]

    cond do
      not valid_id?(user_id) ->
        {:error, :not_found}

      not participant?(user_id, space_id) ->
        {:error, :not_a_participant}

      true ->
        key = dedupe_key(attrs["title"], attrs["source_ref_type"], attrs["source_ref_id"])

        changeset =
          Todo.changeset(
            %Todo{},
            attrs
            |> Map.take(
              ~w(title source_ref_type source_ref_id source_space_id source_quote goal_key due_on)
            )
            |> Map.merge(%{
              "user_id" => user_id,
              "origin" => "heard",
              "status" => "suggested",
              "dedupe_key" => key
            })
          )

        case Repo.insert(changeset,
               on_conflict: :nothing,
               conflict_target: [:user_id, :dedupe_key]
             ) do
          {:ok, %Todo{id: nil}} ->
            {:ok,
             Repo.one!(from(t in Todo, where: t.user_id == ^user_id and t.dedupe_key == ^key))}

          other ->
            other
        end
    end
  end

  @doc "The dedupe key: sha256 of the normalised title and the source ref."
  @spec dedupe_key(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t()
  def dedupe_key(title, ref_type, ref_id) do
    normalised =
      (title || "")
      |> String.downcase()
      |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
      |> String.trim()

    :crypto.hash(:sha256, Enum.join([normalised, ref_type || "", ref_id || ""], "|"))
    |> Base.encode16(case: :lower)
  end

  @doc "Keeps a suggestion."
  @spec keep(binary(), binary()) :: {:ok, Todo.t()} | {:error, term()}
  def keep(user_id, id), do: update_owned(user_id, id, %{status: "kept"})

  @doc "Edits the title, due date or goal of the viewer's entry."
  @spec edit(binary(), binary(), map()) :: {:ok, Todo.t()} | {:error, term()}
  def edit(user_id, id, attrs) when is_map(attrs) do
    attrs = attrs |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.take(@editable)
    update_owned(user_id, id, attrs)
  end

  @doc "Dismisses an entry and records `not_a_todo` feedback for it."
  @spec dismiss(binary(), binary()) :: {:ok, Todo.t()} | {:error, term()}
  def dismiss(user_id, id) do
    Repo.transaction(fn ->
      with {:ok, todo} <- update_owned(user_id, id, %{status: "dismissed"}),
           {:ok, _} <-
             Store.record_feedback(user_id, %{
               ref_type: "todo",
               ref_id: todo.id,
               kind_key: "todo:" <> todo.origin,
               action: "not_a_todo"
             }) do
        todo
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Marks an entry done, with the reason it is done."
  @spec mark_done(binary(), binary(), String.t() | nil) :: {:ok, Todo.t()} | {:error, term()}
  def mark_done(user_id, id, reason \\ nil),
    do: update_owned(user_id, id, %{status: "done", done_reason: reason})

  @doc """
  Undoes a dismissal or a done: a heard entry goes back to `suggested`, the
  viewer's own back to `kept`. Records `undo` feedback.
  """
  @spec undo(binary(), binary()) :: {:ok, Todo.t()} | {:error, term()}
  def undo(user_id, id) do
    Repo.transaction(fn ->
      with %Todo{} = todo <- get(user_id, id),
           status =
             if(todo.origin == "heard" and todo.status == "dismissed",
               do: "suggested",
               else: "kept"
             ),
           {:ok, todo} <- update_owned(user_id, id, %{status: status, done_reason: nil}),
           {:ok, _} <-
             Store.record_feedback(user_id, %{
               ref_type: "todo",
               ref_id: todo.id,
               kind_key: "todo:" <> todo.origin,
               action: "undo"
             }) do
        todo
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "One of the viewer's entries, or nil."
  @spec get(binary(), binary()) :: Todo.t() | nil
  def get(user_id, id) do
    if valid_id?(user_id) and valid_id?(id),
      do: Repo.one(from(t in Todo, where: t.id == ^id and t.user_id == ^user_id))
  end

  @doc """
  The viewer's list. Options: `:statuses` (default `suggested` and `kept`),
  `:limit` (default 200). Kept first, then by due date, then newest.
  """
  @spec list(binary(), keyword()) :: [Todo.t()]
  def list(user_id, opts \\ []) do
    if valid_id?(user_id) do
      statuses = Keyword.get(opts, :statuses, @open_statuses)

      from(t in Todo,
        where: t.user_id == ^user_id and t.status in ^statuses,
        order_by: [
          desc: t.status == "kept",
          asc_nulls_last: t.due_on,
          desc: t.inserted_at,
          desc: t.id
        ],
        limit: ^Keyword.get(opts, :limit, 200)
      )
      |> Repo.all()
    else
      []
    end
  end

  defp update_owned(user_id, id, attrs) do
    case get(user_id, id) do
      nil -> {:error, :not_found}
      todo -> todo |> Todo.changeset(attrs) |> Repo.update()
    end
  end

  defp participant?(user_id, space_id) do
    valid_id?(space_id) and
      Repo.exists?(
        from(p in Participant,
          where:
            p.space_id == ^space_id and p.participant_type == "user" and
              p.participant_id == ^user_id
        )
      )
  end

  defp valid_id?(id), do: is_binary(id) and Platform.UUID.valid?(id)
end
