defmodule SymphonyElixir.WorkspaceLock do
  @moduledoc """
  OS-backed exclusive workspace ownership. Lock files are never removed.

  A monitored guardian holds an OS process running flock for the lifetime of the
  caller's operation. Worker death closes its input; unexpected holder death kills
  the worker. Nested operations in the same worker reuse its ownership.
  """

  use GenServer
  require Logger
  alias SymphonyElixir.{PathSafety, SSH}

  @external_resource Path.expand("../../priv/workspace_lock.py", __DIR__)
  @script File.read!(@external_resource)
  @timeout 10_000

  @spec with_lock(Path.t(), map() | String.t() | nil, String.t() | nil, (-> result)) :: result | {:error, term()}
        when result: var
  def with_lock(workspace, issue, host, operation) do
    with {:ok, path} <- canonical_path(workspace, host) do
      key = {__MODULE__, host, path}

      case Process.get(key) do
        nil -> own(key, path, issue, host, operation)
        _owner -> operation.()
      end
    end
  end

  @doc false
  @spec command(Path.t(), String.t() | nil, String.t()) :: String.t()
  def command(workspace, host, command) do
    with {:ok, path} <- canonical_path(workspace, host),
         %{} = metadata <- Process.get({__MODULE__, host, path}) do
      Enum.map_join(["python3", "-I", "-u", "-c", @script, Jason.encode!(metadata), command], " ", &shell_escape/1)
    else
      _ -> command
    end
  end

  defp own(key, path, issue, host, operation) do
    metadata = %{
      issue_id: issue_id(issue),
      issue_identifier: identifier(issue),
      workspace_path: path,
      owner_pid: System.pid(),
      orchestrator_host: hostname(),
      orchestrator_instance_id: instance_id(),
      attempt_id: Base.encode16(:crypto.strong_rand_bytes(16))
    }

    case GenServer.start(__MODULE__, {self(), metadata, host}) do
      {:ok, guardian} ->
        diagnostics = GenServer.call(guardian, :diagnostics)
        canonical_key = {__MODULE__, host, diagnostics["workspace_path"]}
        Process.put(key, diagnostics)
        Process.put(canonical_key, diagnostics)

        try do
          operation.()
        after
          Process.delete(key)
          Process.delete(canonical_key)
          GenServer.call(guardian, :release, @timeout)
        end

      {:error, reason} ->
        Logger.warning("Workspace ownership denied issue_id=#{issue_id(issue)} issue_identifier=#{identifier(issue)} workspace=#{path} owner=#{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def init({owner, metadata, host}) do
    Process.flag(:trap_exit, true)
    Process.monitor(owner)

    with {:ok, port} <- start_holder(metadata, host),
         {:ok, diagnostics} <- await_acquisition(port) do
      Logger.info("Workspace ownership acquired issue_id=#{metadata.issue_id} issue_identifier=#{metadata.issue_identifier} owner=#{inspect(diagnostics)}")
      {:ok, %{owner: owner, port: port, diagnostics: diagnostics, releasing: nil}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:diagnostics, _from, state) do
    Process.link(state.owner)
    {:reply, state.diagnostics, state}
  end

  def handle_call(:release, from, state) do
    Port.command(state.port, "release\n")
    {:noreply, %{state | releasing: from}}
  end

  @impl true
  def handle_info({port, {:exit_status, _status}}, %{port: port, releasing: from} = state) when not is_nil(from) do
    GenServer.reply(from, :ok)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state) do
    close_port(state.port)
    {:stop, :normal, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("Workspace lock holder lost owner=#{inspect(state.diagnostics)} status=#{status}; stopping worker")
    Process.exit(state.owner, :kill)
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, owner, _reason}, %{owner: owner} = state) do
    close_port(state.port)
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port, releasing: nil} = state) do
    Process.exit(state.owner, :kill)
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_nil(state.releasing) and Process.alive?(state.owner), do: Process.exit(state.owner, :kill)
    close_port(state.port)
  end

  defp await_acquisition(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(line) do
          {:ok, %{"status" => "acquired", "owner" => owner}} -> {:ok, owner}
          {:ok, %{"status" => "locked", "owner" => owner}} -> close_error(port, {:workspace_locked, owner})
          _ -> close_error(port, {:workspace_lock_failed, line})
        end

      {^port, {:data, _data}} ->
        close_error(port, :workspace_lock_invalid_response)

      {^port, {:exit_status, status}} ->
        {:error, {:workspace_lock_exit, status}}
    after
      @timeout -> close_error(port, :workspace_lock_timeout)
    end
  end

  defp start_holder(metadata, nil) do
    case System.find_executable("python3") do
      nil ->
        {:error, :workspace_lock_python3_not_found}

      executable ->
        {:ok,
         Port.open({:spawn_executable, String.to_charlist(executable)}, [
           :binary,
           :exit_status,
           :stderr_to_stdout,
           line: 65_536,
           args: ["-I", "-u", "-c", @script, Jason.encode!(metadata)]
         ])}
    end
  end

  defp start_holder(metadata, host) do
    command = Enum.map_join(["python3", "-I", "-u", "-c", @script, Jason.encode!(metadata)], " ", &shell_escape/1)
    SSH.start_port(host, "exec " <> command, line: 65_536)
  end

  defp close_error(port, reason) do
    close_port(port)
    {:error, reason}
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  defp canonical_path(path, nil), do: PathSafety.canonicalize(path)
  defp canonical_path(path, _host), do: {:ok, path}

  defp instance_id do
    # The VM's system start time survives worker restarts and distinguishes PID reuse.
    started = :erlang.system_info(:start_time) + :erlang.time_offset()
    "#{System.pid()}-#{started}"
  end

  defp hostname do
    {:ok, host} = :inet.gethostname()
    List.to_string(host)
  end

  defp identifier(%{identifier: identifier}), do: identifier
  defp identifier(identifier) when is_binary(identifier), do: identifier
  defp identifier(_), do: "issue"
  defp issue_id(%{id: id}), do: id
  defp issue_id(_), do: "n/a"
  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
