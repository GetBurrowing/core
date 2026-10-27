defmodule PlatformWeb.AgentConfigLive do
  @moduledoc """
  An agent's configuration screen at `/control/:agent_slug/config` (task
  01a17b1c stage 5; direction canvas 01a17b1c-bf31, nodes m1/m2/m3).

  The real files the agent's harness reads (`CLAUDE.md`, skills, settings,
  MCP servers, ...), edited where they live, with the session strip saying
  whether the running session has loaded what is saved.

  ## One door

  Every read, write, delete, secret replace and restart goes through
  `Platform.Agents.ConfigFiles`, which decides access (`ConfigFiles.Access`),
  audits, and redacts. This module never touches a backend, a host or a
  stored file. Anyone `ConfigFiles.describe/2` refuses is redirected to the
  agent page before anything is read.

  ## Guarantees drawn here

    * Sections come from the adapter's `concepts/0`; nothing else is drawn,
      not even an empty or "not supported" section.
    * A refused save ("Changed on the machine since you opened it") offers
      Compare and Copy my version. There is no overwrite: the only way to save
      after a conflict is on top of the machine's version.
    * Secret values never reach the page: rows show the name and "value
      hidden", and the replace field is write-only.
  """
  use PlatformWeb, :live_view

  alias Platform.Agents.{Agent, ConfigFiles}
  alias Platform.Agents.ConfigFiles.Edits
  alias Platform.Chat.ContentRenderer
  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo
  alias PlatformWeb.AgentConfig.{Session, SessionStrip}

  @harness_names %{"claude_code" => "Claude Code", "codex" => "Codex"}

  # ── mount ──────────────────────────────────────────────────────────

  @impl true
  def mount(%{"agent_slug" => slug}, session, socket) do
    actor = socket.assigns[:current_user_record] || actor_from(session)

    case Repo.get_by(Agent, slug: slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That agent was not found.")
         |> push_navigate(to: ~p"/control")}

      %Agent{} = agent ->
        mount_agent(socket, actor, agent, ConfigFiles.describe(actor, agent))
    end
  end

  defp actor_from(%{"current_user_id" => id}) when is_binary(id), do: %{id: id}
  defp actor_from(_), do: nil

  defp mount_agent(socket, _actor, agent, {:error, :forbidden}) do
    {:ok,
     socket
     |> put_flash(:error, "Only the agent's owner can edit its configuration.")
     |> push_navigate(to: ~p"/control/#{agent.slug}")}
  end

  defp mount_agent(socket, _actor, agent, {:error, reason}) do
    {:ok,
     socket
     |> base_assigns(agent)
     |> assign(:unavailable, unavailable(agent, reason))
     |> assign(:session, nil)}
  end

  defp mount_agent(socket, actor, agent, {:ok, info} = described) do
    socket =
      socket
      |> base_assigns(agent)
      |> assign(:actor, actor)
      |> assign(:info, info)
      |> assign(:unavailable, nil)
      |> Session.init(actor, agent, described)
      |> load_files()
      |> select_section(:instructions)

    {:ok, socket}
  end

  defp base_assigns(socket, agent) do
    socket
    |> assign(:page_title, "#{agent.name} · Configuration")
    |> assign(:agent, agent)
    |> assign(:info, nil)
    |> assign(:sections, [])
    |> assign(:section, nil)
    |> assign(:mobile_pane, :list)
    |> assign(:narrow?, false)
    |> assign(:editor, nil)
    |> assign(:file_form, to_form(%{"content" => ""}, as: :file))
    |> assign(:settings, nil)
    |> assign(:settings_form, to_form(%{}, as: :settings))
    |> assign(:raw?, false)
    |> assign(:entry_form, to_form(%{"name" => ""}, as: :entry))
    |> assign(
      :mcp_form,
      to_form(%{"name" => "", "command" => "", "args" => "", "url" => ""}, as: :mcp)
    )
    |> assign(:new_open?, false)
    |> assign(:pending_delete, nil)
    |> assign(:notice, nil)
    |> assign(:secret_nonce, 0)
    |> assign(:has_secrets?, false)
    |> stream_configure(:entries, dom_id: &("entry-" <> dom_safe(&1.path)))
    |> stream_configure(:servers, dom_id: &("server-" <> dom_safe(&1.name)))
    |> stream_configure(:secrets, dom_id: &("secret-" <> dom_safe(&1.path <> "-" <> &1.pointer)))
    |> stream(:entries, [])
    |> stream(:servers, [])
    |> stream(:secrets, [])
  end

  defp dom_safe(s), do: String.replace(s, ~r/[^A-Za-z0-9_-]/, "_")

  defp unavailable(_agent, :opt_in_required),
    do:
      {:opt_in,
       "Config editing is off for this agent. Turn it on from its machine with burrow config-access <dir> owner|admins."}

  defp unavailable(agent, :host_offline) do
    runtime = Federation.get_runtime_for_agent(agent)

    if runtime && RuntimePresence.online?(runtime.runtime_id) do
      {:cli_update,
       "#{agent.name}'s burrow CLI needs updating before its configuration can be edited here."}
    else
      {:offline,
       "#{agent.name} is offline. Its configuration opens here when its machine connects."}
    end
  end

  defp unavailable(_agent, :unsupported_harness),
    do: {:unsupported, "Configuration isn't available for this agent's harness."}

  defp unavailable(_agent, _),
    do: {:error, "Configuration could not be loaded. Try again in a moment."}

  # ── loading ────────────────────────────────────────────────────────

  defp load_files(socket) do
    %{actor: actor, agent: agent, info: info} = socket.assigns

    files =
      case ConfigFiles.list(actor, agent) do
        {:ok, entries} -> entries
        _ -> []
      end

    mcp =
      if :mcp_servers in info.concepts,
        do: read_or_nil(socket, Edits.mcp_path(info.adapter)),
        else: nil

    servers = if mcp, do: Edits.mcp_servers(info.adapter, mcp.content), else: []

    socket
    |> assign(:files, files)
    |> assign(:mcp_servers, servers)
    |> assign(:has_secrets?, Enum.any?(files, & &1.secret?))
    |> assign(:sections, Edits.sections(info.adapter, files, length(servers)))
  end

  defp read_or_nil(socket, path) do
    case ConfigFiles.read(socket.assigns.actor, socket.assigns.agent, path) do
      {:ok, file} -> file
      _ -> nil
    end
  end

  defp select_section(socket, concept) do
    info = socket.assigns.info

    socket =
      socket
      |> assign(:section, concept)
      |> assign(:raw?, false)
      |> assign(:new_open?, false)
      |> assign(:pending_delete, nil)
      |> assign(:notice, nil)
      |> assign(:settings, nil)

    cond do
      concept == :instructions ->
        open_file(socket, info.adapter.instructions_path())

      concept in Edits.entry_concepts() ->
        socket |> assign(:editor, nil) |> stream_entries()

      concept == :settings ->
        socket |> assign(:editor, nil) |> load_settings()

      concept == :mcp_servers ->
        socket
        |> assign(:editor, nil)
        |> stream(:servers, socket.assigns.mcp_servers, reset: true)
    end
  end

  defp stream_entries(socket) do
    %{info: info, section: concept, files: files} = socket.assigns

    entries =
      for e <- Edits.entries(info.adapter, concept, files) do
        desc =
          case read_or_nil(socket, e.path) do
            %{content: content} -> Edits.description(content)
            nil -> ""
          end

        Map.put(e, :description, desc)
      end

    stream(socket, :entries, entries, reset: true)
  end

  defp load_settings(socket) do
    adapter = socket.assigns.info.adapter
    file = read_or_nil(socket, adapter.settings_path())
    values = Edits.known_values(adapter, file && file.content)

    secrets =
      for %{path: path, secret?: true} <- socket.assigns.files,
          String.starts_with?(Path.basename(path), ".env"),
          file = read_or_nil(socket, path),
          file != nil,
          name <- file.secret_names,
          do: %{path: path, pointer: name, name: name}

    socket
    |> assign(:settings, %{file: file, values: values})
    |> assign(:settings_form, to_form(values, as: :settings))
    |> stream(:secrets, secrets, reset: true)
  end

  defp open_file(socket, path, opts \\ []) do
    {content, sha} =
      case ConfigFiles.read(socket.assigns.actor, socket.assigns.agent, path) do
        {:ok, %{content: content, sha256: sha}} -> {content, sha}
        _ -> {Keyword.get(opts, :seed, ""), nil}
      end

    mode = if socket.assigns.narrow? and Edits.markdown?(path), do: :preview, else: :edit

    socket
    |> assign(:editor, %{
      path: path,
      base_sha: sha,
      original: content,
      draft: content,
      mode: mode,
      lang: Edits.language(path),
      error_line: Edits.parse_error_line(path, content),
      conflict: nil,
      compare: nil,
      failure: nil,
      saved?: false
    })
    |> assign(:file_form, to_form(%{"content" => content}, as: :file))
  end

  # ── events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event(event, params, %{assigns: %{unavailable: nil}} = socket)
      when event in ~w(session_restart session_restart_confirm session_restart_cancel),
      do: Session.handle_event(event, params, socket)

  def handle_event(_event, _params, %{assigns: %{unavailable: {_, _}}} = socket),
    do: {:noreply, socket}

  def handle_event("viewport", %{"below" => below}, socket) do
    socket = assign(socket, :narrow?, below == true)

    socket =
      case socket.assigns.editor do
        %{draft: d, original: d, path: path} = ed when below == true ->
          if Edits.markdown?(path),
            do: assign(socket, :editor, %{ed | mode: :preview}),
            else: socket

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("select_section", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.sections, &(Atom.to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      %{id: concept} ->
        {:noreply, socket |> select_section(concept) |> assign(:mobile_pane, :editor)}
    end
  end

  def handle_event("show_list", _params, socket),
    do: {:noreply, assign(socket, :mobile_pane, :list)}

  def handle_event("file_mode", %{"mode" => mode}, %{assigns: %{editor: %{} = ed}} = socket)
      when mode in ~w(edit preview) do
    {:noreply, assign(socket, :editor, %{ed | mode: String.to_existing_atom(mode)})}
  end

  def handle_event(
        "file_change",
        %{"file" => %{"content" => content}},
        %{assigns: %{editor: %{} = ed}} = socket
      ) do
    {:noreply,
     socket
     |> assign(:editor, %{
       ed
       | draft: content,
         error_line: Edits.parse_error_line(ed.path, content),
         saved?: false,
         failure: nil
     })
     |> assign(:file_form, to_form(%{"content" => content}, as: :file))}
  end

  def handle_event("file_discard", _params, %{assigns: %{editor: %{} = ed}} = socket) do
    {:noreply,
     socket
     |> assign(:editor, %{
       ed
       | draft: ed.original,
         error_line: Edits.parse_error_line(ed.path, ed.original),
         conflict: nil,
         failure: nil
     })
     |> assign(:file_form, to_form(%{"content" => ed.original}, as: :file))}
  end

  def handle_event("file_save", params, %{assigns: %{editor: %{} = ed}} = socket) do
    draft = get_in(params, ["file", "content"]) || ed.draft
    ed = %{ed | draft: draft, error_line: Edits.parse_error_line(ed.path, draft)}

    cond do
      ed.error_line != nil or draft == ed.original ->
        {:noreply, assign(socket, :editor, ed)}

      true ->
        result =
          ConfigFiles.write(
            socket.assigns.actor,
            socket.assigns.agent,
            ed.path,
            draft,
            ed.base_sha
          )

        {:noreply, after_write(socket, ed, result)}
    end
  end

  def handle_event(
        "conflict_compare",
        _params,
        %{assigns: %{editor: %{conflict: %{}} = ed}} = socket
      ) do
    %{actor: actor, agent: agent, info: info} = socket.assigns

    theirs =
      if info.backend == :workspace_store do
        case ConfigFiles.read_disk(actor, agent, ed.path) do
          {:ok, f} -> {:ok, f}
          _ -> ConfigFiles.read(actor, agent, ed.path)
        end
      else
        ConfigFiles.read(actor, agent, ed.path)
      end

    compare =
      case theirs do
        {:ok, %{content: content, sha256: sha}} ->
          %{theirs: content, theirs_sha: sha, yours: ed.draft}

        _ ->
          %{theirs: "", theirs_sha: nil, yours: ed.draft}
      end

    {:noreply, assign(socket, :editor, %{ed | compare: compare})}
  end

  # Start from the machine's version: the editor now holds theirs (and its
  # hash), and yours stays on the right to re-apply by hand.
  def handle_event(
        "compare_take_theirs",
        _params,
        %{assigns: %{editor: %{compare: %{} = c} = ed}} = socket
      ) do
    {:noreply,
     socket
     |> assign(:editor, %{
       ed
       | original: c.theirs,
         draft: c.theirs,
         base_sha: c.theirs_sha,
         conflict: nil,
         mode: :edit,
         error_line: Edits.parse_error_line(ed.path, c.theirs),
         compare: %{c | theirs: nil}
     })
     |> assign(:file_form, to_form(%{"content" => c.theirs}, as: :file))}
  end

  def handle_event("compare_close", _params, %{assigns: %{editor: %{} = ed}} = socket),
    do: {:noreply, assign(socket, :editor, %{ed | compare: nil})}

  def handle_event("open_entry", %{"path" => path}, socket) do
    if Enum.any?(socket.assigns.files, &(&1.path == path)),
      do: {:noreply, socket |> open_file(path) |> assign(:mobile_pane, :editor)},
      else: {:noreply, socket}
  end

  def handle_event("close_entry", _params, socket),
    do: {:noreply, assign(socket, :editor, nil)}

  def handle_event("toggle_new", _params, socket),
    do: {:noreply, assign(socket, :new_open?, not socket.assigns.new_open?)}

  def handle_event("entry_new", %{"entry" => %{"name" => name}}, socket) do
    %{info: info, section: concept, actor: actor, agent: agent} = socket.assigns

    with true <- concept in Edits.entry_concepts(),
         {:ok, path} <- Edits.entry_path(info.adapter, concept, name) do
      name = String.trim(name)

      case ConfigFiles.write(actor, agent, path, Edits.entry_seed(name), nil) do
        {:ok, _} ->
          {:noreply,
           socket
           |> load_files()
           |> stream_entries()
           |> assign(:new_open?, false)
           |> assign(:entry_form, to_form(%{"name" => ""}, as: :entry))
           |> Session.refresh_pending()
           |> open_file(path)}

        {:conflict, _} ->
          {:noreply,
           assign(socket, :notice, {:error, "#{path} already exists. Open it from the list."})}

        {:error, reason} ->
          {:noreply, assign(socket, :notice, {:error, write_failure(reason)})}
      end
    else
      _ ->
        {:noreply,
         assign(
           socket,
           :notice,
           {:error, "Use lowercase letters, digits, - and _ for the name."}
         )}
    end
  end

  def handle_event("entry_delete_ask", %{"path" => path}, socket) do
    case Enum.find(socket.assigns.files, &(&1.path == path)) do
      nil -> {:noreply, socket}
      file -> {:noreply, assign(socket, :pending_delete, %{path: path, sha: file.sha256})}
    end
  end

  def handle_event("entry_delete_cancel", _params, socket),
    do: {:noreply, assign(socket, :pending_delete, nil)}

  def handle_event(
        "entry_delete_confirm",
        _params,
        %{assigns: %{pending_delete: %{} = d}} = socket
      ) do
    case ConfigFiles.delete(socket.assigns.actor, socket.assigns.agent, d.path, d.sha) do
      {:ok, _} ->
        socket =
          socket
          |> assign(:pending_delete, nil)
          |> load_files()
          |> stream_entries()
          |> Session.refresh_pending()

        socket =
          if match?(%{path: p} when p == d.path, socket.assigns.editor),
            do: assign(socket, :editor, nil),
            else: socket

        {:noreply, assign(socket, :notice, {:ok, "Deleted #{d.path}."})}

      {:conflict, _} ->
        {:noreply,
         socket
         |> assign(:pending_delete, nil)
         |> assign(
           :notice,
           {:error, "#{d.path} changed on the machine. Open it and check before deleting."}
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:pending_delete, nil)
         |> assign(:notice, {:error, write_failure(reason)})}
    end
  end

  def handle_event("toggle_raw", _params, socket) do
    %{info: info, section: section} = socket.assigns
    raw? = not socket.assigns.raw?

    path =
      case section do
        :settings -> info.adapter.settings_path()
        :mcp_servers -> Edits.mcp_path(info.adapter)
        _ -> nil
      end

    cond do
      is_nil(path) ->
        {:noreply, socket}

      raw? ->
        {:noreply, socket |> assign(:raw?, true) |> open_file(path)}

      true ->
        {:noreply, socket |> assign(:raw?, false) |> assign(:editor, nil) |> reload_section()}
    end
  end

  def handle_event(
        "settings_save",
        %{"settings" => values},
        %{assigns: %{settings: %{} = st}} = socket
      ) do
    %{info: info, actor: actor, agent: agent} = socket.assigns
    path = info.adapter.settings_path()
    content = (st.file && st.file.content) || ""

    case Edits.put_known(info.adapter, content, values) do
      {:ok, ^content} ->
        {:noreply, socket}

      {:ok, new_content} ->
        case ConfigFiles.write(actor, agent, path, new_content, st.file && st.file.sha256) do
          {:ok, _} ->
            {:noreply,
             socket
             |> load_files()
             |> load_settings()
             |> Session.refresh_pending()
             |> assign(:notice, {:ok, "Saved."})}

          {:conflict, current} ->
            # The raw editor carries the conflict, Compare and Copy my version.
            socket = socket |> assign(:raw?, true) |> open_file(path)
            ed = socket.assigns.editor

            {:noreply,
             socket
             |> assign(:editor, %{
               ed
               | draft: new_content,
                 base_sha: st.file && st.file.sha256,
                 conflict: %{current_sha: current}
             })
             |> assign(:file_form, to_form(%{"content" => new_content}, as: :file))}

          {:error, reason} ->
            {:noreply, assign(socket, :notice, {:error, write_failure(reason)})}
        end

      {:error, _} ->
        {:noreply,
         assign(
           socket,
           :notice,
           {:error, "The settings file doesn't parse. Fix it with Edit raw first."}
         )}
    end
  end

  def handle_event(
        "secret_set",
        %{"path" => path, "pointer" => pointer, "secret" => value},
        socket
      ) do
    %{actor: actor, agent: agent} = socket.assigns

    notice =
      case ConfigFiles.set_secret(actor, agent, path, pointer, value) do
        {:ok, _} -> {:ok, "Replaced #{pointer |> String.split("/") |> List.last()}."}
        {:conflict, _} -> {:error, "#{path} changed on the machine. Reload and try again."}
        {:error, reason} -> {:error, write_failure(reason)}
      end

    {:noreply,
     socket
     |> assign(:notice, notice)
     |> assign(:secret_nonce, socket.assigns.secret_nonce + 1)
     |> load_files()
     |> Session.refresh_pending()
     |> reload_section()}
  end

  def handle_event("mcp_add", %{"mcp" => attrs}, socket) do
    %{info: info, actor: actor, agent: agent} = socket.assigns

    paths =
      Enum.reject([Edits.mcp_path(info.adapter), Edits.approval_path(info.adapter)], &is_nil/1)

    current = Map.new(paths, fn p -> {p, read_or_nil(socket, p)} end)
    contents = Map.new(current, fn {p, f} -> {p, f && f.content} end)

    case Edits.add_mcp_server(info.adapter, contents, attrs) do
      {:ok, writes} ->
        results =
          Enum.map(writes, fn {path, content} ->
            ConfigFiles.write(actor, agent, path, content, current[path] && current[path].sha256)
          end)

        notice =
          if Enum.all?(results, &match?({:ok, _}, &1)),
            do: {:ok, "Added #{String.trim(attrs["name"])}. It loads on the next session."},
            else: {:error, "Not added: a file changed on the machine. Reload and try again."}

        {:noreply,
         socket
         |> load_files()
         |> Session.refresh_pending()
         |> assign(:new_open?, false)
         |> assign(
           :mcp_form,
           to_form(%{"name" => "", "command" => "", "args" => "", "url" => ""}, as: :mcp)
         )
         |> reload_section()
         |> assign(:notice, notice)}

      {:error, reason} ->
        {:noreply, assign(socket, :notice, {:error, mcp_failure(reason)})}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp reload_section(%{assigns: %{section: :settings}} = socket), do: load_settings(socket)

  defp reload_section(%{assigns: %{section: :mcp_servers}} = socket),
    do: stream(socket, :servers, socket.assigns.mcp_servers, reset: true)

  defp reload_section(%{assigns: %{section: s}} = socket)
       when s in [:skills, :subagents, :commands],
       do: stream_entries(socket)

  defp reload_section(socket), do: socket

  defp after_write(socket, ed, {:ok, sha}) do
    socket
    |> assign(:editor, %{
      ed
      | original: ed.draft,
        base_sha: sha,
        conflict: nil,
        compare: nil,
        failure: nil,
        saved?: true
    })
    |> load_files()
    |> reload_section_after_save()
    |> Session.refresh_pending()
  end

  defp after_write(socket, ed, {:conflict, current}),
    do: assign(socket, :editor, %{ed | conflict: %{current_sha: current}, failure: nil})

  defp after_write(socket, ed, {:error, reason}),
    do: assign(socket, :editor, %{ed | failure: write_failure(reason)})

  defp reload_section_after_save(%{assigns: %{section: s}} = socket)
       when s in [:skills, :subagents, :commands],
       do: stream_entries(socket)

  defp reload_section_after_save(socket), do: socket

  defp write_failure(:forbidden), do: "Only the agent's owner can change its configuration."
  defp write_failure(:host_offline), do: "The agent's machine did not answer. Nothing was saved."
  defp write_failure(:secret_path), do: "Secret files are changed one value at a time."

  defp write_failure(:unresolved_redaction),
    do: "A hidden value has nothing to keep. Replace it on its own row."

  defp write_failure(:invalid_value),
    do: "That value can't be used (empty, too long, or several lines)."

  defp write_failure(:unsupported), do: "This agent can't do that yet."
  defp write_failure(_), do: "Not saved. Try again in a moment."

  defp mcp_failure(:invalid_name), do: "Use lowercase letters, digits, - and _ for the name."
  defp mcp_failure(:name_taken), do: "A server with that name already exists."
  defp mcp_failure(:command_or_url), do: "Give a command to run, or a URL."
  defp mcp_failure(_), do: "The MCP file doesn't parse. Fix it with Edit raw first."

  @impl true
  def handle_async(:session_restart, result, socket), do: Session.handle_async(result, socket)

  @impl true
  def handle_info(msg, socket) do
    case Session.handle_info(msg, socket) do
      :unhandled -> {:noreply, socket}
      reply -> reply
    end
  end

  # ── render ─────────────────────────────────────────────────────────

  defp harness_name(harness), do: Map.get(@harness_names, harness, harness)

  defp dirty?(%{draft: d, original: o}), do: d != o
  defp dirty?(_), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} embedded={true}>
      <div
        id="agent-config"
        class="clears-tab-bar flex h-full min-h-0 flex-col bg-base-200 text-base-content"
        phx-hook="ViewportBreakpoint"
        data-breakpoint="768"
        data-event="viewport"
      >
        <header
          id="agent-config-header"
          class="flex items-center gap-3 border-b border-edge bg-base-200 px-4 py-3"
        >
          <.link
            navigate={~p"/control/#{@agent.slug}"}
            id="agent-config-back"
            class="btn btn-ghost btn-sm btn-square"
            aria-label="Back to the agent"
          >
            <.icon name="hero-arrow-left" class="size-5" />
          </.link>
          <h1 class="min-w-0 truncate text-xl font-semibold text-base-content">
            {@agent.name}<span :if={@info}> · {harness_name(@info.harness)}</span>
          </h1>
        </header>

        <p
          :if={@unavailable}
          id={"agent-config-#{elem(@unavailable, 0)}"}
          class="px-4 py-6 text-sm text-base-content"
        >
          {elem(@unavailable, 1)}
        </p>

        <SessionStrip.strip
          :if={@session}
          id="session-strip"
          session={@session}
          dirty?={dirty?(@editor)}
        />

        <div :if={is_nil(@unavailable)} class="flex min-h-0 flex-1">
          <nav
            id="config-sections"
            aria-label="Configuration sections"
            class={[
              "w-full shrink-0 overflow-y-auto border-r border-edge bg-base-200 p-2 md:block md:w-64",
              @mobile_pane == :editor && "hidden"
            ]}
          >
            <ul class="flex flex-col gap-1">
              <li :for={s <- @sections}>
                <button
                  id={"section-#{s.id}"}
                  type="button"
                  phx-click="select_section"
                  phx-value-id={s.id}
                  aria-current={if @section == s.id, do: "true"}
                  class={[
                    "flex w-full flex-col items-start rounded-lg px-3 py-2 text-left lg:hover:bg-base-300",
                    @section == s.id && "bg-base-300"
                  ]}
                >
                  <span class="text-sm text-base-content">
                    {s.label}<span :if={s.count}> ({s.count})</span>
                  </span>
                  <span class="font-mono text-xs text-subtle">{s.path}</span>
                </button>
              </li>
            </ul>
          </nav>

          <main
            id="config-pane"
            class={[
              "min-w-0 flex-1 overflow-y-auto bg-base-200 md:block",
              @mobile_pane == :list && "hidden"
            ]}
          >
            <div class="flex items-center gap-2 border-b border-edge px-4 py-2 md:hidden">
              <button
                id="config-show-list"
                type="button"
                phx-click="show_list"
                class="btn btn-ghost btn-sm"
              >
                <.icon name="hero-chevron-left" class="size-4" /> Sections
              </button>
            </div>

            <div class="flex flex-col gap-4 p-4">
              <p
                :if={@notice}
                id="config-notice"
                class={["flex items-center gap-2 text-sm", elem(@notice, 0) == :error && "text-error"]}
              >
                <span
                  :if={elem(@notice, 0) == :error}
                  class="inline-block size-2 shrink-0 rounded-full bg-error"
                  aria-hidden="true"
                >
                </span>
                {elem(@notice, 1)}
              </p>

              <.entries_list
                :if={@section in Edits.entry_concepts()}
                streams={@streams}
                section={@section}
                path_hint={Edits.path_hint(@info.adapter, @section)}
                new_open?={@new_open?}
                entry_form={@entry_form}
                delete?={@info.delete?}
                pending_delete={@pending_delete}
              />

              <.settings_panel
                :if={@section == :settings and not @raw?}
                adapter={@info.adapter}
                form={@settings_form}
                streams={@streams}
                has_secrets?={@has_secrets?}
                nonce={@secret_nonce}
              />

              <.mcp_panel
                :if={@section == :mcp_servers and not @raw?}
                adapter={@info.adapter}
                streams={@streams}
                new_open?={@new_open?}
                form={@mcp_form}
                nonce={@secret_nonce}
              />

              <button
                :if={@section in [:settings, :mcp_servers]}
                id="config-toggle-raw"
                type="button"
                phx-click="toggle_raw"
                class="btn btn-ghost btn-sm self-start border border-edge"
              >
                {if @raw?, do: "Back to the form", else: "Edit raw"}
              </button>

              <.editor :if={@editor} editor={@editor} form={@file_form} />
            </div>
          </main>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── editor ─────────────────────────────────────────────────────────

  attr :editor, :map, required: true
  attr :form, :map, required: true

  defp editor(assigns) do
    ed = assigns.editor

    assigns =
      assigns
      |> assign(:ed, ed)
      |> assign(:dirty?, dirty?(ed))
      |> assign(:markdown?, ed.lang == :markdown)

    ~H"""
    <section
      id="config-editor"
      class="flex flex-col gap-3"
      data-path={@ed.path}
      data-dirty={to_string(@dirty?)}
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <span id="config-editor-path" class="font-mono text-xs text-subtle">{@ed.path}</span>
        <div :if={@markdown?} class="join" role="group" aria-label="Edit or preview">
          <button
            id="config-mode-edit"
            type="button"
            phx-click="file_mode"
            phx-value-mode="edit"
            aria-pressed={to_string(@ed.mode == :edit)}
            class={[
              "btn btn-xs join-item border border-subtle",
              if(@ed.mode == :edit, do: "bg-base-300", else: "btn-ghost")
            ]}
          >
            Edit
          </button>
          <button
            id="config-mode-preview"
            type="button"
            phx-click="file_mode"
            phx-value-mode="preview"
            aria-pressed={to_string(@ed.mode == :preview)}
            class={[
              "btn btn-xs join-item border border-subtle",
              if(@ed.mode == :preview, do: "bg-base-300", else: "btn-ghost")
            ]}
          >
            Preview
          </button>
        </div>
      </div>

      <div :if={@ed.conflict} id="config-conflict" class="flex flex-wrap items-center gap-3 text-sm">
        <span class="flex items-center gap-2 text-error">
          <span class="inline-block size-2 shrink-0 rounded-full bg-error" aria-hidden="true"></span>
          Changed on the machine since you opened it
        </span>
        <button
          id="config-compare"
          type="button"
          phx-click="conflict_compare"
          class="btn btn-sm btn-ghost border border-subtle"
        >
          Compare
        </button>
        <button
          id="config-copy-mine"
          type="button"
          phx-hook="CopyToClipboard"
          data-clipboard-text={@ed.draft}
          data-copy-label="Copy my version"
          class="btn btn-sm btn-ghost border border-subtle"
        >
          Copy my version
        </button>
      </div>

      <div :if={@ed.compare} id="config-compare-panes" class="grid gap-3 md:grid-cols-2">
        <div :if={@ed.compare.theirs} class="flex min-w-0 flex-col gap-2">
          <div class="flex items-center justify-between gap-2">
            <span class="text-sm text-base-content">On the machine</span>
            <button
              id="config-take-theirs"
              type="button"
              phx-click="compare_take_theirs"
              class="btn btn-xs btn-ghost border border-subtle"
            >
              Edit on top of this
            </button>
          </div>
          <pre
            id="config-compare-theirs"
            class="min-h-40 overflow-auto whitespace-pre-wrap rounded-lg border border-edge bg-base-100 p-3 font-mono text-[13px]"
          >{@ed.compare.theirs}</pre>
        </div>
        <div class="flex min-w-0 flex-col gap-2">
          <div class="flex items-center justify-between gap-2">
            <span class="text-sm text-base-content">Yours</span>
            <button
              id="config-compare-close"
              type="button"
              phx-click="compare_close"
              class="btn btn-xs btn-ghost"
            >
              Close
            </button>
          </div>
          <pre
            id="config-compare-yours"
            class="min-h-40 overflow-auto whitespace-pre-wrap rounded-lg border border-edge bg-base-100 p-3 font-mono text-[13px]"
          >{@ed.compare.yours}</pre>
        </div>
      </div>

      <.form
        for={@form}
        id="config-file-form"
        phx-change="file_change"
        phx-submit="file_save"
        class="flex flex-col gap-3"
      >
        <div
          :if={@markdown? and @ed.mode == :preview}
          id="config-preview"
          class="prose prose-sm max-w-none rounded-lg border border-edge bg-base-100 p-4 text-sm text-base-content"
        >
          {Phoenix.HTML.raw(ContentRenderer.sanitized_html(@ed.draft))}
        </div>
        <textarea
          id="config-source"
          name={@form[:content].name}
          spellcheck="false"
          class={[
            "min-h-[50vh] w-full resize-y rounded-lg border border-subtle bg-base-100 p-3 font-mono text-[13px] leading-5 text-base-content",
            (@markdown? and @ed.mode == :preview) && "hidden"
          ]}
        >{Phoenix.HTML.Form.normalize_value("textarea", @form[:content].value)}</textarea>

        <p
          :if={@ed.error_line}
          id="config-parse-error"
          class="flex items-center gap-2 text-sm text-error"
        >
          <span class="inline-block size-2 shrink-0 rounded-full bg-error" aria-hidden="true"></span>
          Doesn't parse as {if @ed.lang == :toml, do: "TOML", else: "JSON"}: line {@ed.error_line}
        </p>
        <p
          :if={@ed.failure}
          id="config-save-failure"
          class="flex items-center gap-2 text-sm text-error"
        >
          <span class="inline-block size-2 shrink-0 rounded-full bg-error" aria-hidden="true"></span>
          {@ed.failure}
        </p>
        <p :if={@ed.saved? and not @dirty?} id="config-saved" class="text-sm text-subtle">Saved.</p>

        <div class="flex justify-end gap-2">
          <button
            :if={@dirty?}
            id="config-discard"
            type="button"
            phx-click="file_discard"
            class="btn btn-sm btn-ghost border border-subtle"
          >
            Discard
          </button>
          <button
            id="config-save"
            type="submit"
            disabled={not @dirty? or not is_nil(@ed.error_line)}
            data-primary={to_string(@dirty? and is_nil(@ed.error_line))}
            class={[
              "btn btn-sm",
              if(@dirty?, do: "btn-primary", else: "btn-ghost border border-subtle")
            ]}
          >
            Save
          </button>
        </div>
      </.form>
    </section>
    """
  end

  # ── skills / subagents / commands ──────────────────────────────────

  attr :streams, :map, required: true
  attr :section, :atom, required: true
  attr :path_hint, :string, required: true
  attr :new_open?, :boolean, required: true
  attr :entry_form, :map, required: true
  attr :delete?, :boolean, required: true
  attr :pending_delete, :map, default: nil

  defp entries_list(assigns) do
    ~H"""
    <section id="config-entries" class="flex flex-col gap-3">
      <div class="flex items-center justify-between gap-2">
        <h2 class="text-sm font-semibold text-base-content">{Edits.label(@section)}</h2>
        <button
          id="entry-new-toggle"
          type="button"
          phx-click="toggle_new"
          class="btn btn-sm btn-ghost border border-subtle"
        >
          <.icon name="hero-plus" class="size-4" /> New
        </button>
      </div>

      <.form
        :if={@new_open?}
        for={@entry_form}
        id="entry-new-form"
        phx-submit="entry_new"
        class="flex flex-wrap items-end gap-2"
      >
        <.input field={@entry_form[:name]} label="Name" placeholder="my-skill" autocomplete="off" />
        <button type="submit" class="btn btn-sm btn-ghost border border-subtle">Create</button>
        <span class="w-full font-mono text-xs text-subtle">{@path_hint}&lt;name&gt;</span>
      </.form>

      <ul
        id="config-entry-list"
        phx-update="stream"
        class="flex flex-col divide-y divide-edge rounded-lg border border-edge bg-base-100"
      >
        <li :for={{id, e} <- @streams.entries} id={id} class="flex items-center gap-2 px-3 py-2">
          <button
            type="button"
            phx-click="open_entry"
            phx-value-path={e.path}
            class="flex min-w-0 flex-1 flex-col items-start text-left"
          >
            <span class="text-sm text-base-content">{e.name}</span>
            <span :if={e.description != ""} class="truncate text-xs text-subtle">
              {e.description}
            </span>
          </button>
          <button
            :if={@delete?}
            type="button"
            phx-click="entry_delete_ask"
            phx-value-path={e.path}
            class="btn btn-ghost btn-xs"
            aria-label={"Delete #{e.name}"}
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </li>
      </ul>

      <div
        :if={@pending_delete}
        id="entry-delete-confirm"
        role="alertdialog"
        aria-labelledby="entry-delete-copy"
        class="flex flex-wrap items-center gap-3 rounded-lg border border-edge bg-base-100 p-3 text-sm"
      >
        <p id="entry-delete-copy" class="min-w-0 flex-1">
          Delete <span class="font-mono text-[13px]">{@pending_delete.path}</span>
          from the agent's machine?
        </p>
        <button
          id="entry-delete-cancel"
          type="button"
          phx-click="entry_delete_cancel"
          class="btn btn-sm btn-ghost border border-subtle"
        >
          Cancel
        </button>
        <button
          id="entry-delete-yes"
          type="button"
          phx-click="entry_delete_confirm"
          class="btn btn-sm btn-ghost border border-error text-error"
        >
          Delete
        </button>
      </div>
    </section>
    """
  end

  # ── settings ───────────────────────────────────────────────────────

  attr :adapter, :atom, required: true
  attr :form, :map, required: true
  attr :streams, :map, required: true
  attr :has_secrets?, :boolean, required: true
  attr :nonce, :integer, required: true

  defp settings_panel(assigns) do
    assigns = assign(assigns, :fields, Edits.known_settings(assigns.adapter))

    ~H"""
    <section id="config-settings" class="flex flex-col gap-4">
      <.form
        for={@form}
        id="settings-form"
        phx-submit="settings_save"
        class="flex flex-col gap-3 rounded-lg border border-edge bg-base-100 p-4"
      >
        <div :for={{key, label} <- @fields} class="flex flex-col gap-1">
          <.input field={@form[key]} label={label} autocomplete="off" />
          <span class="font-mono text-xs text-subtle">{key}</span>
        </div>
        <div class="flex justify-end">
          <button id="settings-save" type="submit" class="btn btn-sm btn-ghost border border-subtle">
            Save
          </button>
        </div>
      </.form>

      <div :if={@has_secrets?} class="flex flex-col gap-2">
        <h2 class="text-sm font-semibold text-base-content">Environment</h2>
        <ul
          id="config-secrets"
          phx-update="stream"
          class="flex flex-col divide-y divide-edge rounded-lg border border-edge bg-base-100"
        >
          <li :for={{id, s} <- @streams.secrets} id={id} class="px-3 py-2">
            <.secret_row path={s.path} pointer={s.pointer} name={s.name} nonce={@nonce} />
          </li>
        </ul>
      </div>
    </section>
    """
  end

  # ── MCP servers ────────────────────────────────────────────────────

  attr :adapter, :atom, required: true
  attr :streams, :map, required: true
  attr :new_open?, :boolean, required: true
  attr :form, :map, required: true
  attr :nonce, :integer, required: true

  defp mcp_panel(assigns) do
    assigns = assign(assigns, :mcp_path, Edits.mcp_path(assigns.adapter))

    ~H"""
    <section id="config-mcp" class="flex flex-col gap-3">
      <div class="flex items-center justify-between gap-2">
        <h2 class="text-sm font-semibold text-base-content">MCP servers</h2>
        <button
          id="mcp-new-toggle"
          type="button"
          phx-click="toggle_new"
          class="btn btn-sm btn-ghost border border-subtle"
        >
          <.icon name="hero-plus" class="size-4" /> New
        </button>
      </div>

      <.form
        :if={@new_open?}
        for={@form}
        id="mcp-new-form"
        phx-submit="mcp_add"
        class="grid gap-2 rounded-lg border border-edge bg-base-100 p-3 md:grid-cols-2"
      >
        <.input field={@form[:name]} label="Name" autocomplete="off" />
        <.input field={@form[:command]} label="Command to run" autocomplete="off" />
        <.input field={@form[:args]} label="Arguments" autocomplete="off" />
        <.input field={@form[:url]} label="Or a URL" autocomplete="off" />
        <div class="flex justify-end md:col-span-2">
          <button type="submit" class="btn btn-sm btn-ghost border border-subtle">Add</button>
        </div>
      </.form>

      <ul id="config-servers" phx-update="stream" class="flex flex-col gap-3">
        <li
          :for={{id, s} <- @streams.servers}
          id={id}
          class="rounded-lg border border-edge bg-base-100 p-3"
        >
          <p class="text-sm font-semibold text-base-content">{s.name}</p>
          <p class="break-all font-mono text-xs text-subtle">
            {if s.transport == :http, do: s.url, else: Enum.join([s.command | s.args], " ")}
          </p>
          <ul
            :if={s.env_names != [] or s.header_names != []}
            class="mt-2 flex flex-col divide-y divide-edge"
          >
            <li :for={sec <- Edits.server_secrets(@adapter, s)} class="py-2">
              <.secret_row path={@mcp_path} pointer={sec.pointer} name={sec.name} nonce={@nonce} />
            </li>
          </ul>
        </li>
      </ul>
    </section>
    """
  end

  attr :path, :string, required: true
  attr :pointer, :string, required: true
  attr :name, :string, required: true
  attr :nonce, :integer, required: true

  # Write-only: the field is named "secret" so `:filter_parameters` keeps a typed
  # value out of the debug "HANDLE EVENT" log. It is always empty, there is no reveal and no copy.
  defp secret_row(assigns) do
    assigns =
      assign(assigns, :dom, dom_safe("#{assigns.path}-#{assigns.pointer}-#{assigns.nonce}"))

    ~H"""
    <form
      id={"secret-form-#{@dom}"}
      phx-submit="secret_set"
      class="flex flex-wrap items-center gap-2"
      data-secret-row={@name}
    >
      <span class="font-mono text-[13px] text-base-content">{@name}</span>
      <span class="text-xs text-subtle">value hidden</span>
      <input type="hidden" name="path" value={@path} />
      <input type="hidden" name="pointer" value={@pointer} />
      <input
        id={"secret-input-#{@dom}"}
        type="password"
        name="secret"
        autocomplete="off"
        placeholder="New value"
        aria-label={"Replace #{@name}"}
        class="input input-sm ml-auto w-44 border-subtle bg-base-100"
      />
      <button type="submit" class="btn btn-sm btn-ghost border border-subtle">Replace</button>
    </form>
    """
  end
end
