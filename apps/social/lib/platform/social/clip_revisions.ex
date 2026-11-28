defmodule Platform.Social.ClipRevisions do
  @moduledoc "Scoped same-clip editing instructions and immutable return receipts."
  import Ecto.Query
  alias Platform.{Repo, Social}

  alias Platform.Social.{
    AgentDrafts,
    Clip,
    ClipClosingVideo,
    ClipEditRequest,
    ClipRender,
    ClipRevisionAccess,
    ClipRevisionContract,
    ClipVersions
  }

  def append_version(scope, clip_id, actor, attrs) do
    with :ok <- outside_transaction(),
         {:ok, input} <- ClipRevisionContract.return_input(attrs),
         {:ok, clip} <- scoped_clip(scope, clip_id),
         profile <- Social.get_profile(scope, clip.profile_id),
         :ok <- ClipRevisionAccess.actor(profile, actor),
         :ok <- precheck_return(clip, actor, input),
         {:ok, file} <- admitted_file(profile, input["file_id"]),
         {:ok, prepared} <- prepare_return(clip, actor, input, file) do
      Repo.transaction(fn ->
        case append_locked(scope, profile.id, clip.id, actor, input, file, prepared) do
          {:ok, value} -> value
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> broadcast_return()
    end
  end

  @doc "Human recut registration. Media preparation precedes Files and Social locks."
  def upload_version(scope, clip_id, user_id, bytes, filename, type, attrs) when is_map(attrs) do
    actor = {:user, user_id}

    with :ok <- outside_transaction(),
         {:ok, clip} <- scoped_clip(scope, clip_id),
         profile <- Social.get_profile(scope, clip.profile_id),
         :ok <- ClipRevisionAccess.actor(profile, actor),
         {:ok, project} <- Social.render_project(profile),
         :ok <- upload_bytes(bytes, filename, type),
         {:ok, input} <-
           ClipRevisionContract.upload_input(attrs),
         :ok <- precheck_return(clip, actor, input),
         :ok <- bytes_identity(bytes, input) do
      key = completion_key(actor, input["submission_id"])
      receipt = Repo.get_by(ClipRender, clip_id: clip.id, completion_key: key)

      if receipt do
        replay_upload(scope, profile, clip, actor, input, receipt)
      else
        prepared_result = prepare_bytes(bytes, input)

        Platform.Files.add_bytes_registered(
          project,
          bytes,
          filename,
          type,
          [uploaded_by_user_id: user_id, human_only: true],
          fn file ->
            # No media, message or broadcast I/O in this callback. Nested rollbacks
            # would be flattened by Files, so expected refusals are ordinary tuples.
            with {:ok, prepared} <- prepared_result do
              input = input |> Map.merge(prepared.media) |> Map.put("file_id", file.id)
              prepared = Map.put(prepared, :file_identity, file_identity(file))
              append_locked(scope, profile.id, clip.id, actor, input, file, prepared)
            end
          end
        )
        |> broadcast_return()
      end
    end
  end

  def upload_version(_, _, _, _, _, _, _), do: {:error, :invalid}

  defp replay_upload(scope, profile, clip, actor, input, receipt) do
    stored = receipt.provenance["submission_facts"] || %{}
    # Identity is checked against the immutable receipt; no media is re-probed.
    if Enum.all?(input, fn {key, value} -> stored[key] == value end) do
      with {:ok, file} <- admitted_file(profile, stored["file_id"]) do
        Repo.transaction(fn ->
          case append_locked(scope, profile.id, clip.id, actor, stored, file, nil) do
            {:ok, value} -> value
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      end
    else
      {:error, :idempotency_conflict}
    end
  end

  defp upload_bytes(bytes, filename, type) do
    cond do
      type not in ClipClosingVideo.content_types() -> {:error, :not_a_video}
      not is_binary(bytes) or byte_size(bytes) == 0 -> {:error, :invalid_video}
      byte_size(bytes) > ClipClosingVideo.max_bytes() -> {:error, :video_too_large}
      not is_binary(filename) or String.trim(filename) == "" -> {:error, :invalid_filename}
      true -> :ok
    end
  end

  defp bytes_identity(bytes, input) do
    if byte_size(bytes) == input["byte_size"] and
         Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == input["sha256"],
       do: :ok,
       else: {:error, :file_facts_mismatch}
  end

  defp prepare_bytes(bytes, _input), do: Social.ClipRevisionMedia.prepare(bytes)

  defp append_locked(scope, profile_id, clip_id, actor, input, file, prepared) do
    profile = Social.lock_profile(scope, profile_id, :share)

    with %{} <- profile || {:error, :not_found},
         :ok <- ClipRevisionAccess.actor(profile, actor),
         true <- profile.project_id == file.project_id || {:error, :project_changed},
         %{} = clip <- lock_clip(profile.id, clip_id) || {:error, :not_found},
         %{} = request <-
           Repo.one(
             from(r in ClipEditRequest,
               where: r.id == ^input["request_id"] and r.clip_id == ^clip.id,
               lock: "FOR UPDATE"
             )
           ) || {:error, :unauthorized},
         true <- assigned?(request, actor) || {:error, :unauthorized},
         :ok <- current_file_access(profile, input["file_id"]) do
      key = completion_key(actor, input["submission_id"])
      digest = return_fingerprint(clip.id, actor, input)

      case Repo.get_by(ClipRender, clip_id: clip.id, completion_key: key) do
        %ClipRender{} = receipt ->
          if receipt.provenance["payload_hash"] == digest and
               request.returned_render_id == receipt.id,
             do: {:ok, %{clip: clip, render: receipt, duplicate?: true}},
             else: {:error, :idempotency_conflict}

        nil ->
          with :ok <- returnable(clip, request, input),
               true <- not is_nil(prepared) || {:error, :retry_required},
               locked_file <- ClipClosingVideo.lock_file(file.id),
               :ok <- file_unchanged(profile, locked_file, prepared.file_identity),
               :ok <- changed_content(request, locked_file) do
            attrs =
              prepared.media
              |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
              |> Map.merge(%{rendered_at: DateTime.utc_now(), error: nil})

            updated =
              ClipVersions.append!(clip.id, locked_file, attrs, %{
                submitted_by_agent_id: actor_agent_id(actor),
                completion_key: key,
                provenance: %{
                  "kind" => "editing_request",
                  "request_id" => request.id,
                  "actor_kind" => actor_kind(actor),
                  "actor_id" => actor_id(actor),
                  "payload_hash" => digest,
                  "submission_facts" => input,
                  "media_facts_source" => prepared.source
                }
              })

            render = Repo.get_by!(ClipRender, clip_id: clip.id, completion_key: key)

            request
            |> Ecto.Changeset.change(
              returned_render_id: render.id,
              returned_at: DateTime.utc_now()
            )
            |> Repo.update!()

            {:ok, %{clip: updated, render: render, duplicate?: false}}
          end
      end
    end
  end

  defp precheck_return(clip, actor, input) do
    with %ClipEditRequest{} = request <-
           Repo.get_by(ClipEditRequest, id: input["request_id"], clip_id: clip.id) ||
             {:error, :unauthorized},
         true <- assigned?(request, actor) || {:error, :unauthorized} do
      key = completion_key(actor, input["submission_id"])
      # A historical receipt need not still be open/latest. The locked path
      # checks its immutable fingerprint and returned-render linkage.
      if Repo.exists?(
           from(r in ClipRender, where: r.clip_id == ^clip.id and r.completion_key == ^key)
         ),
         do: :ok,
         else: returnable(clip, request, input)
    end
  end

  defp returnable(clip, request, input) do
    cond do
      request.returned_render_id != nil ->
        {:error, :request_already_returned}

      latest(clip.id).id != request.id or not awaiting?(clip, request) ->
        {:error, :request_not_open}

      request.base_render_id != input["base_render_id"] ->
        {:error, :stale_version}

      true ->
        :ok
    end
  end

  defp changed_content(request, file) do
    base = Repo.get!(ClipRender, request.base_render_id)

    case Platform.Files.get_file(base.file_id) do
      %{content_hash: hash} when hash == file.content_hash -> {:error, :same_content}
      nil -> {:error, :base_media_unavailable}
      _ -> :ok
    end
  end

  defp broadcast_return({:ok, %{clip: clip}} = result) do
    Social.broadcast_clip(clip)
    result
  end

  defp broadcast_return(result), do: result

  defp file_identity(file),
    do: Map.take(file, [:id, :project_id, :org_id, :content_hash, :byte_size, :content_type])

  defp prepare_return(clip, actor, input, file) do
    key = completion_key(actor, input["submission_id"])

    if Repo.exists?(
         from(r in ClipRender, where: r.clip_id == ^clip.id and r.completion_key == ^key)
       ) do
      # Replays compare the immutable receipt, never fresh measurements or current file facts.
      {:ok, nil}
    else
      if input["sha256"] != file.content_hash or input["byte_size"] != file.byte_size do
        {:error, :file_facts_mismatch}
      else
        prepared =
          with {:ok, path} <- Platform.Files.Extractor.local_path(file),
               {:ok, %{size: size}} <- File.stat(path),
               true <- size <= ClipClosingVideo.max_bytes(),
               {:ok, bytes} <- File.read(path),
               :ok <- bytes_identity(bytes, input) do
            prepare_bytes(bytes, input)
          else
            {:error, :file_facts_mismatch} ->
              {:error, :file_facts_mismatch}

            _ ->
              {:error, :unreadable_video}
          end

        case prepared do
          {:ok, facts} -> {:ok, Map.put(facts, :file_identity, file_identity(file))}
          error -> error
        end
      end
    end
  end

  defp admitted_file(profile, id) do
    with {:ok, file} <- AgentDrafts.check_clip_file(id, profile),
         true <- Platform.Files.finalized_upload?(file) and file.org_id in [nil, profile.org_id] do
      {:ok, file}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :file_not_finalized}
    end
  end

  defp current_file_access(profile, id) do
    case admitted_file(profile, id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp file_unchanged(profile, file, identity) do
    if (file && file.deleted_at == nil) and file.project_id == profile.project_id and
         Map.take(file, Map.keys(identity)) == identity, do: :ok, else: {:error, :file_changed}
  end

  defp actor_kind({:user, _}), do: "user"
  defp actor_kind({:agent, _, _}), do: "agent"
  defp actor_id({:user, id}), do: id
  defp actor_id({:agent, id, _}), do: id
  defp actor_agent_id({:agent, id, _}), do: id
  defp actor_agent_id(_), do: nil

  defp completion_key(actor, id),
    do: "revision:" <> actor_kind(actor) <> ":" <> actor_id(actor) <> ":" <> id

  defp return_fingerprint(clip_id, actor, input),
    do: fingerprint({:return, 1, actor_kind(actor), actor_id(actor), clip_id, Enum.sort(input)})

  def request_edit(scope, clip_id, user_id, attrs) when is_map(attrs) do
    with :ok <- outside_transaction(),
         {:ok, clip} <- scoped_clip(scope, clip_id),
         :ok <- human(Social.get_profile(scope, clip.profile_id), user_id),
         {:ok, input} <- request_input(attrs, user_id) do
      Repo.transaction(fn ->
        profile = Social.lock_profile(scope, clip.profile_id, :share) || Repo.rollback(:not_found)
        ok!(human(profile, user_id))
        clip = lock_clip(profile.id, clip.id) || Repo.rollback(:not_found)

        digest =
          fingerprint(
            {:request, 1, user_id, input.assignee, clip.id, input.base, input.note,
             input.replaces}
          )

        case Repo.get_by(ClipEditRequest, clip_id: clip.id, client_request_id: input.key) do
          %ClipEditRequest{request_payload_hash: ^digest} = existing ->
            {existing, false}

          %ClipEditRequest{} ->
            Repo.rollback(:idempotency_conflict)

          nil ->
            ok!(current_base(clip, input.base))
            ok!(requestable(clip, input))
            {kind, id} = input.assignee
            if kind == :agent, do: ok!(recipient(profile, id))

            decision_at = DateTime.utc_now()

            request =
              Repo.insert!(%ClipEditRequest{
                inserted_at: decision_at,
                clip_id: clip.id,
                base_render_id: input.base,
                requested_by_user_id: user_id,
                assigned_user_id: if(kind == :user, do: id),
                assigned_agent_id: if(kind == :agent, do: id),
                note: input.note,
                client_request_id: input.key,
                request_payload_hash: digest,
                notification_status: if(kind == :user, do: "not_applicable")
              })

            clip
            |> Clip.review_changeset({:reject, user_id, input.note}, decision_at)
            |> Ecto.Changeset.change(reviewed_render_id: input.base)
            |> Repo.update!()

            {request, true}
        end
      end)
      |> case do
        {:ok, {request, new?}} ->
          if new? and request.assigned_agent_id, do: deliver_notification(scope, request.id)
          request = Repo.get!(ClipEditRequest, request.id)
          Social.broadcast_clip(Repo.get!(Clip, clip.id))
          {:ok, %{request: request, notification: notification(request)}}

        error ->
          error
      end
    end
  end

  def request_edit(_, _, _, _), do: {:error, :invalid}

  def get_request(scope, id, actor) do
    with true <- uuid?(id),
         %ClipEditRequest{} = request <- Repo.get(ClipEditRequest, id),
         {:ok, clip} <- scoped_clip(scope, request.clip_id),
         profile <- Social.get_profile(scope, clip.profile_id),
         :ok <- ClipRevisionAccess.actor(profile, actor),
         true <- assigned?(request, actor) or human_actor?(actor) do
      {:ok,
       %{
         request: request,
         current_render_id: current_render_id(clip),
         awaiting?: latest(clip.id).id == request.id and awaiting?(clip, request)
       }}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def list_assigned(scope, actor) do
    with :ok <- ClipRevisionAccess.session(actor) do
      query =
        case actor do
          {:agent, id, _} -> from(r in ClipEditRequest, where: r.assigned_agent_id == ^id)
          {:user, id} -> from(r in ClipEditRequest, where: r.assigned_user_id == ^id)
        end

      # Page only after current authority/latest-state filtering. A pre-filter
      # cap would misreport totals and hide older active assignments.
      values =
        Repo.all(
          from(r in query,
            join: c in Clip,
            on: c.id == r.clip_id,
            where:
              is_nil(r.returned_render_id) and c.status == "rendered" and
                c.review_status == "rejected" and is_nil(c.removed_at) and c.flow == "legacy",
            order_by: [desc: r.position]
          )
        )
        |> Enum.flat_map(fn request ->
          case get_request(scope, request.id, actor) do
            {:ok, %{awaiting?: true} = value} -> [value]
            _ -> []
          end
        end)

      {:ok, values}
    end
  end

  defp requestable(%Clip{review_status: "pending"}, %{replaces: nil}), do: :ok

  defp requestable(clip, %{replaces: id}) when is_binary(id) do
    case latest(clip.id) do
      %ClipEditRequest{id: ^id} = request ->
        if awaiting?(clip, request) and notification_replaceable?(request),
          do: :ok,
          else: {:error, :request_not_replaceable}

      _ ->
        {:error, :request_not_replaceable}
    end
  end

  defp requestable(_, %{replaces: nil}), do: {:error, :not_pending}
  defp requestable(_, _), do: {:error, :request_not_replaceable}

  @doc false
  def notification_replaceable?(request),
    do:
      request.notification_status in ["failed", "uncertain"] or
        (not is_nil(request.assigned_agent_id) and
           request.notification_status in [nil, "attempted"])

  defp deliver_notification(scope, id) do
    reservation =
      Repo.transaction(fn ->
        request = Repo.get!(ClipEditRequest, id)
        clip = Social.get_clip(scope, request.clip_id) || Repo.rollback(:not_found)
        profile = Social.lock_profile(scope, clip.profile_id, :share) || Repo.rollback(:not_found)
        clip = lock_clip(profile.id, clip.id) || Repo.rollback(:not_found)
        request = Repo.one!(from(r in ClipEditRequest, where: r.id == ^id, lock: "FOR UPDATE"))
        if request.notification_status != nil, do: Repo.rollback(:already_attempted)

        if latest(clip.id).id != id or not awaiting?(clip, request),
          do: Repo.rollback(:superseded)

        ok!(human(profile, request.requested_by_user_id))
        ok!(recipient(profile, request.assigned_agent_id))

        {count, _} =
          Repo.update_all(
            from(r in ClipEditRequest,
              where: r.id == ^id and is_nil(r.notification_status)
            ),
            set: [notification_status: "attempted", notification_attempted_at: DateTime.utc_now()]
          )

        if count != 1, do: Repo.rollback(:already_attempted)
        {request, profile}
      end)

    case reservation do
      {:ok, {request, profile}} ->
        # All Social row locks have been released before Chat's external routing effects.
        {status, message_id} =
          notification_attempt(fn ->
            with {:ok, participant} <- Social.Approvals.system_participant(profile.space_id),
                 %{} = agent <- Repo.get(Platform.Agents.Agent, request.assigned_agent_id) do
              Platform.Chat.post_message(%{
                space_id: profile.space_id,
                participant_id: participant.id,
                content_type: "text",
                content:
                  "@[#{agent.name}] A clip is awaiting your edit. " <>
                    "Read editing request #{request.id} for clip #{request.clip_id} using social_clip_edit_request_get; " <>
                    "return it with social_clip_version_append. " <>
                    "[Open editing request](" <>
                    "/m/social?" <>
                    URI.encode_query(%{
                      "tab" => "clips",
                      "view" => "review",
                      "profile" => profile.id,
                      "clip" => request.clip_id
                    }) <>
                    "#clip-edit-request-#{request.id}). Existing posts are unchanged.",
                metadata: %{"social_clip_edit_request_id" => request.id}
              })
            else
              _ -> {:error, :not_sent}
            end
          end)

        Repo.update_all(
          from(r in ClipEditRequest, where: r.id == ^id and r.notification_status == "attempted"),
          set: [notification_status: status, notification_message_id: message_id]
        )

      _ ->
        :ok
    end
  end

  @doc false
  def notification_attempt(fun) do
    # Chat.post_message's error tuples precede insertion; a thrown or unknown
    # outcome may follow insertion/routing, so absence cannot be asserted.
    try do
      case fun.() do
        {:ok, %{id: id}} when is_binary(id) -> {"sent", id}
        {:error, _} -> {"failed", nil}
        _ -> {"uncertain", nil}
      end
    rescue
      _ -> {"uncertain", nil}
    catch
      _, _ -> {"uncertain", nil}
    end
  end

  defp notification(%{notification_status: status}),
    do:
      Map.get(
        %{"not_applicable" => :not_applicable, "sent" => :sent, "failed" => :failed},
        status,
        :uncertain
      )

  defp human_actor?({:user, _}), do: true
  defp human_actor?(_), do: false
  defp assigned?(request, {:user, id}), do: request.assigned_user_id == id
  defp assigned?(request, {:agent, id, _}), do: request.assigned_agent_id == id

  defp recipient(profile, id) do
    case ClipRevisionAccess.recipient(profile, id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def state(scope, clip_id, {:user, user_id}) do
    with {:ok, clip} <- scoped_clip(scope, clip_id),
         :ok <- human(Social.get_profile(scope, clip.profile_id), user_id) do
      request = latest(clip.id)
      if awaiting?(clip, request), do: {:ok, "Awaiting edit"}, else: {:ok, nil}
    end
  end

  def latest(clip_id) do
    Repo.one(
      from(r in ClipEditRequest,
        where: r.clip_id == ^clip_id,
        order_by: [desc: r.position],
        limit: 1
      )
    )
  end

  @doc "Identify editing-note provenance even on a historical clip snapshot; this grants no read authority."
  def editing_note?(%Clip{
        review_note: note,
        reviewed_render_id: render_id,
        reviewed_by_user_id: user_id,
        reviewed_at: %DateTime{} = at,
        id: clip_id
      })
      when is_binary(note) do
    Enum.all?([render_id, user_id, clip_id], &uuid?/1) and
      Repo.exists?(
        from(r in ClipEditRequest,
          where:
            r.clip_id == ^clip_id and r.base_render_id == ^render_id and
              r.requested_by_user_id == ^user_id and r.inserted_at == ^at and r.note == ^note
        )
      )
  end

  def editing_note?(_), do: false

  def awaiting?(
        %Clip{status: "rendered", review_status: "rejected", removed_at: nil} = clip,
        %ClipEditRequest{returned_render_id: nil, base_render_id: id} = request
      ) do
    # Same status/base is insufficient: undo followed by a bare rejection must
    # never revive an older instruction, even with the same actor and note.
    uuid?(id) and clip.reviewed_render_id == id and
      clip.reviewed_at == request.inserted_at and
      clip.reviewed_by_user_id == request.requested_by_user_id and
      clip.review_note == request.note and current_base(clip, id) == :ok
  end

  def awaiting?(_, _), do: false

  defp request_input(attrs, user_id) do
    key = Map.get(attrs, :request_id, attrs["request_id"])
    base = Map.get(attrs, :base_render_id, attrs["base_render_id"])
    note = Map.get(attrs, :note, attrs["note"])
    assignee = Map.get(attrs, :assignee, attrs["assignee"])

    assignee =
      case assignee do
        value when value in [:self, "self"] -> {:user, user_id}
        {:agent, id} -> {:agent, id}
        %{"agent_id" => id} -> {:agent, id}
        _ -> nil
      end

    replaces = Map.get(attrs, :replaces_request_id, attrs["replaces_request_id"])

    cond do
      not uuid?(key) or not uuid?(base) ->
        {:error, :invalid_identity}

      not is_binary(note) or String.trim(note) == "" ->
        {:error, :note_required}

      String.length(String.trim(note)) > 2000 ->
        {:error, :note_too_long}

      is_nil(assignee) ->
        {:error, :invalid_assignee}

      not is_nil(replaces) and not uuid?(replaces) ->
        {:error, :invalid_identity}

      true ->
        {:ok,
         %{key: key, base: base, note: String.trim(note), assignee: assignee, replaces: replaces}}
    end
  end

  defp human(profile, user_id), do: ClipRevisionAccess.human(profile, user_id)

  defp scoped_clip(scope, id) do
    case uuid?(id) && Social.get_clip(scope, id) do
      %Clip{removed_at: nil, flow: "legacy"} = clip -> {:ok, clip}
      _ -> {:error, :not_found}
    end
  end

  defp lock_clip(profile_id, clip_id),
    do:
      Repo.one(
        from(c in Clip,
          where:
            c.id == ^clip_id and c.profile_id == ^profile_id and
              c.flow == "legacy" and is_nil(c.removed_at),
          lock: "FOR UPDATE"
        )
      )

  defp current_base(clip, id) do
    if Repo.exists?(
         from(r in ClipRender,
           where:
             r.id == ^id and r.clip_id == ^clip.id and
               r.rev == ^clip.rev and is_nil(r.removed_at)
         )
       ), do: :ok, else: {:error, :stale_version}
  end

  defp current_render_id(clip),
    do:
      Repo.one(
        from(r in ClipRender,
          where: r.clip_id == ^clip.id and r.rev == ^clip.rev and is_nil(r.removed_at),
          select: r.id
        )
      )

  defp uuid?(id),
    do:
      is_binary(id) and
        Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, id)

  defp outside_transaction,
    do: if(Repo.in_transaction?(), do: {:error, :caller_transaction}, else: :ok)

  defp fingerprint(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp ok!(:ok), do: :ok
  defp ok!({:error, reason}), do: Repo.rollback(reason)
end
