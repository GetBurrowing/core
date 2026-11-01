defmodule Platform.Onboarding.FirstRunGoal do
  @moduledoc """
  The first-run "What do you want to do?" goal box (task 01a19554-fd07,
  stage 1). A new member types a goal once; it is posted into a DM with the
  install's Burrow agent, which takes it from there.

  ## State

  One key in `users.preferences`: `"first_run_goal"`. Its values:

    * `"submitted"` — the goal was posted to Burrow.
    * `"skipped"` — the member dismissed the box.
    * `"existing"` — the member predates this feature (backfilled by
      migration `20261101050000_backfill_first_run_goal_for_existing_users`).
    * `"submitting"` — a submit is in flight. It is the claim that makes a
      double submit post once; a failed post removes it again.

  A member is pending only while the key is ABSENT. Any value, including one
  this module does not know, means "not pending".

  ## Writes are single-key and atomic

  `users.preferences` is shared JSONB: the theme preference lives in the same
  map. `Platform.Accounts.update_user_preference/3` reads the user and writes
  back the WHOLE map, so two concurrent writers of different keys can clobber
  each other. Every write here is one `UPDATE ... SET preferences =
  COALESCE(preferences, '{}') || jsonb_build_object(key, value)` (or `- key`),
  which touches only this key and never reads the map into the BEAM.

  ## Burrow

  This module only FINDS the Burrow agent (`Platform.Agents.Burrow.get/0`) and
  requires the agent host to report it `:running`. It never creates, renames
  or starts an agent.

  The example chips live in `@example_goals` so a later surface (e.g. an
  experiment) can wrap the list without touching templates.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.Burrow
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Repo
  alias Platform.Tenancy

  @pref_key "first_run_goal"
  @submitting "submitting"

  @example_goals [
    "Plan this week's work",
    "Start a project with my team",
    "Turn my to-do list into tasks"
  ]

  @doc "The `users.preferences` key this feature stores its state under."
  def pref_key, do: @pref_key

  @doc "The example goals offered as chips under the box."
  @spec example_goals() :: [String.t()]
  def example_goals, do: @example_goals

  @doc """
  True when `user` should see the goal box: a real, non-external user whose
  stored preferences have no `"first_run_goal"` key. Reads the preferences
  from the database, not from the struct, so a stale struct cannot re-show
  the box after a submit.
  """
  @spec pending?(User.t() | map() | nil) :: boolean()
  def pending?(%{id: user_id} = user) when is_binary(user_id) do
    not Tenancy.external_user?(user) and
      not Map.has_key?(Accounts.get_user_preferences(user_id), @pref_key)
  end

  def pending?(_), do: false

  @doc """
  The Burrow agent when it exists AND the agent host reports it running.
  """
  @spec burrow() :: {:ok, Platform.Agents.Agent.t()} | {:error, :no_agent}
  def burrow do
    with %{} = agent <- Burrow.get(),
         true <- match?(%{state: :running}, Platform.AgentHost.status(agent)) do
      {:ok, agent}
    else
      _ -> {:error, :no_agent}
    end
  end

  @doc """
  Post the member's goal into their DM with Burrow.

  Returns `{:ok, space, message}`. On any error returns `{:error, reason}`
  and leaves the member pending, so they keep the box and their text:

    * `:blank` — nothing but whitespace was typed (nothing is written).
    * `:not_pending` — the member is external, or already submitted, skipped
      or is mid-submit. A second click of the same submit lands here, so the
      goal is posted once.
    * `:no_agent` — no Burrow, or Burrow is not running.
    * anything `Chat.find_or_create_dm/3` or `Chat.post_message/2` returns.

  `opts[:post]` replaces `Chat.post_message/1` (a test seam for a failing post).
  """
  @spec submit(User.t(), String.t() | nil, keyword()) ::
          {:ok, Chat.Space.t(), Chat.Message.t()} | {:error, term()}
  def submit(%{id: user_id} = user, text, opts \\ []) when is_binary(user_id) do
    post = Keyword.get(opts, :post, &Chat.post_message/1)
    trimmed = String.trim(text || "")

    cond do
      trimmed == "" ->
        {:error, :blank}

      Tenancy.external_user?(user) ->
        {:error, :not_pending}

      true ->
        with {:ok, agent} <- burrow(),
             :ok <- claim(user_id) do
          case safe_post_goal(user_id, agent, trimmed, post) do
            {:ok, space, msg} ->
              put_pref(user_id, "submitted")
              {:ok, space, msg}

            {:error, reason} ->
              release_claim(user_id)
              {:error, reason}
          end
        end
    end
  end

  @doc "Record that the member dismissed the box. Idempotent."
  @spec skip(User.t() | map()) :: :ok | {:error, :not_found}
  def skip(%{id: user_id}) when is_binary(user_id), do: put_pref(user_id, "skipped")

  # A raise must not strand the "submitting" claim: release it, then re-raise.
  defp safe_post_goal(user_id, agent, content, post) do
    post_goal(user_id, agent, content, post)
  rescue
    e ->
      release_claim(user_id)
      reraise e, __STACKTRACE__
  end

  defp post_goal(user_id, agent, content, post) do
    with {:ok, space} <- Chat.find_or_create_dm(user_id, "agent", agent.id),
         {:ok, participant} <- own_participant(space.id, user_id),
         {:ok, msg} <-
           post.(%{
             space_id: space.id,
             participant_id: participant.id,
             content_type: "text",
             content: content,
             metadata: %{"source" => "first_run_goal"}
           }) do
      {:ok, space, msg}
    end
  end

  defp own_participant(space_id, user_id) do
    from(p in Participant,
      where:
        p.space_id == ^space_id and p.participant_type == "user" and
          p.participant_id == ^user_id,
      limit: 1
    )
    |> Repo.one()
    |> case do
      %Participant{} = p -> {:ok, p}
      nil -> {:error, :no_participant}
    end
  end

  # ── Single-key atomic writes on users.preferences ───────────────────────

  # Take the submit: set the key to "submitting" only while it is absent. One
  # statement, so of two concurrent submits exactly one updates a row.
  defp claim(user_id) do
    {count, _} =
      from(u in User,
        where:
          u.id == ^user_id and
            not fragment("COALESCE(?, '{}'::jsonb) \\? ?", u.preferences, ^@pref_key),
        update: [
          set: [
            preferences:
              fragment(
                "COALESCE(?, '{}'::jsonb) || jsonb_build_object(?::text, ?::text)",
                u.preferences,
                ^@pref_key,
                ^@submitting
              ),
            updated_at: ^now()
          ]
        ]
      )
      |> Repo.update_all([])

    if count == 1, do: :ok, else: {:error, :not_pending}
  end

  # Undo a claim after a failed post. Only removes OUR in-flight value, so a
  # concurrent skip (or anything else written meanwhile) stays.
  defp release_claim(user_id) do
    from(u in User,
      where:
        u.id == ^user_id and
          fragment("?->>? = ?", u.preferences, ^@pref_key, ^@submitting),
      update: [
        set: [
          preferences: fragment("? - ?", u.preferences, ^@pref_key),
          updated_at: ^now()
        ]
      ]
    )
    |> Repo.update_all([])

    :ok
  end

  defp put_pref(user_id, value) do
    from(u in User,
      where: u.id == ^user_id,
      update: [
        set: [
          preferences:
            fragment(
              "COALESCE(?, '{}'::jsonb) || jsonb_build_object(?::text, ?::text)",
              u.preferences,
              ^@pref_key,
              ^value
            ),
          updated_at: ^now()
        ]
      ]
    )
    |> Repo.update_all([])
    |> case do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
