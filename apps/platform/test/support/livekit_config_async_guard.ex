defmodule Platform.LivekitConfigAsyncGuard do
  @moduledoc """
  Static scheduling guard for literal LiveKit application configuration writes.

  Parses source without evaluating it. Module aliases and imports are resolved,
  and writer status propagates through calls to helpers in the scanned corpus.
  This is deliberately conservative at module granularity: calling a module
  containing a writer requires synchronous scheduling even if a particular
  function happens not to write. Dynamically constructed module/key names and
  runtime metaprogramming are outside this static check's scope.
  """

  def violations(sources) do
    modules =
      Enum.reduce(sources, %{}, fn {file, source}, modules ->
        ast = Code.string_to_quoted!(source, file: file)
        collect(ast, file, modules)
      end)

    writers = propagate(modules, MapSet.new(for {name, %{writes: [_ | _]}} <- modules, do: name))

    modules
    |> Enum.flat_map(fn {name, info} ->
      if info.async and MapSet.member?(writers, name) do
        [%{module: name, file: info.file, line: info.line}]
      else
        []
      end
    end)
    |> Enum.sort_by(&{&1.file, &1.line, &1.module})
  end

  defp collect({:quote, _, _}, _, modules), do: modules

  defp collect({:defmodule, meta, [name, [do: body]]}, file, modules) do
    name = resolve(name, %{})

    initial = %{
      file: file,
      line: meta[:line],
      async: false,
      aliases: %{},
      calls: MapSet.new(),
      writes: []
    }

    info = walk(body, initial)
    collect(body, file, Map.put(modules, name, info))
  end

  defp collect(ast, file, modules) when is_tuple(ast) do
    ast |> Tuple.to_list() |> Enum.reduce(modules, &collect(&1, file, &2))
  end

  defp collect(ast, file, modules) when is_list(ast) do
    Enum.reduce(ast, modules, &collect(&1, file, &2))
  end

  defp collect(_, _, modules), do: modules

  # Quoted code is data; ordinary string fixtures never have executable AST.
  defp walk({:quote, _, _}, info), do: info
  defp walk({:defmodule, _, _}, info), do: info

  defp walk({:alias, _, [{{:., _, [prefix, :{}]}, _, names}]}, info) do
    Enum.reduce(names, info, fn name, acc ->
      root = resolve(prefix, acc.aliases)
      suffix = resolve(name, %{})
      if root && suffix, do: put_alias(acc, Module.concat(root, suffix), nil), else: acc
    end)
  end

  defp walk({:alias, _, [target, opts]}, info) when is_list(opts) do
    put_alias(info, target, opts[:as])
  end

  defp walk({:alias, _, [target]}, info), do: put_alias(info, target, nil)

  defp walk({:use, _, [_target | opts]} = ast, info) do
    options = List.flatten(opts)

    info =
      if Keyword.has_key?(options, :async),
        do: %{info | async: options[:async] != false},
        else: info

    walk_children(ast, info)
  end

  defp walk({:import, _, [target | _]}, info) do
    %{info | calls: MapSet.put(info.calls, resolve(target, info.aliases))}
  end

  defp walk({{:., _, [target, function]}, meta, args}, info) when is_list(args) do
    module = resolve(target, info.aliases)
    info = %{info | calls: MapSet.put(info.calls, module)}

    info =
      if module == Application and mutation?(function, args),
        do: %{info | writes: [meta[:line] | info.writes]},
        else: info

    walk(args, info)
  end

  defp walk({function, meta, args} = ast, info)
       when function in [:put_env, :delete_env, :put_all_env] and is_list(args) do
    info =
      if MapSet.member?(info.calls, Application) and mutation?(function, args),
        do: %{info | writes: [meta[:line] | info.writes]},
        else: info

    walk_children(ast, info)
  end

  defp walk(ast, info) when is_tuple(ast), do: walk_children(ast, info)
  defp walk(ast, info) when is_list(ast), do: Enum.reduce(ast, info, &walk/2)
  defp walk(_, info), do: info
  defp walk_children(ast, info), do: ast |> Tuple.to_list() |> walk(info)

  defp put_alias(info, target, as) do
    case resolve(target, info.aliases) do
      nil ->
        info

      module ->
        key = if as, do: resolve(as, %{}), else: Module.concat([List.last(Module.split(module))])
        %{info | aliases: Map.put(info.aliases, key, module)}
    end
  end

  defp resolve({:__aliases__, _, parts}, aliases) do
    [head | tail] = parts
    root = Map.get(aliases, Module.concat([head]), Module.concat([head]))
    Module.concat([root | tail])
  end

  defp resolve(atom, _) when is_atom(atom), do: atom
  defp resolve(_, _), do: nil

  defp mutation?(function, [:platform, :livekit | _]) when function in [:put_env, :delete_env],
    do: true

  defp mutation?(:put_all_env, [entries | _]) when is_list(entries) do
    entries
    |> Keyword.get(:platform, [])
    |> then(&(is_list(&1) and Keyword.has_key?(&1, :livekit)))
  end

  defp mutation?(_, _), do: false

  defp propagate(modules, writers) do
    next =
      Enum.reduce(modules, writers, fn {name, info}, acc ->
        if Enum.any?(info.calls, &MapSet.member?(writers, &1)),
          do: MapSet.put(acc, name),
          else: acc
      end)

    if MapSet.equal?(next, writers), do: writers, else: propagate(modules, next)
  end
end
