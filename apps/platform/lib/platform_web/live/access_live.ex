defmodule PlatformWeb.AccessLive do
  @moduledoc "Break-glass access inspection and human ledger controls."
  use PlatformWeb, :live_view
  alias Platform.Access
  alias Platform.Access.{Changes, Effective, Grants, Impact, Proposals, Scope, ViewAs}
  alias Platform.{Accounts, Repo}

  @impl true
  def mount(params, _session, socket) do
    socket = assign(socket, page_title: "Access", viewing: false, preview: nil, selected: nil)
    socket = reload(socket)

    case params do
      %{"type" => type, "id" => id} when type in ["user", "agent"] ->
        {:ok, select(socket, type <> ":" <> id)}

      _ ->
        {:ok, socket}
    end
  end

  def on_access_changed(socket), do: reload(socket)

  @impl true
  def handle_event("select", %{"subject" => key}, socket),
    do: {:noreply, select(assign(socket, preview: nil), key)}

  def handle_event("view-as", _, socket),
    do: {:noreply, assign(socket, viewing: not socket.assigns.viewing)}

  def handle_event("reset", _, socket) do
    scope = fresh(socket)
    subject = reset_subject(socket.assigns.selected)

    hash = Proposals.state_hash()

    case Grants.reset_ops(subject, scope) do
      ops when is_list(ops) and ops != [] ->
        case Impact.diff(scope, ops) do
          {:ok, impact} ->
            if Proposals.state_hash() == hash do
              {:noreply, assign(socket, preview: %{ops: ops, impact: impact, hash: hash})}
            else
              {:noreply, failure(assign(socket, preview: nil), :stale)}
            end

          {:error, reason} ->
            {:noreply, failure(socket, reason)}
        end

      _ ->
        {:noreply, put_flash(socket, :info, "No per-person grants to reset.")}
    end
  end

  def handle_event("canvas_action_click", %{"action" => "access_apply"}, socket),
    do: handle_event("apply-reset", %{}, socket)

  def handle_event("canvas_action_click", %{"action" => "access_cancel"}, socket),
    do: handle_event("cancel-reset", %{}, socket)

  def handle_event("canvas_action_click", _, socket),
    do: {:noreply, failure(socket, :unknown_action)}

  def handle_event("cancel-reset", _, socket), do: {:noreply, assign(socket, preview: nil)}

  def handle_event("apply-reset", _, %{assigns: %{preview: preview}} = socket)
      when is_map(preview) do
    result =
      Repo.transaction(fn ->
        Changes.lock_for_consent()
        scope = fresh(socket)

        with true <- Proposals.state_hash() == preview.hash,
             {:ok, impact} <- Impact.diff(scope, preview.ops),
             true <- impact == preview.impact,
             {:ok, result} <-
               Grants.apply_ops(preview.ops,
                 actor: scope,
                 defer_notifications: true,
                 precondition: fn ->
                   if Proposals.state_hash() == preview.hash, do: :ok, else: {:error, :stale}
                 end
               ) do
          result
        else
          false -> Repo.rollback(:stale)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, %{change: %Platform.Access.Change{} = change}} -> Changes.notify_committed(change)
      _ -> :ok
    end

    {:noreply, finish(assign(socket, preview: nil), result)}
  end

  def handle_event("apply-reset", _, socket), do: {:noreply, failure(socket, :no_preview)}

  def handle_event("remove", %{"id" => id}, socket),
    do: {:noreply, finish(socket, Grants.revoke(id, actor: fresh(socket)))}

  def handle_event("undo", %{"id" => id}, socket),
    do: {:noreply, finish(socket, Changes.undo(id, fresh(socket), []))}

  defp finish(socket, {:ok, _}),
    do: socket |> reload() |> put_flash(:info, "Access change recorded.")

  defp finish(socket, {:error, reason}), do: failure(socket, reason)

  defp failure(socket, reason),
    do: put_flash(socket, :error, "Access change refused: #{inspect(reason)}")

  defp fresh(socket),
    do: socket.assigns.current_user.id |> Accounts.get_user() |> Scope.for_user()

  defp reload(socket) do
    scope = fresh(socket)

    subjects =
      Effective.subjects(scope)
      |> Enum.filter(&(&1.type in ["user", "agent"]))
      |> Enum.map(
        &%{
          key: &1.type <> ":" <> &1.id,
          target: &1.target,
          type: if(&1.type == "user", do: "People", else: "Agents"),
          name: &1.name
        }
      )

    changes =
      Repo.all(Platform.Tenancy.Org)
      |> Enum.flat_map(&Changes.list_changes(&1.id, limit: 200))
      |> Enum.filter(fn c ->
        Enum.all?(c.before ++ c.after, fn r ->
          Access.can?(
            scope,
            "access.manage",
            {String.to_existing_atom(r["resource_type"]), r["resource_id"]}
          )
        end)
      end)
      |> Enum.sort_by(& &1.id, :desc)

    undone = MapSet.new(Enum.map(changes, & &1.undoes_change_id))

    socket =
      assign(socket,
        access_scope: scope,
        subjects: subjects,
        changes: changes,
        undone: undone,
        subject_form: to_form(%{"subject" => socket.assigns.selected})
      )

    key =
      if Enum.any?(subjects, &(&1.key == socket.assigns.selected)),
        do: socket.assigns.selected,
        else: (List.first(subjects) || %{})[:key]

    select(socket, key)
  end

  defp select(socket, key) do
    case Enum.find(socket.assigns.subjects, &(&1.key == key)) do
      nil ->
        assign(socket, selected: nil, subject: nil, lines: [], view: nil)

      subject ->
        with {:ok, view} <- ViewAs.compute(fresh(socket), subject.target),
             {:ok, lines} <- Effective.lines(fresh(socket), subject.target) do
          assign(socket,
            selected: key,
            subject: subject,
            lines: lines,
            view: view,
            subject_form: to_form(%{"subject" => key})
          )
        else
          _ -> assign(socket, selected: nil, subject: nil, lines: [], view: nil)
        end
    end
  end

  defp reset_subject("user:" <> id), do: {:user, id}

  defp reset_subject("agent:" <> id) do
    case Platform.Federation.get_runtime(id) do
      nil -> :invalid
      runtime -> runtime
    end
  end

  defp reset_subject(_), do: :invalid

  defp subject_options(subjects) do
    for group <- ["People", "Agents"] do
      {group, for(subject <- subjects, subject.type == group, do: {subject.name, subject.key})}
    end
  end

  defp preview_document(preview) do
    impact = preview.impact |> Jason.encode!() |> Jason.decode!()

    Platform.Access.ChangeCard.document(%Platform.Access.Proposal{
      id: "panel-reset",
      state: "proposed",
      selected_option: "reset",
      options: [
        %{"key" => "reset", "label" => "Reset to role defaults", "ops" => [], "impact" => impact}
      ]
    })
  end

  defp actor_name(id) do
    case Accounts.get_user(id) do
      nil -> "System"
      user -> user.name || user.email
    end
  end

  defp via_name(nil), do: ""

  defp via_name(id) do
    case Platform.Federation.get_runtime(id) do
      nil -> ""
      runtime -> " via " <> (runtime.display_name || runtime.runtime_id)
    end
  end
end
