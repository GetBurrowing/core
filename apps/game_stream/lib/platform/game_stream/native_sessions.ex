defmodule Platform.GameStream.NativeSessions do
  @moduledoc "Durable native mode of Play. All slot allocation is serialized by the session row."
  import Ecto.Query
  alias Platform.{Repo, Federation}
  alias Platform.Accounts.User
  alias Platform.Chat.Space
  alias Platform.GameStream.{GameChannels, NativeBuild, NativeSessionRecord, JoinToken, Provider}
  alias Platform.Types.UUIDv7
  @active ~w(starting running stopping)
  @public ~w(id channel_id project_id build_id protocol_version state endpoint reason capacity generation started_at idle_timeout_s)a

  def play(user, channel_id) do
    with true <- Platform.GameStream.enabled?(),
         {:ok, _binding} <- GameChannels.authorize(user, channel_id),
         {:ok, row} <-
           transaction(fn ->
             Repo.one!(from(s in Space, where: s.id == ^channel_id, lock: "FOR UPDATE"))
             # Recheck authorization after waiting for a channel configuration change.
             {:ok, current} = checked(GameChannels.authorize(user, channel_id))

             row =
               Repo.one(
                 from(s in NativeSessionRecord,
                   where: s.channel_id == ^channel_id and s.state in ^@active
                 )
               )

             if row do
               row
             else
               build = NativeBuild.latest(current.project_id) || Repo.rollback(:no_build)
               host = pick_host() || Repo.rollback(:no_native_host)
               {experiment, variant, timeout} = resolve_idle(channel_id, current.project_id)
               now = DateTime.utc_now()

               Repo.insert!(%NativeSessionRecord{
                 id: UUIDv7.generate(),
                 channel_id: channel_id,
                 project_id: current.project_id,
                 build_id: build.id,
                 immutable_build: build.manifest,
                 server_image: build.manifest["server_image"],
                 protocol_version: build.manifest["protocol_version"],
                 capacity: build.manifest["capacity"],
                 host_runtime_id: host.runtime_id,
                 idle_timeout_s: timeout,
                 experiment_id: experiment,
                 variant_slug: variant,
                 started_at: now,
                 idle_since: now,
                 heartbeat_at: now
               })
             end
           end),
         :ok <- ensure_started(row) do
      {:ok, public(row)}
    else
      false -> {:error, :disabled}
      error -> error
    end
  end

  def status(user, channel_id) do
    with {:ok, _} <- GameChannels.authorize(user, channel_id) do
      row =
        Repo.one(
          from(s in NativeSessionRecord,
            where: s.channel_id == ^channel_id,
            order_by: [desc: s.started_at],
            limit: 1
          )
        )

      {:ok, if(row, do: public(row), else: nil)}
    end
  end

  def mint(user, session_id) do
    if Platform.GameStream.enabled?(), do: reserve(user, session_id), else: {:error, :disabled}
  end

  defp reserve(user, session_id) do
    transaction(fn ->
      unless Platform.UUID.valid?(session_id), do: Repo.rollback(:not_found)
      row = locked(session_id)
      {:ok, binding} = checked(GameChannels.authorize(user, row.channel_id))
      unless binding.project_id == row.project_id, do: Repo.rollback(:unauthorized)
      unless row.state == "running" and fresh?(row), do: Repo.rollback(:not_running)
      now = DateTime.utc_now()
      held = reservations(row.id, now)
      if Enum.any?(held, &(&1.user_id == user.id)), do: Repo.rollback(:already_reserved)
      taken = MapSet.new(held, & &1.slot)
      slot = Enum.find(0..(row.capacity - 1), &(not MapSet.member?(taken, &1)))
      if is_nil(slot), do: Repo.rollback(:full)

      reconnect? =
        Repo.exists?(
          from(t in JoinToken,
            where: t.session_id == ^row.id and t.user_id == ^user.id and not is_nil(t.consumed_at)
          )
        )

      if reconnect?,
        do:
          Repo.update!(Ecto.Changeset.change(row, reconnect_attempts: row.reconnect_attempts + 1))

      raw = JoinToken.mint()

      token =
        Repo.insert!(%JoinToken{
          id: UUIDv7.generate(),
          session_id: row.id,
          user_id: user.id,
          channel_id: row.channel_id,
          build_id: row.build_id,
          generation: row.generation,
          digest: JoinToken.hash(raw),
          slot: slot,
          expires_at: DateTime.add(now, 60)
        })

      # No broadcast, logging or persistence of the raw token. Returned ONLY to its user.
      %{
        token: raw,
        expires_at: token.expires_at,
        server: row.endpoint,
        session_id: row.id,
        channel_id: row.channel_id,
        build_id: row.build_id,
        protocol_version: row.protocol_version,
        generation: row.generation,
        user_id: user.id
      }
    end)
  end

  def control(session_id, credential) when is_binary(credential) do
    with true <- Platform.GameStream.enabled?(),
         true <- Platform.UUID.valid?(session_id),
         %NativeSessionRecord{} = row <- Repo.get(NativeSessionRecord, session_id),
         true <- row.state == "running" and fresh?(row) and host_authorized?(row, credential) do
      {:ok, %{session_id: row.id, generation: row.generation, state: "running"}}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def consume(session_id, credential, claims) when is_binary(credential) and is_map(claims) do
    transaction(fn ->
      unless Platform.GameStream.enabled?(), do: Repo.rollback(:unauthorized)
      unless Platform.UUID.valid?(session_id), do: Repo.rollback(:not_found)
      row = locked(session_id)

      unless host_authorized?(row, credential) and row.state == "running" and fresh?(row),
        do: Repo.rollback(:unauthorized)

      now = DateTime.utc_now()
      raw = claims["token"]
      unless is_binary(raw) and byte_size(raw) in 32..128, do: Repo.rollback(:unauthorized)

      token =
        Repo.one(
          from(t in JoinToken, where: t.digest == ^JoinToken.hash(raw), lock: "FOR UPDATE")
        )

      unless (not is_nil(token) && is_nil(token.consumed_at) && DateTime.compare(token.expires_at, now) == :gt &&
                token.session_id == row.id && token.channel_id == row.channel_id &&
                token.build_id == row.build_id &&
                token.generation == row.generation && claims["build_id"] == row.build_id &&
                claims["channel_id"] == row.channel_id && claims["user_id"] == token.user_id &&
                claims["generation"] == row.generation) and
               claims["protocol_version"] == row.protocol_version,
             do: Repo.rollback(:unauthorized)

      user = Repo.get(User, token.user_id) || Repo.rollback(:unauthorized)
      {:ok, binding} = checked(GameChannels.authorize(user, row.channel_id))
      unless binding.project_id == row.project_id, do: Repo.rollback(:unauthorized)

      reconnect =
        Repo.exists?(
          from(t in JoinToken,
            where:
              t.session_id == ^row.id and
                t.user_id == ^token.user_id and not is_nil(t.consumed_at)
          )
        )

      Repo.update!(Ecto.Changeset.change(token, consumed_at: now, connected: true))

      Repo.update!(
        Ecto.Changeset.change(row,
          idle_since: nil,
          connect_count: row.connect_count + 1,
          reconnect_count: row.reconnect_count + if(reconnect, do: 1, else: 0)
        )
      )

      %{admission_id: token.id, slot: token.slot, user_id: token.user_id, build_id: row.build_id}
    end)
  end

  def consume(_, _, _), do: {:error, :unauthorized}

  # Called ONLY by the existing authenticated runtime event seam. A server cannot
  # change its immutable build, generation or endpoint after becoming running.
  def host_status(runtime_id, payload) do
    with id when is_binary(id) <- payload["session_id"],
         true <- Platform.UUID.valid?(id),
         {:ok, row} <-
           transaction(fn ->
             row = locked(id)

             unless row.host_runtime_id == runtime_id && payload["generation"] == row.generation,
               do: Repo.rollback(:unauthorized)

             state = payload["state"]
             unless state in ~w(running ended failed), do: Repo.rollback(:invalid_status)

             cond do
               row.state not in @active ->
                 row

               row.state == "stopping" and state == "running" ->
                 row

               state in ~w(ended failed) ->
                 finish(
                   row,
                   state,
                   if(state == "failed",
                     do: "Native host stopped or could not start",
                     else: "Session ended"
                   )
                 )

               true ->
                 hash = payload["credential_hash"]
                 endpoint = payload["endpoint"]

                 unless (is_binary(hash) and Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)) &&
                          valid_endpoint?(endpoint),
                        do: Repo.rollback(:invalid_status)

                 if row.state == "running" &&
                      (row.host_credential_hash != hash || row.endpoint != endpoint),
                    do: Repo.rollback(:identity_changed)

                 admissions = payload["admissions"]

                 unless is_list(admissions) and length(admissions) <= row.capacity and
                          Enum.all?(admissions, &(is_binary(&1) and Platform.UUID.valid?(&1))),
                        do: Repo.rollback(:invalid_status)

                 # Only already consumed reservations may be reported as connected.
                 elapsed =
                   max(
                     0,
                     min(
                       30,
                       DateTime.diff(DateTime.utc_now(), row.heartbeat_at || row.started_at)
                     )
                   )

                 connected_count =
                   Repo.aggregate(
                     from(t in JoinToken, where: t.session_id == ^row.id and t.connected),
                     :count
                   )

                 # Give an admitted peer time to appear in the game's next roster file.
                 cutoff = DateTime.add(DateTime.utc_now(), -15)

                 Repo.update_all(
                   from(t in JoinToken,
                     where:
                       t.session_id == ^row.id and
                         t.connected and t.id not in ^admissions and t.consumed_at < ^cutoff
                   ),
                   set: [connected: false]
                 )

                 active? = reservations(row.id, DateTime.utc_now()) != []

                 Repo.update!(
                   Ecto.Changeset.change(row,
                     state: "running",
                     endpoint: endpoint,
                     host_handle: row.id,
                     host_credential_hash: hash,
                     heartbeat_at: DateTime.utc_now(),
                     player_seconds: row.player_seconds + elapsed * connected_count,
                     idle_seconds:
                       row.idle_seconds + if(connected_count == 0, do: elapsed, else: 0),
                     idle_since: if(active?, do: nil, else: row.idle_since || DateTime.utc_now())
                   )
                 )
             end
           end) do
      broadcast(row)
      :ok
    else
      _ -> {:error, :invalid_status}
    end
  end

  def tick(now \\ DateTime.utc_now()) do
    Repo.all(from(s in NativeSessionRecord, where: s.state in ^@active, select: s.id))
    |> Enum.each(fn id ->
      case transaction(fn ->
             row = locked(id)

             cond do
               row.state not in @active ->
                 {:none, row}

               row.state == "starting" and DateTime.diff(now, row.started_at) >= 90 ->
                 {:stop, stopping(row, "Server start timed out", now)}

               row.state == "stopping" and DateTime.diff(now, row.updated_at) >= 90 ->
                 {:none, finish(row, "failed", "Host did not confirm stop")}

               row.state == "stopping" ->
                 {:stop, row}

               DateTime.diff(now, row.heartbeat_at || row.started_at) >= 90 ->
                 {:stop, stopping(row, "Host heartbeat timed out", now)}

               row.state == "running" and reservations(row.id, now) == [] ->
                 idle = row.idle_since || now

                 if DateTime.diff(now, idle) >= row.idle_timeout_s do
                   {:stop, stopping(row, "idle", now)}
                 else
                   {:reconcile, Repo.update!(Ecto.Changeset.change(row, idle_since: idle))}
                 end

               true ->
                 {:reconcile, row}
             end
           end) do
        {:ok, {:stop, row}} -> Provider.native().stop(handle(row), row.reason)
        {:ok, {:reconcile, row}} -> Provider.native().reconcile(row.id)
        _ -> :ok
      end
    end)

    :ok
  end

  def public(row) do
    roster =
      Repo.all(
        from(t in JoinToken,
          where: t.session_id == ^row.id and t.connected,
          select: %{user_id: t.user_id, slot: t.slot}
        )
      )

    row |> Map.take(@public) |> Map.put(:roster, roster)
  end

  defp ensure_started(%{state: "starting"} = row) do
    limits = %{
      host_runtime_id: row.host_runtime_id,
      generation: row.generation,
      idle_timeout_s: row.idle_timeout_s,
      capacity: row.capacity,
      build_id: row.build_id,
      protocol_version: row.protocol_version
    }

    case Provider.native().start(row.id, row.immutable_build, limits) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :host_unavailable}
    end
  end

  defp ensure_started(%{state: "running"}), do: :ok
  defp ensure_started(_), do: {:error, :stopping}
  defp pick_host, do: Federation.present_runtimes_with_feature("game_native_host") |> List.first()

  defp locked(id),
    do:
      Repo.one(from(s in NativeSessionRecord, where: s.id == ^id, lock: "FOR UPDATE")) ||
        Repo.rollback(:not_found)

  defp transaction(fun), do: Repo.transaction(fun)
  defp checked({:ok, value}), do: {:ok, value}
  defp checked({:error, error}), do: Repo.rollback(error)
  defp fresh?(row), do: DateTime.diff(DateTime.utc_now(), row.heartbeat_at || row.started_at) < 30

  defp reservations(id, now),
    do:
      Repo.all(
        from(t in JoinToken,
          where:
            t.session_id == ^id and
              (t.connected or (is_nil(t.consumed_at) and t.expires_at > ^now))
        )
      )

  defp handle(row), do: %{session_id: row.id, host_runtime_id: row.host_runtime_id}

  defp host_authorized?(row, raw),
    do:
      is_binary(row.host_credential_hash) and
        Plug.Crypto.secure_compare(row.host_credential_hash, JoinToken.hash(raw))

  defp valid_endpoint?(endpoint),
    do:
      is_binary(endpoint) and
        Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}:[0-9]{1,5}\z/, endpoint) and
        (endpoint |> String.split(":") |> List.last() |> String.to_integer()) in 1..65535

  defp stopping(row, reason, now),
    do:
      Repo.update!(
        Ecto.Changeset.change(row,
          state: "stopping",
          reason: reason,
          idle_seconds:
            row.idle_seconds +
              if(row.idle_since,
                do: max(0, min(30, DateTime.diff(now, row.heartbeat_at || row.started_at))),
                else: 0
              )
        )
      )

  defp finish(row, state, reason) do
    Repo.update_all(from(t in JoinToken, where: t.session_id == ^row.id), set: [connected: false])

    Repo.update!(
      Ecto.Changeset.change(row,
        state: state,
        reason: reason,
        ended_at: DateTime.utc_now(),
        host_credential_hash: nil,
        duration_s: max(0, DateTime.diff(DateTime.utc_now(), row.started_at))
      )
    )
  end

  defp broadcast(row),
    do:
      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        Platform.GameStream.topic(row.id),
        {:native_session, public(row)}
      )

  defp resolve_idle(channel_id, project_id) do
    subject = Platform.Experiments.Subject.new("channel", channel_id, %{project_id: project_id})

    result =
      Platform.Experiments.Surfaces.resolve(
        "game_stream.native_idle",
        "native_session.start",
        subject
      )

    case result do
      {:variant, experiment, slug, %{"idle_timeout_s" => timeout}}
      when timeout in [300, 600, 900] ->
        {experiment.id, slug, timeout}

      {:default, %{"idle_timeout_s" => timeout}} when timeout in [300, 600, 900] ->
        {nil, "default", timeout}

      _ ->
        {nil, "control", 600}
    end
  end
end
