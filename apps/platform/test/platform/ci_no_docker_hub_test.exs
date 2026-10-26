defmodule Platform.CiNoDockerHubTest do
  @moduledoc """
  CI and the Dockerfiles pull nothing from Docker Hub.

  Every third-party image is a digest-pinned mirror under ghcr.io/getburrowing,
  copied by `.github/workflows/mirror-images.yml`. Docker Hub rate-limits
  anonymous pulls from the self-hosted runners' shared egress IP, and the
  repository has no Docker Hub credentials to log in with.

  Scanned: every workflow under `.github/workflows` and every `Dockerfile*`,
  `*.Dockerfile` and `Containerfile*` in the repository (`git ls-files`,
  tracked and untracked-but-not-ignored). Full-line comments are skipped.

  A line fails if it:

    * names a Docker Hub host (`docker.io`, `index.docker.io`,
      `registry-1.docker.io`, `hub.docker.com`) or a `DOCKERHUB` secret or
      variable;
    * pulls an image ref with no registry host, which Docker resolves to
      Docker Hub: a Dockerfile `FROM elixir:...`, a workflow `image:`,
      `container:` or `driver-opts` `image=`, or a `docker|podman
      run|pull|create` argument;
    * pulls a ref built from a `$` variable, which this text check cannot see
      through.

  `scratch` and earlier build stages are not images. Any registry with a host
  (ghcr.io, public.ecr.aws, mcr.microsoft.com, localhost, ...) passes.

  The one exemption is the mirror list itself (the `<<'MIRRORS'` heredoc in
  mirror-images.yml), whose first column must name Docker Hub. Every reference
  to a mirror elsewhere must carry that entry's tag and digest, so a bump to
  one side without the other fails here.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @mirror_workflow ".github/workflows/mirror-images.yml"
  @hub_hosts ~w(docker.io index.docker.io registry-1.docker.io registry.hub.docker.com)
  @hub_text ~r/docker\.io\b|hub\.docker\.com|DOCKERHUB/i
  @mirror_entry ~r/^\s*(docker\.io\/\S+?):([\w.-]+)@(sha256:[0-9a-f]{64})\s+(ghcr\.io\/getburrowing\/[a-z0-9._-]+):([\w.-]+)\s*$/

  setup_all do
    files =
      for path <- scanned_paths(), into: %{} do
        {path, File.read!(Path.join(@repo_root, path))}
      end

    {:ok, files: files, mirrors: mirror_list(Map.fetch!(files, @mirror_workflow))}
  end

  describe "the scanned file set" do
    test "includes the workflows and every image-building Dockerfile", %{files: files} do
      for path <- [
            ".github/workflows/ci.yml",
            @mirror_workflow,
            "apps/platform/Dockerfile",
            "apps/burrow_release/Dockerfile",
            "services/agent-host/Dockerfile",
            "deployment/operators/suite-runner.Dockerfile"
          ] do
        assert Map.has_key?(files, path),
               "#{path} is not in the scanned set #{inspect(Map.keys(files))}"
      end
    end

    test "the extractor sees each kind of image ref in the real files", %{files: files} do
      ci = refs(".github/workflows/ci.yml", Map.fetch!(files, ".github/workflows/ci.yml"))
      kinds = ci |> Enum.map(fn {_, kind, _} -> kind end) |> Enum.uniq() |> Enum.sort()

      assert kinds == [:docker_run, :driver_opts, :image],
             "ci.yml yielded ref kinds #{inspect(kinds)}: #{inspect(ci)}"

      platform = refs("apps/platform/Dockerfile", Map.fetch!(files, "apps/platform/Dockerfile"))
      assert length(platform) == 3, "expected 3 FROM images, got #{inspect(platform)}"
    end
  end

  describe "no Docker Hub pulls" do
    test "no workflow or Dockerfile names Docker Hub or a bare image", %{files: files} do
      violations =
        for {path, text} <- Enum.sort(files), {line, reason} <- violations(path, text) do
          "#{path}:#{line}: #{reason}"
        end

      assert violations == [],
             "Docker Hub references (mirror the image with " <>
               "#{@mirror_workflow} and pull ghcr.io/getburrowing/<name>:<tag>@<digest>):\n  " <>
               Enum.join(violations, "\n  ")
    end

    test "every mirror reference carries its mirror-list tag and digest",
         %{files: files, mirrors: mirrors} do
      by_repo = Map.new(mirrors, fn m -> {m.dst, m} end)

      bad =
        for {path, text} <- Enum.sort(files),
            path != @mirror_workflow,
            {line, l} <- code_lines(text),
            [ref, repo, tag, digest] <-
              ~r/(ghcr\.io\/getburrowing\/[a-z0-9._-]+)(?::([\w.-]+))?(?:@(sha256:[0-9a-f]{64}))?/
              |> Regex.scan(l)
              |> Enum.map(&pad(&1, 4)),
            m <- List.wrap(by_repo[repo]),
            tag != m.tag or digest != m.digest do
          "#{path}:#{line}: #{ref} (mirror list: #{repo}:#{m.tag}@#{m.digest})"
        end

      assert mirrors != [], "no entries parsed from the mirror list in #{@mirror_workflow}"

      assert bad == [],
             "mirror refs out of step with #{@mirror_workflow}:\n  " <> Enum.join(bad, "\n  ")
    end

    test "each mirror-list entry copies a Docker Hub image to its own name and tag",
         %{files: files, mirrors: mirrors} do
      list_lines = mirror_list_lines(Map.fetch!(files, @mirror_workflow))

      assert length(list_lines) == length(mirrors),
             "unparseable mirror-list lines: #{inspect(list_lines)}"

      for m <- mirrors do
        assert m.dst == "ghcr.io/getburrowing/" <> Path.basename(m.src)
        assert m.tag == m.src_tag
      end
    end
  end

  describe "positive control: the detector on planted text" do
    @hub_dockerfile """
    FROM elixir:1.20.4-otp-28-slim AS build
    FROM --platform=linux/amd64 library/debian:bookworm-slim
    FROM docker.io/library/node:22
    FROM build AS app
    FROM scratch
    FROM $BASE
    RUN docker run --rm oven/bun:1 bun --version
    """

    @hub_workflow """
    jobs:
      a:
        container: node:18
        services:
          db:
            image: postgres:16
          cache:
            image: "redis:7"
        steps:
          - uses: docker/setup-buildx-action@v4
            with:
              driver-opts: image=moby/buildkit:latest
          - run: |
              docker run --rm -v "$PWD/x:/src:ro" -p 8080:80 -e A=b oven/bun:1 sh
              docker pull \\
                alpine:3
          - uses: docker/login-action@v4
            with:
              registry: docker.io
              username: ${{ secrets.DOCKERHUB_USERNAME }}
      b:
        container:
          image: ${{ matrix.image }}
    """

    test "each Docker Hub form in a Dockerfile is flagged" do
      lines = "Dockerfile" |> violations(@hub_dockerfile) |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      assert lines == [1, 2, 3, 6, 7]
    end

    test "each Docker Hub form in a workflow is flagged" do
      lines =
        ".github/workflows/x.yml"
        |> violations(@hub_workflow)
        |> Enum.map(&elem(&1, 0))
        |> Enum.uniq()

      assert lines == [3, 6, 8, 12, 14, 15, 19, 20, 23]
    end

    test "non-Docker Hub registries, scratch and build stages pass" do
      dockerfile = """
      FROM ghcr.io/getburrowing/elixir:1.20.4-otp-28-slim@sha256:#{String.duplicate("a", 64)} AS build
      FROM public.ecr.aws/docker/library/debian:bookworm-slim
      FROM mcr.microsoft.com/dotnet/runtime:8.0
      FROM localhost/core-test:1.20.4
      FROM build AS app
      FROM scratch
      # FROM elixir:1.20 in a comment
      """

      workflow = """
      jobs:
        a:
          container:
            image: ghcr.io/getburrowing/python:3.12-slim
          services:
            db:
              image: public.ecr.aws/docker/library/postgres:16
          steps:
            - uses: docker/setup-buildx-action@v4
              with:
                driver-opts: image=mcr.microsoft.com/x/buildkit:1
            - run: docker run --rm -e A=b ghcr.io/getburrowing/bun:1 sh
      """

      assert violations("Dockerfile", dockerfile) == []
      assert violations(".github/workflows/x.yml", workflow) == []
    end
  end

  # ---- scanning --------------------------------------------------------------

  defp scanned_paths do
    {out, 0} =
      System.cmd(
        "git",
        ["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--"] ++
          [
            ":(glob).github/workflows/*.yml",
            ":(glob).github/workflows/*.yaml",
            ":(glob)**/Dockerfile*",
            ":(glob)**/*.Dockerfile",
            ":(glob)**/Containerfile*"
          ],
        cd: @repo_root
      )

    out
    |> String.split(<<0>>, trim: true)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?(Path.join(@repo_root, &1)))
  end

  # {line, reason} for every Docker Hub reference in one file.
  defp violations(path, text) do
    lines = code_lines(text)
    list = if path == @mirror_workflow, do: mirror_list_line_numbers(text), else: MapSet.new()

    hub =
      for {n, l} <- lines, not MapSet.member?(list, n), Regex.match?(@hub_text, l) do
        {n, "names Docker Hub: #{String.trim(l)}"}
      end

    pulls =
      for {n, kind, ref} <- refs(path, text), reason = ref_problem(ref), reason != nil do
        {n, "#{kind} #{ref} #{reason}"}
      end

    Enum.sort_by(hub ++ pulls, &elem(&1, 0))
  end

  defp ref_problem(ref) do
    cond do
      String.contains?(ref, "$") -> "is built from a variable; pin a literal mirror ref"
      docker_hub?(ref) -> "resolves to Docker Hub"
      true -> nil
    end
  end

  defp docker_hub?("scratch"), do: false

  defp docker_hub?(ref) do
    case String.split(ref, "/", parts: 2) do
      [host, _] ->
        if host == "localhost" or host =~ ~r/[.:]/ do
          (host |> String.split(":") |> hd() |> String.downcase()) in @hub_hosts
        else
          true
        end

      [_] ->
        true
    end
  end

  # {line, kind, ref} for every image a file pulls.
  defp refs(path, text) do
    lines = code_lines(text)

    if String.starts_with?(path, ".github/") do
      yaml_refs(lines) ++ run_refs(lines)
    else
      from_refs(lines) ++ run_refs(lines)
    end
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp from_refs(lines) do
    {refs, _stages} =
      Enum.reduce(lines, {[], MapSet.new()}, fn {n, l}, {acc, stages} ->
        case Regex.run(~r/^\s*FROM\s+(?:--\S+\s+)*(\S+)(?:\s+AS\s+(\S+))?/i, l) do
          nil ->
            {acc, stages}

          [_, ref | as] ->
            acc =
              if MapSet.member?(stages, String.downcase(ref)),
                do: acc,
                else: [{n, :from, ref} | acc]

            {acc, Enum.reduce(as, stages, &MapSet.put(&2, String.downcase(&1)))}
        end
      end)

    Enum.reverse(refs)
  end

  defp yaml_refs(lines) do
    for {n, l} <- lines,
        {kind, re} <- [
          image: ~r/^\s*(?:-\s+)?image:\s*["']?([^"'\s#]+)/,
          image: ~r/^\s*(?:-\s+)?container:\s*["']?([^"'\s#|>]+)/,
          driver_opts: ~r/(?:^|[\s,"'])image=([^\s,"']+)/
        ],
        [_, ref] <- [Regex.run(re, l)] |> Enum.reject(&is_nil/1) do
      {n, kind, ref}
    end
  end

  # The image argument of `docker|podman [container] run|pull|create`, with
  # `\` continuations joined: the first token shaped like an image ref
  # (lowercase start, ref characters only, and a `:`, `/` or `@`). Quoted,
  # `$`, option and option-value tokens (`-p 8080:80`, `-e A=b`,
  # `/host:/ctr`) do not have that shape.
  defp run_refs(lines) do
    lines
    |> join_continuations()
    |> Enum.flat_map(fn {n, l} ->
      case Regex.run(
             ~r/\b(?:docker|podman)\s+(?:container\s+|image\s+)?(?:run|pull|create)\s+(.*)$/,
             l
           ) do
        nil ->
          []

        [_, rest] ->
          rest
          |> String.split(~r/\s+/, trim: true)
          |> Enum.find(&image_token?/1)
          |> case do
            nil -> []
            ref -> [{n, :docker_run, ref}]
          end
      end
    end)
  end

  defp image_token?(t) do
    String.match?(t, ~r/^[a-z][\w.\-\/:@]*$/) and String.match?(t, ~r/[:\/@]/)
  end

  defp join_continuations(lines) do
    lines
    |> Enum.reduce({[], nil}, fn {n, l}, {acc, open} ->
      case open do
        nil -> continue_or_close(acc, {n, l})
        {n0, l0} -> continue_or_close(acc, {n0, l0 <> " " <> l})
      end
    end)
    |> then(fn {acc, open} -> Enum.reverse(if open, do: [open | acc], else: acc) end)
  end

  defp continue_or_close(acc, {n, l}) do
    if String.ends_with?(String.trim_trailing(l), "\\"),
      do: {acc, {n, l |> String.trim_trailing() |> String.trim_trailing("\\")}},
      else: {[{n, l} | acc], nil}
  end

  defp code_lines(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn {l, n} -> {n, l} end)
    |> Enum.reject(fn {_, l} -> Regex.match?(~r/^\s*#/, l) end)
  end

  # ---- the mirror list -------------------------------------------------------

  defp mirror_list_lines(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.drop_while(fn {l, _} -> not String.contains?(l, "<<'MIRRORS'") end)
    |> Enum.drop(1)
    |> Enum.take_while(fn {l, _} -> String.trim(l) != "MIRRORS" end)
    |> Enum.reject(fn {l, _} -> String.trim(l) == "" end)
  end

  defp mirror_list_line_numbers(text) do
    for {l, n} <- mirror_list_lines(text),
        Regex.match?(@mirror_entry, l),
        into: MapSet.new(),
        do: n
  end

  defp mirror_list(text) do
    for {l, _} <- mirror_list_lines(text),
        [_, src, src_tag, digest, dst, tag] <-
          [Regex.run(@mirror_entry, l)] |> Enum.reject(&is_nil/1) do
      %{src: src, src_tag: src_tag, digest: digest, dst: dst, tag: tag}
    end
  end

  defp pad(list, n), do: list ++ List.duplicate("", n - length(list))
end
