defmodule SymphonyElixir.Codex.WorkspaceGit do
  @moduledoc """
  Narrow client-side Git mutations for an issue workspace.

  Codex workspace-write deliberately keeps repository Git metadata read-only.
  This bridge lets the orchestrator perform the small set of Git mutations an
  autonomous worker needs without exposing an arbitrary shell escape.
  """

  alias SymphonyElixir.{Config, PathSafety, Workspace}

  @tool_name "workspace_git"
  @operations ["ensure_branch", "commit", "push"]
  @max_message_bytes 20_000
  @max_output_bytes 8_000

  @spec tool_name?(term()) :: boolean()
  def tool_name?(tool), do: tool == @tool_name

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @tool_name,
        "description" => """
        Perform allowlisted Git mutations in the current Symphony issue workspace.
        Use this instead of `git switch`, `git commit`, or `git push` when Codex is
        running with the workspace-write sandbox. Supported operations are:
        `ensure_branch`, `commit`, and `push`. This tool never accepts arbitrary
        shell commands, remotes, repository paths, or force-push options.
        """,
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["operation"],
          "properties" => %{
            "operation" => %{
              "type" => "string",
              "enum" => @operations,
              "description" => "Allowlisted Git operation."
            },
            "branch" => %{
              "type" => ["string", "null"],
              "description" => "Branch for `ensure_branch`."
            },
            "message" => %{
              "type" => ["string", "null"],
              "description" => "Commit message for `commit`."
            },
            "paths" => %{
              "type" => ["array", "null"],
              "items" => %{"type" => "string"},
              "description" => "Explicit repository-relative paths to stage for `commit`."
            }
          }
        }
      }
    ]
  end

  @spec execute(term(), keyword()) :: map()
  def execute(arguments, opts \\ []) do
    with {:ok, issue} <- issue_from_opts(opts),
         {:ok, workspace} <- workspace_for_issue(issue),
         {:ok, operation} <- operation(arguments) do
      operation
      |> execute_operation(arguments, workspace)
      |> response()
    else
      {:error, reason} -> failure(reason)
    end
  end

  defp execute_operation("ensure_branch", arguments, workspace) do
    with {:ok, branch} <- required_string(arguments, "branch"),
         :ok <- validate_branch(workspace, branch),
         {:ok, current} <- current_branch(workspace) do
      cond do
        current == branch ->
          {:ok, %{"operation" => "ensure_branch", "branch" => branch, "changed" => false}}

        local_branch?(workspace, branch) ->
          with {:ok, _output} <- git(workspace, ["switch", branch]) do
            {:ok, %{"operation" => "ensure_branch", "branch" => branch, "changed" => true}}
          end

        remote_tracking_branch?(workspace, branch) ->
          with {:ok, _output} <- git(workspace, ["switch", "--track", "-c", branch, "origin/#{branch}"]) do
            {:ok, %{"operation" => "ensure_branch", "branch" => branch, "changed" => true}}
          end

        true ->
          with {:ok, _output} <- git(workspace, ["switch", "-c", branch]) do
            {:ok, %{"operation" => "ensure_branch", "branch" => branch, "changed" => true}}
          end
      end
    end
  end

  defp execute_operation("commit", arguments, workspace) do
    with {:ok, message} <- commit_message(arguments),
         {:ok, paths} <- commit_paths(arguments),
         {:ok, _output} <- git(workspace, ["add", "--" | paths]),
         :ok <- ensure_staged_changes(workspace),
         {:ok, output} <-
           git(workspace, ["-c", "core.hooksPath=/dev/null", "commit", "-m", message]),
         {:ok, commit} <- git(workspace, ["rev-parse", "HEAD"]) do
      {:ok,
       %{
         "operation" => "commit",
         "commit" => String.trim(commit),
         "paths" => paths,
         "output" => truncate(output)
       }}
    end
  end

  defp execute_operation("push", _arguments, workspace) do
    with {:ok, branch} <- current_branch(workspace),
         :ok <- validate_branch(workspace, branch),
         :ok <- reject_default_branch_push(workspace, branch),
         {:ok, output} <-
           git(workspace, ["push", "--set-upstream", "origin", "HEAD:refs/heads/#{branch}"]) do
      {:ok,
       %{
         "operation" => "push",
         "branch" => branch,
         "output" => truncate(output)
       }}
    end
  end

  defp execute_operation(_operation, _arguments, _workspace), do: {:error, :invalid_operation}

  defp issue_from_opts(opts) do
    case Keyword.get(opts, :issue) do
      %{identifier: identifier} = issue when is_binary(identifier) and identifier != "" -> {:ok, issue}
      _ -> {:error, :missing_issue}
    end
  end

  defp workspace_for_issue(issue) do
    root = Config.local_workspace_root()
    candidate = Path.join(root, Workspace.workspace_key(issue))

    with {:ok, canonical_root} <- PathSafety.canonicalize(root),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(candidate),
         true <- String.starts_with?(canonical_workspace <> "/", canonical_root <> "/"),
         true <- File.dir?(canonical_workspace),
         true <- File.exists?(Path.join(canonical_workspace, ".git")) do
      {:ok, canonical_workspace}
    else
      false -> {:error, :invalid_workspace}
      {:error, reason} -> {:error, {:invalid_workspace, reason}}
    end
  end

  defp operation(arguments) when is_map(arguments) do
    case Map.get(arguments, "operation") do
      operation when operation in @operations -> {:ok, operation}
      _ -> {:error, :invalid_operation}
    end
  end

  defp operation(_arguments), do: {:error, :invalid_arguments}

  defp required_string(arguments, key) when is_map(arguments) do
    case Map.get(arguments, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed != "" and not String.contains?(trimmed, ["\n", "\r", <<0>>]) do
          {:ok, trimmed}
        else
          {:error, {:invalid_string, key}}
        end

      _ ->
        {:error, {:invalid_string, key}}
    end
  end

  defp commit_message(arguments) do
    with {:ok, message} <- required_string(arguments, "message"),
         true <- byte_size(message) <= @max_message_bytes do
      {:ok, message}
    else
      false -> {:error, :commit_message_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit_paths(arguments) when is_map(arguments) do
    case Map.get(arguments, "paths") do
      paths when is_list(paths) and paths != [] ->
        if Enum.all?(paths, &safe_relative_path?/1) do
          {:ok, Enum.uniq(paths)}
        else
          {:error, :invalid_paths}
        end

      _ ->
        {:error, :invalid_paths}
    end
  end

  defp safe_relative_path?(path) when is_binary(path) do
    path != "" and path != "." and Path.type(path) == :relative and
      not String.contains?(path, ["\n", "\r", <<0>>]) and
      ".." not in Path.split(path) and ".git" not in Path.split(path)
  end

  defp safe_relative_path?(_path), do: false

  defp validate_branch(workspace, branch) do
    case git(workspace, ["check-ref-format", "--branch", branch]) do
      {:ok, _output} -> :ok
      {:error, _reason} -> {:error, :invalid_branch}
    end
  end

  defp current_branch(workspace) do
    with {:ok, branch} <- git(workspace, ["branch", "--show-current"]),
         branch = String.trim(branch),
         true <- branch != "" do
      {:ok, branch}
    else
      false -> {:error, :detached_head}
      {:error, reason} -> {:error, reason}
    end
  end

  defp local_branch?(workspace, branch) do
    match?({:ok, _}, git(workspace, ["show-ref", "--verify", "refs/heads/#{branch}"]))
  end

  defp remote_tracking_branch?(workspace, branch) do
    match?({:ok, _}, git(workspace, ["show-ref", "--verify", "refs/remotes/origin/#{branch}"]))
  end

  defp ensure_staged_changes(workspace) do
    case System.cmd("git", ["diff", "--cached", "--quiet", "--exit-code"],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {_output, 1} -> :ok
      {_output, 0} -> {:error, :nothing_to_commit}
      {output, status} -> {:error, {:git_failed, status, truncate(output)}}
    end
  end

  defp reject_default_branch_push(workspace, branch) do
    fallback_defaults = ["main", "master"]

    defaults =
      case git(workspace, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]) do
        {:ok, remote_ref} ->
          remote_ref
          |> String.trim()
          |> String.replace_prefix("origin/", "")
          |> then(&[&1 | fallback_defaults])

        {:error, _reason} ->
          fallback_defaults
      end

    if branch in defaults, do: {:error, :default_branch_push_forbidden}, else: :ok
  end

  defp git(workspace, args) do
    case System.cmd("git", args,
           cd: workspace,
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}]
         ) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, status, truncate(output)}}
    end
  rescue
    error in ErlangError -> {:error, {:git_unavailable, Exception.message(error)}}
  end

  defp response({:ok, payload}), do: dynamic_response(true, payload)
  defp response({:error, reason}), do: failure(reason)

  defp failure(reason) do
    dynamic_response(false, %{"error" => error_payload(reason)})
  end

  defp dynamic_response(success, payload) do
    output = Jason.encode!(payload, pretty: true)

    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp error_payload(:missing_issue), do: %{"message" => "`workspace_git` requires the current issue context."}
  defp error_payload(:invalid_workspace), do: %{"message" => "The current issue workspace is missing or invalid."}
  defp error_payload({:invalid_workspace, reason}), do: %{"message" => "The current issue workspace is invalid.", "reason" => inspect(reason)}
  defp error_payload(:invalid_arguments), do: %{"message" => "`workspace_git` expects a JSON object."}
  defp error_payload(:invalid_operation), do: %{"message" => "`workspace_git.operation` must be ensure_branch, commit, or push."}
  defp error_payload({:invalid_string, key}), do: %{"message" => "`workspace_git.#{key}` must be a non-empty single-line string."}
  defp error_payload(:commit_message_too_large), do: %{"message" => "Commit message exceeds the workspace Git safety limit."}
  defp error_payload(:invalid_paths), do: %{"message" => "`workspace_git.paths` must contain explicit safe repository-relative paths; `.` and `.git` are forbidden."}
  defp error_payload(:invalid_branch), do: %{"message" => "Branch name is not a valid Git branch."}
  defp error_payload(:detached_head), do: %{"message" => "Workspace is in detached HEAD state."}
  defp error_payload(:nothing_to_commit), do: %{"message" => "No staged changes remain after adding the requested paths."}
  defp error_payload(:default_branch_push_forbidden), do: %{"message" => "`workspace_git` refuses to push the repository default branch."}
  defp error_payload({:git_failed, status, output}), do: %{"message" => "Git command failed.", "status" => status, "output" => output}
  defp error_payload({:git_unavailable, reason}), do: %{"message" => "Git executable is unavailable.", "reason" => reason}
  defp error_payload(reason), do: %{"message" => "Workspace Git operation failed.", "reason" => inspect(reason)}

  defp truncate(output) when is_binary(output) and byte_size(output) <= @max_output_bytes, do: output
  defp truncate(output) when is_binary(output), do: binary_part(output, 0, @max_output_bytes) <> "... (truncated)"
end
