defmodule E2bEx.Pty do
  @moduledoc """
  Run an interactive pseudo-terminal (PTY) inside a running sandbox.

  Like `E2bEx.Commands`, this talks directly to the sandbox's `envd` daemon over
  the Connect protocol. `create/3` launches an interactive login shell
  (`/bin/bash -i -l`) attached to a PTY of the given size; you drive it by sending
  input, and merged terminal output arrives as messages:

      {:ok, h} = E2bEx.Pty.create(client, sandbox, cols: 80, rows: 24)
      receive do
        {ref, {:pty, data}} when ref == h.ref -> IO.binwrite(data)
      end
      :ok = E2bEx.Pty.Handle.send_input(h, "ls\\r")
      :ok = E2bEx.Pty.Handle.resize(h, %{cols: 120, rows: 40})

  Output is delivered to the subscriber (`opts[:subscriber]`, default the caller)
  as `{handle.ref, {:pty, binary}}`, ending with a terminal
  `{handle.ref, {:exit, %E2bEx.CommandResult{}}}` (any exit code) or
  `{handle.ref, {:error, %E2bEx.Error{}}}`. Use the message stream or
  `E2bEx.Pty.Handle.wait/1`.

  As with `E2bEx.Commands`, the `sandbox` must carry an `:envd_access_token`
  (from `E2bEx.Sandboxes.create/2`, `connect/3`, or `get/2`); a `list/2`-derived
  sandbox will get `401` from envd.
  """

  alias E2bEx.{Client, Error, Sandbox}
  alias E2bEx.Commands.HandleServer
  alias E2bEx.Envd.Rpc
  alias E2bEx.Pty.Handle

  @start_path "/process.Process/Start"
  @connect_path "/process.Process/Connect"

  @default_envs %{
    "TERM" => "xterm-256color",
    "LANG" => "C.UTF-8",
    "LC_ALL" => "C.UTF-8"
  }

  @doc """
  Create a PTY-backed interactive shell (`/bin/bash -i -l`) and return a handle.

  ## Options
    * `:cols`, `:rows` — terminal size (**required**, integers). Missing either
      raises `ArgumentError`.
    * `:envs` — environment variables merged over the terminal defaults
      (`TERM=xterm-256color`, `LANG=C.UTF-8`, `LC_ALL=C.UTF-8`); caller values win.
    * `:cwd` — working directory.
    * `:user` — Linux user to run as (adds an `Authorization: Basic` header).
    * `:subscriber` — pid to receive output messages (default the caller).
    * `:timeout_ms`, `:domain`, `:port`, `:base_url` — as for `E2bEx.Commands.run/4`.
  """
  @spec create(Client.t(), Sandbox.t(), keyword()) :: {:ok, Handle.t()} | {:error, Error.t()}
  def create(%Client{} = client, %Sandbox{} = sandbox, opts \\ []) do
    {cols, rows} = fetch_size!(opts)

    with {:ok, ctx} <- Rpc.context(client, sandbox, opts) do
      spawn_handle(ctx, @start_path, create_request(cols, rows, opts), opts)
    end
  end

  @doc """
  Reconnect to a running PTY by `pid` and return a handle that streams its output
  (`/process.Process/Connect`). Options: `:subscriber`, `:timeout_ms`, `:domain`,
  `:port`, `:base_url`.
  """
  @spec connect(Client.t(), Sandbox.t(), non_neg_integer(), keyword()) ::
          {:ok, Handle.t()} | {:error, Error.t()}
  def connect(%Client{} = client, %Sandbox{} = sandbox, pid, opts \\ []) when is_integer(pid) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts) do
      spawn_handle(ctx, @connect_path, %{process: %{pid: pid}}, opts)
    end
  end

  # ---- request building ----

  defp fetch_size!(opts) do
    cols = Keyword.get(opts, :cols)
    rows = Keyword.get(opts, :rows)

    unless is_integer(cols) and is_integer(rows) do
      raise ArgumentError, "E2bEx.Pty.create/3 requires integer :cols and :rows options"
    end

    {cols, rows}
  end

  defp create_request(cols, rows, opts) do
    envs = Map.merge(@default_envs, opts[:envs] || %{})

    process =
      %{cmd: "/bin/bash", args: ["-i", "-l"], envs: envs}
      |> put_present(:cwd, opts[:cwd])

    %{process: process, pty: %{size: %{cols: cols, rows: rows}}}
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # Spawn a HandleServer for the stream and wrap the result in a %Pty.Handle{}.
  # Mirrors E2bEx.Commands' private spawn_handle deliberately (PTY-only scope —
  # sharing is left to a later cleanup pass).
  defp spawn_handle(ctx, path, request, opts) do
    ref = make_ref()
    subscriber = opts[:subscriber] || self()

    arg = %{
      ctx: ctx,
      path: path,
      request: request,
      subscriber: subscriber,
      ref: ref,
      timeout_ms: ctx.timeout_ms
    }

    with {:ok, server} <- HandleServer.start(arg) do
      await = if ctx.timeout_ms == 0, do: :infinity, else: ctx.timeout_ms

      try do
        case GenServer.call(server, :await_start, await) do
          {:ok, pid} -> {:ok, %Handle{server: server, ref: ref, pid: pid, context: ctx}}
          {:error, error} -> {:error, error}
        end
      catch
        :exit, _ -> {:error, %Error{message: "pty failed to start"}}
      end
    end
  end
end
