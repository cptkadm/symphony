defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Dispatches client-side tool calls to the configured tracker adapter.
  """

  alias SymphonyElixir.Codex.WorkspaceGit
  alias SymphonyElixir.GitHub.Adapter, as: GitHubAdapter
  alias SymphonyElixir.Tracker

  @spec execute(String.t() | nil, term(), map(), keyword()) :: map()
  def execute(tool, arguments, binding, opts \\ []) do
    if workspace_git_enabled?(binding) and WorkspaceGit.tool_name?(tool) do
      WorkspaceGit.execute(arguments, opts)
    else
      Tracker.execute_bound_agent_tool(binding, tool, arguments, opts)
    end
  end

  @spec bind() :: map()
  def bind do
    binding = Tracker.bind_agent_tools()

    if workspace_git_enabled?(binding) do
      Map.update!(binding, :tool_specs, &(&1 ++ WorkspaceGit.tool_specs()))
    else
      binding
    end
  end

  defp workspace_git_enabled?(%{adapter: GitHubAdapter}), do: true
  defp workspace_git_enabled?(_binding), do: false
end
