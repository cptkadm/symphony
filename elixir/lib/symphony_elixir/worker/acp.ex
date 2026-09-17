defmodule SymphonyElixir.Worker.ACP do
  @moduledoc """
  Reusable Agent Client Protocol (ACP) worker gateway.

  ACP is a JSON-RPC 2.0 protocol over stdio that connects clients (like Symphony)
  to coding agents (like OpenHands or other ACP-compliant engines) in an isolated,
  leased workspace.
  """

  @behaviour SymphonyElixir.Worker

  require Logger
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Config
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.Worker.Result

  @default_command "openhands acp"
  @default_turn_timeout_ms 3_600_000
  @default_read_timeout_ms 5_000
  @port_line_bytes 1_048_576

  @type handle :: %{
          port: port() | nil,
          session_id: String.t(),
          agent_info: map(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          harness: String.t(),
          protocol: String.t(),
          transport: term(),
          transport_state: term(),
          req_id: pos_integer(),
          opts: keyword()
        }

  @impl true
  def identity do
    settings = get_settings()
    provider = settings[:provider] || "acp"
    model = settings[:model]

    %{
      provider: provider,
      model: model,
      harness: "acp-gateway",
      protocol: "acp"
    }
  end

  @impl true
  def capabilities do
    %{
      conversation: true,
      resume: false,
      usage: true,
      quota: false,
      acp: true
    }
  end

  @impl true
  def start(context) do
    opts = Map.get(context, :opts, [])
    worker_host = context[:worker_host]

    with {:ok, expanded_workspace} <- validate_workspace_cwd(context.workspace, worker_host) do
      do_start(expanded_workspace, context, opts)
    end
  end

  @impl true
  def run(handle, context, on_update) do
    prompt = context.prompt
    turn_timeout_ms = get_turn_timeout_ms(handle.opts)
    read_timeout_ms = get_read_timeout_ms(handle.opts)

    case handle.transport do
      {:custom, transport_mod} ->
        run_turn_custom(transport_mod, handle, prompt, context, on_update, turn_timeout_ms)

      :port ->
        run_turn_port(handle, prompt, context, on_update, turn_timeout_ms, read_timeout_ms)
    end
  end

  @impl true
  def stop(handle) do
    case handle.transport do
      {:custom, transport_mod} ->
        try do
          transport_mod.stop(handle.transport_state)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end

        :ok

      :port ->
        stop_port(handle.port)
        :ok

      _ ->
        :ok
    end
  end

  # --- Session Startup & Handshake ---

  defp do_start(workspace, context, opts) do
    custom_transport = Keyword.get(opts, :transport) || Application.get_env(:symphony_elixir, :acp_transport)

    if custom_transport do
      start_custom_session(workspace, context, opts, custom_transport)
    else
      start_port_session(workspace, context, opts)
    end
  end

  defp start_custom_session(workspace, context, opts, transport_mod) do
    harness = Keyword.get(opts, :harness, "acp-gateway")

    case transport_mod.init(workspace, context, opts) do
      {:ok, session_id, agent_info, transport_state} ->
        handle = %{
          port: nil,
          session_id: session_id,
          agent_info: agent_info || %{},
          workspace: workspace,
          worker_host: context[:worker_host],
          harness: harness,
          protocol: "acp",
          transport: {:custom, transport_mod},
          transport_state: transport_state,
          req_id: 3,
          opts: opts
        }

        {:ok, handle}

      {:error, reason} ->
        {:error, classify(reason)}

      other ->
        {:error, classify(other)}
    end
  rescue
    error -> {:error, classify(error)}
  end

  defp start_port_session(workspace, context, opts) do
    command = resolve_command(opts)
    dynamic_tool_binding = DynamicTool.bind()
    harness = Keyword.get(opts, :harness, "acp-gateway")

    with {:ok, port} <- launch_port(command, workspace, dynamic_tool_binding) do
      read_timeout_ms = get_read_timeout_ms(opts)

      # 1. Initialize Handshake
      init_req = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "1",
          "clientCapabilities" => %{
            "fileSystem" => true,
            "terminal" => true
          },
          "clientInfo" => %{
            "name" => "symphony",
            "version" => "0.0.2"
          }
        }
      }

      with :ok <- send_json_port(port, init_req),
           {:ok, %{"result" => init_result}} <- read_response_port(port, 1, read_timeout_ms) do
        agent_info = init_result["agentInfo"] || %{}

        # 2. Session Setup
        session_req = %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "session/new",
          "params" => %{
            "cwd" => workspace,
            "mcpServers" => []
          }
        }

        with :ok <- send_json_port(port, session_req),
             {:ok, %{"result" => session_result}} <- read_response_port(port, 2, read_timeout_ms) do
          session_id = session_result["sessionId"] || session_result["session_id"] || "session-#{System.unique_integer([:positive])}"

          handle = %{
            port: port,
            session_id: session_id,
            agent_info: agent_info,
            workspace: workspace,
            worker_host: context[:worker_host],
            harness: harness,
            protocol: "acp",
            transport: :port,
            transport_state: nil,
            req_id: 3,
            opts: opts
          }

          {:ok, handle}
        else
          {:ok, %{"error" => error}} ->
            stop_port(port)
            {:error, classify(error)}

          {:error, reason} ->
            stop_port(port)
            {:error, classify(reason)}
        end
      else
        {:ok, %{"error" => error}} ->
          stop_port(port)
          {:error, classify(error)}

        {:error, reason} ->
          stop_port(port)
          {:error, classify(reason)}
      end
    end
  end

  # --- Running Turns ---

  defp run_turn_custom(transport_mod, handle, prompt, context, on_update, turn_timeout_ms) do
    attribution = make_attribution(handle)

    case transport_mod.run_prompt(handle.transport_state, prompt, context, on_update, turn_timeout_ms) do
      {:ok, %{stop_reason: stop_reason} = result} ->
        classify_turn_result(stop_reason, result[:usage], handle.session_id, attribution)

      {:ok, stop_reason} when is_binary(stop_reason) or is_atom(stop_reason) ->
        classify_turn_result(to_string(stop_reason), nil, handle.session_id, attribution)

      {:error, reason} ->
        classify(reason, handle)

      %Result{} = res ->
        res

      other ->
        classify(other, handle)
    end
  rescue
    error -> classify(error, handle)
  end

  defp run_turn_port(handle, prompt, _context, on_update, turn_timeout_ms, _read_timeout_ms) do
    port = handle.port
    prompt_id = handle.req_id
    attribution = make_attribution(handle)

    req = %{
      "jsonrpc" => "2.0",
      "id" => prompt_id,
      "method" => "session/prompt",
      "params" => %{
        "sessionId" => handle.session_id,
        "prompt" => prompt
      }
    }

    with :ok <- send_json_port(port, req) do
      loop_turn_port(port, prompt_id, handle.session_id, attribution, on_update, turn_timeout_ms)
    else
      {:error, reason} ->
        classify(reason, handle)
    end
  end

  defp loop_turn_port(port, prompt_id, session_id, attribution, on_update, timeout_ms) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(line) do
          {:ok, %{"id" => ^prompt_id, "result" => result}} ->
            stop_reason = result["stopReason"] || result["stop_reason"] || "end_turn"
            usage = normalize_usage(result["usage"] || result["total_tokens"])
            classify_turn_result(stop_reason, usage, session_id, attribution)

          {:ok, %{"id" => ^prompt_id, "error" => error}} ->
            classify(error, %{session_id: session_id, attribution: attribution})

          {:ok, %{"method" => "session/update", "params" => params}} ->
            emit_progress(on_update, params)
            loop_turn_port(port, prompt_id, session_id, attribution, on_update, timeout_ms)

          {:ok, %{"method" => _other_method, "params" => params}} ->
            emit_progress(on_update, params)
            loop_turn_port(port, prompt_id, session_id, attribution, on_update, timeout_ms)

          {:ok, _other_message} ->
            loop_turn_port(port, prompt_id, session_id, attribution, on_update, timeout_ms)

          {:error, _} ->
            loop_turn_port(port, prompt_id, session_id, attribution, on_update, timeout_ms)
        end

      {^port, {:data, {:noeol, _fragment}}} ->
        loop_turn_port(port, prompt_id, session_id, attribution, on_update, timeout_ms)

      {^port, {:exit_status, status}} ->
        classify({:port_exit, status}, %{session_id: session_id, attribution: attribution})
    after
      timeout_ms ->
        classify(:turn_timeout, %{session_id: session_id, attribution: attribution})
    end
  end

  defp emit_progress(on_update, params) when is_map(params) do
    content = params["content"] || params["message"] || params["thought"] || params[:content]
    usage = normalize_usage(params["usage"] || params[:usage])

    telemetry = %{
      event: :progress,
      timestamp: DateTime.utc_now(),
      content: content,
      worker_usage: usage
    }

    try do
      on_update.(telemetry)
    rescue
      _ -> :ok
    end
  end

  defp emit_progress(_on_update, _), do: :ok

  defp classify_turn_result(stop_reason, usage, session_id, attribution) do
    normalized_reason = stop_reason |> to_string() |> String.downcase()

    cond do
      normalized_reason in ["end_turn", "completed", "stop", "finished", "success"] ->
        %Result{
          class: :success,
          session_id: session_id,
          usage: usage,
          attribution: attribution
        }

      normalized_reason in ["cancelled", "canceled", "aborted"] ->
        %Result{
          class: :cancelled,
          session_id: session_id,
          usage: usage,
          attribution: attribution
        }

      normalized_reason in ["input_required", "waiting_for_input", "ask_user"] ->
        %Result{
          class: :input_required,
          session_id: session_id,
          usage: usage,
          attribution: attribution
        }

      normalized_reason in ["max_tokens", "length", "context_length_exceeded"] ->
        %Result{
          class: :implementation_failure,
          session_id: session_id,
          usage: usage,
          attribution: attribution
        }

      true ->
        classify(normalized_reason, %{session_id: session_id, attribution: attribution})
    end
  end

  # --- Result Classification ---

  @doc """
  Classifies ACP error payloads and system errors into normalized `Worker.Result` structs.
  """
  @spec classify(term()) :: Result.t()
  def classify(error), do: classify(error, nil)

  @spec classify(term(), map() | nil) :: Result.t()
  def classify(%Result{} = res, _context), do: res

  def classify({:error, reason}, context), do: classify(reason, context)

  def classify(%{"code" => -32001}, context) do
    build_result(:provider_capacity, context)
  end

  def classify(%{"code" => code, "message" => msg} = payload, context) when is_integer(code) do
    data = payload["data"] || %{}
    info = data["error_type"] || data["type"] || msg
    class = error_string_to_class(info)
    retry_at = extract_retry_at_ms(data)
    build_result(class, context, retry_at)
  end

  def classify(%{"error" => inner}, context), do: classify(inner, context)

  def classify(reason, context) when reason in [:turn_timeout, :read_timeout, :timeout] do
    build_result(:transport_failure, context)
  end

  def classify({:port_exit, _status}, context) do
    build_result(:transport_failure, context)
  end

  def classify(:cancelled, context) do
    build_result(:cancelled, context)
  end

  def classify(error_str, context) when is_binary(error_str) do
    class = error_string_to_class(error_str)
    build_result(class, context)
  end

  def classify(atom, context) when is_atom(atom) do
    class =
      case atom do
        :provider_capacity -> :provider_capacity
        :rate_limited -> :rate_limited
        :authentication_failure -> :authentication_failure
        :transport_failure -> :transport_failure
        :input_required -> :input_required
        :cancelled -> :cancelled
        :implementation_failure -> :implementation_failure
        _ -> :unknown_failure
      end

    build_result(class, context)
  end

  def classify(_other, context) do
    build_result(:unknown_failure, context)
  end

  defp error_string_to_class(str) when is_binary(str) do
    lower = String.downcase(str)

    cond do
      String.contains?(lower, ["overload", "capacity", "503", "server_overloaded"]) ->
        :provider_capacity

      String.contains?(lower, ["rate_limit", "quota", "429", "usagelimitexceeded", "too many requests"]) ->
        :rate_limited

      String.contains?(lower, ["unauthorized", "auth", "401", "403", "forbidden", "invalid_api_key"]) ->
        :authentication_failure

      String.contains?(lower, ["connect", "econnrefused", "closed", "pipe", "timeout", "transport", "network"]) ->
        :transport_failure

      String.contains?(lower, ["input_required", "ask_user", "approval_required", "elicitation"]) ->
        :input_required

      String.contains?(lower, ["cancelled", "canceled", "aborted"]) ->
        :cancelled

      String.contains?(lower, ["bad_request", "invalid_params", "syntax", "context_length", "max_tokens", "recursion"]) ->
        :implementation_failure

      true ->
        :unknown_failure
    end
  end

  defp error_string_to_class(_), do: :unknown_failure

  defp extract_retry_at_ms(%{"retry_after" => seconds}) when is_integer(seconds) and seconds > 0 do
    System.system_time(:millisecond) + seconds * 1_000
  end

  defp extract_retry_at_ms(%{"retry_at_ms" => ms}) when is_integer(ms) and ms > 0 do
    ms
  end

  defp extract_retry_at_ms(_), do: nil

  defp build_result(class, context, retry_at_ms \\ nil) do
    session_id = context && context[:session_id]
    attribution = context && context[:attribution]

    %Result{
      class: class,
      session_id: session_id,
      retry_at_ms: retry_at_ms,
      attribution: attribution
    }
  end

  defp make_attribution(handle) do
    agent_info = handle.agent_info || %{}

    provider =
      agent_info["provider"] ||
        agent_info[:provider] ||
        get_settings()[:provider] ||
        "acp"

    model =
      agent_info["model"] ||
        agent_info[:model] ||
        get_settings()[:model]

    %{
      provider: to_string(provider),
      model: model && to_string(model),
      harness: handle[:harness] || "acp-gateway",
      protocol: "acp"
    }
  end

  # --- Port Helpers ---

  defp launch_port(command, workspace, dynamic_tool_binding) do
    env = tracker_secret_port_env(dynamic_tool_binding)

    port =
      Port.open(
        {:spawn, command},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          line: @port_line_bytes,
          cd: workspace,
          env: env
        ]
      )

    {:ok, port}
  rescue
    error -> {:error, {:port_spawn_failed, Exception.message(error)}}
  end

  defp send_json_port(port, payload) when is_port(port) and is_map(payload) do
    case Jason.encode(payload) do
      {:ok, json} ->
        try do
          Port.command(port, json <> "\n")
          :ok
        rescue
          error -> {:error, {:port_command_failed, Exception.message(error)}}
        end

      {:error, reason} ->
        {:error, {:json_encode_failed, reason}}
    end
  end

  defp read_response_port(port, target_id, timeout_ms) when is_port(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(line) do
          {:ok, %{"id" => ^target_id} = response} ->
            {:ok, response}

          {:ok, _other_line} ->
            read_response_port(port, target_id, timeout_ms)

          {:error, _} ->
            read_response_port(port, target_id, timeout_ms)
        end

      {^port, {:data, {:noeol, _}}} ->
        read_response_port(port, target_id, timeout_ms)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :read_timeout}
    end
  end

  defp stop_port(port) when is_port(port) do
    try do
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) and pid > 0 ->
          System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
          Process.sleep(20)
          System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

        _ ->
          :ok
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    try do
      Port.close(port)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp stop_port(_), do: :ok

  defp tracker_secret_port_env(dynamic_tool_binding) do
    dynamic_tool_binding.secret_environment_names
    |> Enum.filter(fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Config.local_workspace_root()
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    end
  end

  defp validate_workspace_cwd(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    {:ok, workspace}
  end

  defp validate_workspace_cwd(_workspace, _worker_host), do: {:error, :invalid_workspace_cwd}

  defp normalize_usage(usage) when is_map(usage) do
    input = usage["input_tokens"] || usage[:input_tokens] || usage["prompt_tokens"] || usage[:prompt_tokens] || usage["input"] || usage[:input]
    output = usage["output_tokens"] || usage[:output_tokens] || usage["completion_tokens"] || usage[:completion_tokens] || usage["output"] || usage[:output]
    total = usage["total_tokens"] || usage[:total_tokens] || usage["total"] || usage[:total]

    %{
      input: to_non_neg_int(input),
      output: to_non_neg_int(output),
      total: to_non_neg_int(total)
    }
  end

  defp normalize_usage(_), do: nil

  defp to_non_neg_int(val) when is_integer(val) and val >= 0, do: val

  defp to_non_neg_int(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {num, ""} when num >= 0 -> num
      _ -> nil
    end
  end

  defp to_non_neg_int(_), do: nil

  defp resolve_command(opts) do
    Keyword.get(opts, :command) ||
      get_settings()[:command] ||
      @default_command
  end

  defp get_turn_timeout_ms(opts) do
    Keyword.get(opts, :turn_timeout_ms) ||
      get_settings()[:turn_timeout_ms] ||
      @default_turn_timeout_ms
  end

  defp get_read_timeout_ms(opts) do
    Keyword.get(opts, :read_timeout_ms) ||
      get_settings()[:read_timeout_ms] ||
      @default_read_timeout_ms
  end

  defp get_settings do
    try do
      case Config.settings() do
        {:ok, %{acp: acp}} when is_map(acp) ->
          Map.from_struct(acp)

        _ ->
          %{}
      end
    rescue
      _ -> %{}
    catch
      :exit, _ -> %{}
    end
  end
end
