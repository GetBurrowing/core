defmodule Platform.Meetings.Synthesis.Visibility do
  @moduledoc "Permission checks for synthesis citations. Unknown sources fail closed."
  import Ecto.Query
  alias Platform.{Access, Accounts, Chat, Meetings, Repo}

  @doc "Resolve the referenced row and check the recipient's current permissions."
  def readable_by?(user_id, %{ref: ref} = source) do
    readable_by?(user_id, ref) and
      Enum.all?(Map.get(source, :required_refs, []), &readable_by?(user_id, &1))
  end

  def readable_by?(user_id, {kind, id}) do
    with true <- Platform.UUID.valid?(id),
         %{} = user <- Accounts.get_user(user_id) do
      readable?(user, Access.scope_for(user), kind, id)
    else
      _ -> false
    end
  end

  def readable_by?(_, _), do: false

  @kinds %{
    "task" => :task,
    "canvas" => :canvas,
    "message" => :message,
    "meeting_candidate" => :meeting_candidate,
    "meeting_briefing" => :meeting_briefing,
    "memory_page" => :memory_page,
    "memory_journal" => :memory_journal,
    "mail" => :mail
  }

  @doc """
  Parse a stored `"kind:id"` citation ref into the `{kind, id}` tuple
  `readable_by?/2` takes. Only the closed set of source kinds parses; any
  other string is `:error` (never `String.to_atom/1`).
  """
  @spec parse_ref(term()) :: {:ok, {atom(), binary()}} | :error
  def parse_ref(ref) when is_binary(ref) do
    with [kind, id] <- String.split(ref, ":", parts: 2),
         {:ok, atom} <- Map.fetch(@kinds, kind) do
      {:ok, {atom, id}}
    else
      _ -> :error
    end
  end

  def parse_ref(_ref), do: :error

  @doc """
  Whether `user_id` can read a STORED finding citation
  (`%{"ref" => "kind:id", "requires" => ["kind:id", ...]}`) right now: the
  cited source and every required ref. An unparseable ref fails closed.
  """
  @spec citation_readable_by?(term(), map()) :: boolean()
  def citation_readable_by?(user_id, %{"ref" => ref} = citation) do
    Enum.all?([ref | List.wrap(citation["requires"])], fn r ->
      case parse_ref(r) do
        {:ok, tuple} -> readable_by?(user_id, tuple)
        :error -> false
      end
    end)
  end

  def citation_readable_by?(_user_id, _citation), do: false

  @doc """
  Whether `user_id` can read EVERY stored `"kind:id"` ref in `refs` right
  now. Used for a finding's `prompt_refs`: every source that was in the
  prompt which produced the finding body (task 01a16974 stage 6). The user
  and their access scope are loaded once for the whole list. An empty list
  is vacuously readable; any unparseable ref, or an unknown user, fails
  closed.
  """
  @spec refs_readable_by?(term(), [String.t()]) :: boolean()
  def refs_readable_by?(_user_id, []), do: true

  def refs_readable_by?(user_id, refs) when is_binary(user_id) and is_list(refs) do
    with true <- Platform.UUID.valid?(user_id),
         %{} = user <- Accounts.get_user(user_id) do
      scope = Access.scope_for(user)

      refs
      |> Enum.uniq()
      |> Enum.all?(fn ref ->
        case parse_ref(ref) do
          {:ok, {kind, id}} -> Platform.UUID.valid?(id) and readable?(user, scope, kind, id)
          :error -> false
        end
      end)
    else
      _ -> false
    end
  end

  def refs_readable_by?(_user_id, _refs), do: false

  @doc """
  The `user_id`'s EXISTING participant row in `space_id`, when they can read
  that space right now (same checks as a chat citation). Never creates a
  participant: `:error` for anyone who is not already in the space.
  """
  @spec readable_participant(term(), binary()) :: {:ok, Chat.Participant.t()} | :error
  def readable_participant(user_id, space_id) when is_binary(space_id) do
    with %{} = user <- Accounts.get_user(user_id),
         scope = Access.scope_for(user),
         {:ok, participant} <- Chat.SpaceAccess.authorize_writer(space_id, user),
         true <- space_readable?(user, scope, space_id) do
      {:ok, participant}
    else
      _ -> :error
    end
  end

  def readable_participant(_user_id, _space_id), do: :error

  defp readable?(_user, scope, :task, id),
    do: match?({:ok, _}, Access.task_target(scope, {:task, id}, "tasks.read"))

  defp readable?(user, scope, :canvas, id) do
    case Chat.CanvasAccess.fetch_for_viewer(id, user, access_scope: scope) do
      {:ok, %{space_id: space_id, deleted_at: nil}, _level} ->
        Access.can?(scope, "canvas.read", {:canvas, id}) and
          not MapSet.member?(Access.restricted_space_ids(scope, [space_id]), space_id)

      _ ->
        false
    end
  end

  defp readable?(user, scope, :message, id) do
    case fetch(Chat.Message, id) do
      %{space_id: space_id, deleted_at: nil, log_only: false, canvas_id: nil} ->
        space_readable?(user, scope, space_id)

      %{space_id: space_id, deleted_at: nil, log_only: false, canvas_id: canvas_id} ->
        space_readable?(user, scope, space_id) and readable?(user, scope, :canvas, canvas_id)

      _ ->
        false
    end
  end

  defp readable?(user, scope, :meeting_candidate, id) do
    case fetch(Platform.Meetings.MeetingCandidate, id) do
      %{meeting_id: meeting_id, disposition: :accepted} ->
        readable?(user, scope, :meeting_briefing, meeting_id)

      _ ->
        false
    end
  end

  # A meeting's outcomes (briefing summary, accepted candidates) are readable
  # by whoever can read the meeting's chat space right now: a participant
  # with `chat.read` on it, the space not restricted for them, and not an
  # org guest. Attendance is NOT required (task 01a16974 stage 5): a reader
  # of meeting B's space who attended only meeting A must be able to see a
  # finding that cites B's accepted action item, or a cross-meeting conflict
  # between disjoint attendee sets reaches nobody. Recipients stay bounded
  # by `Context.recipients_for/2`, which intersects readers with the human
  # attendees of the meetings the finding names.
  defp readable?(user, scope, :meeting_briefing, meeting_id) do
    case Meetings.get_meeting(meeting_id) do
      %{chat_space_id: space_id} = meeting when is_binary(space_id) ->
        not Meetings.meeting_org_guest?(meeting, user.id) and
          space_readable?(user, scope, space_id)

      _ ->
        false
    end
  end

  defp readable?(user, scope, :memory_page, id) do
    case fetch(Platform.Org.WikiPage, id) do
      nil ->
        false

      page ->
        memory_readable?(scope, page) and
          namespace_readable?(user, scope, page.file_key) and
          Repo.exists?(
            Platform.Org.Wiki.scope_by(
              from(p in Platform.Org.WikiPage, where: p.id == ^id),
              scope,
              :memory_page
            )
          )
    end
  end

  defp readable?(user, scope, :memory_journal, id) do
    case fetch(Platform.Org.WikiJournalEntry, id) do
      nil ->
        false

      entry ->
        path = journal_path(entry)

        memory_readable?(scope, entry) and namespace_readable?(user, scope, path) and
          Access.within?(scope, "memory.read", {:memory, path}, true)
    end
  end

  defp readable?(user, scope, :mail, id) do
    case fetch(Platform.Mail.InboundMessage, id) do
      %{org_id: org_id, chat_message_id: message_id} when is_binary(message_id) ->
        Platform.Mail.can_use?(user, org_id) and Access.can?(scope, "mail.use", org_id) and
          readable?(user, scope, :message, message_id)

      _ ->
        false
    end
  end

  defp readable?(_, _, _, _), do: false

  defp journal_path(entry) do
    namespace =
      Map.get(entry.metadata || %{}, "namespace", Platform.Org.Wiki.Journal.default_namespace())

    Platform.Org.Wiki.Journal.virtual_file_key(namespace, entry.date)
  end

  defp namespace_readable?(user, scope, path) do
    if String.contains?(path, "/private/") do
      false
    else
      case String.split(path, "/") do
        ["org" | _] ->
          true

        ["project", id | _] ->
          Platform.UUID.valid?(id) and Access.can?(scope, "memory.read", {:project, id})

        ["space", id | _] ->
          Platform.UUID.valid?(id) and space_readable?(user, scope, id)

        _ ->
          false
      end
    end
  end

  defp memory_readable?(scope, %{org_id: org_id, project_id: project_id}) do
    target = if project_id, do: {:project, project_id}, else: org_id
    Access.can?(scope, "memory.read", target)
  end

  defp space_readable?(user, scope, space_id) do
    match?({:ok, _}, Chat.SpaceAccess.authorize_writer(space_id, user)) and
      Access.can?(scope, "chat.read", {:space, space_id}) and
      not MapSet.member?(Access.restricted_space_ids(scope, [space_id]), space_id)
  end

  defp fetch(schema, id), do: Repo.one(from(r in schema, where: r.id == ^id))
end
