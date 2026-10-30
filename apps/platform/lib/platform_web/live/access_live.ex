defmodule PlatformWeb.AccessLive do
  @moduledoc "Break-glass access inspection and human ledger controls."
  use PlatformWeb, :live_view
  alias Platform.Access

  alias Platform.Access.{
    Changes,
    Effective,
    Grant,
    Grants,
    Impact,
    Proposals,
    Registry,
    Scope,
    ViewAs
  }

  alias Platform.{Accounts, Repo}

  @lock_verbs %{"Added" => "Locked", "Removed" => "Unlocked", "Remove" => "Unlock"}

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
        with {:ok, impact} <- Impact.diff(scope, ops),
             {:ok, prepared} <- Grants.prepare_ops(ops, scope) do
          rows = Enum.map(prepared, fn {_op, row} -> Platform.Access.Grant.snapshot(row) end)

          if Proposals.state_hash() == hash do
            {:noreply,
             assign(socket, preview: %{ops: ops, rows: rows, impact: impact, hash: hash})}
          else
            {:noreply, failure(assign(socket, preview: nil), :stale)}
          end
        else
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

  # "Lock module" (task 01a14721 stage 3): a module-scoped deny through
  # `Grants.deny/2` as the signed-in actor, so `Platform.Access.Delegation`
  # decides and the ledger records it. The principal is the selected person,
  # never a client-supplied id; the org is client-supplied and Delegation
  # refuses one the actor does not manage.
  # The select opens on a "Choose a module" prompt, so a submit without a
  # choice locks nothing (a default first option once locked Chat by accident
  # on the dev rig).
  def handle_event("lock-module", %{"module" => ""}, socket),
    do: {:noreply, failure(socket, :choose_a_module)}

  def handle_event("lock-module", %{"module" => module, "org" => org_id}, socket) do
    case socket.assigns.selected do
      "user:" <> user_id ->
        result =
          Grants.deny(
            %{principal: {:user, user_id}, permission: module, resource: {:module, org_id}},
            actor: fresh(socket)
          )

        {:noreply, finish(socket, result)}

      _ ->
        {:noreply, failure(socket, :no_subject)}
    end
  end

  def handle_event("lock-module", _, socket), do: {:noreply, failure(socket, :invalid_lock)}

  defp finish(socket, {:ok, _}),
    do: socket |> reload() |> put_flash(:info, "Access change recorded.")

  defp finish(socket, {:error, reason}), do: failure(socket, reason)

  defp failure(socket, reason),
    do: put_flash(socket, :error, "Access change refused: #{inspect(reason)}")

  defp fresh(socket),
    do: socket.assigns.current_user_id |> Accounts.get_user() |> Scope.for_user()

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
        Platform.Access.Delegation.root_admin?(scope) or
          Enum.all?(c.before ++ c.after, &manages_row?(scope, &1))
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

  # A module lock's resource is its org (`Platform.Access.Delegation`): it is
  # managed through `access.manage` over that org, not over a typed resource.
  defp manages_row?(scope, %{"resource_type" => "module", "org_id" => org_id}),
    do: Effective.manages_org?(scope, org_id)

  defp manages_row?(scope, row),
    do:
      Access.can?(
        scope,
        "access.manage",
        {String.to_existing_atom(row["resource_type"]), row["resource_id"]}
      )

  defp select(socket, key) do
    case Enum.find(socket.assigns.subjects, &(&1.key == key)) do
      nil ->
        assign(socket, selected: nil, subject: nil, lines: [], view: nil, lock_form: nil)

      subject ->
        with {:ok, view} <- ViewAs.compute(fresh(socket), subject.target),
             {:ok, lines} <- Effective.lines(fresh(socket), subject.target) do
          assign(socket,
            selected: key,
            subject: subject,
            lines: lines,
            view: view,
            subject_form: to_form(%{"subject" => key}),
            lock_form: lock_form(fresh(socket), subject, lines)
          )
        else
          _ -> assign(socket, selected: nil, subject: nil, lines: [], view: nil, lock_form: nil)
        end
    end
  end

  # The "Lock module" form for a person: the lockable modules not already
  # locked, and the orgs of the person's memberships the viewer manages
  # (Delegation decides again on submit). nil when nothing can be offered.
  defp lock_form(viewer, %{target: {:user, user_id}}, lines) do
    locked = for %{source: "Locked", module: m, where: %{id: org}} <- lines, do: {m, org}

    orgs =
      for %{org_id: org_id} <- Accounts.get_user(user_id).org_memberships,
          Effective.manages_org?(viewer, org_id),
          org = Platform.Tenancy.get_org(org_id),
          uniq: true,
          do: {org.name, org.id}

    modules =
      for m <- Grant.lockable_modules(),
          not Enum.all?(orgs, fn {_name, org} -> {m, org} in locked end),
          do: {module_label(m), m}

    if orgs != [] and modules != [],
      do: %{orgs: orgs, modules: modules, form: to_form(%{"module" => nil, "org" => nil})}
  end

  defp lock_form(_viewer, _subject, _lines), do: nil

  @doc false
  # The module's display name: its rail label when it has a rail tile, else
  # its capitalised name (`canvas` -> "Canvas").
  def module_label(module) do
    labels =
      Map.new(PlatformWeb.Components.IconRail.destinations(root_user: true), &{&1.key, &1.label})

    Enum.find_value(Registry.rail_entries(), fn entry ->
      entry.module == module && Map.get(labels, entry.key)
    end) || String.capitalize(module)
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

  defp rail_chips(view) do
    active = PlatformWeb.AccessViewAs.rail_keys(view)

    PlatformWeb.Components.IconRail.destinations(root_user: true)
    |> Enum.map(&%{key: &1.key, label: &1.label, active: &1.key in active})
  end

  defp subject_role(%{surface: :agent}), do: "agent"

  defp subject_role(%{scope: scope}) do
    scope.role_keys
    |> Map.values()
    |> Enum.flat_map(&MapSet.to_list/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp change_label(change) do
    added = change.after -- change.before
    removed = change.before -- change.after
    undo? = change.action == "undo"
    verb = if undo?, do: "Restored", else: "Added"

    (Enum.map(removed, &change_row_label(&1, "Removed", undo?)) ++
       Enum.map(added, &change_row_label(&1, verb, undo?)))
    |> Enum.join("; ")
  end

  # A module lock reads as what it does to the person (task 01a14721
  # stage 3): an undo that removes a lock restores the module to them.
  defp change_row_label(%{"resource_type" => "module"} = row, "Removed", true),
    do: lock_label(row, "Restored") <> " (lock undone)"

  defp change_row_label(%{"resource_type" => "module"} = row, "Restored", true),
    do: lock_label(row, "Re-locked") <> " (unlock undone)"

  defp change_row_label(row, verb, _undo?), do: row_label(row, verb)

  defp lock_label(row, verb) do
    org = Platform.Tenancy.get_org(row["org_id"])

    "#{verb} #{module_label(row["permission"])} module in " <>
      "#{(org && org.name) || row["resource_id"]} for #{principal_label(row)}"
  end

  defp row_label(%{"resource_type" => "module"} = row, verb),
    do: lock_label(row, Map.get(@lock_verbs, verb, verb))

  defp row_label(row, verb) do
    subject = principal_label(row)

    schema = %{
      "project" => Platform.Tasks.Project,
      "space" => Platform.Chat.Space,
      "canvas" => Platform.Chat.Canvas,
      "memory_node" => Platform.Org.Wiki.Node,
      "org" => Platform.Tenancy.Org
    }

    resource =
      case Map.get(schema, row["resource_type"]) do
        nil -> nil
        module -> Repo.get(module, row["resource_id"])
      end

    where =
      if resource,
        do: Map.get(resource, :name) || Map.get(resource, :title) || row["resource_id"],
        else: row["resource_id"]

    "#{verb} #{row["effect"]} #{row["permission"]} on #{where} for #{subject}"
  end

  defp principal_label(row) do
    case row["principal_type"] do
      "user" ->
        actor_name(row["principal_id"])

      "role" ->
        "role " <> row["principal_role_key"]

      "agent" ->
        case Repo.get(Platform.Agents.Agent, row["principal_id"]) do
          nil -> "agent " <> row["principal_id"]
          agent -> agent.name
        end
    end
  end

  defp preview_document(preview) do
    impact = preview.impact |> Jason.encode!() |> Jason.decode!()
    ops = preview.ops |> Jason.encode!() |> Jason.decode!()

    label =
      (["Reset to role defaults"] ++ Enum.map(preview.rows, &row_label(&1, "Remove")))
      |> Enum.join("; ")

    Platform.Access.ChangeCard.document(%Platform.Access.Proposal{
      id: "panel-reset",
      state: "proposed",
      selected_option: "reset",
      options: [
        %{"key" => "reset", "label" => label, "ops" => ops, "impact" => impact}
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

  # The hue of a permission line's source rides on a dot, not on its text
  # (task 01a1557a stage 5).
  defp source_dot("grant"), do: "bg-info"
  defp source_dot(source) when source in ["deny", "restricted", "Locked"], do: "bg-error"
  defp source_dot("capped"), do: "bg-warning"
  defp source_dot(_), do: nil

  # Burrow redesign 24 stage 5: a stray message (a shell broadcast, a late
  # reply) must not crash an admin page.
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}
end
