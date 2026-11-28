defmodule PlatformWeb.SocialClipRevisionState do
  @moduledoc "Read-only, freshly authorized projection for a clip's editing requests."
  import Ecto.Query, only: [from: 2]
  alias Platform.{Accounts, Repo, Social}
  alias Platform.Social.{Clip, ClipEditRequest, ClipRender, ClipRevisionAccess, ClipRevisions}

  def load(scope, profile_id, clip_id, user_id) do
    with %{} = profile <- Social.get_profile(scope, profile_id),
         %Clip{profile_id: ^profile_id, flow: "legacy", removed_at: nil} = clip <-
           Social.get_clip(scope, clip_id),
         :ok <- ClipRevisionAccess.human(profile, user_id) do
      base =
        Repo.one(
          from(r in ClipRender,
            where: r.clip_id == ^clip.id and r.rev == ^clip.rev and is_nil(r.removed_at)
          )
        )

      latest = ClipRevisions.latest(clip.id)
      history = history(scope, clip.id, user_id)
      request = latest && Enum.find(history, &(&1.id == latest.id))
      awaiting? = ClipRevisions.awaiting?(clip, latest)

      replaceable? =
        awaiting? and not is_nil(request) and
          ClipRevisions.notification_replaceable?(request)

      {:ok,
       %{
         profile: profile,
         clip: clip,
         base: base,
         request: request,
         history: history,
         agents: agents(profile),
         awaiting?: awaiting?,
         replaceable?: replaceable?,
         editor_blocked?:
           awaiting? and not is_nil(request) and not editor_available?(profile, request),
         can_request?:
           not is_nil(base) and clip.status == "rendered" and
             (clip.review_status == "pending" or replaceable?),
         can_upload?: awaiting? and not is_nil(request) and request.assigned_user_id == user_id,
         returned?:
           not is_nil(base) and not is_nil(request) and
             request.returned_render_id == base.id and clip.review_status == "pending"
       }}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp history(scope, clip_id, user_id) do
    from(r in ClipEditRequest,
      where: r.clip_id == ^clip_id,
      order_by: [desc: r.position],
      select: r.id
    )
    |> Repo.all()
    |> Enum.flat_map(fn id ->
      case ClipRevisions.get_request(scope, id, {:user, user_id}) do
        {:ok, %{request: request}} -> [receipt(request, user_id)]
        _ -> []
      end
    end)
  end

  defp receipt(request, user_id) do
    request
    |> Map.take([
      :id,
      :base_render_id,
      :note,
      :assigned_user_id,
      :assigned_agent_id,
      :notification_status,
      :returned_render_id,
      :returned_at,
      :inserted_at
    ])
    |> Map.put(:assignee_name, assignee_name(request, user_id))
  end

  defp assignee_name(%{assigned_user_id: id}, id) when is_binary(id), do: "You"

  defp assignee_name(%{assigned_user_id: id}, _) when is_binary(id) do
    case Accounts.get_user(id) do
      %{name: name} when is_binary(name) -> name
      _ -> "Human editor"
    end
  end

  defp assignee_name(%{assigned_agent_id: id}, _) do
    case Repo.get(Platform.Agents.Agent, id) do
      %{name: name} when is_binary(name) -> name
      _ -> "Editing agent"
    end
  end

  defp editor_available?(profile, %{assigned_user_id: id}) when is_binary(id),
    do: ClipRevisionAccess.human(profile, id) == :ok

  defp editor_available?(profile, %{assigned_agent_id: id}) when is_binary(id),
    do: match?({:ok, _}, ClipRevisionAccess.agent(profile, id))

  defp editor_available?(_profile, _request), do: false

  defp agents(%{space_id: nil}), do: []

  defp agents(profile) do
    Platform.Chat.list_participants(profile.space_id, participant_type: "agent")
    |> Enum.reject(& &1.silenced)
    |> Enum.flat_map(fn participant ->
      case ClipRevisionAccess.recipient(profile, participant.participant_id) do
        {:ok, agent} -> [%{id: agent.id, name: agent.name || "Editing agent"}]
        _ -> []
      end
    end)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&{String.downcase(&1.name), &1.id})
  end
end
