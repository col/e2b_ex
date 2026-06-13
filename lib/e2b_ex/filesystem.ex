defmodule E2bEx.Filesystem do
  @moduledoc """
  Read, write, and manage files inside a sandbox.

  Like `E2bEx.Commands`, this talks to the sandbox's `envd` daemon, so the
  `sandbox` must carry an `:envd_access_token` (from `E2bEx.Sandboxes.create/2`,
  `connect/3`, or `get/2`); a `list/2`-derived sandbox gets `401` from envd.

  Metadata operations (`list`/`get_info`/`exists`/`make_dir`/`rename`/`remove`)
  use the envd Connect API; file content (`read`/`write`) uses envd's HTTP file
  transfer. All functions accept `:user`, `:timeout_ms`, `:domain`, `:port`, and
  `:base_url` options, as for `E2bEx.Commands`.
  """

  alias E2bEx.{Client, EntryInfo, Error, Sandbox}
  alias E2bEx.Envd.Rpc
  alias E2bEx.Filesystem.{WatchHandle, WatchServer}

  @stat_path "/filesystem.Filesystem/Stat"
  @list_path "/filesystem.Filesystem/ListDir"
  @make_dir_path "/filesystem.Filesystem/MakeDir"
  @move_path "/filesystem.Filesystem/Move"
  @remove_path "/filesystem.Filesystem/Remove"
  @watch_path "/filesystem.Filesystem/WatchDir"

  @doc "List a directory's entries (`ListDir`). `:depth` defaults to 1."
  @spec list(Client.t(), Sandbox.t(), String.t(), keyword()) ::
          {:ok, [EntryInfo.t()]} | {:error, Error.t()}
  def list(%Client{} = client, %Sandbox{} = sandbox, path, opts \\ []) when is_binary(path) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts),
         {:ok, body} <- Rpc.unary(ctx, @list_path, %{path: path, depth: opts[:depth] || 1}) do
      {:ok, Enum.map(Map.get(body, "entries", []), &EntryInfo.from_api/1)}
    end
  end

  @doc "Stat a file or directory (`Stat`)."
  @spec get_info(Client.t(), Sandbox.t(), String.t(), keyword()) ::
          {:ok, EntryInfo.t()} | {:error, Error.t()}
  def get_info(%Client{} = client, %Sandbox{} = sandbox, path, opts \\ []) when is_binary(path) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts),
         {:ok, %{"entry" => entry}} <- Rpc.unary(ctx, @stat_path, %{path: path}) do
      {:ok, EntryInfo.from_api(entry)}
    else
      {:ok, _} -> {:error, %Error{message: "envd Stat response missing entry"}}
      {:error, _} = error -> error
    end
  end

  @doc "Whether a path exists (`Stat`). `{:ok, false}` on a not_found error."
  @spec exists(Client.t(), Sandbox.t(), String.t(), keyword()) ::
          {:ok, boolean()} | {:error, Error.t()}
  def exists(%Client{} = client, %Sandbox{} = sandbox, path, opts \\ []) when is_binary(path) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts) do
      case Rpc.unary(ctx, @stat_path, %{path: path}) do
        {:ok, _} -> {:ok, true}
        {:error, %Error{code: "not_found"}} -> {:ok, false}
        {:error, %Error{status: 404}} -> {:ok, false}
        {:error, _} = error -> error
      end
    end
  end

  @doc "Create a directory (`MakeDir`, recursive). `{:ok, false}` if it already existed."
  @spec make_dir(Client.t(), Sandbox.t(), String.t(), keyword()) ::
          {:ok, boolean()} | {:error, Error.t()}
  def make_dir(%Client{} = client, %Sandbox{} = sandbox, path, opts \\ []) when is_binary(path) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts) do
      case Rpc.unary(ctx, @make_dir_path, %{path: path}) do
        {:ok, _} -> {:ok, true}
        {:error, %Error{code: "already_exists"}} -> {:ok, false}
        {:error, _} = error -> error
      end
    end
  end

  @doc "Move/rename a file or directory (`Move`)."
  @spec rename(Client.t(), Sandbox.t(), String.t(), String.t(), keyword()) ::
          {:ok, EntryInfo.t()} | {:error, Error.t()}
  def rename(%Client{} = client, %Sandbox{} = sandbox, old_path, new_path, opts \\ [])
      when is_binary(old_path) and is_binary(new_path) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts),
         {:ok, %{"entry" => entry}} <-
           Rpc.unary(ctx, @move_path, %{source: old_path, destination: new_path}) do
      {:ok, EntryInfo.from_api(entry)}
    else
      {:ok, _} -> {:error, %Error{message: "envd Move response missing entry"}}
      {:error, _} = error -> error
    end
  end

  @doc "Remove a file or directory (`Remove`)."
  @spec remove(Client.t(), Sandbox.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def remove(%Client{} = client, %Sandbox{} = sandbox, path, opts \\ []) when is_binary(path) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts) do
      case Rpc.unary(ctx, @remove_path, %{path: path}) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  @doc "Read a file's content (`GET /files`). Returns the raw bytes; `\"\"` for an empty file."
  @spec read(Client.t(), Sandbox.t(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, Error.t()}
  def read(%Client{} = client, %Sandbox{} = sandbox, path, opts \\ []) when is_binary(path) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts) do
      Rpc.get_file(ctx, path, opts)
    end
  end

  @doc """
  Write `data` (a binary) to a file (`POST /files`), overwriting if it exists.
  Returns the written entry.
  """
  @spec write(Client.t(), Sandbox.t(), String.t(), binary(), keyword()) ::
          {:ok, EntryInfo.t()} | {:error, Error.t()}
  def write(%Client{} = client, %Sandbox{} = sandbox, path, data, opts \\ [])
      when is_binary(path) and is_binary(data) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts),
         {:ok, infos} <- Rpc.put_file(ctx, path, data, opts) do
      {:ok, write_info(infos)}
    end
  end

  @doc """
  Watch a directory for changes (`WatchDir`), returning a `%E2bEx.Filesystem.WatchHandle{}`.

  Change events are pushed to the subscriber (`opts[:subscriber]`, default the
  caller) as `{handle.ref, {:fs_event, %E2bEx.FilesystemEvent{}}}`, ending with a
  terminal `{handle.ref, {:error, %E2bEx.Error{}}}` if the stream fails or closes.
  Call `E2bEx.Filesystem.WatchHandle.stop/1` to end the watch.

  ## Options
    * `:recursive` — watch subdirectories too (default `false`).
    * `:include_entry` — include the `%EntryInfo{}` of the affected entry in each
      event when available (default `false`).
    * `:subscriber` — pid to receive event messages (default the caller).
    * `:user`, `:timeout_ms`, `:domain`, `:port`, `:base_url` — as for the other
      `E2bEx.Filesystem` functions.
  """
  @spec watch_dir(Client.t(), Sandbox.t(), String.t(), keyword()) ::
          {:ok, WatchHandle.t()} | {:error, Error.t()}
  def watch_dir(%Client{} = client, %Sandbox{} = sandbox, path, opts \\ []) when is_binary(path) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts) do
      request = %{
        path: path,
        recursive: opts[:recursive] || false,
        includeEntry: opts[:include_entry] || false
      }

      spawn_watch(ctx, request, opts)
    end
  end

  defp spawn_watch(ctx, request, opts) do
    ref = make_ref()
    subscriber = opts[:subscriber] || self()

    arg = %{
      ctx: ctx,
      path: @watch_path,
      request: request,
      subscriber: subscriber,
      ref: ref,
      timeout_ms: ctx.timeout_ms
    }

    with {:ok, server} <- WatchServer.start(arg) do
      await = if ctx.timeout_ms == 0, do: :infinity, else: ctx.timeout_ms

      try do
        case GenServer.call(server, :await_start, await) do
          :ok -> {:ok, %WatchHandle{server: server, ref: ref}}
          {:error, error} -> {:error, error}
        end
      catch
        :exit, _ -> {:error, %Error{message: "watch failed to start"}}
      end
    end
  end

  defp write_info([entry | _]) when is_map(entry), do: EntryInfo.from_api(entry)
  defp write_info(_), do: %EntryInfo{}
end
