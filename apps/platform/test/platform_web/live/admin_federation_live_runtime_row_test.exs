defmodule PlatformWeb.AdminFederationLiveRuntimeRowTest do
  @moduledoc """
  The `/admin/federation` runtime row (task 01a06d01 stage 4).

  Stages 1-3 collected the build, the process start time and the observed
  capability proofs, and taught `federation_status/0` to report them. This is
  the surface a human actually reads, so these tests pin the three statements
  the design canvas says the row must be able to make at once:

    * the socket is up (`Online`),
    * the process is running code of some named age (`Build`),
    * core has or has NOT observed a given capability (`Last proven`).

  The originating incident is the anti-vacuity brief for the whole file: an
  agent showed a green dot all evening and could not hear a meeting, because
  its process predated the plugin's `meeting_transcript` listener. Nothing on
  any surface said so, and two people spent an hour on the wrong layer.
  `transcript / never` beside a green dot is the row that ends that in ten
  seconds — so every assertion here is about a cell EXISTING and carrying a
  particular word, not about the page containing a substring somewhere.

  `async: false`: `RuntimePresence` is a node-global named Agent, not
  sandboxed per test.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  setup do
    on_exit(fn -> Agent.update(RuntimePresence, fn _ -> %{} end) end)
    :ok
  end

  defp admin_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "fed-row-admin-#{n}@example.com",
        name: "Federation Row Admin #{n}",
        oidc_sub: "oidc-fed-row-admin-#{n}"
      })

    Repo.insert!(%OrgMembership{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: "admin"
    })

    Plug.Test.init_test_session(conn, %{"current_user_id" => user.id})
  end

  # An ACTIVE runtime — `federation_status/0` only reports active rows —
  # carrying whatever `client_info` the stage-1 handshake would have
  # persisted. `client_info: nil` means "this client never told us anything",
  # which is the honest state of every runtime on a build older than stage 1.
  defp active_runtime!(prefix, client_info \\ nil) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "fed-row-#{n}@example.com",
        name: "Federation Row User #{n}",
        oidc_sub: "oidc-fed-row-#{n}"
      })

    runtime_id = "#{prefix}-#{n}"

    {:ok, runtime} = Federation.register_runtime(user.id, %{runtime_id: runtime_id})
    {:ok, runtime, _token} = Federation.activate_runtime(runtime)

    if client_info do
      {:ok, _} = Federation.update_metadata(runtime, %{"client_info" => client_info})
    end

    runtime_id
  end

  defp row(runtime_id), do: "#runtime-row-#{runtime_id}"

  # Read one element's text out of a render. Uses `LazyHTML.query/2`, which
  # DESCENDS the tree — `filter/2` matches only a fragment's root nodes and
  # would come back `[]` for anything nested, reading as "not there".
  defp text_at(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end

  defp attr_at(html, selector, attribute) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(attribute)
  end

  describe "Last proven reports observed events, and an unobserved one is a word" do
    test "a runtime with no proofs renders the literal `never` in every proof cell", %{conn: conn} do
      # The canvas is explicit: an empty proof cell is information, so it is
      # rendered as `never` — never a blank, never a dash. A surface that
      # omitted unobserved capabilities would restore the exact blind spot
      # this ticket exists to close, and would do it while looking tidier.
      runtime_id = active_runtime!("rt-noproof", %{"build" => "abc1234"})
      RuntimePresence.track(runtime_id)

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/federation")

      for capability <- RuntimePresence.reported_capabilities() do
        assert has_element?(
                 view,
                 ~s|#{row(runtime_id)} [data-proof="#{capability}"] [data-proof-value]|,
                 "never"
               ),
               "#{capability} was not reported as `never` for a runtime that has proven nothing"
      end
    end

    test "a capability core HAS observed stops reading `never` in the same cell", %{conn: conn} do
      # The counterweight to the test above. Without this, a `proof_value/1`
      # hardcoded to "never" would leave the whole file green while making the
      # column say the same thing about every runtime forever — which is
      # indistinguishable from the bug.
      runtime_id = active_runtime!("rt-proven", %{"build" => "abc1234"})
      RuntimePresence.track(runtime_id)
      :ok = RuntimePresence.prove(runtime_id, "chat_reply")

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/federation")

      chat = ~s|#{row(runtime_id)} [data-proof="chat_reply"] [data-proof-value]|
      transcript = ~s|#{row(runtime_id)} [data-proof="meeting_transcript"] [data-proof-value]|

      refute has_element?(view, chat, "never"),
             "a capability core observed this second still reported `never`"

      assert has_element?(view, transcript, "never"),
             "the unobserved capability stopped reading `never` in the same row, so the " <>
               "cell is not reporting per-capability observation at all"

      html = render(view)

      refute text_at(html, chat) == text_at(html, transcript),
             "the proven and unproven capabilities rendered the same value " <>
               "(#{inspect(text_at(html, chat))}) — the cell is not discriminating"
    end

    test "the proven rows sit above a base-300 hairline and the declared claim below it",
         %{conn: conn} do
      # The canvas calls this rule the most load-bearing pixel on the page:
      # everything above it happened, everything below it was asserted by the
      # process whose competence is in question. The declared list is info
      # blue for that reason — a declaration is information, not a promise.
      runtime_id =
        active_runtime!("rt-declared", %{
          "build" => "abc1234",
          "features" => ["system_event_prompt"]
        })

      RuntimePresence.track(runtime_id)

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/federation")

      assert has_element?(view, ~s|#{row(runtime_id)} [data-proof-list] [data-proof-value]|)
      assert has_element?(view, ~s|#{row(runtime_id)} [data-proof-rule].border-edge|)

      assert has_element?(
               view,
               ~s|#{row(runtime_id)} [data-proof-rule] [data-declared].text-info|
             ),
             "the declared claim is not rendered in info blue below the hairline"

      assert has_element?(
               view,
               ~s|#{row(runtime_id)} [data-proof-rule] [data-declared-chip]|,
               "system_event_prompt"
             )
    end
  end

  describe "Build is its own cell and distinguishes two runtimes" do
    test "two runtimes on different builds render different shas in ONE render", %{conn: conn} do
      # The whole ticket, on the page this time. The two values are compared
      # to EACH OTHER rather than to constants: a `build_sha/1` that returned
      # any single hardcoded string would satisfy a pair of equality
      # assertions against literals and still leave the two rows agreeing,
      # which is precisely the surface that cost an hour of misdiagnosis.
      old = active_runtime!("rt-old", %{"build" => "b238164e"})
      new = active_runtime!("rt-new", %{"build" => "63229ebf"})

      RuntimePresence.track(old)
      RuntimePresence.track(new)

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/federation")
      html = render(view)

      old_sha = text_at(html, ~s|#{row(old)} [data-build]|)
      new_sha = text_at(html, ~s|#{row(new)} [data-build]|)

      assert old_sha != ""
      assert new_sha != ""

      refute old_sha == new_sha,
             "two runtimes on different builds rendered the same sha (#{inspect(old_sha)}) — " <>
               "the page cannot tell them apart"

      # Truncated to 7 characters, per the canvas: the sha is the field an
      # operator pastes into an incident note, and it gives up width first.
      assert old_sha == "b238164"
      assert new_sha == "63229eb"
    end

    test "a runtime that never told us its build renders the literal `unknown`", %{conn: conn} do
      # Not a blank, not a dash, and never a borrowed `version`: "unknown" is
      # a positive statement that core asked and was not told, which is a
      # different and reportable fact from any sha.
      runtime_id = active_runtime!("rt-nobuild")
      RuntimePresence.track(runtime_id)

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/federation")

      assert has_element?(view, ~s|#{row(runtime_id)} [data-build]|, "unknown")

      assert attr_at(render(view), ~s|#{row(runtime_id)} [data-build]|, "data-build") ==
               ["unknown"]
    end

    test "build age is adjacent to connection age, so the row can say both", %{conn: conn} do
      # "connected 20 seconds ago, running for six days" is the sentence
      # nobody could read on the night this ticket was filed. It needs two
      # cells, not one dot.
      runtime_id =
        active_runtime!("rt-ages", %{
          "build" => "b238164e",
          "started_at" => DateTime.utc_now() |> DateTime.add(-6, :day) |> DateTime.to_iso8601()
        })

      RuntimePresence.track(runtime_id)

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/federation")

      assert has_element?(view, ~s|#{row(runtime_id)} [data-build-age]|, "6 days old")
    end
  end

  describe "amber fires on a predated capability and on nothing else" do
    test "a process that started before the capability landed is marked, in warning",
         %{conn: conn} do
      runtime_id =
        active_runtime!("rt-predates", %{
          "build" => "b238164e",
          "started_at" => "2026-08-29T00:00:00Z"
        })

      RuntimePresence.track(runtime_id)

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/federation")

      assert has_element?(
               view,
               ~s|#{row(runtime_id)} [data-build-warning="meeting_transcript"].text-warning|,
               "predates meeting_transcript"
             )
    end

    test "a process started after the capability landed is NOT ambered", %{conn: conn} do
      # The canvas rejected amber-for-behind-main outright: every merge would
      # make the whole fleet amber and the column would be ignored inside a
      # week. This runtime is on the SAME old build as the row above and is
      # still quiet, because the only thing amber claims is "this code cannot
      # be loaded here", which a recent start does not support.
      runtime_id =
        active_runtime!("rt-recent", %{
          "build" => "b238164e",
          "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

      RuntimePresence.track(runtime_id)

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/federation")

      refute has_element?(view, ~s|#{row(runtime_id)} [data-build-warning]|),
             "a runtime whose process postdates every known capability was ambered anyway — " <>
               "the column will be permanently amber and therefore ignored"
    end

    test "nothing on the runtime row uses error colour for staleness", %{conn: conn} do
      # `--color-error` is deliberately unused here. A stale agent is
      # answering, just with old code; restarting it costs its liveness, and
      # red would push an operator toward a bounce more expensive than the
      # condition. The ONLY error on an online row would be the offline badge,
      # which this runtime does not have.
      runtime_id =
        active_runtime!("rt-noerror", %{
          "build" => "b238164e",
          "started_at" => "2026-08-29T00:00:00Z"
        })

      RuntimePresence.track(runtime_id)

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/federation")

      assert has_element?(view, ~s|#{row(runtime_id)} .text-success|),
             "the online runtime lost its success dot"

      refute has_element?(view, ~s|#{row(runtime_id)} .text-error|),
             "an online but stale runtime rendered error colour"
    end
  end

  describe "the column is a log, not a verdict" do
    test "the header reads `Last proven`, never `Capabilities`", %{conn: conn} do
      runtime_id = active_runtime!("rt-header", %{"build" => "abc1234"})
      RuntimePresence.track(runtime_id)

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/federation")

      assert has_element?(view, "table thead th", "Last proven")
      refute has_element?(view, "table thead th", "Capabilities")
    end
  end
end
