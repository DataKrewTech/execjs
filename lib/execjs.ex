defmodule Execjs do
  readme_path = [__DIR__, "..", "README.md"] |> Path.join() |> Path.expand()

  @external_resource readme_path
  @moduledoc readme_path |> File.read!() |> String.trim()

  alias Execjs.Runtimes

  defmodule(ExecError, do: defexception([:message]))
  defmodule(RuntimeError, do: defexception([:message, :stack]))

  @type context() :: (iodata -> iodata)

  @spec eval(String.t()) :: Poison.Parser.t() | :undefined | no_return
  def eval(source) when is_binary(source) do
    exec(~s[eval(#{Poison.encode!(source, escape: :javascript)})])
  end

  @spec compile(iodata) :: context()
  def compile(source) do
    preamble = IO.iodata_to_binary(["(function(){\n", source, ";\n"])
    &IO.iodata_to_binary([preamble, &1, ";\n})()"])
  end

  @spec call(context(), String.t(), list(Poison.Encoder.t())) ::
          Poison.Parser.t(), Poison.Parser.t() | :undefined | no_return
  def call(context, identifier, args \\ [], opts\\ %{})
      when is_binary(identifier) and is_list(args) do
    logger = get_logger();
    source =
      "#{logger};
      result = #{identifier}.apply(this, #{
        Poison.encode!(args, escape: :javascript)
      });
      resp = {code_output: result, logs: logs};
      return JSON.stringify(resp);"

    exec(context.(source), opts)
  end

  defp exec(source), do: exec(source, %{})
  defp exec(source, opts) do
    # default 128 MB
    mem_limit = Map.get(opts, :mem_limit, 128)
    # default 600000(10 mins)
    timeout = Map.get(opts, :timeout, 600000)

    runtime = Runtimes.best_available()
    command = runtime.command |> System.find_executable()
    program = runtime.template(source, mem_limit, timeout)
    tmpfile = compile_to_tempfile(program)
    try do
      port =
        Port.open({:spawn_executable, command}, [
          :stream,
          :in,
          :binary,
          :eof,
          :hide,
          {:args, Enum.concat(runtime.arguments, [tmpfile])},
          {:parallelism, true}
        ])

      extract_result(loop(port))
    after
      File.rm!(tmpfile)
    end
  end

  defp loop(port, acc \\ "") do
    receive do
      {^port, {:data, data}} ->
        loop(port, acc <> data)

      {^port, :eof} ->
        send(port, {self(), :close})
        receive do: ({^port, :closed} -> :ok)
        acc
    end
  end

  defp compile_to_tempfile(program) do
    hash = :erlang.phash2({System.get_pid(), System.monotonic_time()})
    filename = ".execjs-#{hash}.js"
    tmp_file_path = System.get_env("JS_TEMP_FILE_PATH", "/app")
    path = Path.join(tmp_file_path, filename)
    File.write!(path, program, ~w[binary exclusive raw sync]a)
    path
  end

  defp extract_result(output) do
    case Poison.decode!(output) do
      ["ok", value] ->
        value

      ["ok"] ->
        :undefined

      ["err", message, stack] ->
        raise RuntimeError, message: message, stack: stack

      ["err"] ->
        raise ExecError, message: "Unexpected error"
    end
  end

  defp get_logger() do
    "
    var logs = {
      entries: []
    };

    var console = {};
    console.log = function(obj){
      logs.entries.push({
        content: obj
      });
    };
    "
  end
end
