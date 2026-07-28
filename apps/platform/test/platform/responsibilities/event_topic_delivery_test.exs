defmodule Platform.Responsibilities.EventTopicDeliveryTest do
  @moduledoc """
  Every `event_topic` responsibility the platform ships must be bound to a
  named delivery path, and every PubSub-delivered one must actually fire when
  its real publisher broadcasts (task 019fa56b-c81f stage 5).

  ## What this file settles

  The ticket asks whether a `has_production_caller?` axis — a compile-time
  census of `fire/2` call sites — belongs in `Reachability.report/0`. It does
  not, for three reasons in increasing severity:

    1. It produces a FALSE POSITIVE on the one key in this family that works.
       `meetings.summarize` is fired from `meetings/summarizer.ex:101` as
       `ResponsibilityRouter.fire(:meetings_summarize, …)` — the atom
       shorthand through `Router`, not the string key through
       `Responsibilities`. A census keyed on `Responsibilities.fire/2` with a
       string literal reports the working key callerless.

    2. It measures the wrong edge. After stage 1 the dominant trigger path for
       all four `meetings.*` keys is a `Phoenix.PubSub` broadcast the Router
       converts into a fire internally — there is no `fire/2` call site at all.

    3. It cannot see the failure that actually happened here. A census would
       have found `broadcast_meeting_finished/2` at
       `livekit_webhook_controller.ex:401` and reported "has a caller —
       healthy". The publisher was never missing. What was missing was
       ENVELOPE AGREEMENT between publisher and subscriber: a property of two
       call sites' data shapes, not of either one's existence.

  So the property worth enforcing is not "has a caller" but "has a publisher
  whose envelope this subscription will actually match" — decidable by RUNNING
  it, not by reading it. `@topic_delivery` below is the honest version of the
  axis: a required, hand-maintained binding from each declared topic to how it
  is delivered, enforced by tests that exercise both sides. An UNMAPPED topic
  FAILS (`test "every declared event_topic topic is classified…"`) rather than
  being skipped, so a new `event_topic` key with no publisher is caught instead
  of silently passing. It cannot be defeated by dynamic dispatch because it
  does not read the caller graph — it runs the publisher.

  ## Restated assertion (correction to the stage plan — read this before editing)

  The stage plan asked for: "assert every `event_topic` spec declares a
  non-empty `event_match`." That assertion is WRONG as written — it fails on 7
  of the 11 rows shipping today, and satisfying it by bolting `event_match`
  onto them would be actively harmful, because `event_match` is what the
  Router routes PubSub deliveries by (`router.ex` `fire_event_match/3`).
  Declaring one on a row nothing broadcasts to would either be inert noise or,
  worse, cross-fire against a real publisher's event name.

    * `security.{cve_scan,deploy_audit,secret_leak,code_audit}` declare the
      sentinel topic `platform.security.sweeper_only`, published by NOTHING by
      design — `Platform.Security.Sweeper` owns those keys through its own
      scanner table (ADR-0043 §Rationale).
    * `architecture.review_plan`, `architecture.audit_diff` and
      `design.task_direction` are fired directly through lifecycle code hooks
      calling `Responsibilities.fire/2`. Their `topic` string is documentation
      for operators inspecting the row, not a live subscription.

  Only the four meetings-family rows are PubSub-delivered, and only those
  declare `event_match`. So the assertion is restated as: **every spec whose
  topic is classified `:pubsub` in `@topic_delivery` declares a non-empty
  `event_match`, and every spec whose topic is not so classified declares
  none.** That keeps the tripwire the plan wanted — a new PubSub-delivered key
  with no `event_match` still fails — without demanding a field from rows that
  are not PubSub-delivered at all, and adds the dual tripwire the blanket
  version would have destroyed: a non-PubSub row that quietly grows an
  `event_match` is now a failure too, because it would start firing off
  somebody else's broadcast.

  ## Why this file is not vacuous

  Each assertion was detonated before being committed:

    * an extra spec on an unclassified topic → the classification test goes red
      naming the topic and key;
    * `event_match` removed from `meetings.action_items` → the restated
      assertion goes red;
    * `meetings.intent_classify`'s `event_match` changed to
      `"meeting_finished"` → the cross-topic uniqueness test goes red;
    * `PubSub.broadcast_meeting_finished/2`'s event atom renamed to
      `:meeting_finished_v2` → the `meeting:finished` end-to-end case goes red
      with an empty mailbox;
    * `broadcast_transcript_chunk/2` made to wrap the payload with one extra
      field → the `meeting:transcript_chunk` end-to-end case goes red on
      payload identity. Those last two are the envelope-drift class no static
      caller census can see at all;
    * the negative control's deliberately-wrong `event_match` set to the real
      one → `refute_receive` goes red, proving the control is not passing
      merely because the assignee wiring never delivers anything.

  The end-to-end cases run against a real database through `DataCase` and
  publish through the REAL publisher rather than a hand-rolled envelope. A
  test that hand-builds `{topic_string, payload}` is exactly the shape that
  was green for months against a Router which delivered nothing (see
  `router_test.exs` "event_topic delivery via the production publisher").
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.{BuiltIns, Router}
  alias Platform.Roles
  alias Platform.Roles.Role

  # ── The topic-to-delivery map ────────────────────────────────────────────
  #
  # EVERY topic declared by an event_topic spec must appear here. Adding a
  # responsibility without adding its topic fails
  # `"every declared event_topic topic is classified in @topic_delivery"`,
  # which is the point: the author is forced to say how the row is delivered.
  #
  #   :pubsub      — a Phoenix.PubSub publisher broadcasts on this topic. Must
  #                  name the publishing MFA and the event atom it puts at the
  #                  head of its message; both are exercised end-to-end below.
  #                  Rows on the topic MUST declare a matching `event_match`.
  #   :sweeper_only — sentinel topic; nothing broadcasts. Keys are owned by
  #                  `Platform.Security.Sweeper`'s scanner table, asserted
  #                  below so a retired scanner cannot leave the key stranded.
  #   :direct_fire — fired by a lifecycle code hook calling
  #                  `Responsibilities.fire/2`. Names the public entry point
  #                  that reaches the fire, asserted exported below so
  #                  renaming the hook out from under the row goes red.
  #
  # `:pubsub` entries assume an arity-2 publisher taking `(room_id, payload)`.
  # A future publisher with a different shape needs a builder here, not a
  # special case in the test body.
  @topic_delivery %{
    "meeting:finished" => %{
      mode: :pubsub,
      publisher: {Platform.Meetings.PubSub, :broadcast_meeting_finished, 2},
      event_match: "meeting_finished",
      payload_keys: [:transcript_id, :room_id, :space_id]
    },
    "meeting:transcript_chunk" => %{
      mode: :pubsub,
      publisher: {Platform.Meetings.PubSub, :broadcast_transcript_chunk, 2},
      event_match: "transcript_chunk",
      payload_keys: [:room_id, :transcript_id, :meeting_id, :segment]
    },
    "platform.security.sweeper_only" => %{
      mode: :sweeper_only,
      owner: Platform.Security.Sweeper
    },
    "plan:submitted" => %{
      mode: :direct_fire,
      entry_point: {Platform.Tasks, :submit_plan_for_review, 1}
    },
    "stage:completed" => %{
      mode: :direct_fire,
      entry_point: {Platform.Tasks.PlanEngine, :evaluate_validation, 2}
    },
    "task:planning_started" => %{
      mode: :direct_fire,
      entry_point: {Platform.Design.PreplanStep, :responsibility_key, 0}
    }
  }

  # ── enumeration ──────────────────────────────────────────────────────────
  #
  # Mirrors `Registry.declared_feature_keys/1` (registry.ex:281-291): walk the
  # shipped providers and read what each module's own `register/0` declares,
  # so the enumeration tracks the code rather than a second hand-kept list.

  defp event_topic_specs do
    for module <- BuiltIns.providers(),
        spec <- safe_register(module),
        fetch(spec, :trigger_kind) == "event_topic" do
      config = fetch(spec, :trigger_config) || %{}

      %{
        module: module,
        key: fetch(spec, :key),
        feature: fetch(spec, :feature),
        topic: fetch(config, :topic),
        event_match: fetch(config, :event_match)
      }
    end
  end

  defp safe_register(module) do
    module.register()
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # `register/0` declares outer keys as atoms and `trigger_config` keys as
  # strings; read both spellings rather than depending on either.
  defp fetch(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp pubsub_topics do
    for {topic, entry} <- @topic_delivery, entry.mode == :pubsub, do: topic
  end

  # ── the map is total ─────────────────────────────────────────────────────

  describe "topic-to-delivery map coverage" do
    test "every declared event_topic topic is classified in @topic_delivery" do
      unclassified =
        event_topic_specs()
        |> Enum.reject(&Map.has_key?(@topic_delivery, &1.topic))
        |> Enum.map(&{&1.key, &1.topic})

      assert unclassified == [],
             """
             event_topic responsibilities declare topics with no entry in
             @topic_delivery (test/platform/responsibilities/event_topic_delivery_test.exs):

             #{Enum.map_join(unclassified, "\n", fn {key, topic} -> "  #{key} → #{inspect(topic)}" end)}

             This is the check that replaces a `has_production_caller?` static
             census. Classify the topic:

               :pubsub       — name the publishing MFA + the event atom it heads
                               its message with; the e2e case below will run it.
               :sweeper_only — nothing broadcasts; a sweeper owns the key.
               :direct_fire  — a lifecycle hook calls Responsibilities.fire/2;
                               name its public entry point.

             If you cannot name any of the three, the responsibility is
             unfireable — which is the bug this task exists to close.
             """
    end

    test "@topic_delivery has no entry for a topic nothing declares" do
      # The dual: a stale entry would silently exempt a topic that no longer
      # exists, and would make the coverage test above pass for the wrong
      # reason if a key were later re-added under that name.
      declared = event_topic_specs() |> Enum.map(& &1.topic) |> MapSet.new()
      stale = Enum.reject(Map.keys(@topic_delivery), &MapSet.member?(declared, &1))

      assert stale == [],
             "@topic_delivery classifies topics no event_topic spec declares: #{inspect(stale)}"
    end

    test "every declared event_topic spec names a topic at all" do
      topicless =
        event_topic_specs() |> Enum.filter(&(&1.topic in [nil, ""])) |> Enum.map(& &1.key)

      assert topicless == [],
             "event_topic rows with no topic (Router.subscribe_event_topics/1 drops them): " <>
               inspect(topicless)
    end
  end

  # ── the restated event_match assertion ───────────────────────────────────

  describe "event_match declaration" do
    test "every PubSub-delivered spec declares a non-empty event_match" do
      missing =
        event_topic_specs()
        |> Enum.filter(&(&1.topic in pubsub_topics()))
        |> Enum.filter(&(&1.event_match in [nil, ""]))
        |> Enum.map(&{&1.key, &1.topic})

      assert missing == [],
             """
             PubSub-delivered event_topic rows with no `event_match`:

             #{Enum.map_join(missing, "\n", fn {key, topic} -> "  #{key} on #{topic}" end)}

             Phoenix.PubSub withholds the topic on delivery, so the Router
             routes these by `trigger_config["event_match"]` — the event atom
             the publisher heads its message with (router.ex fire_event_match/3).
             Without one the row subscribes and never fires, which is the exact
             omission that made task 019fa56b-c81f's bug possible.
             """
    end

    test "PubSub-delivered specs declare the event_match their publisher actually emits" do
      # Binds the declaration to @topic_delivery; the e2e cases below bind
      # @topic_delivery to the publisher. Together those two links make a
      # publisher rename fail here AND there.
      mismatched =
        event_topic_specs()
        |> Enum.filter(&(&1.topic in pubsub_topics()))
        |> Enum.reject(&(&1.event_match == @topic_delivery[&1.topic].event_match))
        |> Enum.map(&{&1.key, &1.event_match, @topic_delivery[&1.topic].event_match})

      assert mismatched == [],
             "event_match disagrees with the publisher's event atom: #{inspect(mismatched)}"
    end

    test "no non-PubSub-delivered spec declares an event_match" do
      # The dual tripwire the plan's blanket "everything declares event_match"
      # assertion would have destroyed. `fire_event_match/3` matches on the
      # event name across every subscribed topic, so an event_match on a row
      # nothing broadcasts to is at best inert and at worst cross-fires off a
      # real publisher's event.
      spurious =
        event_topic_specs()
        |> Enum.reject(&(&1.topic in pubsub_topics()))
        |> Enum.reject(&(&1.event_match in [nil, ""]))
        |> Enum.map(&{&1.key, &1.topic, &1.event_match})

      assert spurious == [],
             """
             Rows classified as non-PubSub-delivered declare an `event_match`:

             #{Enum.map_join(spurious, "\n", fn {k, t, m} -> "  #{k} on #{t} → #{inspect(m)}" end)}

             Either the row IS PubSub-delivered (reclassify its topic :pubsub in
             @topic_delivery and add the e2e binding), or the event_match is a
             mistake — it would fire the row off whatever publisher emits that
             event atom.
             """
    end

    test "event_match values are unique ACROSS distinct topics" do
      # Because PubSub withholds the topic, the Router cannot tell which
      # subscription an atom-headed message arrived through. Same-topic
      # sharing is correct fan-in (three meetings.* rows share
      # `meeting_finished` on `meeting:finished`); cross-topic sharing would
      # make either broadcast fire both families.
      collisions =
        event_topic_specs()
        |> Enum.reject(&(&1.event_match in [nil, ""]))
        |> Enum.group_by(& &1.event_match, & &1.topic)
        |> Enum.map(fn {event_match, topics} -> {event_match, Enum.uniq(topics)} end)
        |> Enum.filter(fn {_event_match, topics} -> length(topics) > 1 end)

      assert collisions == [],
             """
             The same `event_match` is declared on more than one topic:

             #{Enum.map_join(collisions, "\n", fn {m, ts} -> "  #{inspect(m)} → #{inspect(ts)}" end)}

             Phoenix.PubSub does not deliver the topic, so both families would
             fire on either broadcast (router.ex config_event_match/1 documents
             this ambiguity and points here). Same-topic sharing is permitted
             and intended; cross-topic sharing is a declaration bug.
             """
    end
  end

  # ── non-PubSub classifications are held to a real check ──────────────────

  describe "non-PubSub delivery classifications" do
    test ":sweeper_only keys are owned by the Sweeper's scanner table" do
      owner = @topic_delivery["platform.security.sweeper_only"].owner
      scanner_keys = owner.default_scanner_modules() |> Map.keys() |> MapSet.new()

      stranded =
        event_topic_specs()
        |> Enum.filter(&(&1.topic == "platform.security.sweeper_only"))
        |> Enum.reject(&MapSet.member?(scanner_keys, &1.key))
        |> Enum.map(& &1.key)

      assert stranded == [],
             """
             Keys on the sweeper-only sentinel topic that #{inspect(owner)} does
             not own: #{inspect(stranded)}

             Nothing broadcasts on that topic, so the Sweeper's dispatch table
             is the ONLY thing that fires these. Retire a scanner without
             retiring the row and the key black-holes.
             """

      # Anti-vacuity for the exemption itself: the topic must really have rows.
      assert Enum.any?(event_topic_specs(), &(&1.topic == "platform.security.sweeper_only"))
    end

    test ":direct_fire topics name an exported lifecycle entry point" do
      for {topic, %{mode: :direct_fire, entry_point: {module, fun, arity}}} <-
            Enum.filter(@topic_delivery, fn {_t, e} -> e.mode == :direct_fire end) do
        assert Code.ensure_loaded?(module),
               "#{topic} names a firing module that does not load: #{inspect(module)}"

        assert function_exported?(module, fun, arity),
               """
               #{topic} is classified :direct_fire but its named entry point
               #{inspect(module)}.#{fun}/#{arity} is not exported. Nothing
               broadcasts on this topic, so if the lifecycle hook was renamed or
               removed the responsibility is now unfireable.
               """
      end
    end

    test "design.task_direction's key matches the hook that fires it" do
      # PreplanStep exposes its key, so this binding is checkable rather than
      # asserted by comment. Rename the responsibility without updating the
      # hook and this goes red.
      key = Platform.Design.PreplanStep.responsibility_key()

      assert Enum.any?(
               event_topic_specs(),
               &(&1.key == key and &1.topic == "task:planning_started")
             )
    end
  end

  # ── end-to-end: the real publisher fires the real subscription ───────────
  #
  # One generated case per :pubsub topic. Publishing through the REAL publisher
  # (never a hand-rolled envelope) is what makes these break if a publisher's
  # shape drifts — the failure mode this whole task exists to close was
  # envelope disagreement, invisible to any static census.

  describe "end-to-end delivery through the production publisher" do
    setup do
      Logger.put_module_level(Platform.Responsibilities.Router, :info)
      {:ok, _} = Application.ensure_all_started(:req)

      Application.put_env(
        :platform,
        :external_agents_dispatcher_req_client,
        Req.new(plug: {Req.Test, :event_topic_delivery_test})
      )

      on_exit(fn ->
        Logger.delete_module_level(Platform.Responsibilities.Router)
        Application.delete_env(:platform, :external_agents_dispatcher_req_client)
      end)

      :ok
    end

    for {topic, entry} <- @topic_delivery, entry.mode == :pubsub do
      {publisher_module, publisher_fun, publisher_arity} = entry.publisher

      @topic topic
      @entry entry
      @publisher_module publisher_module
      @publisher_fun publisher_fun
      @publisher_arity publisher_arity

      test "#{inspect(@publisher_module)}.#{@publisher_fun}/#{@publisher_arity} fires #{@topic} with the payload intact" do
        # `ensure_loaded?` first: `function_exported?/3` answers false for a
        # module that simply has not been loaded yet in a lazily-loading test
        # VM, which would fail for a reason that has nothing to do with the
        # publisher's existence.
        assert Code.ensure_loaded?(@publisher_module),
               "#{@topic}'s declared publisher module #{inspect(@publisher_module)} does not load."

        assert function_exported?(@publisher_module, @publisher_fun, @publisher_arity),
               "#{@topic}'s declared publisher " <>
                 "#{inspect(@publisher_module)}.#{@publisher_fun}/#{@publisher_arity} " <>
                 "is not exported — nothing can deliver this topic."

        assert @publisher_arity == 2,
               "@topic_delivery's e2e case assumes an arity-2 (room_id, payload) publisher; " <>
                 "#{@topic} needs an explicit arg builder."

        feature = "evt_delivery_#{System.unique_integer([:positive])}"
        key = "#{feature}.probe_#{System.unique_integer([:positive])}"
        test_pid = self()

        define_provider(
          feature,
          quote do
            @behaviour Platform.Responsibilities.Provider

            @impl true
            def register, do: []

            @impl true
            def gather_context(responsibility, meta) do
              send(unquote(test_pid), {:fired, responsibility.key, meta})
              {:ok, %{}}
            end

            @impl true
            def handle_output(_r, _o), do: :ok

            @impl true
            def handle_output(_r, _o, _m), do: :ok
          end
        )

        insert!(%{
          key: key,
          feature: feature,
          trigger_kind: "event_topic",
          trigger_config: %{"topic" => @topic, "event_match" => @entry.event_match}
        })

        wire_external_assignee(key)

        Req.Test.stub(:event_topic_delivery_test, fn conn ->
          Req.Test.json(conn, %{
            "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]
          })
        end)

        {router_pid, _name} = start_router()
        Req.Test.allow(:event_topic_delivery_test, self(), router_pid)

        room_id = "room-#{System.unique_integer([:positive])}"

        payload =
          Map.new(@entry.payload_keys, fn field ->
            {field, "#{field}-#{System.unique_integer([:positive])}"}
          end)

        :ok = apply(@publisher_module, @publisher_fun, [room_id, payload])

        assert_receive {:fired, ^key, meta}, 2_000

        assert meta.kind == :event_topic
        assert meta.topic == @topic

        # Payload IDENTITY, not merely "a payload arrived": the publisher must
        # hand the subscriber exactly what it was given. A publisher that
        # started wrapping, renaming, or dropping fields fails here.
        assert meta.payload == payload
      end
    end

    test "a row whose event_match does not match the publisher's event never fires" do
      # Negative control for the whole mechanism: without it, a Router that
      # fired every event_topic row on every atom-headed message would pass
      # every positive case above.
      feature = "evt_delivery_neg_#{System.unique_integer([:positive])}"
      key = "#{feature}.probe_#{System.unique_integer([:positive])}"
      test_pid = self()

      define_provider(
        feature,
        quote do
          @behaviour Platform.Responsibilities.Provider

          @impl true
          def register, do: []

          @impl true
          def gather_context(responsibility, meta) do
            send(unquote(test_pid), {:fired, responsibility.key, meta})
            {:ok, %{}}
          end

          @impl true
          def handle_output(_r, _o), do: :ok

          @impl true
          def handle_output(_r, _o, _m), do: :ok
        end
      )

      insert!(%{
        key: key,
        feature: feature,
        trigger_kind: "event_topic",
        trigger_config: %{
          "topic" => "meeting:finished",
          "event_match" => "meeting_finished_but_not_really"
        }
      })

      wire_external_assignee(key)
      {_pid, _name} = start_router()

      :ok =
        Platform.Meetings.PubSub.broadcast_meeting_finished("room-neg", %{
          transcript_id: "t-neg"
        })

      refute_receive {:fired, ^key, _meta}, 300
    end
  end

  # ── fixtures ─────────────────────────────────────────────────────────────

  defp insert!(overrides) do
    attrs =
      Map.merge(
        %{
          key: "evtdelivery.verb_#{System.unique_integer([:positive])}",
          feature: "evtdelivery",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"},
          scope: "global",
          context_provided: [],
          output_contract: %{"summary" => "string"},
          default_prompt_template: "evtdelivery.v1",
          cost_profile: "low_freq_capable"
        },
        overrides
      )

    {:ok, row} = Responsibilities.create_responsibility(attrs)
    row
  end

  defp start_router(opts \\ []) do
    name = Module.concat([Router, "EvtInst#{System.unique_integer([:positive])}"])
    pid = start_supervised!({Router, Keyword.put(opts, :name, name)})
    # DataCase's sandbox owns the connection on the test pid; the Router reads
    # Repo on its own process during dispatch.
    :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    {pid, name}
  end

  # Register a throwaway provider through the documented override seam (the
  # Router resolves providers through `Providers.feature_provider/1`, not by
  # deriving a module name from `feature`).
  defp define_provider(feature, body) do
    provider_name =
      Module.concat([
        Platform.Responsibilities.Providers,
        "EvtDelivery#{System.unique_integer([:positive])}"
      ])

    Module.create(provider_name, body, Macro.Env.location(__ENV__))

    current = Application.get_env(:platform, :responsibility_provider_overrides, %{})

    Application.put_env(
      :platform,
      :responsibility_provider_overrides,
      Map.put(current, feature, provider_name)
    )

    on_exit(fn ->
      remaining = Application.get_env(:platform, :responsibility_provider_overrides, %{})

      Application.put_env(
        :platform,
        :responsibility_provider_overrides,
        Map.delete(remaining, feature)
      )
    end)

    provider_name
  end

  # An assignee must exist for the fire to reach `gather_context/2` — an
  # unfilled row stops at the `{:ok, :unfilled}` arm, which would make the
  # payload-identity assertion unreachable.
  defp wire_external_assignee(responsibility_key) do
    role_key = "historian"

    Repo.insert!(
      %Role{key: role_key, name: "Historian", description: "test", icon: "hero-star"},
      on_conflict: :nothing,
      conflict_target: :key
    )

    %Platform.Roles.RoleResponsibility{}
    |> Platform.Roles.RoleResponsibility.changeset(%{
      role_key: role_key,
      responsibility_key: responsibility_key
    })
    |> Repo.insert!()

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "evt-delivery-ext-#{System.unique_integer([:positive])}",
        name: "Event Delivery External",
        status: "active",
        kind: "external",
        endpoint_kind: "openai_compat",
        base_url: "https://api.example.test",
        model: "test-model",
        workspace_id: nil
      })
      |> Repo.insert!()

    :ok = Platform.ExternalAgents.EphemeralCredentials.put(agent.id, "sk-evt-delivery-test")
    on_exit(fn -> Platform.ExternalAgents.EphemeralCredentials.delete(agent.id) end)

    {:ok, _} = Roles.assign_role(role_key, agent.id)

    agent
  end
end
