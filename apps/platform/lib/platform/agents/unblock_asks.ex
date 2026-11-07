defmodule Platform.Agents.UnblockAsks do
  @moduledoc """
  Unblock asks (task 01a1b6de stage 4): the lead agent asks the one human who
  can unstick a subject, as an `agent_unblock_ask` Inbox item backed by an
  `unblock_asks` row (`Platform.Agents.UnblockAsk`).

  Subjects are agents the team check classified as blocked
  (`Platform.Agents.TeamCheck`, stage 3) and people stuck on setup steps
  (`Platform.Onboarding.PersonSetup`, stage 2).

  ## Who is asked

    * an agent: its classified fixer, the sponsor (the owning runtime's
      `owner_user_id`) or else the install owner;
    * a person: the person, since only they can finish their own setup.

  ## One ask per subject and class

  `sync_agents/2` and `sync_people/2` run on every `agents.team_check` fire.
  For each blocked subject there is at most ONE live ask per class (the
  partial unique index `unblock_asks_live_subject_class_index`):

    * no live ask: one is written and the fixer's Inbox gets one row;
    * a live ask whose state fingerprint CHANGED: the ask is updated in
      place (evidence, details, fingerprint). No new ask, no re-ask;
    * a live ask whose fingerprint is UNCHANGED: re-asked only when
      `now - last_asked_at >= interval`. A re-ask moves `last_asked_at`,
      bumps `ask_count`, reopens a "Not now", and replaces the Inbox row so
      exactly one stays listed. Before the interval nothing happens.

  The interval is resolved per subject through the experiment surface
  `agents.unblock_ask.reask_interval` (`interval_for/2`): a running arm or a
  promoted default wins, else `TeamCheck.reask_after_hours/1` (operator
  config, row metadata, then config).

  ## Clearing is derived from the subject's state (ADR 0049)

  A live ask resolves when the check no longer reads its class: an agent
  that reads `:ok`, an access ask on an agent now blocked by something else,
  an offline ask on an agent that is present again, a person no longer
  stuck. An `:offline` reading resolves nothing else: an agent that cannot be
  reached cannot show its access was fixed. The Inbox reconciler dismisses a
  resolved or "Not now" ask's row (`inbox_row_stale?/1`).

  ## "I did it, check again"

  `check_again/3` never marks done by itself. It sets the ask `verifying`,
  asks the agent's owning runtime to re-verify (a `unblock_check_requested`
  push on `runtime:<runtime_id>`, the channel `BlockerReassessment` uses),
  re-runs the stage-3 check for that subject NOW, and then either resolves
  the ask with its success line or reopens it with a plain still-missing
  line. `begin_check/2` and `finish_check/2` are the two halves, for a
  caller that shows `verifying` in between.

  Granting anything is out of scope: an ask links to the setting and a human
  grants.
  """

  import Ecto.Query

  require Logger

  alias Platform.Accounts
  alias Platform.Agents.TeamCheck
  alias Platform.Agents.UnblockAsk
  alias Platform.Agents.UnblockAsks.Templates
  alias Platform.Experiments.Subject
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.UnblockAskReaskInterval, as: Surface
  alias Platform.Inbox
  alias Platform.Onboarding.PersonSetup
  alias Platform.Repo

  @kind "agent_unblock_ask"
  @source_type "unblock_ask"
  @person_class "person_setup"
  @live UnblockAsk.live_statuses()

  @doc "The Inbox kind."
  def kind, do: @kind

  @doc "The Inbox source type."
  def source_type, do: @source_type

  @doc "Where the Inbox row opens."
  @spec url(String.t()) :: String.t()
  def url(ask_id) when is_binary(ask_id), do: "/inbox/unblock/" <> ask_id

  @doc "PubSub topic carrying `{:unblock_ask_changed, ask}` for one fixer."
  def topic(user_id), do: "unblock_asks:#{user_id}"

  @doc """
  The fingerprint of a classified state: a digest of the class and the
  classifier's stable `basis` (no growing ages), so it changes only when the
  state does.
  """
  @spec fingerprint(String.t() | atom(), String.t()) :: String.t()
  def fingerprint(class, basis) do
    :crypto.hash(:sha256, "#{class}\n#{basis}") |> Base.encode16(case: :lower)
  end

  @doc """
  The re-ask interval in hours for `subject_id`, and the experiment arm it
  came from (nil when none): the `agents.unblock_ask.reask_interval` arm or
  promoted default first, else `TeamCheck.reask_after_hours(row)`.
  """
  @spec interval_for(String.t(), Platform.Responsibilities.Responsibility.t() | nil) ::
          {pos_integer(), String.t() | nil}
  def interval_for(subject_id, row) do
    subject = Subject.new(Surface.subject_type(), subject_id)

    case Surfaces.resolve(Surface.key(), Surface.target(), subject) do
      {:variant, _experiment, slug, %{"reask_after_hours" => hours}} when is_integer(hours) ->
        {hours, slug}

      {:default, payload} ->
        case Surface.validate_payload(payload) do
          {:ok, %{"reask_after_hours" => hours}} -> {hours, nil}
          _ -> {TeamCheck.reask_after_hours(row), nil}
        end

      _ ->
        {TeamCheck.reask_after_hours(row), nil}
    end
  end

  # ── sync ─────────────────────────────────────────────────────────────────

  @doc """
  Bring the asks in line with agent `statuses` (`TeamCheck.statuses/1`).
  Returns `[{outcome, ask, status}]` for every ask touched, `outcome` one of
  `:asked`, `:reasked`, `:updated` or `:resolved`.

  Options: `:row` (the `agents.team_check` row), `:now`.
  """
  @spec sync_agents([map()], keyword()) :: [{atom(), UnblockAsk.t(), map()}]
  def sync_agents(statuses, opts \\ []) do
    row = Keyword.get(opts, :row)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    Enum.flat_map(statuses, fn status ->
      live = live_asks("agent", status.agent_id)
      class = Atom.to_string(status.class)

      resolved =
        live
        |> Enum.filter(&cleared_by?(&1.class, status.class))
        |> Enum.flat_map(&resolve_outcome(&1, status, now))

      asked =
        case {status.class, status.fixer} do
          {:ok, _} ->
            []

          {_, %{id: owner_id}} when is_binary(owner_id) ->
            attrs = %{
              subject_type: "agent",
              subject_id: status.agent_id,
              class: class,
              state_fingerprint: fingerprint(class, status.basis),
              owner_user_id: owner_id,
              evidence: status.evidence,
              details: Map.merge(Map.get(status, :details, %{}), %{"agent" => status.agent_name})
            }

            upsert(attrs, Enum.find(live, &(&1.class == class)), row, now, status)

          _ ->
            []
        end

      resolved ++ asked
    end)
  end

  # Which live asks a reading clears. `:offline` clears nothing but itself
  # can't be cleared by an offline reading; any present reading clears an
  # offline ask; a text class clears asks of other text classes.
  defp cleared_by?(_ask_class, :offline), do: false
  defp cleared_by?("offline", _class), do: true
  defp cleared_by?(_ask_class, :ok), do: true
  defp cleared_by?(ask_class, class), do: ask_class != Atom.to_string(class)

  @doc """
  Bring the people asks in line with `PersonSetup`: one `person_setup` ask
  per person with a stuck step, addressed to that person, resolved once no
  step is stuck. Options: `:row`, `:now`, `:users` (default every active
  user), `:stuck_after_seconds` (passed to `PersonSetup.status/2`).
  """
  @spec sync_people(keyword()) :: [{atom(), UnblockAsk.t(), map()}]
  def sync_people(opts \\ []) do
    row = Keyword.get(opts, :row)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    users = Keyword.get_lazy(opts, :users, fn -> Accounts.list_users() end)
    setup_opts = Keyword.take(opts, [:now, :stuck_after_seconds]) |> Keyword.put(:now, now)

    Enum.flat_map(users, fn user ->
      status = person_status(user, setup_opts)
      live = live_asks("person", user.id) |> Enum.filter(&(&1.class == @person_class))

      case status do
        %{stuck: [_ | _] = stuck} ->
          steps = Enum.map(stuck, &Atom.to_string/1)

          attrs = %{
            subject_type: "person",
            subject_id: user.id,
            class: @person_class,
            state_fingerprint: fingerprint(@person_class, Enum.join(Enum.sort(steps), ",")),
            owner_user_id: user.id,
            evidence: "Setup steps still open: " <> Enum.join(steps, ", "),
            details: %{"steps" => steps, "owner" => user.name}
          }

          upsert(attrs, List.first(live), row, now, %{user: user, setup: status})

        _ ->
          Enum.flat_map(live, &resolve_outcome(&1, %{user: user, setup: status}, now))
      end
    end)
  end

  defp person_status(user, opts) do
    PersonSetup.status(user, opts)
  rescue
    error ->
      Logger.warning("[unblock_asks] person setup read raised: #{inspect(error.__struct__)}")
      nil
  end

  defp upsert(attrs, nil, row, now, status) do
    {hours, variant} = interval_for(attrs.subject_id, row)

    changeset =
      UnblockAsk.changeset(
        %UnblockAsk{},
        Map.merge(attrs, %{
          status: "open",
          asked_at: now,
          last_asked_at: now,
          ask_count: 1,
          variant: variant,
          reask_after_hours: hours
        })
      )

    case Repo.insert(changeset) do
      {:ok, ask} ->
        emit(ask)
        [{:asked, ask, status}]

      {:error, reason} ->
        Logger.warning("[unblock_asks] could not write an ask: #{inspect(reason)}")
        []
    end
  end

  defp upsert(attrs, %UnblockAsk{} = live, row, now, status) do
    {hours, variant} = interval_for(live.subject_id, row)

    cond do
      live.state_fingerprint != attrs.state_fingerprint ->
        write(live, Map.take(attrs, [:state_fingerprint, :evidence, :details, :owner_user_id]))
        |> moved_owner(live)
        |> tag(:updated, status)

      DateTime.diff(now, live.last_asked_at, :second) >= hours * 3600 ->
        case write(
               live,
               Map.merge(Map.take(attrs, [:evidence, :details, :owner_user_id]), %{
                 status: "open",
                 last_asked_at: now,
                 ask_count: live.ask_count + 1,
                 still_missing: nil,
                 variant: variant,
                 reask_after_hours: hours
               })
             ) do
          {:ok, ask} ->
            Inbox.dismiss_by_source(live.owner_user_id, @source_type, ask.id, kind: @kind)
            emit(ask)
            [{:reasked, ask, status}]

          _ ->
            []
        end

      true ->
        []
    end
  end

  # The interval is resolved per subject at each check, so a changed
  # operator value or a new arm applies to live asks too.
  defp moved_owner({:ok, ask}, %UnblockAsk{owner_user_id: old}) when ask.owner_user_id != old do
    Inbox.dismiss_by_source(old, @source_type, ask.id, kind: @kind)
    emit(ask)
    {:ok, ask}
  end

  defp moved_owner(result, _live), do: result

  defp tag({:ok, ask}, outcome, status), do: [{outcome, ask, status}]
  defp tag(_error, _outcome, _status), do: []

  defp resolve_outcome(ask, status, now) do
    case resolve(ask, now) do
      {:ok, resolved} -> [{:resolved, resolved, status}]
      _ -> []
    end
  end

  # ── the fixer's actions ─────────────────────────────────────────────────

  @doc """
  "I did it, check again": `begin_check/2` then `finish_check/2`. Returns
  `{:ok, %{ask, outcome: :resolved | :still_missing, message}}`, or
  `{:error, :not_found | :already_resolved}`.

  Options: `:row`, `:now`, `:federation` (passed to `TeamCheck.statuses/1`),
  `:stuck_after_seconds` (passed to `PersonSetup.status/2`).
  """
  @spec check_again(term(), term(), keyword()) ::
          {:ok, %{ask: UnblockAsk.t(), outcome: atom(), message: String.t()}}
          | {:error, :not_found | :already_resolved | term()}
  def check_again(ask_id, user_id, opts \\ []) do
    with {:ok, ask} <- begin_check(ask_id, user_id, opts) do
      finish_check(ask, opts)
    end
  end

  @doc """
  Set a live ask `verifying` and ask the agent's owning runtime to re-verify.
  Owner-scoped: only the ask's fixer may. Never resolves anything.
  """
  @spec begin_check(term(), term(), keyword()) ::
          {:ok, UnblockAsk.t()} | {:error, :not_found | :already_resolved | term()}
  def begin_check(ask_id, user_id, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    result =
      Repo.transaction(fn ->
        case lock_for_owner(ask_id, user_id) do
          nil ->
            Repo.rollback(:not_found)

          %UnblockAsk{status: "resolved"} ->
            Repo.rollback(:already_resolved)

          ask ->
            case write(ask, %{status: "verifying", checked_at: now}) do
              {:ok, ask} -> ask
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      end)

    with {:ok, ask} <- result do
      request_runtime_check(ask, opts)
      broadcast(ask)
      {:ok, ask}
    end
  end

  @doc """
  Re-run the subject's check now and settle a `verifying` ask: resolved with
  the success line when its class no longer reads, else reopened with what
  is still missing.
  """
  @spec finish_check(UnblockAsk.t(), keyword()) ::
          {:ok, %{ask: UnblockAsk.t(), outcome: atom(), message: String.t()}} | {:error, term()}
  def finish_check(%UnblockAsk{} = ask, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    view = view(ask)

    case recheck(ask, opts) do
      :cleared ->
        with {:ok, resolved} <- resolve(ask, now) do
          {:ok, %{ask: resolved, outcome: :resolved, message: view.success}}
        end

      {:still, line} ->
        message = view.still_missing <> " " <> line

        with {:ok, reopened} <- write(ask, %{status: "open", still_missing: message}) do
          broadcast(reopened)
          {:ok, %{ask: reopened, outcome: :still_missing, message: message}}
        end
    end
  end

  @doc """
  "Not now": the ask stays live but quiet (`dismissed`) and its Inbox row is
  dismissed. It is asked again after the interval if nothing changed.
  """
  @spec not_now(term(), term()) :: {:ok, UnblockAsk.t()} | {:error, :not_found | term()}
  def not_now(ask_id, user_id) do
    case get_for_owner(ask_id, user_id) do
      %UnblockAsk{status: status} = ask when status in ["open", "verifying"] ->
        with {:ok, ask} <- write(ask, %{status: "dismissed"}) do
          Inbox.dismiss_by_source(user_id, @source_type, ask.id, kind: @kind)
          broadcast(ask)
          {:ok, ask}
        end

      %UnblockAsk{} = ask ->
        {:ok, ask}

      nil ->
        {:error, :not_found}
    end
  end

  defp recheck(%UnblockAsk{subject_type: "agent"} = ask, opts) do
    status =
      opts
      |> Keyword.take([:row, :now, :federation])
      |> TeamCheck.statuses()
      |> Enum.find(&(&1.agent_id == ask.subject_id))

    cond do
      is_nil(status) ->
        {:still, "It is no longer an active agent, so it can't be checked."}

      ask.class == "offline" and status.class != :offline ->
        :cleared

      ask.class != "offline" and status.class == :offline ->
        {:still, "It isn't connected right now, so the fix can't be checked yet."}

      Atom.to_string(status.class) == ask.class ->
        {:still, status.evidence}

      true ->
        :cleared
    end
  end

  defp recheck(%UnblockAsk{subject_type: "person"} = ask, opts) do
    setup_opts = Keyword.take(opts, [:now, :stuck_after_seconds])

    case PersonSetup.status(ask.subject_id, setup_opts) do
      %{stuck: [_ | _] = stuck} ->
        steps = Enum.map(stuck, &Atom.to_string/1)
        texts = view(%{ask | details: Map.put(ask.details || %{}, "steps", steps)}).steps
        {:still, Enum.map_join(texts, "; ", & &1.text) <> "."}

      _ ->
        :cleared
    end
  end

  # The owning runtime is asked to re-verify over the channel
  # `BlockerReassessment` uses. Best effort; the check below reads the rows.
  defp request_runtime_check(%UnblockAsk{subject_type: "agent"} = ask, opts) do
    runtime_ids =
      Keyword.get_lazy(opts, :runtime_ids, fn ->
        opts
        |> Keyword.take([:row, :now, :federation])
        |> TeamCheck.statuses()
        |> Enum.find_value([], &(&1.agent_id == ask.subject_id && &1.runtime_ids))
      end)

    Enum.each(runtime_ids, fn runtime_id ->
      PlatformWeb.Endpoint.broadcast("runtime:#{runtime_id}", "unblock_check_requested", %{
        ask_id: ask.id,
        agent_id: ask.subject_id,
        class: ask.class
      })
    end)
  rescue
    error ->
      Logger.warning("[unblock_asks] runtime check request raised: #{inspect(error.__struct__)}")
      :ok
  end

  defp request_runtime_check(_ask, _opts), do: :ok

  # ── reads ────────────────────────────────────────────────────────────────

  @doc "The ask, when `user_id` is its fixer; else nil."
  @spec get_for_owner(term(), term()) :: UnblockAsk.t() | nil
  def get_for_owner(ask_id, user_id) do
    if Platform.UUID.valid?(ask_id) and Platform.UUID.valid?(user_id) do
      Repo.one(from(a in UnblockAsk, where: a.id == ^ask_id and a.owner_user_id == ^user_id))
    end
  end

  @doc "`user_id`'s live asks, newest first."
  @spec list_live_for_owner(term()) :: [UnblockAsk.t()]
  def list_live_for_owner(user_id) do
    if Platform.UUID.valid?(user_id) do
      Repo.all(
        from(a in UnblockAsk,
          where: a.owner_user_id == ^user_id and a.status in ^@live,
          order_by: [desc: a.last_asked_at]
        )
      )
    else
      []
    end
  end

  @doc "Live asks for one subject."
  @spec live_asks(String.t(), term()) :: [UnblockAsk.t()]
  def live_asks(subject_type, subject_id) do
    if Platform.UUID.valid?(subject_id) do
      Repo.all(
        from(a in UnblockAsk,
          where:
            a.subject_type == ^subject_type and a.subject_id == ^subject_id and
              a.status in ^@live
        )
      )
    else
      []
    end
  end

  @doc """
  The rendered ask: the template for its class filled with its details
  (`Templates.render/2`), plus `why` (the stage-3 evidence line) and the
  ask's status and still-missing line.
  """
  @spec view(UnblockAsk.t()) :: map()
  def view(%UnblockAsk{} = ask) do
    ask.class
    |> Templates.render(ask.details || %{})
    |> Map.merge(%{
      id: ask.id,
      class: ask.class,
      status: ask.status,
      why: ask.evidence,
      still_missing_line: ask.still_missing
    })
  end

  @doc """
  Whether an `agent_unblock_ask` row's ask is positively settled for its
  Inbox row: resolved, or put off with "Not now". A missing ask is NOT stale.
  """
  @spec inbox_row_stale?(term()) :: boolean()
  def inbox_row_stale?(ask_id) do
    Platform.UUID.valid?(ask_id) and
      Repo.exists?(
        from(a in UnblockAsk, where: a.id == ^ask_id and a.status in ["resolved", "dismissed"])
      )
  end

  # ── writes ───────────────────────────────────────────────────────────────

  defp emit(%UnblockAsk{} = ask) do
    view = view(ask)

    case Inbox.emit(%{
           user_id: ask.owner_user_id,
           kind: @kind,
           source_type: @source_type,
           source_id: ask.id,
           title: view.title,
           body: view.subtitle,
           url: url(ask.id)
         }) do
      {:ok, item} ->
        {:ok, item}

      error ->
        Logger.warning("[unblock_asks] inbox emit failed: #{inspect(error)}")
        error
    end
  end

  defp resolve(%UnblockAsk{} = ask, now) do
    with {:ok, resolved} <-
           write(ask, %{status: "resolved", resolved_at: now, still_missing: nil}) do
      Inbox.dismiss_by_source(resolved.owner_user_id, @source_type, resolved.id, kind: @kind)
      broadcast(resolved)
      {:ok, resolved}
    end
  end

  defp write(%UnblockAsk{} = ask, attrs) do
    ask |> UnblockAsk.changeset(attrs) |> Repo.update()
  end

  defp lock_for_owner(ask_id, user_id) do
    if Platform.UUID.valid?(ask_id) and Platform.UUID.valid?(user_id) do
      Repo.one(
        from(a in UnblockAsk,
          where: a.id == ^ask_id and a.owner_user_id == ^user_id,
          lock: "FOR UPDATE"
        )
      )
    end
  end

  defp broadcast(%UnblockAsk{} = ask) do
    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      topic(ask.owner_user_id),
      {:unblock_ask_changed, ask}
    )
  end
end
