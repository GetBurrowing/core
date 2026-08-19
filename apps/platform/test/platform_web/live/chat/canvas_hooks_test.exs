defmodule PlatformWeb.ChatLive.CanvasHooksTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias PlatformWeb.ChatLive.CanvasHooks

  # Registrations are counted by reading Platform.PubSub's Registry DIRECTLY.
  # Counting through CanvasHooks or a ChatPubSub wrapper would be circular:
  # both are code this stage changes.
  defp registration_count(canvas_id) do
    Platform.PubSub
    |> Registry.lookup(ChatPubSub.canvas_topic(canvas_id))
    |> Enum.count(fn {pid, _} -> pid == self() end)
  end

  defp canvas(id, seconds) do
    %{id: id, title: "Nettlefold Sketchpad", inserted_at: DateTime.from_unix!(seconds)}
  end

  defp socket do
    %Socket{
      assigns: %{
        __changed__: %{},
        canvases: [],
        canvases_by_id: %{},
        active_canvas: nil
      }
    }
  end

  describe "put/2 subscription guard" do
    test "putting the same canvas three times leaves exactly one registration" do
      c = canvas(Ecto.UUID.generate(), 1_700_000_000)
      on_exit(fn -> :ok end)

      s = socket() |> CanvasHooks.put(c) |> CanvasHooks.put(c) |> CanvasHooks.put(c)

      assert length(s.assigns.canvases) == 1
      assert registration_count(c.id) == 1

      # Independent second reading: one broadcast must be delivered once.
      ChatPubSub.broadcast_canvas(c.id, {:canvas_patched, c})
      assert_receive {:canvas_patched, ^c}
      refute_receive {:canvas_patched, ^c}, 100

      ChatPubSub.unsubscribe_canvas(c.id)
    end

    test "a first-sight canvas gets exactly one registration" do
      c = canvas(Ecto.UUID.generate(), 1_700_000_100)

      assert registration_count(c.id) == 0

      s = CanvasHooks.put(socket(), c)

      assert Map.has_key?(s.assigns.canvases_by_id, c.id)
      assert registration_count(c.id) == 1

      ChatPubSub.broadcast_canvas(c.id, {:canvas_patched, c})
      assert_receive {:canvas_patched, ^c}
      refute_receive {:canvas_patched, ^c}, 100

      ChatPubSub.unsubscribe_canvas(c.id)
    end
  end

  describe "remove/2 unsubscribe" do
    test "removed canvas topic no longer reaches the pid while a held canvas still does" do
      removed = canvas(Ecto.UUID.generate(), 1_700_000_200)
      held = canvas(Ecto.UUID.generate(), 1_700_000_300)

      s = socket() |> CanvasHooks.put(removed) |> CanvasHooks.put(held)
      assert registration_count(removed.id) == 1
      assert registration_count(held.id) == 1

      s = CanvasHooks.remove(s, removed)
      refute Map.has_key?(s.assigns.canvases_by_id, removed.id)

      ChatPubSub.broadcast_canvas(removed.id, {:canvas_patched, removed})
      ChatPubSub.broadcast_canvas(held.id, {:canvas_patched, held})

      # Positive control in the same test: the still-held topic DOES arrive,
      # so the absence assertion below cannot pass via a broken broadcast.
      assert_receive {:canvas_patched, ^held}
      refute_receive {:canvas_patched, ^removed}, 100
      assert registration_count(removed.id) == 0

      ChatPubSub.unsubscribe_canvas(held.id)
    end
  end
end
