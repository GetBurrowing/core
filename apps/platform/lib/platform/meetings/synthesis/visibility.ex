defmodule Platform.Meetings.Synthesis.Visibility do
  @moduledoc "Permission checks for synthesis citations. Unknown sources fail closed."
  import Ecto.Query
  alias Platform.{Access, Accounts, Chat, Meetings, Repo}
  alias Platform.Meetings.MeetingBriefings

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

  defp readable?(user, scope, :meeting_briefing, meeting_id) do
    case MeetingBriefings.get_for_attendee(meeting_id, user.id) do
      %{meeting: meeting} ->
        not Meetings.meeting_org_guest?(meeting, user.id) and
          Access.can?(scope, "chat.read", {:space, meeting.chat_space_id}) and
          not MapSet.member?(
            Access.restricted_space_ids(scope, [meeting.chat_space_id]),
            meeting.chat_space_id
          )

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
        Platform.Mail.can_use?(user, org_id) and Access.can?(scope, "mail.use", {:org, org_id}) and
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
    case String.split(path, "/") do
      ["org", kind | _] when kind in ["page", "journal"] ->
        true

      ["project", id, kind | _] when kind in ["page", "journal"] ->
        Platform.UUID.valid?(id) and Access.can?(scope, "memory.read", {:project, id})

      ["space", id, kind | _] when kind in ["page", "journal"] ->
        Platform.UUID.valid?(id) and space_readable?(user, scope, id)

      _ ->
        false
    end
  end

  defp memory_readable?(scope, %{org_id: org_id, project_id: project_id}) do
    target = if project_id, do: {:project, project_id}, else: {:org, org_id}
    Access.can?(scope, "memory.read", target)
  end

  defp space_readable?(user, scope, space_id) do
    match?({:ok, _}, Chat.SpaceAccess.authorize_writer(space_id, user)) and
      Access.can?(scope, "chat.read", {:space, space_id}) and
      not MapSet.member?(Access.restricted_space_ids(scope, [space_id]), space_id)
  end

  defp fetch(schema, id), do: Repo.one(from(r in schema, where: r.id == ^id))
end
