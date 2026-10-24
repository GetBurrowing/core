defmodule PlatformWeb.Tasks.MaskHooks do
  @moduledoc """
  Screen-share name masking for the Tasks rail (task 01a00cf1 stage 2).

  ## Why this is a hook module and not lines in the shell

  The stage text says "add the handlers to `tasks_live.ex`", and that is where
  they were written first. GUARD 4 in `tasks_live_board_invariance_test.exs`
  then failed: the shell is pinned at 653 lines by the surface-budget ratchet
  PR #770 landed, and the three handlers plus their mount assigns took it to
  718.

  The pin was NOT moved. The ratchet's promise is that no concern re-enters
  the shell after the ADR-0035 extraction, and masking is exactly a concern:
  two assigns, three events, one derived map, all reachable from one another
  and from nothing else. Moving the pin to accommodate the first feature that
  wanted shell space is how `chat_live.ex` went 684 -> 4,335 lines. The
  ownership the stage asked for is preserved exactly — these assigns live on
  the SHELL's socket, written by a `:handle_event` hook attached in
  `TasksLive.mount/3`, and `SidebarComponent` still receives them as read-only
  attrs. Only the source file differs.

  ## What it owns

  `:mask_names?` (boolean) and `:revealed_rail_ids` (`MapSet` of REAL org slugs and
  project ids), plus `:mask_labels`, the resolved map every rail render site
  reads through `TaskDisplay.rail_label/2`.

  `:mask_names?` is SEEDED on every mount from the person's own preference,
  `Platform.Accounts.mask_names?/1` over the `:current_user_record` ShellLive
  loaded (no extra query), and the `toggle_mask_names` clause PERSISTS the
  requested state through `PlatformWeb.ShellLive.put_mask_names/2`, the web
  layer's one route to `Platform.Accounts.put_mask_names/3` (task 01a1557a-e538
  stage 2; routed through the shell by task 01a1600d stage 1, which also keeps
  `:current_user_record` current). ShellLive's own `toggle_mask_names` clause
  runs first and yields to this one on TasksLive. On means masked for 12 hours; off
  deletes the key. The product owner approved the 12-hour cross-device scope on
  2026-10-21: "12 hour cross-device is fine". So a mask turned on in Chat
  holds on a fresh Tasks mount and the reverse, and a mask set for a call is
  gone by the next morning.

  Per user only: no PubSub broadcast, no write to any Tasks, org or chat
  row, nothing another viewer of the same orgs can observe. The state
  follows the person across their own devices; a LiveView already open
  elsewhere picks a change up at its next mount. `:revealed_rail_ids` stays
  per-LiveView and starts empty on every mount, so a mount is fully masked.
  See `Platform.Chat.SidebarMask`'s moduledoc for why this is a COSMETIC
  PRESENTATION AID and not a security control.

  ## The controls

  `toggle_mask_names`, `reveal_rail_item` and `remask_all` are rendered by
  `TasksLive.SidebarComponent` with NO `phx-target`, so their events reach the
  LiveView and therefore this hook — the same arrangement the org lifecycle
  controls in that component already use.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Platform.Accounts
  alias PlatformWeb.Tasks.TaskDisplay

  @doc """
  Seed the masking state from the person's preference and attach the event
  hook.

  Call from `TasksLive.mount/3` BEFORE `LifecycleHooks.refresh_containers/1`,
  so that pass's `assign_mask_labels/1` reads this state rather than its own
  fallbacks.
  """
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:mask_names?, Accounts.mask_names?(socket.assigns[:current_user_record]))
    |> assign(:revealed_rail_ids, MapSet.new())
    |> attach_hook(:tasks_mask_events, :handle_event, &handle_event/3)
  end

  @doc """
  Recompute `:mask_labels` from the CURRENT `:project_sections` and masking
  state.

  Called by `LifecycleHooks.refresh_containers/1` — the single writer of
  `:project_sections` — so the two assigns can never disagree. A project
  created mid-session gets its letter on the same pass that puts it in the
  rail; without that, the new row would fall through `rail_label/2`'s
  fail-closed branch and read as a bare `Project` until the next toggle.

  Defaults are read through `socket.assigns[...]` so `refresh_containers/1`
  stays callable before `attach/1` has run.
  """
  @spec assign_mask_labels(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_mask_labels(socket) do
    assign(
      socket,
      :mask_labels,
      TaskDisplay.mask_labels(
        socket.assigns[:project_sections] || [],
        socket.assigns[:mask_names?] || false,
        socket.assigns[:revealed_rail_ids] || MapSet.new(),
        socket.assigns[:epics] || []
      )
    )
  end

  # `masked` arrives as the DESIRED next state ("true"/"false") rather than as
  # a flip, matching chat's `toggle_mask_names` and the rail's own
  # `toggle_section_collapsed` convention: a duplicated event from a
  # client-side render race is then idempotent instead of landing in the
  # opposite mode from the one the eye showed.
  #
  # Turning the mode OFF also CLEARS the per-item reveals, so re-enabling
  # starts fully masked. Otherwise a reveal from earlier in the session is
  # resurrected on the next share and one workspace is silently visible — the
  # feature failing in the exact direction it exists to prevent.
  defp handle_event("toggle_mask_names", params, socket) do
    masked? = params["masked"] in ["true", "on", true]
    # Persist the REQUESTED state through the shell's one web writer, which
    # also refreshes `:current_user_record` (no-op without a user row).
    socket = PlatformWeb.ShellLive.put_mask_names(socket, masked?)

    {:halt,
     socket
     |> assign(:mask_names?, masked?)
     |> assign(
       :revealed_rail_ids,
       if(masked?, do: socket.assigns.revealed_rail_ids, else: MapSet.new())
     )
     |> assign_mask_labels()}
  end

  # Reveal exactly one rail row's real name while the mode stays on — the
  # "walk this workspace through their own project" case. One click, no menu.
  #
  # `kind` ("org" / "project") is carried for the DOM's benefit and for the
  # symmetry of the two call sites; the reveal set is keyed on `id` alone,
  # because that is what `Platform.Chat.SidebarMask.label/5` matches on. Org
  # ids are slugs and project ids are UUIDs, so the two namespaces cannot
  # collide.
  #
  # `kind == "org"` is ALSO the resolution point for the org alias: while
  # masked, the button carries the placeholder slug (`workspace-b`) rather than
  # the real one, so `id` is run back through `TaskDisplay.real_org_slug/2`
  # before it joins the reveal set — which is keyed on REAL slugs. Skip this
  # and the reveal button becomes a no-op the moment the mask is on, i.e. in
  # the only state it is ever rendered in.
  defp handle_event("reveal_rail_item", %{"kind" => kind, "id" => id}, socket)
       when kind in ["org", "project"] and is_binary(id) do
    resolved =
      if kind == "org",
        do: TaskDisplay.real_org_slug(socket.assigns[:mask_labels] || %{}, id),
        else: id

    {:halt,
     socket
     |> assign(:revealed_rail_ids, MapSet.put(socket.assigns.revealed_rail_ids, resolved))
     |> assign_mask_labels()}
  end

  # Re-mask everything in one action, leaving the mode on.
  defp handle_event("remask_all", _params, socket) do
    {:halt, socket |> assign(:revealed_rail_ids, MapSet.new()) |> assign_mask_labels()}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}
end
