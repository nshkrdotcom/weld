defmodule Weld.HTTPFixture do
  @moduledoc false

  alias Weld.Core.Identity

  def start(handler) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        ip: {127, 0, 0, 1},
        reuseaddr: true
      ])

    {:ok, {_, port}} = :inet.sockname(listener)
    owner = self()
    server = spawn_link(fn -> accept(listener, owner, handler) end)
    %{listener: listener, server: server, url: "http://127.0.0.1:#{port}"}
  end

  def stop(server) do
    :gen_tcp.close(server.listener)
    if Process.alive?(server.server), do: Process.exit(server.server, :normal)
    :ok
  end

  defp accept(listener, owner, handler) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        request = request!(socket, "")
        send(owner, {:http_request, request})

        case handler.(request) do
          :close ->
            :ok

          {status, headers, body} ->
            headers =
              Map.merge(
                %{"content-length" => to_string(byte_size(body)), "connection" => "close"},
                headers
              )

            lines = Enum.map_join(headers, "\r\n", fn {name, value} -> name <> ": " <> value end)

            :ok =
              :gen_tcp.send(
                socket,
                "HTTP/1.1 #{status} Fixture\r\n" <> lines <> "\r\n\r\n" <> body
              )
        end

        :gen_tcp.close(socket)
        accept(listener, owner, handler)

      {:error, :closed} ->
        :ok
    end
  end

  defp request!(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [head, rest] ->
        if byte_size(head) > 32_768, do: raise("request headers too large")
        [line | lines] = String.split(head, "\r\n")
        [method, path, _version] = String.split(line, " ")

        headers =
          Map.new(lines, fn line ->
            [key, value] = String.split(line, ":", parts: 2)
            {String.downcase(key), String.trim(value)}
          end)

        length = String.to_integer(headers["content-length"] || "0")
        if length > 32 * 1024 * 1024, do: raise("request too large")
        body = body!(socket, rest, length)

        %{
          method: method,
          path: path,
          headers: headers,
          body: body,
          sha256: Identity.raw(body)
        }

      [_] ->
        if byte_size(bytes) > 32_768, do: raise("request headers too large")
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 5000)
        request!(socket, bytes <> chunk)
    end
  end

  defp body!(_socket, bytes, size) when byte_size(bytes) == size, do: bytes

  defp body!(socket, bytes, size) when byte_size(bytes) < size do
    {:ok, chunk} = :gen_tcp.recv(socket, size - byte_size(bytes), 5000)
    body!(socket, bytes <> chunk, size)
  end
end
