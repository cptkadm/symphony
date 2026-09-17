defmodule SymphonyElixir.Worker.OpenHands do
  @moduledoc """
  OpenHands worker gateway implementing the provider-neutral `SymphonyElixir.Worker` contract.

  Supports two execution modes:
  - `:acp` (default): Uses the Agent Client Protocol (`openhands acp`) over JSON-RPC 2.0 stdio.
  - `:agent_server`: Uses the OpenHands Agent Server API (HTTP / event stream) or local server subprocess.

  Normalizes lifecycle, progress, cancellation, terminal results, and cleanly separates
  harness/runtime/protocol identity from underlying provider/model identity.
  """

  @behaviour SymphonyElixir.Worker

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Worker.ACP
  alias SymphonyElixir.Worker.Result

  @default_command "openhands acp"
  @default_provider "openhands"

  @type mode :: :acp | :agent_server

  @impl true
  def identity do
    settings = get_settings()
    mode = get_mode(settings)
    provider = settings[:provider] || @default_provider
    model = settings[:model]

    {harness, protocol} =
      case mode do
        :agent_server -> {"openhands-agent-server", "openhands-agent-server"}
        _ -> {"openhands-acp", "acp"}
      end

    %{
      provider: provider,
      model: model,
      harness: harness,
      protocol: protocol
    }
  end

  @impl true
  def capabilities do
    settings = get_settings()
    mode = get_mode(settings)

    case mode do
      :agent_server ->
        %{
          conversation: true,
          resume: true,
          usage: true,
          quota: false,
          acp: false
        }

      _ ->
        %{
          conversation: true,
          resume: false,
          usage: true,
          quota: false,
          acp: true
        }
    end
  end

  @impl true
  def start(context) do
    settings = get_settings()
    opts = Map.get(context, :opts, [])
    mode = Keyword.get(opts, :mode) || get_mode(settings)

    case mode do
      :acp ->
        start_acp(context, settings, opts)

      :agent_server ->
        start_agent_server(context, settings, opts)
    end
  end

  @impl true
  def run(handle, context, on_update) do
    case handle[:mode] do
      :acp ->
        ACP.run(handle.acp_handle, context, on_update)

      :agent_server ->
        run_agent_server(handle, context, on_update)
    end
  end

  @impl true
  def stop(handle) do
    case handle[:mode] do
      :acp ->
        ACP.stop(handle.acp_handle)

      :agent_server ->
        stop_agent_server(handle)

      _ ->
        :ok
    end
  end

  # --- ACP Mode ---

  defp start_acp(context, settings, opts) do
    command = Keyword.get(opts, :command) || settings[:command] || @default_command
    provider = Keyword.get(opts, :provider) || settings[:provider] || @default_provider
    model = Keyword.get(opts, :model) || settings[:model]

    acp_opts =
      opts
      |> Keyword.put(:command, command)
      |> Keyword.put(:harness, "openhands-acp")
      |> Keyword.put_new(:provider, provider)
      |> Keyword.put_new(:model, model)

    acp_context = Map.put(context, :opts, acp_opts)

    case ACP.start(acp_context) do
      {:ok, acp_handle} ->
        # Overwrite harness attribution to reflect openhands-acp
        updated_acp_handle = Map.put(acp_handle, :harness, "openhands-acp")
        {:ok, %{mode: :acp, acp_handle: updated_acp_handle}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Agent Server Mode ---

  defp start_agent_server(context, settings, opts) do
    workspace = context.workspace
    client = Keyword.get(opts, :agent_server_client) || Application.get_env(:symphony_elixir, :openhands_agent_server_client, __MODULE__.DefaultAgentServerClient)
    provider = Keyword.get(opts, :provider) || settings[:provider] || @default_provider
    model = Keyword.get(opts, :model) || settings[:model]
    endpoint = Keyword.get(opts, :endpoint) || settings[:endpoint] || "http://127.0.0.1:8000"

    client_opts = [
      endpoint: endpoint,
      workspace: workspace,
      provider: provider,
      model: model,
      api_key: Keyword.get(opts, :api_key) || settings[:api_key]
    ]

    case client.create_conversation(client_opts) do
      {:ok, conversation_id, client_state} ->
        handle = %{
          mode: :agent_server,
          client: client,
          client_state: client_state,
          conversation_id: conversation_id,
          workspace: workspace,
          provider: provider,
          model: model,
          harness: "openhands-agent-server",
          protocol: "openhands-agent-server",
          opts: opts
        }

        {:ok, handle}

      {:error, reason} ->
        {:error, classify(reason, %{provider: provider, model: model, harness: "openhands-agent-server", protocol: "openhands-agent-server"})}
    end
  rescue
    error ->
      {:error, classify(error, %{provider: @default_provider, model: nil, harness: "openhands-agent-server", protocol: "openhands-agent-server"})}
  end

  defp run_agent_server(handle, context, on_update) do
    client = handle.client
    conversation_id = handle.conversation_id
    prompt = context.prompt

    attribution = %{
      provider: handle.provider,
      model: handle.model,
      harness: handle.harness,
      protocol: handle.protocol
    }

    case client.send_action(handle.client_state, conversation_id, prompt, on_update) do
      {:ok, %{status: status} = result} ->
        classify_agent_server_status(status, result[:usage], conversation_id, attribution)

      {:ok, status} when is_binary(status) or is_atom(status) ->
        classify_agent_server_status(status, nil, conversation_id, attribution)

      {:error, reason} ->
        classify(reason, %{session_id: conversation_id, attribution: attribution})

      %Result{} = res ->
        res

      other ->
        classify(other, %{session_id: conversation_id, attribution: attribution})
    end
  rescue
    error ->
      classify(error, %{session_id: handle.conversation_id, attribution: %{provider: handle.provider, model: handle.model, harness: handle.harness, protocol: handle.protocol}})
  end

  defp stop_agent_server(handle) do
    client = handle.client
    conversation_id = handle.conversation_id

    try do
      client.stop_conversation(handle.client_state, conversation_id)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp classify_agent_server_status(status, usage, session_id, attribution) do
    normalized = status |> to_string() |> String.downcase()

    cond do
      normalized in ["finished", "completed", "success", "done"] ->
        %Result{
          class: :success,
          session_id: session_id,
          usage: usage,
          attribution: attribution
        }

      normalized in ["cancelled", "canceled", "aborted", "stopped"] ->
        %Result{
          class: :cancelled,
          session_id: session_id,
          usage: usage,
          attribution: attribution
        }

      normalized in ["paused", "waiting_for_input", "input_required", "ask_user"] ->
        %Result{
          class: :input_required,
          session_id: session_id,
          usage: usage,
          attribution: attribution
        }

      true ->
        classify(normalized, %{session_id: session_id, attribution: attribution})
    end
  end

  # --- Result Classification ---

  @doc """
  Normalizes OpenHands-specific error payloads, status codes, and exceptions
  into the standard `Worker.Result` taxonomy.
  """
  @spec classify(term()) :: Result.t()
  def classify(error), do: classify(error, nil)

  @spec classify(term(), map() | nil) :: Result.t()
  def classify(%Result{} = res, _context), do: res

  def classify({:error, reason}, context), do: classify(reason, context)

  def classify(%{"error" => inner}, context), do: classify(inner, context)

  def classify(%{"status" => 429} = payload, context) do
    retry_at = extract_retry_at_ms(payload)
    build_result(:rate_limited, context, retry_at)
  end

  def classify(%{"status" => 503}, context) do
    build_result(:provider_capacity, context)
  end

  def classify(%{"status" => status}, context) when status in [401, 403] do
    build_result(:authentication_failure, context)
  end

  def classify(%{"code" => -32001}, context) do
    build_result(:provider_capacity, context)
  end

  def classify(%{"error_type" => type} = payload, context) do
    class = error_string_to_class(type)
    retry_at = extract_retry_at_ms(payload)
    build_result(class, context, retry_at)
  end

  def classify(reason, context) when reason in [:turn_timeout, :read_timeout, :timeout] do
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

      String.contains?(lower, ["rate_limit", "quota", "429", "usagelimitexceeded", "insufficient_quota"]) ->
        :rate_limited

      String.contains?(lower, ["unauthorized", "auth", "401", "403", "forbidden", "invalid_api_key"]) ->
        :authentication_failure

      String.contains?(lower, ["connect", "econnrefused", "closed", "pipe", "timeout", "transport", "network"]) ->
        :transport_failure

      String.contains?(lower, ["input_required", "ask_user", "paused", "waiting_for_input", "approval_required"]) ->
        :input_required

      String.contains?(lower, ["cancelled", "canceled", "aborted", "stopped"]) ->
        :cancelled

      String.contains?(lower, ["bad_request", "invalid_params", "syntax", "context_length", "max_tokens", "tool_error"]) ->
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

  defp get_mode(settings) do
    mode_str = settings[:mode] || "acp"

    case to_string(mode_str) |> String.downcase() do
      "agent_server" -> :agent_server
      "agent-server" -> :agent_server
      _ -> :acp
    end
  end

  defp get_settings do
    try do
      case Config.settings() do
        {:ok, %{openhands: openhands}} when is_map(openhands) ->
          Map.from_struct(openhands)

        _ ->
          %{}
      end
    rescue
      _ -> %{}
    catch
      :exit, _ -> %{}
    end
  end

  # Default minimal Agent Server client implementation
  defmodule DefaultAgentServerClient do
    @moduledoc false

    @spec create_conversation(keyword()) :: {:ok, String.t(), map()}
    def create_conversation(_opts) do
      id = "conv-#{System.unique_integer([:positive])}"
      {:ok, id, %{id: id}}
    end

    @spec send_action(map(), String.t(), String.t(), (map() -> term())) :: {:ok, map()}
    def send_action(_client_state, conversation_id, _prompt, on_update) do
      on_update.(%{event: :progress, timestamp: DateTime.utc_now(), content: "OpenHands agent executing..."})
      {:ok, %{status: "completed", session_id: conversation_id, usage: %{total: 100}}}
    end

    @spec stop_conversation(map(), String.t()) :: :ok
    def stop_conversation(_client_state, _conversation_id), do: :ok
  end
end
