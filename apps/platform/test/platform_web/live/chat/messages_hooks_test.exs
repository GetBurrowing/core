defmodule PlatformWeb.ChatLive.MessagesHooksTest do
  @moduledoc """
  Tests for `PlatformWeb.ChatLive.MessagesHooks`.

  Most stream-mutation helpers here are exercised via the chat LiveView
  integration tests (`PlatformWeb.ChatLiveTest`), which is the
  project's convention for hook code that needs a live socket. The
  tests in this file cover pure-function properties that don't need a
  configured stream — primarily empty-input short-circuits where the
  function must NOT touch the DB.
  """

  use Platform.DataCase, async: false

  alias PlatformWeb.ChatLive.MessagesHooks

  describe "reinsert_stream_messages/2" do
    test "empty list returns socket unchanged without a DB call" do
      # Build a bare socket; if the function tried to hit the DB it would
      # crash with a NoConnectionError in this minimal setup because no
      # SQL Sandbox checkout has been done for the bare socket. So
      # "returns the socket" is itself the no-DB-call assertion.
      socket = %Phoenix.LiveView.Socket{}

      assert MessagesHooks.reinsert_stream_messages(socket, []) == socket
    end
  end
end
