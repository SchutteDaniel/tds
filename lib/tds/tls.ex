defmodule Tds.Tls do
  @moduledoc false
  use GenServer

  require Logger

  import Kernel, except: [send: 2]
  import Tds.BinaryUtils

  @default_ssl_opts [active: false, cb_info: {Tds.Tls, :tcp, :tcp_closed, :tcp_error}]

  defstruct [:socket, :ssl_opts, :owner_pid, :handshake?, :buffer]

  def connect(socket, ssl_opts) do
    ssl_opts = ssl_opts ++ @default_ssl_opts
    :inet.setopts(socket, active: false)

    with {:ok, pid} <- GenServer.start_link(__MODULE__, {socket, ssl_opts}, []),
         :ok <- :gen_tcp.controlling_process(socket, pid) do
      connection_result = :ssl.connect(socket, ssl_opts, :infinity)

      # Check if ssl connection was established successfully
      if elem(connection_result, 0) == :ok do
        GenServer.cast(pid, :handshake_complete)
      end

      connection_result
    else
      error -> error
    end
  end

  def controlling_process(socket, tls_conn_pid) do
    socket
    |> assert_connected!()
    |> GenServer.call({:controlling_process, tls_conn_pid})
  end

  def send(socket, payload) do
    try do
      socket
      |> assert_connected!()
      |> GenServer.call({:send, payload})
    catch
      :exit, {:noproc, _} -> {:error, :closed}
      :exit, {:normal, _} -> {:error, :closed}
      :exit, reason -> {:error, reason}
    end
  end

  def recv(socket, length, timeout \\ :infinity) do
    try do
      socket
      |> assert_connected!()
      |> GenServer.call({:recv, length, timeout}, timeout)
    catch
      :exit, {:noproc, _} -> {:error, :closed}
      :exit, {:normal, _} -> {:error, :closed}
      :exit, reason -> {:error, reason}
    end
  end

  defdelegate getopts(port, options), to: :inet

  # defdelegate setopts(socket, options), to: :inet
  def setopts(socket, options) do
    try do
      socket
      |> assert_connected!()
      |> GenServer.call({:setopts, options})
    catch
      :exit, {:noproc, _} -> {:error, :closed}
      :exit, {:normal, _} -> {:error, :closed}
      :exit, reason -> {:error, reason}
    end
  end

  defdelegate peername(socket), to: :inet

  :exports
  |> :gen_tcp.module_info()
  |> Enum.reject(fn {fun, arity} ->
    fun in [:send, :recv, :module_info, :controlling_process] or (fun == :connect and arity == 2)
  end)
  |> Enum.each(fn
    {name, 0} ->
      defdelegate unquote(name)(), to: :gen_tcp

    {name, 1} ->
      defdelegate unquote(name)(arg1), to: :gen_tcp

    {name, 2} ->
      defdelegate unquote(name)(arg1, arg2), to: :gen_tcp

    {name, 3} ->
      defdelegate unquote(name)(arg1, arg2, arg3), to: :gen_tcp

    {name, 4} ->
      defdelegate unquote(name)(arg1, arg2, arg3, arg4), to: :gen_tcp
  end)

  # Asserts that the port / socket is still open and returns its `pid`
  defp assert_connected!(socket) do
    case Port.info(socket, :connected) do
      {:connected, pid} -> pid
      nil -> raise "Port is not connected"
    end
  end

  # SERVER
  def init({socket, ssl_opts}) do
    {:ok, %__MODULE__{socket: socket, ssl_opts: ssl_opts, handshake?: true}}
  end

  def handle_call({:controlling_process, tls_conn_pid}, _from, s) do
    {:reply, :ok, %{s | owner_pid: tls_conn_pid}}
  end

  def handle_call({:setopts, options}, _from, %{socket: socket, handshake?: hs} = s) do
    tds_header_size = if hs == true, do: 8, else: 0

    opts =
      options
      |> Enum.map(fn
        {:active, val} when is_number(val) -> {:active, val + tds_header_size}
        val -> val
      end)

    {:reply, :inet.setopts(socket, opts), s}
  end

  def handle_call({:send, data}, _from, %{socket: socket, handshake?: true} = s) do
    try do
      size = IO.iodata_length(data) + 8
      header = <<0x12, 0x01, size::unsigned-size(2)-unit(8), 0x00, 0x00, 0x00, 0x00>>
      resp = :gen_tcp.send(socket, [header, data])
      {:reply, resp, s}
    catch
      :error, :closed -> {:reply, {:error, :closed}, s}
      :error, :enotconn -> {:reply, {:error, :closed}, s}
      :error, reason -> {:reply, {:error, reason}, s}
    end
  end

  def handle_call({:send, data}, _from, %{socket: socket, handshake?: false} = s) do
    try do
      resp = :gen_tcp.send(socket, data)
      {:reply, resp, s}
    catch
      :error, :closed -> {:reply, {:error, :closed}, s}
      :error, :enotconn -> {:reply, {:error, :closed}, s}
      :error, reason -> {:reply, {:error, reason}, s}
    end
  end

  def handle_call({:recv, length, timeout}, _from, %{socket: socket} = s) do
    try do
      res = :gen_tcp.recv(socket, length, timeout)
      {:reply, res, s}
    catch
      :error, :closed -> {:reply, {:error, :closed}, s}
      :error, :enotconn -> {:reply, {:error, :closed}, s}
      :error, reason -> {:reply, {:error, reason}, s}
    end
  end

  def handle_cast(:handshake_complete, s), do: {:noreply, %{s | handshake?: false}}

  def handle_info({:tcp, _, _} = msg, %{owner_pid: pid, handshake?: false, buffer: nil} = s) do
    Kernel.send(pid, msg)
    {:noreply, s}
  end

  def handle_info(
        {:tcp, port, <<0x12, 0, size::unsigned-16, _::32, tail::binary>>},
        %{socket: socket, owner_pid: pid, buffer: nil, handshake?: true} = s
      ) do
    expecting = size - 8

    case tail do
      <<ssl_payload::binary(expecting), next_packet::binary>> ->
        Kernel.send(pid, {:tcp, socket, ssl_payload})
        handle_info({:tcp, port, next_packet}, %{s | buffer: nil})

      next_slice ->
        state = %{s | buffer: {next_slice, expecting}}
        {:noreply, state}
    end
  end

  def handle_info(
        {:tcp, port, <<0x12, 1, size::unsigned-16, _::32, tail::binary>>},
        %{socket: socket, owner_pid: pid, buffer: nil, handshake?: true} = s
      ) do
    expecting = size - 8

    case tail do
      <<ssl_payload::binary(expecting), next_packet::binary>> ->
        Kernel.send(pid, {:tcp, socket, ssl_payload})
        handle_info({:tcp, port, next_packet}, %{s | buffer: nil})

      next_slice ->
        state = %{s | buffer: {next_slice, expecting}}
        {:noreply, state}
    end
  end

  def handle_info(
        {:tcp, port, bin},
        %{socket: socket, owner_pid: pid, buffer: {slice, expecting}, handshake?: true} = s
      ) do
    case IO.iodata_to_binary([slice, bin]) do
      <<ssl_payload::binary(expecting), next_packet::binary>> ->
        Kernel.send(pid, {:tcp, socket, ssl_payload})
        handle_info({:tcp, port, next_packet}, %{s | buffer: nil})

      next_slice ->
        state = %{s | buffer: {next_slice, expecting}}
        {:noreply, state}
    end
  end

  def handle_info({:tcp, _, _} = msg, %{owner_pid: pid, handshake?: true, buffer: nil} = s) do
    Kernel.send(pid, msg)
    {:noreply, s}
  end

  def handle_info(
        {:tcp_passive, _port} = msg,
        %{owner_pid: pid, handshake?: false, buffer: nil} = s
      ) do
    Kernel.send(pid, msg)
    {:noreply, s}
  end

  def handle_info({:tcp_closed, _} = msg, %{owner_pid: pid} = s) do
    if pid, do: Kernel.send(pid, msg)
    {:stop, :normal, s}
  end

  def handle_info({:tcp_error, _, reason} = msg, %{owner_pid: pid} = s) do
    if pid, do: Kernel.send(pid, msg)
    {:stop, reason, s}
  end
end
