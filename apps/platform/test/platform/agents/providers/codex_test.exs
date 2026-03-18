defmodule Platform.Agents.Providers.CodexTest do
  use ExUnit.Case, async: true

  alias Platform.Agents.Providers.Codex

  setup do
    {:ok, _} = Application.ensure_all_started(:req)

    Req.Test.stub(:codex_provider_test, fn conn ->
      send(self(), {:codex_request, conn})

      Plug.Conn.send_resp(
        conn,
        200,
        """
        event: response.created
        data: {"type":"response.created","response":{"id":"resp_test","model":"gpt-5.4","status":"in_progress"}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"COD"}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"EX"}

        event: response.output_text.done
        data: {"type":"response.output_text.done","text":"CODEX_OK"}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_test","model":"gpt-5.4","status":"completed","usage":{"input_tokens":12,"output_tokens":5,"total_tokens":17}}}

        data: [DONE]

        """
      )
    end)

    Application.put_env(
      :platform,
      :codex_req_client,
      Req.new(plug: {Req.Test, :codex_provider_test})
    )

    on_exit(fn ->
      Application.delete_env(:platform, :codex_req_client)
    end)

    :ok
  end

  test "uses Codex backend headers and response.create payload shape" do
    token = fake_token("acct_test_123")

    assert {:ok, response} =
             Codex.chat(
               %{"access_token" => token},
               [
                 %{"role" => "user", "content" => "Earlier question"},
                 %{"role" => "assistant", "content" => "Earlier answer"},
                 %{"role" => "user", "content" => "Reply with CODEX_OK"}
               ],
               system: "system prompt"
             )

    assert response.content == "CODEX_OK"
    assert response.model == "gpt-5.4"
    assert response.finish_reason == "completed"
    assert response.usage == %{"input_tokens" => 12, "output_tokens" => 5, "total_tokens" => 17}

    assert_receive {:codex_request, conn}
    headers = Map.new(conn.req_headers)

    assert conn.request_path == "/backend-api/codex/responses"
    assert headers["authorization"] == "Bearer #{token}"
    assert headers["chatgpt-account-id"] == "acct_test_123"
    assert headers["openai-beta"] == "responses=experimental"
    assert headers["originator"] == "pi"
    assert headers["content-type"] == "application/json"
    assert headers["accept"] == "text/event-stream"

    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)

    assert request["model"] == "gpt-5.4"
    assert request["store"] == false
    assert request["stream"] == true
    assert request["instructions"] == "system prompt"

    assert request["input"] == [
             %{
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "Earlier question"}]
             },
             %{
               "type" => "message",
               "role" => "assistant",
               "status" => "completed",
               "id" => request["input"] |> Enum.at(1) |> Map.fetch!("id"),
               "content" => [
                 %{"type" => "output_text", "text" => "Earlier answer", "annotations" => []}
               ]
             },
             %{
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "Reply with CODEX_OK"}]
             }
           ]
  end

  test "returns an error for invalid tokens" do
    assert {:error, :invalid_codex_token} =
             Codex.chat(%{"access_token" => "not-a-jwt"}, [%{"role" => "user", "content" => "hi"}])
  end

  defp fake_token(account_id) do
    header = Base.url_encode64(~s({"alg":"none","typ":"JWT"}), padding: false)

    payload =
      Jason.encode!(%{
        "https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}
      })
      |> Base.url_encode64(padding: false)

    header <> "." <> payload <> ".signature"
  end
end
