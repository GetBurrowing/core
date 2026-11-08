defmodule Platform.Calendar.Draft do
  @moduledoc """
  The write-free handoff from a calendar agent to its owner (task 01a1b8a5
  stage 3).

  The owner describes what to schedule in Calendar. Calendar sends that
  text, with the owner's time zone and today's date, to an agent the owner
  has granted `create` through the ordinary chat path (`ask/3`, the owner's
  DM with that agent). The agent answers in chat and, when it can, calls the
  `calendar_draft` tool, which lands here in `create/4`.

  A draft is NOT a calendar event, a meeting, a guest invitation, a busy
  reservation or an Inbox consent, and creating one writes none of them.
  `calendar_propose` is the tool that reserves time; this one only leaves
  structured fields for the owner to review in the ONE Calendar editor
  (`PlatformWeb.CalendarLive.Editor.open_agent_draft/2`), where the owner's
  own Save goes through `Platform.Calendar.Authoring.save/4` like every
  other save.

  ## What the tool must not guess, and does not

    * Times are taken as given. An ISO 8601 value with an offset is that
      instant. A local wall time is read in `time_zone`; if a daylight-saving
      change repeats it or skips it, the draft keeps NO instant for it and
      carries a `time` clarification instead.
    * Attendees are given as a user id, an email address or a name. A name
      matching more than one person, or nobody, becomes an `attendee`
      clarification listing the candidates. Nobody is picked for the owner.
    * Nothing else is defaulted: a missing title, start or end stays missing
      and is listed in `issues`.

  A draft with clarifications or issues is still reviewable. It cannot be
  saved until the owner has answered every attendee clarification in the
  editor, and the editor's own validation refuses a missing or ambiguous
  time.

  ## Who can see a draft

  Only its owner, while it is unexpired (24 hours) and unsaved. The link's
  token is opaque, and every read also requires the signed-in owner, so a
  copied link opens nothing for anyone else. A retried tool call with the
  same `request_key` returns the original draft. A saved draft is spent:
  the second Save of the same draft is refused.
  """
  use Ecto.Schema
  import Ecto.Query

  alias Ecto.Changeset
  alias Platform.{Accounts, Repo}
  alias Platform.Access.Scope
  alias Platform.Calendar.{AgentAccess, Authoring, EventDraft}

  @ttl_seconds 24 * 60 * 60
  @max_attendees 50
  @max_candidates 8
  @presets ~w(event focus ooo)

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "calendar_drafts" do
    field(:owner_id, :binary_id)
    field(:agent_id, :binary_id)
    field(:token, :string)
    field(:request_key, :string)
    field(:attrs, :map, default: %{})
    field(:clarifications, {:array, :map}, default: [])
    field(:issues, {:array, :string}, default: [])
    field(:expires_at, :utc_datetime_usec)
    field(:saved_at, :utc_datetime_usec)
    field(:event_id, :binary_id)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "How long a draft link stays usable."
  def ttl_seconds, do: @ttl_seconds

  @doc "The PubSub topic an owner's Calendar listens on for new drafts."
  def topic(owner_id), do: "calendar_drafts:" <> owner_id

  def subscribe(%Scope{actor: %Accounts.User{id: id}}),
    do: Phoenix.PubSub.subscribe(Platform.PubSub, topic(id))

  def subscribe(_scope), do: :ok

  @doc "The owner-only Calendar link for a draft."
  def url(%__MODULE__{token: token}), do: "/calendar?draft=" <> token

  @doc """
  `ready`, `needs_clarification` (an answer is owed before Save) or
  `incomplete` (something is missing; the editor asks for it).
  """
  def status(%__MODULE__{clarifications: [_ | _]}), do: "needs_clarification"
  def status(%__MODULE__{issues: [_ | _]}), do: "incomplete"
  def status(%__MODULE__{}), do: "ready"

  # ── asking an agent ─────────────────────────────────────────────────────

  @doc """
  Send the owner's own words to `agent_id` in the owner's DM with it, with
  the context a scheduling agent needs: the owner id, a fresh request key,
  the owner's time zone and today's date there. Nothing is parsed here.

  The agent must be one `AgentAccess.draft_agents/1` offers this owner, and
  one of its runtimes must be connected; otherwise nothing is sent and
  `{:error, :unavailable}` says so. `{:ok, %{space: space, message: msg,
  request_key: key}}` on success.
  """
  def ask(scope, agent_id, text, opts \\ [])

  def ask(%Scope{actor: %Accounts.User{id: owner_id}} = scope, agent_id, text, opts) do
    text = String.trim(to_string(text))
    zone = Keyword.get(opts, :time_zone, "Etc/UTC")
    today = Keyword.get(opts, :today) || DateTime.to_date(DateTime.now!(zone))

    with true <- text != "" || {:error, :blank},
         %{} = agent <-
           Enum.find(AgentAccess.draft_agents(scope), &(&1.id == agent_id)) ||
             {:error, :forbidden},
         true <- agent.online? || {:error, :unavailable} do
      key = "cal-" <> random(9)

      content =
        text <>
          "\n\n" <>
          "Calendar request #{key}: please prepare this as a draft with the calendar_draft tool " <>
          "(owner_id #{owner_id}, request_key #{key}, time_zone #{zone}). " <>
          "Today is #{Calendar.strftime(today, "%A, %B %-d, %Y")} in #{zone}. " <>
          "Give attendees by user_id (principal_search), email or name; Calendar matches names " <>
          "against the people I can invite and asks me when more than one matches. " <>
          "If a person, date or time is unclear, ask me instead of guessing. " <>
          "Nothing is saved until I save it in Calendar."

      metadata = %{
        "source" => "calendar_draft_request",
        "request_key" => key,
        "owner_id" => owner_id,
        "time_zone" => zone,
        "today" => Date.to_iso8601(today)
      }

      case Platform.Chat.post_to_agent_dm(owner_id, agent.id, content, metadata: metadata) do
        {:ok, space, message} -> {:ok, %{space: space, message: message, request_key: key}}
        {:error, _} -> {:error, :send_failed}
      end
    end
  end

  def ask(_scope, _agent_id, _text, _opts), do: {:error, :forbidden}

  # ── the tool ────────────────────────────────────────────────────────────

  @doc """
  The `calendar_draft` tool's write: one draft row, nothing else.

  `scope` is the calling runtime's scope; the grant and runtime checks are
  `AgentAccess.draft_authority/2` (the same live checks `calendar_propose`
  makes for `create`). Returns `{:ok, draft, :created | :existing}`,
  `{:error, :forbidden}`, or `{:error, {:invalid, messages}}` when the call
  itself is malformed (no request key, no or an unknown time zone, a value
  of the wrong shape) and the agent should fix and retry.
  """
  def create(scope, owner_id, args, opts \\ [])

  def create(%Scope{} = scope, owner_id, args, opts) when is_map(args) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, key} <- request_key(args["request_key"]),
         {:ok, owner_scope, grant} <- AgentAccess.draft_authority(scope, owner_id) do
      case Repo.get_by(__MODULE__, owner_id: owner_id, agent_id: grant.agent_id, request_key: key) do
        %__MODULE__{} = existing ->
          {:ok, existing, :existing}

        nil ->
          with {:ok, resolved} <- resolve(args, owner_scope) do
            insert(owner_id, grant.agent_id, key, resolved, now)
          end
      end
    end
  end

  def create(_scope, _owner_id, _args, _opts), do: {:error, :forbidden}

  defp insert(owner_id, agent_id, key, resolved, now) do
    row = %__MODULE__{
      owner_id: owner_id,
      agent_id: agent_id,
      token: random(24),
      request_key: key,
      attrs: resolved.attrs,
      clarifications: resolved.clarifications,
      issues: resolved.issues,
      expires_at: DateTime.add(now, @ttl_seconds, :second)
    }

    row
    |> Changeset.change()
    |> Changeset.unique_constraint([:owner_id, :agent_id, :request_key],
      name: :calendar_drafts_owner_id_agent_id_request_key_index
    )
    |> Repo.insert()
    |> case do
      {:ok, draft} ->
        Phoenix.PubSub.broadcast(
          Platform.PubSub,
          topic(owner_id),
          {:calendar_draft, %{id: draft.id, agent_id: agent_id, request_key: key}}
        )

        {:ok, draft, :created}

      # A concurrent retry with the same key won the insert.
      {:error, _} ->
        case Repo.get_by(__MODULE__, owner_id: owner_id, agent_id: agent_id, request_key: key) do
          %__MODULE__{} = existing -> {:ok, existing, :existing}
          nil -> {:error, :forbidden}
        end
    end
  end

  # ── reading a draft ─────────────────────────────────────────────────────

  @doc """
  The draft behind a link's `token`, for its owner only. `{:error,
  :not_found}` for anyone else (indistinguishable from no such draft),
  `:expired` and `:saved` for the owner's own spent links.
  """
  def fetch(scope, token, opts \\ [])

  def fetch(%Scope{actor: %Accounts.User{id: owner_id}}, token, opts)
      when is_binary(token) and byte_size(token) in 16..64 do
    __MODULE__ |> Repo.get_by(token: token, owner_id: owner_id) |> usable(opts)
  end

  def fetch(_scope, _token, _opts), do: {:error, :not_found}

  @doc "The same as `fetch/3`, by id (Calendar's own Review draft button)."
  def get(scope, id, opts \\ [])

  def get(%Scope{actor: %Accounts.User{id: owner_id}}, id, opts) when is_binary(id) do
    if Platform.UUID.valid?(id),
      do: __MODULE__ |> Repo.get_by(id: id, owner_id: owner_id) |> usable(opts),
      else: {:error, :not_found}
  end

  def get(_scope, _id, _opts), do: {:error, :not_found}

  defp usable(nil, _opts), do: {:error, :not_found}

  defp usable(%__MODULE__{} = draft, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    cond do
      draft.saved_at -> {:error, :saved}
      DateTime.compare(draft.expires_at, now) != :gt -> {:error, :expired}
      true -> {:ok, draft}
    end
  end

  @doc "The agent's display name for a draft."
  def agent_name(%__MODULE__{agent_id: id}) do
    case Repo.get(Platform.Agents.Agent, id) do
      %{name: name} -> name
      _ -> "Your agent"
    end
  end

  @doc """
  The editor's `EventDraft` for a draft. A new event (no event or call
  record yet), so the editor says New event / Create event. The call stays
  off unless the draft asks for it AND the owner may have one. The call's
  project is not the event's: the editor offers it as the call's Project
  (`attrs["project_id"]`), so the event itself stays private.
  """
  def event_draft(%__MODULE__{attrs: attrs}, scope) do
    draft =
      Authoring.new_draft(
        scope,
        attrs
        |> Map.take(~w(title notes starts_at ends_at time_zone all_day start_date end_date
                       visibility preset call_enabled add_invitees))
        |> Map.update("call_enabled", false, &(&1 == true))
      )

    %{draft | source: "agent"}
  end

  @doc "The draft's local date, kept even when its times need an answer."
  def local_date(%__MODULE__{attrs: attrs}), do: attrs["date"]

  @doc "Attendee clarifications not yet answered in `resolved` (a list of ids)."
  def unresolved(%__MODULE__{clarifications: clarifications}, resolved) do
    Enum.filter(clarifications, &(&1["kind"] == "attendee" and &1["id"] not in resolved))
  end

  # ── saving (called by Authoring.save/4 only) ────────────────────────────

  @doc false
  # Inside Authoring's transaction: lock the owner's draft and refuse a
  # spent, expired or still-unanswered one.
  def lock_for_save(%Scope{actor: %Accounts.User{id: owner_id}}, id, resolved) do
    draft =
      Platform.UUID.valid?(id) &&
        Repo.one(
          from(d in __MODULE__,
            where: d.id == ^id and d.owner_id == ^owner_id,
            lock: "FOR UPDATE"
          )
        )

    with {:ok, draft} <- usable(draft || nil, []),
         [] <- unresolved(draft, resolved) do
      {:ok, draft}
    else
      [_ | _] -> {:error, :unresolved}
      {:error, _} = error -> error
    end
  end

  def lock_for_save(_scope, _id, _resolved), do: {:error, :not_found}

  @doc false
  def mark_saved(%__MODULE__{} = draft, event_id) do
    draft
    |> Changeset.change(saved_at: DateTime.utc_now(), event_id: event_id)
    |> Repo.update()
  end

  # ── resolving the tool's arguments ──────────────────────────────────────

  defp request_key(key) when is_binary(key) do
    key = String.trim(key)

    if byte_size(key) in 1..128,
      do: {:ok, key},
      else: {:error, {:invalid, ["request_key must be 1 to 128 characters"]}}
  end

  defp request_key(_), do: {:error, {:invalid, ["request_key is required"]}}

  @doc false
  # Structured arguments -> `%{attrs, clarifications, issues}`. Public only
  # for the tests; `create/4` is the caller.
  def resolve(args, %Scope{actor: %Accounts.User{} = owner} = owner_scope) do
    with {:ok, zone} <- time_zone(args["time_zone"]),
         {:ok, preset} <- one_of(args, "category", @presets, "event"),
         {:ok, visibility} <- one_of(args, "visibility", ~w(busy details), "details"),
         {:ok, specs} <- attendee_specs(args["attendees"]),
         {:ok, title} <- optional_string(args, "title", 300),
         {:ok, notes} <- optional_string(args, "notes", 10_000),
         {:ok, all_day?} <- optional_boolean(args, "all_day"),
         {:ok, call?} <- optional_boolean(args, "call_enabled") do
      {window, clarifications, issues} = window(args, zone, all_day?)
      {invitees, people} = attendees(specs, owner)

      {call?, issues} =
        if call? and not Authoring.call_available?(owner_scope),
          do: {false, issues ++ ["A Burrow call isn't available to you, so the draft has none."]},
          else: {call?, issues}

      {project_id, issues} = project(args["project_id"], owner, issues)

      attrs =
        Map.merge(window, %{
          "title" => title,
          "notes" => notes,
          "time_zone" => zone,
          "preset" => preset,
          "visibility" => visibility,
          "call_enabled" => call?,
          "project_id" => project_id,
          "add_invitees" => invitees
        })

      issues = issues ++ missing(attrs) ++ draft_errors(attrs, owner_scope)

      {:ok,
       %{
         attrs: attrs,
         clarifications: clarifications ++ people,
         issues: Enum.uniq(issues)
       }}
    end
  end

  defp time_zone(zone) when is_binary(zone) and zone != "" do
    case DateTime.now(zone) do
      {:ok, _} -> {:ok, zone}
      _ -> {:error, {:invalid, ["time_zone #{inspect(zone)} is not an IANA time zone"]}}
    end
  end

  defp time_zone(_),
    do: {:error, {:invalid, ["time_zone is required (the owner's zone is in the request)"]}}

  defp one_of(args, key, allowed, default) do
    case Map.get(args, key) do
      nil ->
        {:ok, default}

      value when is_binary(value) ->
        if value in allowed, do: {:ok, value}, else: bad(key, allowed)

      _ ->
        bad(key, allowed)
    end
  end

  defp bad(key, allowed),
    do: {:error, {:invalid, ["#{key} must be one of #{Enum.join(allowed, ", ")}"]}}

  defp optional_string(args, key, max) do
    case Map.get(args, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value |> String.trim() |> String.slice(0, max)}
      _ -> {:error, {:invalid, ["#{key} must be a string"]}}
    end
  end

  defp optional_boolean(args, key) do
    case Map.get(args, key) do
      nil -> {:ok, false}
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, {:invalid, ["#{key} must be true or false"]}}
    end
  end

  defp attendee_specs(nil), do: {:ok, []}

  defp attendee_specs(list) when is_list(list) and length(list) <= @max_attendees do
    if Enum.all?(list, &is_map/1),
      do: {:ok, list},
      else: {:error, {:invalid, ["each attendee must be an object with user_id, email or name"]}}
  end

  defp attendee_specs(_),
    do: {:error, {:invalid, ["attendees must be a list of at most #{@max_attendees}"]}}

  # The window, in UTC, plus a clarification for every local time a DST
  # change makes ambiguous or nonexistent (no instant is kept for those).
  defp window(args, zone, true = _all_day) do
    {first, first_issue} = day(args["start"], "start")
    {last, last_issue} = day(args["end"], "end")

    {%{
       "all_day" => true,
       "date" => first && Date.to_iso8601(first),
       "start_date" => first && Date.to_iso8601(first),
       # The tool's end is the last day; the event stores the day after.
       "end_date" => last && last |> Date.add(1) |> Date.to_iso8601(),
       "starts_at" => nil,
       "ends_at" => nil,
       "time_zone" => zone
     }, [], Enum.reject([first_issue, last_issue], &is_nil/1)}
  end

  defp window(args, zone, false) do
    start = instant(args["start"], zone)
    finish = instant(args["end"], zone)

    clarifications =
      for {field, result} <- [{"start", start}, {"end", finish}],
          clarification = time_clarification(field, result, zone),
          do: clarification

    issues =
      for {field, {:invalid, _}} <- [{"start", start}, {"end", finish}],
          do: "The #{field} time isn't an ISO 8601 date and time."

    date =
      Enum.find_value([start, finish], fn
        {:ok, at} -> at |> DateTime.shift_zone!(zone) |> DateTime.to_date()
        {kind, local} when kind in [:ambiguous, :gap] -> NaiveDateTime.to_date(local)
        _ -> nil
      end)

    {%{
       "all_day" => false,
       "date" => date && Date.to_iso8601(date),
       "starts_at" => at(start),
       "ends_at" => at(finish),
       "start_date" => nil,
       "end_date" => nil
     }, clarifications, issues}
  end

  defp day(nil, _field), do: {nil, nil}

  defp day(value, field) when is_binary(value) do
    case Date.from_iso8601(String.slice(value, 0, 10)) do
      {:ok, date} -> {date, nil}
      _ -> {nil, "The #{field} date isn't an ISO 8601 date."}
    end
  end

  defp day(_value, field), do: {nil, "The #{field} date isn't an ISO 8601 date."}

  defp instant(nil, _zone), do: :missing
  defp instant("", _zone), do: :missing

  defp instant(value, zone) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} ->
        {:ok, DateTime.shift_zone!(at, "Etc/UTC")}

      _ ->
        with {:ok, local} <- NaiveDateTime.from_iso8601(value) do
          case DateTime.from_naive(local, zone) do
            {:ok, at} -> {:ok, DateTime.shift_zone!(at, "Etc/UTC")}
            {:ambiguous, _, _} -> {:ambiguous, local}
            {:gap, _, _} -> {:gap, local}
            _ -> {:invalid, value}
          end
        else
          _ -> {:invalid, value}
        end
    end
  end

  defp instant(value, _zone), do: {:invalid, value}

  defp at({:ok, at}), do: DateTime.to_iso8601(at)
  defp at(_), do: nil

  defp time_clarification(field, {:ambiguous, local}, zone) do
    %{
      "id" => "time:" <> field,
      "kind" => "time",
      "field" => field,
      "question" =>
        "#{local_label(local)} happens twice on #{date_label(local)} in #{zone} because the clocks change. Pick a time that happens once, or ask again with the offset."
    }
  end

  defp time_clarification(field, {:gap, local}, zone) do
    %{
      "id" => "time:" <> field,
      "kind" => "time",
      "field" => field,
      "question" =>
        "#{local_label(local)} doesn't exist on #{date_label(local)} in #{zone} because the clocks change. Pick another #{field} time."
    }
  end

  defp time_clarification(_field, _result, _zone), do: nil

  defp local_label(local), do: Calendar.strftime(local, "%-I:%M %p")
  defp date_label(local), do: Calendar.strftime(local, "%B %-d, %Y")

  # Each attendee: a user id (must exist), an email (a member with that
  # address, else a guest), or a name (exactly one match, else a question).
  # The search is the editor's own add-people search.
  defp attendees(specs, owner) do
    {invitees, questions} =
      specs
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {spec, index}, {invitees, questions} ->
        case attendee(spec, owner) do
          {:ok, entry} ->
            {[entry | invitees], questions}

          {:ask, question} ->
            {invitees, [Map.put(question, "id", "attendee:#{index}") | questions]}
        end
      end)

    {invitees |> Enum.reverse() |> Enum.uniq_by(&{&1["user_id"], &1["email"]}),
     Enum.reverse(questions)}
  end

  defp attendee(%{"user_id" => id} = spec, owner) when is_binary(id) do
    case Platform.UUID.valid?(id) && id != owner.id && Accounts.get_user(id) do
      %Accounts.User{} = user ->
        {:ok, user_entry(user)}

      _ ->
        {:ask,
         ask_attendee(
           spec["name"] || id,
           [],
           "I couldn't find #{spec["name"] || "that person"} by id. Who did you mean?"
         )}
    end
  end

  defp attendee(%{"email" => email} = spec, owner) when is_binary(email) do
    email = String.trim(email)
    %{users: users, email: guest} = candidates(email, owner)

    case Enum.filter(users, &(String.downcase(&1.email || "") == String.downcase(email))) do
      [user] ->
        {:ok, user_entry(user)}

      _ when is_binary(guest) ->
        {:ok, %{"kind" => "guest", "user_id" => nil, "email" => guest, "display_name" => guest}}

      _ ->
        {:ask,
         ask_attendee(
           spec["name"] || email,
           users,
           "#{email} isn't an address I can invite. Who did you mean?"
         )}
    end
  end

  defp attendee(%{"name" => name}, owner) when is_binary(name) do
    name = String.trim(name)

    case candidates(name, owner) do
      %{users: [user]} ->
        {:ok, user_entry(user)}

      %{users: [], email: guest} when is_binary(guest) ->
        {:ok, %{"kind" => "guest", "user_id" => nil, "email" => guest, "display_name" => guest}}

      %{users: []} ->
        {:ask, ask_attendee(name, [], "I couldn't find anyone called #{name}. Who did you mean?")}

      %{users: users} ->
        {:ask,
         ask_attendee(
           name,
           users,
           "#{length(users)} people match #{name}. Which one did you mean?"
         )}
    end
  end

  defp attendee(_spec, _owner),
    do: {:ask, ask_attendee("an attendee", [], "One attendee had no id, email or name.")}

  defp candidates(query, owner),
    do: Platform.Meetings.resolve_invite_candidates(query, exclude_user_ids: [owner.id])

  defp user_entry(user),
    do: %{
      "kind" => "user",
      "user_id" => user.id,
      "email" => user.email,
      "display_name" => user.name || user.email
    }

  defp ask_attendee(query, users, question),
    do: %{
      "kind" => "attendee",
      "query" => query,
      "question" => question,
      "candidates" =>
        users
        |> Enum.take(@max_candidates)
        |> Enum.map(&%{"user_id" => &1.id, "name" => &1.name || &1.email, "email" => &1.email})
    }

  defp project(nil, _owner, issues), do: {nil, issues}

  defp project(id, owner, issues) do
    if is_binary(id) and Enum.any?(Platform.Tasks.list_projects_for_user(owner), &(&1.id == id)),
      do: {id, issues},
      else: {nil, issues ++ ["That project isn't one of yours, so the draft has none."]}
  end

  defp missing(attrs) do
    [
      attrs["title"] in [nil, ""] && "No title yet.",
      if(attrs["all_day"],
        do:
          (is_nil(attrs["start_date"]) or is_nil(attrs["end_date"])) &&
            "No first or last day yet.",
        else:
          (is_nil(attrs["starts_at"]) or is_nil(attrs["ends_at"])) && "No start or end time yet."
      ),
      ends_before_start?(attrs) && "The end isn't after the start."
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp ends_before_start?(%{"starts_at" => a, "ends_at" => b})
       when is_binary(a) and is_binary(b) do
    {:ok, a, _} = DateTime.from_iso8601(a)
    {:ok, b, _} = DateTime.from_iso8601(b)
    DateTime.compare(b, a) != :gt
  end

  defp ends_before_start?(%{"start_date" => a, "end_date" => b})
       when is_binary(a) and is_binary(b),
       do: b <= a

  defp ends_before_start?(_), do: false

  # EventDraft's own refusals (a preset with a call or people, a call with
  # no project), in plain words. Title and time are `missing/1`'s.
  defp draft_errors(attrs, owner_scope) do
    %EventDraft{}
    |> EventDraft.changeset(attrs, call_available?: Authoring.call_available?(owner_scope))
    |> Map.fetch!(:errors)
    |> Enum.reject(fn {field, _} -> field == :title end)
    |> Enum.map(fn
      {:project_id, _} -> "Pick a project for the Burrow call."
      {:call_enabled, _} -> "Focus time and Out of office can't have a Burrow call."
      {:add_invitees, _} -> "Focus time and Out of office can't have people."
      {field, {message, _}} -> "#{Phoenix.Naming.humanize(field)} #{message}."
    end)
  end

  defp random(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
