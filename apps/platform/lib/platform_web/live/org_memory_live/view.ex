defmodule PlatformWeb.OrgMemoryLive do
  @moduledoc """
  Org Memory wiki LiveView (ADR-0041 T7).

  Three-pane shell:

    * left — `PlatformWeb.OrgMemoryLive.NamespaceTree` (collapsible
      namespace tree over `Wiki.list_pages/1`)
    * main — `PlatformWeb.OrgMemoryLive.PageViewer` (stage 4: viewer /
      editor sub-states with wikilink-aware rendering
      via `PlatformWeb.OrgMemoryLive.MarkdownRenderer`) plus the
      create panel
    * right — `PlatformWeb.OrgMemoryLive.RightPane` (stage 5: backlinks
      via `Wiki.backlinks/2` + page metadata — the canonical home for
      the version / updated-by / relative-time meta)

  State lives here; the pane modules are stateless function components.

  Stage 6 adds a tab strip across the top of the main pane —
  `@view_mode :: :pages | :journal | :search | :insights` swaps the
  main-pane render only. The left tree stays mounted on every tab; the
  right pane renders only on `:pages` (the grid collapses to two
  columns on the other tabs, giving the feed / results / table the
  extra width). Tab switches never touch `:namespace_tree`,
  `:expanded_prefixes`, or `:selected_page` — `:pages → :search →
  :pages` returns to the same selected page without a re-fetch.

  Journal tab: `PlatformWeb.OrgMemoryLive.JournalPane` — append-only
  form over `Wiki.Journal.append/2` + a date-grouped
  `Wiki.Journal.list_recent/1` feed, scoped to the namespace derived
  from the selected page (default `"org"`).

  Search tab: `PlatformWeb.OrgMemoryLive.SearchPane` — dispatches
  through `Platform.Federation.ToolSurface.execute("memory_search", ...)`
  (the same gate path agents use; swappable in tests via the
  `:org_memory_tool_surface` app env).

  Insights tab (task 01a13867 stage 5, renamed from Proposals):
  `PlatformWeb.OrgMemoryLive.InsightsPane` — open
  `Platform.Memory.Insight` rows from dreaming, each rendered as the
  artefact its button produces. The handlers `insight_act`,
  `insight_edit`, `insight_reroute`, `insight_reject`, `insight_dismiss`
  and `insight_revert` each LOAD THE USER AGAIN and build a fresh
  `Platform.Access.Scope` for the click (`click_scope/1`), then call
  `Platform.Memory.Insights`, which decides on that scope alone: the
  rendered buttons are presentation, not the check. The tab subscribes to
  `Platform.Memory.Insights.topic/0` and reloads on every change, so a
  second session sees an insight leave as soon as someone acts on it.

  Agent gate (design lock §6): the `"save_page"` handler fails closed
  when `current_user` is shaped like a `Platform.Agents.Agent` — UI
  editing is for humans; agents propose changes via `memory_create`.

  Burrow Docs (task 01a10a44 stage 5): `burrow/` rows are product-owned
  docs, written only by `Platform.Org.BurrowDocs`. They render as their own
  section above Pages (see `PlatformWeb.OrgMemoryLive.ProductDocs`), never
  in the Pages tree, and the edit and delete events (`start_edit`,
  `save_page`, `confirm_delete`, `delete_file`) are refused for a `burrow/`
  key HERE, on the server, before the domain is reached. The absent buttons
  are presentation; this is the check. `Platform.Org.Wiki` refuses the
  write again as `{:error, :product_owned}` (the stage-2 backstop).

  Routes: `/org_memory` (`:index`), `/org_memory/:file_key` (`:show`),
  and `/memory/insights` (`:insights`, direct entry to the Insights tab).
  `/memory/proposals` (`:proposals`) redirects to `/memory/insights`, so
  links in old journals and notifications still land. Legacy
  `/org-context*` paths 301-redirect in `PageController`.
  """

  use PlatformWeb, :live_view

  alias Platform.Access.Scope
  alias Platform.Accounts
  alias Platform.Agents.Agent
  alias Platform.Memory.Insights
  alias Platform.Memory.Insights.Routing
  alias Platform.Memory.Insights.Settings, as: InsightSettings
  alias Platform.Memory.Insights.Tier
  alias Platform.Memory.JournalSweep
  alias Platform.Org.Context
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Journal
  alias PlatformWeb.OrgMemoryLive.JournalPane
  alias PlatformWeb.OrgMemoryLive.MarkdownRenderer
  alias PlatformWeb.OrgMemoryLive.MobileShell
  alias PlatformWeb.OrgMemoryLive.NamespaceTree
  alias PlatformWeb.OrgMemoryLive.PageViewer
  alias PlatformWeb.OrgMemoryLive.ProductDocs
  alias PlatformWeb.OrgMemoryLive.InsightsPane
  alias PlatformWeb.OrgMemoryLive.RightPane
  alias PlatformWeb.OrgMemoryLive.SearchPane

  @journal_days_back 14
  @journal_limit 100
  @tabs ~w(pages journal search insights)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Platform.PubSub, Insights.topic())

    pages = Wiki.list_pages(page_access_opts(socket))
    {tree, burrow_docs} = build_trees(pages)

    {:ok,
     socket
     |> assign(:page_title, "Org Memory")
     |> assign(:pages, pages)
     |> assign(:namespace_tree, tree)
     |> assign(:burrow_docs, burrow_docs)
     |> assign(:expanded_prefixes, default_expanded(tree, burrow_docs))
     |> assign(:selected_page, nil)
     |> assign(:backlinks, [])
     |> assign(:view_mode, :pages)
     |> assign(:editing, false)
     |> assign(:editor_content, "")
     |> assign(:preview_html, "")
     |> assign(:creating, false)
     |> assign(:new_file_key, "")
     |> assign(:new_file_template, nil)
     |> assign(:save_error, nil)
     |> assign(:confirm_delete, nil)
     |> assign(:fm_form, nil)
     |> assign(:fm_complex, nil)
     |> assign(:updated_by_display, nil)
     |> assign(:journal_groups, [])
     |> assign(:journal_draft, "")
     |> assign(:journal_focus_date, nil)
     |> assign(:journal_namespace_override, nil)
     |> assign(:search_query, "")
     |> assign(:search_corpus, "all")
     |> assign(:search_namespace, "all")
     |> assign(:search_results, [])
     |> assign(:search_performed, false)
     |> assign(:search_truncated, false)
     |> assign(:search_error, nil)
     |> assign(:search_degraded, false)
     |> assign(:search_dead_channels, [])
     |> assign(:search_results_revealed, false)
     |> assign(:tree_drawer_open, false)
     |> assign(:insights_open_count, count_open_insights())
     |> assign(:insights, [])
     |> assign(:insights_done, [])
     |> assign(:insight_handle_ids, MapSet.new())
     |> assign(:insight_dissemination_on, false)
     |> assign(:insight_admin?, false)
     |> assign(:insight_receives?, true)
     |> assign(:insight_filter_type, "all")
     |> assign(:insight_filter_confidence, "any")
     |> assign(:insight_reject_for, nil)
     |> assign(:insight_reroute_for, nil)
     |> assign(:insight_edit_for, nil)
     |> assign(:insight_people, [])
     |> assign(:insight_names, %{})}
  end

  # `/memory/proposals` is the retired Proposals tab's address: links to it
  # live on in journals and notifications, so it lands on the Insights tab.
  # On the dead render `push_navigate/2` answers with a redirect.
  @impl true
  def handle_params(_params, _url, %{assigns: %{live_action: :proposals}} = socket) do
    {:noreply, push_navigate(socket, to: ~p"/memory/insights", replace: true)}
  end

  # Live_action-based route entry: `/memory/insights` mounts with
  # `socket.assigns.live_action == :insights`. Load the tab BEFORE the
  # first render so users land on it without a client-side switch.
  def handle_params(_params, _url, %{assigns: %{live_action: :insights}} = socket) do
    {:noreply, load_insights_tab(socket)}
  end

  @impl true
  def handle_params(%{"file_key" => file_key}, _url, socket) do
    # Glob route — `file_key` arrives as a list of path segments.
    file_key = if is_list(file_key), do: Enum.join(file_key, "/"), else: file_key

    case Wiki.get_page(file_key, page_access_opts(socket)) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Page not found: #{file_key}")
         |> push_patch(to: ~p"/org_memory")}

      page ->
        {:noreply,
         socket
         |> assign(:selected_page, page)
         |> assign(:backlinks, Wiki.backlinks(page.file_key))
         |> assign(:editor_content, page.content)
         |> assign(:preview_html, render_page(page, socket.assigns))
         |> assign(:editing, false)
         |> assign(:creating, false)
         |> assign(:save_error, nil)
         |> assign(:confirm_delete, nil)
         |> assign(:fm_form, nil)
         |> assign(:fm_complex, nil)
         |> assign(:updated_by_display, updated_by_display(page.updated_by))
         |> update(
           :expanded_prefixes,
           &MapSet.union(&1, NamespaceTree.ancestor_prefixes(page.file_key))
         )}
    end
  end

  # Journal deep link (task 01a1170a stage 2):
  # `/org_memory?tab=journal&date=<iso>[&ns=<namespace>]`. This is the
  # href the retired Proposals table's Source cell pointed at, and old
  # links still carry it, so it must survive a full page load from another route — `open_result_journal` is a
  # phx-click event with no URL and cannot. An invalid or missing date
  # opens the Journal tab unfocused (no crash, no flash); an `ns` outside
  # `org` / `project/<id>` / `space/<id>` falls back to the default.
  def handle_params(
        %{"tab" => "journal"} = params,
        _url,
        %{assigns: %{live_action: :index}} = socket
      ) do
    focus_date =
      with date_str when is_binary(date_str) <- params["date"],
           {:ok, date} <- Date.from_iso8601(date_str) do
        date
      else
        _ -> nil
      end

    {:noreply,
     socket
     |> assign(:selected_page, nil)
     |> assign(:backlinks, [])
     |> assign(:editing, false)
     |> assign(:creating, false)
     |> assign(:view_mode, :journal)
     |> assign(:journal_focus_date, focus_date)
     |> assign(:journal_namespace_override, parse_namespace_param(params["ns"]))
     |> load_journal()}
  end

  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:selected_page, nil)
     |> assign(:backlinks, [])
     |> assign(:editing, false)
     |> assign(:creating, false)}
  end

  # ── Events: tree ────────────────────────────────────────────────────────

  @impl true
  def handle_event("select_page", %{"file_key" => file_key}, socket) do
    # Close-on-select for the mobile tree drawer (task 019f9282). The
    # desktop rail ignores `:tree_drawer_open`, so assigning false is a
    # no-op there — the tree/expansion/selection invariants are untouched.
    #
    # Selecting a page drops any `?ns=` journal override (stage 2 of task
    # 01a1170a): the journal namespace follows the selected page again.
    {:noreply,
     socket
     |> assign(:tree_drawer_open, false)
     |> assign(:journal_namespace_override, nil)
     |> push_patch(to: ~p"/org_memory/#{String.split(file_key, "/")}")}
  end

  @impl true
  def handle_event("toggle_namespace", %{"prefix" => prefix}, socket) do
    {:noreply,
     update(socket, :expanded_prefixes, fn expanded ->
       if MapSet.member?(expanded, prefix) do
         MapSet.delete(expanded, prefix)
       else
         MapSet.put(expanded, prefix)
       end
     end)}
  end

  # ── Events: mobile tree drawer (task 019f9282) ──────────────────────────

  # The slide-out namespace tree drawer on the mobile (`lg:hidden`)
  # branch. Desktop is unaffected — the left rail is always visible
  # behind `hidden lg:grid`, so `:tree_drawer_open` is a mobile-only
  # concern. Opening/closing never touches `:namespace_tree`,
  # `:expanded_prefixes`, or `:selected_page`.
  @impl true
  def handle_event("open_tree_drawer", _params, socket) do
    {:noreply, assign(socket, :tree_drawer_open, true)}
  end

  @impl true
  def handle_event("close_tree_drawer", _params, socket) do
    {:noreply, assign(socket, :tree_drawer_open, false)}
  end

  # ── Events: tabs (stage 6) ──────────────────────────────────────────────

  # Tab switches swap the main-pane render only. CRITICAL INVARIANT:
  # never touch :namespace_tree, :expanded_prefixes, or :selected_page
  # here — :pages → :search → :pages must return to the same selected
  # page without a re-fetch.
  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) when tab in @tabs do
    view_mode = view_mode_for(tab)

    # A tab click drops the `?ns=` deep-link override (task 01a1170a
    # stage 2), so the journal namespace follows the tree as before.
    socket =
      socket
      |> assign(:view_mode, view_mode)
      |> assign(:journal_namespace_override, nil)

    socket =
      case view_mode do
        :journal -> load_journal(socket)
        :insights -> load_insights_tab(socket)
        _ -> socket
      end

    {:noreply, socket}
  end

  # ── Events: journal (stage 6) ───────────────────────────────────────────

  @impl true
  def handle_event("update_journal_draft", %{"content" => content}, socket) do
    {:noreply, assign(socket, :journal_draft, content)}
  end

  @impl true
  def handle_event("append_journal", %{"content" => content}, socket) do
    content = String.trim(content)

    if content == "" do
      {:noreply, socket}
    else
      attrs = %{
        content: content,
        date: Date.utc_today(),
        authored_by: socket.assigns.current_user_id
      }

      namespace =
        effective_journal_namespace(
          socket.assigns.journal_namespace_override,
          socket.assigns.selected_page
        )

      case Journal.append(attrs, namespace: namespace) do
        {:ok, entry} ->
          JournalSweep.sweep(entry, namespace)

          {:noreply,
           socket
           |> assign(:journal_draft, "")
           |> load_journal()}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, put_flash(socket, :error, changeset_error_message(changeset))}
      end
    end
  end

  # ── Events: search (stage 6) ────────────────────────────────────────────

  @impl true
  def handle_event("search_memory", %{"query" => query} = params, socket) do
    corpus = Map.get(params, "corpus", "all")
    namespace = Map.get(params, "namespace", "all")

    socket =
      socket
      |> assign(:search_query, query)
      |> assign(:search_corpus, corpus)
      |> assign(:search_namespace, namespace)

    if String.trim(query) == "" do
      {:noreply,
       socket
       |> assign(:search_results, [])
       |> assign(:search_performed, false)
       |> assign(:search_truncated, false)
       |> assign(:search_error, nil)
       |> assign(:search_degraded, false)
       |> assign(:search_dead_channels, [])
       |> assign(:search_results_revealed, false)}
    else
      # Dispatch through the federation tool surface — the same gate
      # code path agents use (never Wiki.Search directly). Nil-ish
      # filters are dropped from args rather than passed as nils.
      args =
        %{"query" => query}
        |> put_filter("source", corpus)
        |> put_filter("namespace", namespace)

      case tool_surface().execute("memory_search", args, search_context(socket)) do
        # A degraded search with surviving hits (task 01a0941e stage 1):
        # the envelope carries NO `results` key at all, so this clause is
        # the only way those hits reach the page — and it hands them over
        # UNREVEALED. `search_error` stays nil: a degraded search is a
        # failed measurement, not a search error, and the red error line
        # is reserved for the latter.
        {:ok, %{retrieval_status: "degraded", partial_results: hits, degraded: deg}} ->
          {:noreply,
           socket
           |> assign(:search_results, hits)
           |> assign(:search_performed, true)
           |> assign(:search_truncated, true)
           |> assign(:search_error, nil)
           |> assign(:search_degraded, true)
           |> assign(:search_dead_channels, Map.get(deg, :dead_channels, []))
           |> assign(:search_results_revealed, false)}

        # Degraded with zero surviving hits. Matched BEFORE the generic
        # `{:error, %{error: message}}` clause below, which would
        # otherwise swallow it (the degraded error map carries an
        # `:error` key too) and render it in the wrong register.
        {:error, %{code: :search_degraded, dead_channels: dead}} ->
          {:noreply,
           socket
           |> assign(:search_results, [])
           |> assign(:search_performed, true)
           |> assign(:search_truncated, true)
           |> assign(:search_error, nil)
           |> assign(:search_degraded, true)
           |> assign(:search_dead_channels, dead)
           |> assign(:search_results_revealed, false)}

        {:ok, %{results: results} = envelope} ->
          {:noreply,
           socket
           |> assign(:search_results, results)
           |> assign(:search_performed, true)
           |> assign(:search_truncated, Map.get(envelope, :truncated, false))
           |> assign(:search_error, nil)
           |> assign(:search_degraded, false)
           |> assign(:search_dead_channels, [])
           |> assign(:search_results_revealed, true)}

        {:error, %{error: message}} ->
          {:noreply,
           socket
           |> assign(:search_results, [])
           |> assign(:search_performed, true)
           |> assign(:search_truncated, false)
           |> assign(:search_error, message)
           |> assign(:search_degraded, false)
           |> assign(:search_dead_channels, [])
           |> assign(:search_results_revealed, false)}
      end
    end
  end

  # Server-side reveal of a degraded search's partial hits (stage 4 renders
  # the button). Deliberately NOT a JS class toggle: the gate has to be a
  # state transition the reader performs, not a style a reader learns to
  # look past. A fresh search resets it to false above.
  @impl true
  def handle_event("reveal_degraded_results", _params, socket) do
    {:noreply, assign(socket, :search_results_revealed, true)}
  end

  # Page hit click-through: back to the :pages tab, patched to the hit.
  @impl true
  def handle_event("open_result_page", %{"file_key" => file_key}, socket) do
    {:noreply,
     socket
     |> assign(:view_mode, :pages)
     |> push_patch(to: ~p"/org_memory/#{String.split(file_key, "/")}")}
  end

  # Journal hit click-through: switch to :journal focused on the hit's
  # date (journal hits carry the ISO date in :date_or_inserted_at).
  @impl true
  def handle_event("open_result_journal", %{"date" => date_str}, socket) do
    focus_date =
      case Date.from_iso8601(date_str) do
        {:ok, date} -> date
        _ -> nil
      end

    {:noreply,
     socket
     |> assign(:view_mode, :journal)
     |> assign(:journal_focus_date, focus_date)
     |> load_journal()}
  end

  # ── Events: insights (task 01a13867 stage 5) ────────────────────────────

  # Every handler below builds its scope from a FRESH read of the user
  # (`click_scope/1`) and lets `Platform.Memory.Insights` decide on it. The
  # buttons a row renders are presentation: a forged event for an insight
  # the viewer may not handle is refused there, not here.
  @impl true
  def handle_event("insight_act", %{"id" => id}, socket) do
    with_click_scope(socket, fn scope ->
      case Insights.act(id, scope) do
        {:ok, %{state: "done"}} -> {:info, "Done."}
        {:ok, insight} -> {:info, "Sent to #{addressee_label(insight)}'s briefing."}
        {:error, reason} -> {:error, insight_error(reason)}
      end
    end)
  end

  def handle_event("insight_show_reject", %{"id" => id}, socket) do
    {:noreply, socket |> close_insight_forms() |> assign(:insight_reject_for, id)}
  end

  def handle_event("insight_show_reroute", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> close_insight_forms()
     |> assign(:insight_reroute_for, id)
     |> assign(:insight_people, reroute_people(id))}
  end

  def handle_event("insight_show_edit", %{"id" => id}, socket) do
    {:noreply, socket |> close_insight_forms() |> assign(:insight_edit_for, id)}
  end

  def handle_event("insight_cancel_form", _params, socket) do
    {:noreply, close_insight_forms(socket)}
  end

  # The id arrives as `"_id"`: an input named `id` would override its form
  # element's DOM id.
  def handle_event("insight_reject", %{"_id" => id} = params, socket) do
    with_click_scope(socket, fn scope ->
      case Insights.reject_as(id, scope, Map.get(params, "reason")) do
        {:ok, _} -> {:info, "Rejected. Your reason will teach the next dreaming run."}
        {:error, :blank} -> {:error, "Say why this is wrong. The reason is required."}
        {:error, reason} -> {:error, insight_error(reason)}
      end
    end)
  end

  def handle_event("insight_reroute", %{"_id" => id} = params, socket) do
    with_click_scope(socket, fn scope ->
      case Insights.reroute(id, scope, Map.get(params, "addressee") || "") do
        {:ok, insight} -> {:info, "Rerouted to #{addressee_label(insight)}."}
        {:error, :not_found} -> {:error, "Choose a person to send this to."}
        {:error, reason} -> {:error, insight_error(reason)}
      end
    end)
  end

  def handle_event("insight_edit", %{"_id" => id} = params, socket) do
    attrs =
      %{}
      |> put_present("body", params["body"])
      |> put_hunks(params["hunks"])

    with_click_scope(socket, fn scope ->
      case Insights.edit(id, scope, attrs) do
        {:ok, _} -> {:info, "Saved."}
        {:error, reason} -> {:error, insight_error(reason)}
      end
    end)
  end

  def handle_event("insight_dismiss", %{"id" => id}, socket) do
    with_click_scope(socket, fn scope ->
      case Insights.dismiss(id, scope) do
        {:ok, _} -> {:info, "Dismissed."}
        {:error, reason} -> {:error, insight_error(reason)}
      end
    end)
  end

  def handle_event("insight_revert", %{"id" => id}, socket) do
    with_click_scope(socket, fn scope ->
      case Insights.revert(id, scope) do
        {:ok, _} -> {:info, "Reverted. The page is back as it was."}
        {:error, reason} -> {:error, insight_error(reason)}
      end
    end)
  end

  def handle_event("insight_filter", params, socket) do
    type =
      if params["type"] in ~w(all page_edit question briefing task),
        do: params["type"],
        else: "all"

    confidence = if params["confidence"] in ~w(any high), do: params["confidence"], else: "any"

    {:noreply,
     socket
     |> assign(:insight_filter_type, type)
     |> assign(:insight_filter_confidence, confidence)
     |> load_insights_tab()}
  end

  # The personal opt-out ("Insight briefings and questions"). It writes only
  # the signed-in user's own preference, read from the session id.
  def handle_event("insight_toggle_delivery", params, socket) do
    receive? = List.wrap(params["receive"]) |> List.last() == "true"

    case socket.assigns[:current_user_id] do
      user_id when is_binary(user_id) ->
        case Accounts.update_user_preference(
               user_id,
               Accounts.insight_delivery_opt_out_key(),
               not receive?
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:insight_receives?, receive?)
             |> put_flash(
               :info,
               if(receive?,
                 do: "You will receive insight briefings and questions.",
                 else: "You will not receive insight briefings or questions."
               )
             )}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not save your preference.")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # ── Events: editing ─────────────────────────────────────────────────────

  @impl true
  def handle_event("start_edit", _params, socket) do
    case socket.assigns.selected_page do
      %{file_key: file_key} = page ->
        if ProductDocs.product_owned?(file_key),
          do: refuse_product_owned(socket, file_key),
          else: start_edit(page, socket)

      nil ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    page = socket.assigns.selected_page

    {:noreply,
     socket
     |> assign(:editing, false)
     |> assign(:editor_content, page.content)
     |> assign(:preview_html, render_markdown(page.content, socket.assigns.pages))
     |> assign(:fm_form, nil)
     |> assign(:fm_complex, nil)
     |> assign(:save_error, nil)}
  end

  @impl true
  def handle_event("update_preview", %{"content" => content}, socket) do
    {:noreply,
     socket
     |> assign(:editor_content, content)
     |> assign(:preview_html, render_markdown(content, socket.assigns.pages))}
  end

  @impl true
  def handle_event("update_frontmatter", %{"frontmatter" => params}, socket) do
    {:noreply, assign(socket, :fm_form, to_form(params, as: :frontmatter))}
  end

  @impl true
  def handle_event("save_page", params, socket) do
    # Design lock §6: agents must propose changes via memory_create —
    # the UI save path fails closed for Agent-shaped users without
    # touching the domain layer.
    cond do
      agent_actor?(socket.assigns) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Agents must propose changes via memory_create. UI editing is for humans only."
         )}

      product_owned_selection?(socket.assigns) ->
        refuse_product_owned(socket, socket.assigns.selected_page.file_key)

      true ->
        save_page(params, socket)
    end
  end

  # ── Events: create ──────────────────────────────────────────────────────

  @impl true
  def handle_event("show_create", _params, socket) do
    {:noreply,
     socket
     |> assign(:creating, true)
     |> assign(:new_file_key, "")
     |> assign(:new_file_template, nil)}
  end

  @impl true
  def handle_event("cancel_create", _params, socket) do
    {:noreply, assign(socket, :creating, false)}
  end

  @impl true
  def handle_event("select_template", %{"key" => key}, socket) do
    {:noreply,
     socket
     |> assign(:new_file_key, key)
     |> assign(:new_file_template, Context.default_template(key))}
  end

  @impl true
  def handle_event("update_new_file_key", %{"value" => value}, socket) do
    {:noreply, assign(socket, :new_file_key, value)}
  end

  @impl true
  def handle_event("create_file", %{"file_key" => file_key}, socket) do
    file_key = String.trim(file_key)

    # Ensure .md extension
    file_key =
      if String.ends_with?(file_key, ".md"), do: file_key, else: file_key <> ".md"

    # Normalize to the page grammar (`<ns>/page/<rest>`) so UI-created
    # pages are recognised by the memory_* gates. The flash + patch
    # below use the normalized key, so the user sees where it landed.
    file_key = normalize_page_key(file_key)

    template =
      Context.default_template(file_key) || "# #{String.replace(file_key, ".md", "")}\n\n"

    case Wiki.upsert_page(file_key, %{
           content: template,
           updated_by: socket.assigns.current_user_id
         }) do
      {:ok, _page} ->
        {:noreply,
         socket
         |> refresh_pages()
         |> assign(:creating, false)
         |> push_patch(to: ~p"/org_memory/#{String.split(file_key, "/")}")
         |> put_flash(:info, "Created #{file_key}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, changeset_error_message(changeset))}

      {:error, :stale} ->
        {:noreply, put_flash(socket, :error, "Conflicting update for #{file_key} — try again")}

      # The product-owned `burrow/` backstop in `Platform.Org.Wiki`.
      {:error, :product_owned} ->
        {:noreply, put_flash(socket, :error, product_owned_message(file_key))}
    end
  end

  # ── Events: delete ──────────────────────────────────────────────────────

  @impl true
  def handle_event("confirm_delete", %{"key" => file_key}, socket) do
    if ProductDocs.product_owned?(file_key),
      do: refuse_product_owned(socket, file_key),
      else: {:noreply, assign(socket, :confirm_delete, file_key)}
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, nil)}
  end

  @impl true
  def handle_event("delete_file", %{"key" => file_key}, socket) do
    if ProductDocs.product_owned?(file_key),
      do: refuse_product_owned(socket, file_key),
      else: delete_file(file_key, socket)
  end

  # ── Events: seeding ─────────────────────────────────────────────────────

  @impl true
  def handle_event("seed_defaults", _params, socket) do
    Context.seed_defaults(updated_by: socket.assigns.current_user_id)

    {:noreply,
     socket
     |> refresh_pages()
     |> put_flash(:info, "Default org memory pages created")}
  end

  defp start_edit(page, socket) do
    {frontmatter, body} = Wiki.parse_frontmatter(page.content)

    socket =
      cond do
        frontmatter == %{} ->
          # No frontmatter — the textarea edits the full content.
          socket
          |> assign(:fm_form, nil)
          |> assign(:fm_complex, nil)
          |> assign(:editor_content, page.content)

        flat_frontmatter?(frontmatter) ->
          # Flat string-keyed scalars: one form row per key; the
          # textarea edits the body only (frontmatter is rebuilt from
          # the form on save).
          socket
          |> assign(:fm_form, to_form(frontmatter, as: :frontmatter))
          |> assign(:fm_complex, nil)
          |> assign(:editor_content, body)

        true ->
          # Nested / non-scalar frontmatter: read-only display, edit
          # the YAML directly in the body textarea.
          socket
          |> assign(:fm_form, nil)
          |> assign(:fm_complex, leading_frontmatter_block(page.content, body))
          |> assign(:editor_content, page.content)
      end

    {:noreply,
     socket
     |> assign(:editing, true)
     |> assign(
       :preview_html,
       render_markdown(socket.assigns.editor_content, socket.assigns.pages)
     )}
  end

  defp delete_file(file_key, socket) do
    # Route through `Platform.Org.Context.delete_file/2` (not
    # `Wiki.delete_page/2`) so the memory-feedback ledger captures the
    # delete — Context.delete_file wraps the Repo.delete + capture in a
    # single transaction. `editor_id` threads through so the row is
    # attributed to the human clicking the delete button.
    case Context.delete_file(file_key, editor_id: socket.assigns.current_user_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_pages()
         |> assign(:confirm_delete, nil)
         |> push_patch(to: ~p"/org_memory")
         |> put_flash(:info, "Deleted #{file_key}")}

      # The product-owned `burrow/` backstop in `Platform.Org.Context`
      # (an alias can resolve a non-burrow key onto a product row).
      {:error, :product_owned} ->
        refuse_product_owned(socket, file_key)

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete #{file_key}")}
    end
  end

  # ── PubSub: insights (task 01a13867 stage 5) ────────────────────────────

  # Any change to any insight reloads the tab (or just its count when the
  # tab is not open). A list bounded to 50 rows; reloading is cheap.
  @impl true
  def handle_info({:memory_insights, _event, _payload}, socket) do
    socket =
      if socket.assigns.view_mode == :insights,
        do: load_insights_tab(socket),
        else: assign(socket, :insights_open_count, count_open_insights())

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Rendering ───────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :insights_pane, insights_pane_assigns(assigns))

    ~H"""
    <div class="h-full overflow-hidden">
      <%!-- Desktop three-pane grid — unchanged, guarded behind
           `hidden lg:grid` (task 019f9282). Renders byte-identically
           to before on lg+ viewports. --%>
      <div
        class={[
          "hidden h-full overflow-hidden lg:grid",
          if(@view_mode == :pages,
            do: "grid-cols-[16rem_minmax(0,1fr)_18rem]",
            else: "grid-cols-[16rem_minmax(0,1fr)]"
          )
        ]}
        data-view-mode={@view_mode}
      >
        <NamespaceTree.namespace_tree
          tree={@namespace_tree}
          expanded_prefixes={@expanded_prefixes}
          selected_file_key={@selected_page && @selected_page.file_key}
          burrow_docs={@burrow_docs}
        />

        <div class="flex min-h-0 flex-col overflow-hidden">
          <.tab_strip view_mode={@view_mode} insights_open_count={@insights_open_count} />

          <%= case @view_mode do %>
            <% :journal -> %>
              <JournalPane.journal_pane
                groups={@journal_groups}
                draft={@journal_draft}
                namespace={effective_journal_namespace(@journal_namespace_override, @selected_page)}
                focus_date={@journal_focus_date}
              />
            <% :search -> %>
              <SearchPane.search_pane
                query={@search_query}
                corpus={@search_corpus}
                namespace={@search_namespace}
                namespaces={top_level_namespaces(@namespace_tree, @burrow_docs)}
                results={@search_results}
                performed={@search_performed}
                truncated={@search_truncated}
                error={@search_error}
                degraded={@search_degraded}
                dead_channels={@search_dead_channels}
                results_revealed={@search_results_revealed}
                burrow_docs={@burrow_docs}
              />
            <% :insights -> %>
              <InsightsPane.insights_pane surface={:desktop} {@insights_pane} />
            <% :pages -> %>
              <%= if @creating do %>
                <.create_panel
                  new_file_key={@new_file_key}
                  new_file_template={@new_file_template}
                  pages={@pages}
                />
              <% else %>
                <PageViewer.page_viewer
                  page={@selected_page}
                  editing={@editing}
                  editor_content={@editor_content}
                  preview_html={@preview_html}
                  save_error={@save_error}
                  confirm_delete={@confirm_delete}
                  fm_form={@fm_form}
                  fm_complex={@fm_complex}
                  doc={ProductDocs.find(@burrow_docs, @selected_page)}
                  burrow_docs={@burrow_docs}
                />
              <% end %>
          <% end %>
        </div>

        <%!-- Backlinks/meta make sense only against a selected page —
           the right pane renders on :pages only and the grid collapses
           to two columns on the other tabs (judgment call: the feed /
           results get the extra width instead of an empty aside). --%>
        <RightPane.right_pane
          :if={@view_mode == :pages}
          page={@selected_page}
          backlinks={@backlinks}
          updated_by_display={@updated_by_display}
          doc={ProductDocs.find(@burrow_docs, @selected_page)}
        />
      </div>

      <%!-- Mobile branch (`lg:hidden`) — task 019f9282. --%>
      <MobileShell.mobile_shell
        view_mode={@view_mode}
        insights_open_count={@insights_open_count}
        tree_drawer_open={@tree_drawer_open}
        namespace_tree={@namespace_tree}
        expanded_prefixes={@expanded_prefixes}
        burrow_docs={@burrow_docs}
        creating={@creating}
        page={@selected_page}
        preview_html={@preview_html}
        editing={@editing}
        editor_content={@editor_content}
        save_error={@save_error}
        confirm_delete={@confirm_delete}
        backlinks={@backlinks}
        updated_by_display={@updated_by_display}
        journal_groups={@journal_groups}
        journal_namespace={effective_journal_namespace(@journal_namespace_override, @selected_page)}
        journal_draft={@journal_draft}
        journal_focus_date={@journal_focus_date}
        search_query={@search_query}
        search_corpus={@search_corpus}
        search_namespace={@search_namespace}
        namespaces={top_level_namespaces(@namespace_tree, @burrow_docs)}
        search_results={@search_results}
        search_performed={@search_performed}
        search_truncated={@search_truncated}
        search_error={@search_error}
        search_degraded={@search_degraded}
        search_dead_channels={@search_dead_channels}
        search_results_revealed={@search_results_revealed}
        insights_pane={@insights_pane}
      >
        <:create_panel>
          <.create_panel
            new_file_key={@new_file_key}
            new_file_template={@new_file_template}
            pages={@pages}
          />
        </:create_panel>
      </MobileShell.mobile_shell>
    </div>
    """
  end

  # ── Tab strip (stage 6) ─────────────────────────────────────────────────

  attr(:view_mode, :atom, required: true)
  attr(:insights_open_count, :integer, default: 0)

  defp tab_strip(assigns) do
    ~H"""
    <div
      class="flex items-center gap-1 border-b border-edge bg-base-200/40 px-4 pt-2"
      data-role="tab-strip"
      role="tablist"
    >
      <button
        :for={
          {tab, label} <- [
            {"pages", "Pages"},
            {"journal", "Journal"},
            {"search", "Search"},
            {"insights", "Insights"}
          ]
        }
        phx-click="switch_tab"
        phx-value-tab={tab}
        data-tab={tab}
        role="tab"
        aria-selected={to_string(Atom.to_string(@view_mode) == tab)}
        class={[
          "flex items-center gap-1.5 rounded-t-lg border-x border-t px-4 py-1.5 text-sm transition-colors",
          if(Atom.to_string(@view_mode) == tab,
            do: "border-edge bg-base-100 font-medium text-base-content",
            else:
              "border-transparent text-base-content/50 hover:bg-base-300/60 hover:text-base-content"
          )
        ]}
      >
        {label}
        <span
          :if={tab == "insights" and @insights_open_count > 0}
          class="badge badge-neutral badge-xs"
          data-role="insights-tab-count"
        >
          {@insights_open_count}
        </span>
      </button>
    </div>
    """
  end

  # ── Local panels (create flow stays here until a later stage) ───────────

  attr(:new_file_key, :string, required: true)
  attr(:new_file_template, :string, default: nil)
  attr(:pages, :list, required: true)

  defp create_panel(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col overflow-hidden">
      <%!-- Header --%>
      <div class="flex items-center justify-between border-b border-edge px-6 py-3">
        <div>
          <h1 class="text-lg font-bold">Create Memory Page</h1>
          <p class="text-xs text-base-content/40">Choose a template or create a custom page</p>
        </div>
        <button phx-click="cancel_create" class="btn btn-ghost btn-sm">
          Cancel
        </button>
      </div>

      <div class="flex-1 overflow-y-auto px-6 py-6">
        <%!-- Template cards --%>
        <h2 class="mb-3 text-sm font-semibold uppercase tracking-wider text-base-content/50">
          Templates
        </h2>
        <div class="grid grid-cols-2 gap-3 mb-8">
          <%= for {key, _template} <- Context.default_templates(),
                  not ProductDocs.product_owned?(key) do %>
            <% existing = Enum.any?(@pages, &(&1.file_key == key)) %>
            <button
              phx-click="select_template"
              phx-value-key={key}
              disabled={existing}
              class={[
                "flex flex-col items-start rounded-lg border p-4 text-left transition-colors",
                if(existing,
                  do: "border-edge bg-base-200/50 opacity-50 cursor-not-allowed",
                  else: "border-edge hover:border-primary hover:bg-primary/5 cursor-pointer"
                ),
                if(@new_file_key == key,
                  do: "border-primary bg-primary/5 ring-1 ring-primary",
                  else: ""
                )
              ]}
            >
              <span class={[
                NamespaceTree.file_icon(key),
                "size-5 mb-2",
                if(existing, do: "text-base-content/30", else: "text-primary")
              ]}>
              </span>
              <span class="text-sm font-medium">{key}</span>
              <span class="text-xs text-base-content/40 mt-0.5">
                {template_description(key)}
              </span>
              <span :if={existing} class="mt-1 text-xs text-base-content/30">
                Already exists
              </span>
            </button>
          <% end %>
        </div>

        <%!-- Custom page input --%>
        <h2 class="mb-3 text-sm font-semibold uppercase tracking-wider text-base-content/50">
          Custom Page
        </h2>
        <div class="flex items-end gap-3">
          <div class="flex-1">
            <label class="text-xs text-base-content/50 mb-1 block">
              Page path (e.g. <code>org/custom.md</code>)
            </label>
            <input
              type="text"
              value={@new_file_key}
              phx-keyup="update_new_file_key"
              placeholder="org/custom.md"
              class="input input-bordered input-sm w-full font-mono"
            />
          </div>
          <button
            phx-click="create_file"
            phx-value-file_key={@new_file_key}
            disabled={@new_file_key == ""}
            class="btn btn-primary btn-sm gap-1"
          >
            <span class="hero-plus size-4"></span> Create
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  # Page-grammar normalization for the create path (Sloane-authorized,
  # 2026-06-11). The T5 routing grammar only recognises pages at
  # `<ns>/page/<rest>` (ns ∈ org | project/<uuid> | space/<uuid>) —
  # flat keys (`org/custom.md`) classify :unknown and are dropped by
  # memory_search's read-gate hydration. The DOMAIN stays free-form
  # (`Wiki.upsert_page/3` accepts any key); only this LiveView create
  # handler inserts the `page/` segment. Keys already under `page/`,
  # `journal/`, or `private/` — and keys outside the namespace grammar
  # (non-UUID project/space slots, no recognised namespace) — pass
  # through untouched.
  defp normalize_page_key(file_key) do
    case String.split(file_key, "/") do
      ["org" | [_ | _] = rest] ->
        insert_page_segment("org", rest)

      [kind, id | [_ | _] = rest] when kind in ["project", "space"] ->
        # Platform.UUID.cast/1, NOT Ecto.UUID.cast/1. FABRICATED-VALUE site:
        # nothing raises here — a bare cast simply accepts any 16-character
        # LiveView param as a namespace uuid and rewrites the page key around
        # it. Assert on the returned key, not on an exception.
        case Platform.UUID.cast(id) do
          {:ok, _} -> insert_page_segment("#{kind}/#{id}", rest)
          :error -> file_key
        end

      _ ->
        file_key
    end
  end

  defp insert_page_segment(ns, [first | _] = rest) when first in ~w(page journal private) do
    ns <> "/" <> Enum.join(rest, "/")
  end

  defp insert_page_segment(ns, rest), do: ns <> "/page/" <> Enum.join(rest, "/")

  # Body source: explicit `content` param (textarea save via the
  # MarkdownEditor hook) or the tracked `@editor_content` (frontmatter
  # form submit). When the frontmatter form is active the textarea
  # holds the body only, so the serialized frontmatter block is
  # prepended before the upsert.
  defp save_page(params, socket) do
    %{selected_page: page, current_user_id: current_user_id} = socket.assigns

    body = Map.get(params, "content", socket.assigns.editor_content)
    content = prepend_frontmatter(body, params, socket.assigns.fm_form)

    case Wiki.upsert_page(page.file_key, %{content: content, updated_by: current_user_id}) do
      {:ok, updated_page} ->
        socket = refresh_pages(socket)

        {:noreply,
         socket
         |> assign(:selected_page, updated_page)
         |> assign(:editor_content, updated_page.content)
         |> assign(:preview_html, render_markdown(updated_page.content, socket.assigns.pages))
         |> assign(:editing, false)
         |> assign(:save_error, nil)
         |> assign(:fm_form, nil)
         |> assign(:fm_complex, nil)
         |> assign(:updated_by_display, updated_by_display(updated_page.updated_by))
         |> put_flash(:info, "#{updated_page.file_key} saved (v#{updated_page.version})")}

      {:error, :stale} ->
        {:noreply,
         assign(
           socket,
           :save_error,
           "Page was updated elsewhere — reload and re-apply your edit."
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :save_error, changeset_error_message(changeset))}

      # The product-owned `burrow/` backstop in `Platform.Org.Wiki`.
      {:error, :product_owned} ->
        {:noreply, put_flash(socket, :error, product_owned_message(page.file_key))}
    end
  end

  defp product_owned_message(file_key) do
    "#{file_key} is Burrow product documentation and is read-only. It is updated on deploy."
  end

  # ── Stage 6 helpers: tabs / journal / search ────────────────────────────

  defp view_mode_for("pages"), do: :pages
  defp view_mode_for("journal"), do: :journal
  defp view_mode_for("search"), do: :search
  defp view_mode_for("insights"), do: :insights

  # Load the Insights tab: open insights (filtered), the "Already done" rows
  # while dissemination is on, and which rows the viewer may press buttons
  # on. Re-run on every PubSub change and after every click, so a second
  # session sees an insight leave as soon as someone acts on it.
  #
  # An insight that was delivered (its briefing line or question is already
  # in someone's briefing) is not on the open list: the recipient's answer
  # settles it, and asking again would deliver it twice. A `needs_call`
  # insight is the exception (task 01a13867 stage 6): the briefing only
  # points an admin at this tab, so it stays here whatever `delivered_at`
  # says. See `tab_insights/1`.
  defp load_insights_tab(socket) do
    now = DateTime.utc_now()
    settings = InsightSettings.get()
    scope = click_scope(socket)
    actionable = tab_insights(Insights.list_open(workspace_id: nil, now: now))
    shown = Enum.filter(actionable, &insight_filter?(&1, socket.assigns))
    done = if settings.dissemination_enabled, do: Insights.list_done(now: now), else: []

    handle_ids =
      case scope do
        %Scope{} = scope ->
          shown |> Enum.filter(&Insights.may_handle?(&1, scope)) |> MapSet.new(& &1.id)

        nil ->
          MapSet.new()
      end

    names = Routing.names(Enum.map(shown, & &1.addressee_user_id))

    socket
    |> assign(:view_mode, :insights)
    |> assign(:insights_open_count, length(actionable))
    |> assign(:insights, shown)
    |> assign(:insights_done, done)
    |> assign(:insight_handle_ids, handle_ids)
    |> assign(:insight_dissemination_on, settings.dissemination_enabled)
    |> assign(:insight_admin?, scope != nil and Platform.Access.authorize_install(scope) == :ok)
    |> assign(
      :insight_receives?,
      not Accounts.insight_delivery_opted_out?(socket.assigns[:current_user_id])
    )
    |> assign(:insight_names, names)
  end

  defp insight_filter?(insight, assigns) do
    (assigns.insight_filter_type == "all" or insight.action_type == assigns.insight_filter_type) and
      (assigns.insight_filter_confidence == "any" or insight.confidence == "high")
  end

  defp insights_pane_assigns(assigns) do
    %{
      insights: assigns.insights,
      done: assigns.insights_done,
      dissemination_on: assigns.insight_dissemination_on,
      admin?: assigns.insight_admin?,
      receives?: assigns.insight_receives?,
      handle_ids: assigns.insight_handle_ids,
      filter_type: assigns.insight_filter_type,
      filter_confidence: assigns.insight_filter_confidence,
      reject_for: assigns.insight_reject_for,
      reroute_for: assigns.insight_reroute_for,
      edit_for: assigns.insight_edit_for,
      people: assigns.insight_people,
      names: assigns.insight_names
    }
  end

  # A fresh scope for one click: the user is READ AGAIN, never taken from
  # mount, so a membership or role change made since mount applies to the
  # very next click. nil when the session names no user.
  defp click_scope(socket) do
    with user_id when is_binary(user_id) <- socket.assigns[:current_user_id],
         %Platform.Accounts.User{} = user <- Accounts.get_user(user_id) do
      Scope.for_user(user)
    else
      _ -> nil
    end
  end

  defp with_click_scope(socket, fun) do
    socket =
      case click_scope(socket) do
        nil ->
          put_flash(socket, :error, "Sign in to act on insights.")

        scope ->
          case fun.(scope) do
            {:info, message} -> socket |> close_insight_forms() |> put_flash(:info, message)
            {:error, message} -> put_flash(socket, :error, message)
          end
      end

    {:noreply, load_insights_tab(socket)}
  end

  defp close_insight_forms(socket) do
    socket
    |> assign(:insight_reject_for, nil)
    |> assign(:insight_reroute_for, nil)
    |> assign(:insight_edit_for, nil)
  end

  defp reroute_people(id) do
    case Insights.get(id) do
      %{} = insight -> Routing.candidates(Tier.org_id(insight))
      nil -> []
    end
  end

  defp addressee_label(%{addressee_user_id: id}) when is_binary(id),
    do: Map.get(Routing.names([id]), id, "the addressee")

  defp addressee_label(_insight), do: "the addressee"

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value) when is_binary(value), do: Map.put(map, key, value)
  defp put_present(map, _key, _value), do: map

  # Edit form hunks arrive as `%{"0" => %{"old" => _, "new" => _}, ...}`.
  defp put_hunks(map, hunks) when is_map(hunks) do
    list =
      hunks
      |> Enum.sort_by(fn {index, _} -> String.to_integer(index) end)
      |> Enum.map(fn {_index, %{"old" => old, "new" => new}} -> %{"old" => old, "new" => new} end)

    Map.put(map, "hunks", list)
  rescue
    _ -> map
  end

  defp put_hunks(map, _hunks), do: map

  defp insight_error(:expired), do: "This insight has expired. Nothing was done."

  defp insight_error(:unauthorized),
    do: "You cannot act on this insight. An install admin decides it."

  defp insight_error(:stale),
    do: "The page changed since this edit was written. Nothing was applied."

  defp insight_error(:not_open), do: "Someone already handled this insight."
  defp insight_error(:not_found), do: "The page or project this insight names was not found."
  defp insight_error(:no_project), do: "This insight names no project. Pick a project to file it."
  defp insight_error(:no_addressee), do: "No one to send this to. Reroute it first."

  defp insight_error(:opted_out),
    do: "The addressee has turned off insight briefings and questions."

  defp insight_error(:no_agent),
    do: "No agent holds the dreaming responsibility, so there is no briefing to deliver to."

  defp insight_error(:not_revertible), do: "This edit can no longer be reverted."
  defp insight_error(:not_supported), do: "This insight has no action to run."
  defp insight_error(:invalid), do: "This insight is malformed. Reject it with a reason."
  defp insight_error(%Ecto.Changeset{} = changeset), do: changeset_error_message(changeset)
  defp insight_error(other), do: "Could not do that: #{inspect(other)}"

  # Cheap count for the tab-strip badge: open insights that still need
  # someone on this tab (the same rows `load_insights_tab/1` lists).
  defp count_open_insights do
    Insights.list_open(workspace_id: nil) |> tab_insights() |> length()
  end

  # The open insights the tab lists: every undelivered one, plus every
  # delivered one that needs a call. The Digest routes by the tier it
  # re-classifies at delivery (`Tier.classify/1`), not the stored one, so a
  # delivered row is re-classified the same way and, when it needs a call,
  # carries that tier for the row's warning styling and button gate.
  defp tab_insights(open) do
    Enum.flat_map(open, fn
      %{delivered_at: nil} = insight ->
        [insight]

      insight ->
        if insight.tier == "needs_call" or Tier.classify(insight) == :needs_call,
          do: [%{insight | tier: "needs_call"}],
          else: []
    end)
  end

  # Reload the journal feed: recent entries for the active namespace,
  # grouped by date (newest day first, entries within a day oldest
  # first — the V1 memory-feed grouping).
  #
  # When `:journal_focus_date` is set, that day is read with
  # `Journal.get_for_date/2` and merged in as its own group (task
  # 01a1170a stage 2): a deep link to a day older than the 14-day window,
  # or a busy day the `limit` pushed out, must still land on rendered
  # content. The focused day replaces any partial group the recent read
  # returned for it.
  defp load_journal(socket) do
    %{journal_namespace_override: override, selected_page: page} = socket.assigns
    namespace = effective_journal_namespace(override, page)

    groups =
      [days_back: @journal_days_back, limit: @journal_limit, namespace: namespace]
      |> Journal.list_recent()
      |> Enum.group_by(& &1.date)
      |> merge_focus_day(socket.assigns.journal_focus_date, namespace)
      |> Enum.sort_by(fn {date, _entries} -> date end, {:desc, Date})
      |> Enum.map(fn {date, entries} ->
        {date, Enum.sort_by(entries, & &1.inserted_at, DateTime)}
      end)

    assign(socket, :journal_groups, groups)
  end

  defp merge_focus_day(groups, nil, _namespace), do: groups

  defp merge_focus_day(groups, %Date{} = focus_date, namespace) do
    case Journal.get_for_date(focus_date, namespace: namespace) do
      [] -> groups
      entries -> Map.put(groups, focus_date, entries)
    end
  end

  # The namespace the Journal tab reads from and appends to: the `?ns=`
  # deep-link override when one is set, else the selected page's.
  defp effective_journal_namespace(override, _page) when is_binary(override), do: override
  defp effective_journal_namespace(nil, page), do: journal_namespace(page)

  # `?ns=` accepts only `org`, `project/<id>` or `space/<id>`; anything
  # else (missing, empty, extra segments, unknown kind) falls back to the
  # journal default.
  defp parse_namespace_param("org"), do: "org"

  defp parse_namespace_param(ns) when is_binary(ns) do
    case String.split(ns, "/") do
      [kind, id] when kind in ["project", "space"] and id != "" -> ns
      _ -> Journal.default_namespace()
    end
  end

  defp parse_namespace_param(_), do: Journal.default_namespace()

  # Namespace dimension for journal reads/appends: derived from the
  # selected page's file_key (`org/...` → `"org"`,
  # `project/<uuid>/...` → `"project/<uuid>"`), falling back to the
  # journal default (`"org"`) when nothing is selected or the key
  # doesn't carry a recognizable namespace.
  defp journal_namespace(nil), do: Journal.default_namespace()

  defp journal_namespace(%{file_key: file_key}) do
    case String.split(file_key, "/") do
      ["org", _ | _] -> "org"
      [kind, id, _ | _] when kind in ["project", "space"] -> "#{kind}/#{id}"
      _ -> Journal.default_namespace()
    end
  end

  # Drop nil-ish filter values ("all" / "") instead of passing nils —
  # the tool surface validates arg types.
  defp put_filter(args, _key, value) when value in [nil, "", "all"], do: args
  defp put_filter(args, key, value), do: Map.put(args, key, value)

  # Seam for tests: swap in a recorder via
  # `Application.put_env(:platform, :org_memory_tool_surface, Stub)`.
  # Same pattern as :chat_agent_module / :quick_agent_provider_module.
  defp tool_surface do
    Application.get_env(:platform, :org_memory_tool_surface, Platform.Federation.ToolSurface)
  end

  # Top-level namespace prefixes from the built tree ("org/" → "org"),
  # feeding the search pane's namespace dropdown. The Pages tree no longer
  # carries `burrow/`, so `burrow` is added back when Burrow Docs exist
  # (the pane labels it "Burrow Docs").
  defp top_level_namespaces(%{folders: folders}, burrow_docs) do
    org =
      folders
      |> Map.values()
      |> Enum.map(&String.trim_trailing(&1.prefix, "/"))

    (if(burrow_docs == [], do: [], else: ["burrow"]) ++ org)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # RBAC v2 resource grants (task 01a1386d-e528 stage 4): the user's
  # `@access_scope` (LiveAuth) narrows the tree, the page read and the search
  # to the pages it may `memory.read`; a denied page reads as absent.
  defp page_access_opts(socket) do
    case socket.assigns[:access_scope] do
      %Platform.Access.Scope{} = scope -> [access_scope: scope]
      _ -> []
    end
  end

  # The search goes through the tool surface with the anonymous UI caller
  # context `%{agent: nil}`. The scope rides on it only when a `memory.read`
  # grant applies: with none the search is unchanged, so the context is too.
  defp search_context(socket) do
    case socket.assigns[:access_scope] do
      %Platform.Access.Scope{} = scope ->
        if Platform.Access.grants_apply?(scope, "memory.read"),
          do: %{agent: nil, access_scope: scope},
          else: %{agent: nil}

      _ ->
        %{agent: nil}
    end
  end

  defp refresh_pages(socket) do
    pages = Wiki.list_pages(page_access_opts(socket))
    {tree, burrow_docs} = build_trees(pages)

    socket
    |> assign(:pages, pages)
    |> assign(:namespace_tree, tree)
    |> assign(:burrow_docs, burrow_docs)
    |> update(:expanded_prefixes, &MapSet.union(&1, default_expanded(tree, burrow_docs)))
  end

  # ── Burrow Docs (task 01a10a44 stage 5) ─────────────────────────────────

  # The Pages tree is built from org pages only; `burrow/` rows become the
  # Burrow Docs section's entries instead.
  defp build_trees(pages) do
    {product_pages, org_pages} = ProductDocs.split(pages)
    {NamespaceTree.build(org_pages), ProductDocs.entries(product_pages)}
  end

  # Burrow Docs start collapsed. They open by default only when the install
  # has no org pages yet, so the docs are the first thing a new install
  # sees. (Selecting a Burrow page opens them too, via `ancestor_prefixes/1`
  # in `handle_params/3`.)
  defp default_expanded(tree, burrow_docs) do
    expanded = NamespaceTree.default_expanded(tree)

    if burrow_docs != [] and tree.folders == %{} and tree.pages == [],
      do: MapSet.put(expanded, NamespaceTree.burrow_prefix()),
      else: expanded
  end

  # The selected page's HTML. A Burrow page drops a first heading that
  # repeats its title, since the page header already shows the title.
  defp render_page(page, assigns) do
    content =
      case ProductDocs.find(assigns[:burrow_docs] || [], page) do
        %{title: title} -> ProductDocs.display_content(page.content, title)
        nil -> page.content
      end

    render_markdown(content, assigns.pages)
  end

  defp product_owned_selection?(%{selected_page: %{file_key: file_key}}),
    do: ProductDocs.product_owned?(file_key)

  defp product_owned_selection?(_assigns), do: false

  # The server-side refusal for every edit / delete event on a `burrow/`
  # key. It resets any edit or delete-confirm state, so a forged event
  # cannot leave the page in an editing sub-state either.
  defp refuse_product_owned(socket, file_key) do
    {:noreply,
     socket
     |> assign(:editing, false)
     |> assign(:confirm_delete, nil)
     |> put_flash(:error, product_owned_message(file_key))}
  end

  defp changeset_error_message(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
    |> Enum.map_join(", ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end

  # Render markdown with wikilinks swapped. The lookup table is built
  # once per render: direct hits against the already-loaded `@pages`
  # list, `Wiki.resolve_alias/2` fallback for misses, then
  # `Wiki.resolve_basename/2` as the last resort (`[[identity]]` →
  # `org/page/identity.md` when the basename is unique in scope;
  # ambiguous/zero matches stay dangling) — so the renderer itself
  # stays pure (no DB calls inside `MarkdownRenderer.render/2`).
  defp render_markdown(content, pages) do
    MarkdownRenderer.render(content, wikilink_lookup(content, pages))
  end

  defp wikilink_lookup(content, pages) when is_binary(content) do
    page_keys = MapSet.new(pages, & &1.file_key)

    content
    |> Wiki.parse_wikilinks()
    |> Enum.map(& &1.target_path)
    |> Enum.uniq()
    |> Map.new(fn target ->
      cond do
        MapSet.member?(page_keys, target) ->
          {target, target}

        page = Wiki.resolve_alias(target) ->
          {target, page.file_key}

        page = Wiki.resolve_basename(target) ->
          {target, page.file_key}

        true ->
          {target, nil}
      end
    end)
  end

  defp wikilink_lookup(_content, _pages), do: %{}

  # ── Agent gate (design lock §6) ─────────────────────────────────────────

  # `ShellLive` puts the user struct in `:current_user_record` (with a
  # display string in `:current_user`); check both shapes so an
  # Agent-shaped principal fails closed regardless of which assign it
  # arrived through.
  defp agent_actor?(assigns) do
    match?(%Agent{}, assigns[:current_user_record]) or match?(%Agent{}, assigns[:current_user])
  end

  # ── Frontmatter editor helpers ──────────────────────────────────────────

  defp flat_frontmatter?(frontmatter) do
    Enum.all?(frontmatter, fn {_key, value} ->
      is_binary(value) or is_boolean(value) or is_number(value) or is_nil(value)
    end)
  end

  # The frontmatter block is the leading slice of `content` that
  # `Wiki.parse_frontmatter/1` stripped to produce `body`.
  defp leading_frontmatter_block(content, body) do
    prefix_len = byte_size(content) - byte_size(body)
    binary_part(content, 0, max(prefix_len, 0))
  end

  # Rebuild the page content for the upsert. When the frontmatter form
  # is active, serialize its current values (submit params win over the
  # phx-change-tracked form state) into a YAML block and prepend it to
  # the body. Otherwise the body already is the full content.
  defp prepend_frontmatter(body, params, fm_form) do
    fm_params =
      case params do
        %{"frontmatter" => fm} when is_map(fm) -> fm
        _ -> fm_form && fm_form.params
      end

    if fm_params do
      serialize_frontmatter(fm_params) <> body
    else
      body
    end
  end

  # Hand-serialized YAML for flat string-keyed scalars (the only shape
  # the form edits — `Wiki.parse_frontmatter/1` produces string keys,
  # and non-scalar values route to the read-only fallback instead).
  # LiveView's `_unused_*` change-tracking params are dropped.
  defp serialize_frontmatter(params) do
    lines =
      params
      |> Enum.reject(fn {key, _value} -> String.starts_with?(key, "_") end)
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, value} -> "#{key}: #{yaml_scalar(value)}" end)

    "---\n" <> Enum.join(lines, "\n") <> "\n---\n"
  end

  defp yaml_scalar(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp yaml_scalar(nil), do: ~s("")

  defp yaml_scalar(value) when is_binary(value) do
    cond do
      value in ~w(true false) -> value
      match?({_, ""}, Integer.parse(value)) -> value
      match?({_, ""}, Float.parse(value)) -> value
      true -> inspect(value)
    end
  end

  defp yaml_scalar(value), do: inspect(to_string(value))

  # ── History meta ────────────────────────────────────────────────────────

  defp updated_by_display(nil), do: nil

  defp updated_by_display(user_id) do
    case Accounts.get_user(user_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      %{email: email} when is_binary(email) -> email
      _ -> String.slice(user_id, 0, 8)
    end
  end

  defp template_description("org/page/identity.md"), do: "Mission, values, product summary"
  defp template_description("org/page/memory.md"), do: "Long-term curated org knowledge"
  defp template_description("org/page/agents.md"), do: "Agent registry and roles"
  defp template_description("org/page/directory.md"), do: "Auto-generated user/agent roster"
  defp template_description(_), do: "Custom memory page"
end
