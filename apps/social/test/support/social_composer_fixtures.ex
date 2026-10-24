defmodule Platform.SocialComposerFixtures do
  @moduledoc """
  The composer's model seam for tests (Social authoring 6/11, task
  01a16c50). No real LLM traffic: the drafting agent's provider is the
  Anthropic module with `:anthropic_req_client` pointed at a `Req.Test`
  stub (`llm_stub/0`) that answers per platform FROM THE PROMPT IT RECEIVED,
  so a column sent the wrong prompt gets the wrong shape.

  `stub_llm!/1` options:

    * `fail: [kind]` - those platforms' calls return a 500;
    * `replies: %{kind => map}` - override a platform's first reply;
    * `retry_replies: %{kind => map}` - the reply to a regeneration (a
      prompt carrying the banned-phrase note);
    * `test: pid` - who receives `{:llm, kind, model, prompt}` (default
      the caller).

  Callers must be `async: false`: the client is application env.
  """

  import Platform.SocialFixtures, only: [unique: 0]

  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Social.Composer

  @llm Platform.SocialComposerFixtures.LLM

  @doc "The `Req.Test` stub name the provider is pointed at."
  def llm_stub, do: @llm

  @doc "Points the Anthropic client at the stub; returns an on_exit restore fun."
  def use_llm_stub! do
    previous = Application.get_env(:platform, :anthropic_req_client)
    Application.put_env(:platform, :anthropic_req_client, Req.new(plug: {Req.Test, @llm}))

    fn ->
      if previous,
        do: Application.put_env(:platform, :anthropic_req_client, previous),
        else: Application.delete_env(:platform, :anthropic_req_client)
    end
  end

  @doc "An agent row whose credentials reach the stub. `attrs` override."
  def composer_agent!(attrs \\ %{}) do
    %Agent{}
    |> Agent.changeset(
      Map.merge(
        %{
          slug: "composer-#{unique()}",
          name: "Composer drafter",
          status: "active",
          kind: "external",
          runtime_type: "external",
          endpoint_kind: "openai_compat",
          base_url: "http://stub.example.local/v1",
          model: "agent-model",
          vault_key: "sk-ant-api03-test-not-real"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  @doc "A composer agent set as the fallback drafter (the responsibility key)."
  def drafting_agent!(attrs \\ %{}) do
    agent = composer_agent!(attrs)
    {:ok, _} = Platform.Roles.set_override(Composer.config(:responsibility_key), agent.id)
    agent
  end

  def stub_llm!(opts \\ []) do
    test = Keyword.get(opts, :test, self())
    fail = Keyword.get(opts, :fail, [])
    replies = Keyword.get(opts, :replies, %{})
    retry_replies = Keyword.get(opts, :retry_replies, %{})

    Req.Test.stub(@llm, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      [%{"role" => "user", "content" => prompt}] = body["messages"]
      kind = kind(prompt)
      retry? = prompt =~ "Your previous version used the phrase"
      send(test, {:llm, kind, body["model"], prompt})

      if kind in fail do
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => %{"message" => "boom"}})
      else
        reply =
          cond do
            retry? and Map.has_key?(retry_replies, kind) -> Map.fetch!(retry_replies, kind)
            Map.has_key?(replies, kind) -> Map.fetch!(replies, kind)
            true -> reply(kind)
          end

        Req.Test.json(conn, %{
          "model" => body["model"],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
          "content" => [%{"type" => "text", "text" => Jason.encode!(reply)}]
        })
      end
    end)
  end

  @doc "Which platform a prompt is for."
  def kind(prompt) do
    cond do
      prompt =~ "Platform: LinkedIn" -> "linkedin"
      prompt =~ "Platform: X." -> "x"
      prompt =~ "Platform: Instagram" -> "instagram"
      prompt =~ "Platform: YouTube" -> "youtube"
      prompt =~ "Platform: TikTok" -> "tiktok"
      true -> "unknown"
    end
  end

  def reply("linkedin"),
    do: %{"text" => "LinkedIn long-form on the launch.", "why_shape" => "Room for a story."}

  def reply("x"),
    do: %{"posts" => ["The launch, in brief.", "Why it matters."], "why_shape" => "A thread."}

  def reply("instagram"),
    do: %{"text" => "Launch day caption #htc", "why_shape" => "Caption first line."}

  def reply("youtube"),
    do: %{
      "title" => "How the launch came together",
      "description" => "The whole story of the launch.",
      "why_shape" => "Search reads the title."
    }

  def reply("tiktok"), do: %{"text" => "Launch, fast. #htc", "why_shape" => "Short wins."}
  def reply(_), do: %{"unexpected" => true}

  @doc "A 600-character X version: three posts once split."
  def long_x_reply do
    sentence = "Every step of the launch taught the team something worth sharing today. "
    text = sentence |> String.duplicate(9) |> String.slice(0, 600) |> String.trim()
    %{"posts" => [text], "why_shape" => "A thread carries the detail."}
  end
end
