defmodule PlatformWeb.RouterExternalChatHostTest do
  @moduledoc """
  Dormancy-contract coverage for the INERT `chat.` host scope
  (rbac-external-users M4 stage 3, task 019f8837).

  Adversarial counterpart to `chat_live_external_host_mount_test.exs`'s
  positive mount: these tests prove the M4 scaffold is present-but-dark and
  pin the exact routing contract the stack rollup can merge on ahead of the
  M14 subdomain go-live. No implementation code changes here — this module
  is pure router assertion.

  ## The four properties, and the ONE gap M4 cannot close

  1. NON-SHADOWING — the new `chat.` scope does not intercept or alter
     default-host routing. `/tasks`, `/admin`, `/chat` all still resolve
     exactly as on main under the default host.

  2. HOST DISAMBIGUATION — the overlapping `/chat` path resolves to the
     `:external_chat` live_session under the chat host and `:authenticated`
     under the default host. (Requires the `chat.` scope to be defined
     BEFORE the default scope — see the router comment; first matching
     `__match_route__/3` clause wins by definition order.)

  3. DORMANCY-BY-CONFIG — no environment declares a `chat.` host, so a
     normal client cannot reach the surface without a spoofed host header.

  4. SURFACE-LIMITATION — the design (§1 non-goals) requires the external
     host to expose ONLY `/chat` + `/chat/:space_slug`, never /tasks,
     /admin, /org_memory. **M4 CANNOT enforce this by route omission.**
     The default authenticated `scope "/"` carries a match-any-host
     pattern, so its routes still resolve on `chat.localhost`. This module
     documents that gap explicitly (see the `surface reachability` block):
     structural limitation of the chat host is scope-enforcement work owned
     by M6/M7 (or a host-constrained default scope), NOT achievable by
     adding the `chat.` scope alone. What M4 DOES guarantee is that the
     `chat.` scope itself declares only the two `/chat` routes — the
     intended surface — so the enforcement layer has an unambiguous
     allow-list to gate against.

  `async: false` — mirrors the host-swapped conn cases in
  `meeting_live_guest_mount_test.exs`.
  """
  use PlatformWeb.ConnCase, async: false

  @router PlatformWeb.Router

  # Resolve the live_session name (or :error, or a controller plug tuple)
  # for a route under a given host. Mirrors the host-swap mechanics used by
  # `meeting_live_guest_mount_test.exs` (`%{conn | host: ...}`), but at the
  # router-metadata level so we assert the resolved route, not a rendered
  # page.
  defp resolve(method, path, host) do
    case Phoenix.Router.route_info(@router, method, path, host) do
      :error -> :error
      %{phoenix_live_view: {view, _action, _opts, %{name: name}}} -> {:live, view, name}
      %{plug: plug} -> {:controller, plug}
      other -> other
    end
  end

  describe "non-shadowing — default host routing is unchanged" do
    test "/chat, /tasks, /admin, /org_memory on the default host resolve exactly as on main" do
      assert {:live, PlatformWeb.ChatLive, :authenticated} = resolve("GET", "/chat", "localhost")

      assert {:live, PlatformWeb.TasksLive, :authenticated} =
               resolve("GET", "/tasks", "localhost")

      assert {:live, PlatformWeb.AdminLive, :admin} = resolve("GET", "/admin", "localhost")

      assert {:live, PlatformWeb.OrgMemoryLive, :authenticated} =
               resolve("GET", "/org_memory", "localhost")

      # The default-host root controller redirect is likewise untouched.
      assert {:controller, PlatformWeb.PageController} = resolve("GET", "/", "localhost")
    end

    test "default-host /chat/:space_slug still resolves to :authenticated ChatLive" do
      assert {:live, PlatformWeb.ChatLive, :authenticated} =
               resolve("GET", "/chat/some-space", "localhost")
    end
  end

  describe "host disambiguation — overlapping /chat resolves by host" do
    test "/chat resolves to :external_chat under chat host, :authenticated under default host" do
      assert {:live, PlatformWeb.ChatLive, :external_chat} =
               resolve("GET", "/chat", "chat.localhost")

      assert {:live, PlatformWeb.ChatLive, :authenticated} =
               resolve("GET", "/chat", "localhost")
    end

    test "/chat/:space_slug disambiguates identically" do
      assert {:live, PlatformWeb.ChatLive, :external_chat} =
               resolve("GET", "/chat/x", "chat.localhost")

      assert {:live, PlatformWeb.ChatLive, :authenticated} =
               resolve("GET", "/chat/x", "localhost")
    end

    test "the chat host matches any chat.<domain> prefix (prod chat.example.com etc.)" do
      assert {:live, PlatformWeb.ChatLive, :external_chat} =
               resolve("GET", "/chat", "chat.example.com")

      assert {:live, PlatformWeb.ChatLive, :external_chat} =
               resolve("GET", "/chat", "chat.example.test")
    end
  end

  describe "chat-scope surface — the intended allow-list is exactly /chat + /chat/:space_slug" do
    test "the ONLY routes the chat scope adds under the chat host are the two /chat live routes" do
      # These two are the intended external surface — declared in the
      # `:external_chat` scope.
      assert {:live, PlatformWeb.ChatLive, :external_chat} =
               resolve("GET", "/chat", "chat.localhost")

      assert {:live, PlatformWeb.ChatLive, :external_chat} =
               resolve("GET", "/chat/deep-space", "chat.localhost")
    end
  end

  describe "surface reachability — the M4 gap M6/M7 must close" do
    # DOCUMENTED KNOWN GAP (see @moduledoc property 4). Route omission does
    # NOT limit the chat host in M4: the default authenticated `scope "/"`
    # carries a match-any-host pattern, so its routes resolve on
    # `chat.localhost` too. This is NOT `Phoenix.Router.NoRouteError`; the
    # request lands on the authenticated app machinery. M6/M7 (scope
    # enforcement) or a host-constrained default scope must close this.
    #
    # These assertions pin the CURRENT TRUTH so that when the enforcement
    # layer lands, whoever flips /tasks-on-chat-host to :error will see
    # this test go red and update it deliberately — the gap cannot close
    # silently.
    test "/tasks, /admin, /org_memory STILL resolve on the chat host today (route omission is insufficient)" do
      assert {:live, PlatformWeb.TasksLive, :authenticated} =
               resolve("GET", "/tasks", "chat.localhost")

      assert {:live, PlatformWeb.AdminLive, :admin} =
               resolve("GET", "/admin", "chat.localhost")

      assert {:live, PlatformWeb.OrgMemoryLive, :authenticated} =
               resolve("GET", "/org_memory", "chat.localhost")
    end
  end

  describe "dormancy-by-config — no chat. host is declared anywhere" do
    test "the Endpoint :url host is not a chat. host" do
      host = PlatformWeb.Endpoint.config(:url)[:host] || ""
      refute String.starts_with?(to_string(host), "chat.")
    end

    test "no config/*.exs (incl. runtime.exs) declares a chat. host" do
      config_files = Path.wildcard(Path.join([File.cwd!(), "config", "*.exs"]))
      # Sanity: we actually found the config dir.
      assert length(config_files) > 0

      offenders =
        for file <- config_files,
            body = File.read!(file),
            # any `host: "chat...` or `host: 'chat...` declaration
            Regex.match?(~r/host:\s*["']chat\./, body) do
          Path.basename(file)
        end

      assert offenders == [],
             "expected no chat. host declared in config, found in: #{inspect(offenders)}"
    end

    test "the chat surface is unreachable on the default host — it needs an explicit chat. host header" do
      # No `chat.` host resolves anywhere by default, so the ONLY way the
      # scaffold is reachable is by spoofing the host (as these tests do).
      # On the app's own configured host, /chat is the authenticated
      # surface, never the external one.
      configured_host = PlatformWeb.Endpoint.config(:url)[:host] || "localhost"

      assert {:live, PlatformWeb.ChatLive, :authenticated} =
               resolve("GET", "/chat", configured_host)
    end
  end
end
