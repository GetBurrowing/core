defmodule Platform.FilesPubSubDuplicateSubscribeTest do
  # WHY THIS FILE EXISTS — it is a guard over a documented contract, not a test
  # of a third-party library.
  #
  # Four sites in this repo used to claim that `Phoenix.PubSub.subscribe/2` is
  # idempotent per pid. It is not: the registry is started with
  # `keys: :duplicate` (deps/phoenix_pubsub/lib/phoenix/pubsub/supervisor.ex)
  # and `subscribe/3` is a bare `Registry.register/3`
  # (deps/phoenix_pubsub/lib/phoenix/pubsub.ex), so a second subscribe from the
  # same process adds a SECOND registration and every later broadcast on that
  # topic is delivered twice. The four corrected sites are:
  #
  #   * lib/platform/files.ex — the `@doc` on `subscribe_project/1`
  #   * lib/platform/agents/meeting_historian_handler.ex — `init/1`
  #   * lib/platform/meetings/meeting_notifier.ex — moduledoc
  #   * lib/platform/meetings/meeting_notifier.ex — `init/1`
  #
  # If this file reds, do not relax it: something either restored the false
  # idempotence claim, or a dependency upgrade changed the registry's `keys:`
  # mode — in which case the guard subscriptions those four sites describe
  # (`maybe_subscribe_project/2`'s MapSet check, FilesLive's
  # `:subscribed_project_id`) need re-reading before the docs are rewritten.
  #
  # The double-delivery case is the property. The single-subscribe control
  # below is what makes it non-vacuous: without it, two `assert_receive`s
  # cannot distinguish "two registrations" from "the harness delivers twice".
  use ExUnit.Case, async: true

  alias Platform.Files

  # Invented per-test id: `core` is public, and a fresh UUID also isolates the
  # topic from any concurrently running test.
  setup do
    %{project_id: Ecto.UUID.generate()}
  end

  test "two subscribes from one pid receive one broadcast twice", %{project_id: project_id} do
    :ok = Files.subscribe_project(project_id)
    :ok = Files.subscribe_project(project_id)

    # Registration count read directly off the registry, NOT inferred from
    # subscribe_project/1's own return value.
    assert length(Registry.lookup(Platform.PubSub, Files.project_topic(project_id))) == 2

    :ok = Files.broadcast_project(project_id, {:file_ingested, "file-1"})

    assert_receive {:file_ingested, "file-1"}, 500
    assert_receive {:file_ingested, "file-1"}, 500
    refute_receive {:file_ingested, "file-1"}, 200
  end

  test "control: one subscribe from one pid receives one broadcast once", %{
    project_id: project_id
  } do
    :ok = Files.subscribe_project(project_id)

    assert length(Registry.lookup(Platform.PubSub, Files.project_topic(project_id))) == 1

    :ok = Files.broadcast_project(project_id, {:file_ingested, "file-1"})

    assert_receive {:file_ingested, "file-1"}, 500
    refute_receive {:file_ingested, "file-1"}, 200
  end
end
