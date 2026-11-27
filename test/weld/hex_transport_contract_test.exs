defmodule Weld.HexTransportContractTest do
  use ExUnit.Case, async: false
  alias Weld.Core.Identity
  alias Weld.{Error, HTTPFixture}
  alias Weld.Shell.Hex

  test "pinned Hex Core and docs HTTP routes transmit the original body buffers" do
    Application.ensure_all_started(:inets)

    server =
      HTTPFixture.start(fn _ ->
        {201, %{"content-type" => "application/vnd.hex+erlang"}, :erlang.term_to_binary(%{})}
      end)

    on_exit(fn -> HTTPFixture.stop(server) end)

    config =
      :hex_core.default_config()
      |> Map.merge(%{
        api_url: server.url <> "/api",
        api_key: "loopback-test-key",
        weld_loopback: true
      })

    transport = Hex.http_transport(config)

    metadata = %{
      "name" => "transport_probe",
      "version" => "1.0.0",
      "app" => "transport_probe",
      "files" => ["mix.exs"],
      "requirements" => %{}
    }

    {:ok, %{tarball: package}} =
      :hex_tarball.create(metadata, [{~c"mix.exs", "# exact buffer\n"}])

    {:ok, docs} = :hex_tarball.create_docs([{~c"index.html", "<h1>Exact</h1>"}])
    assert {:ok, {201, _, _}} = transport.write.(:package, "transport_probe", "1.0.0", package)
    assert_receive {:http_request, request}
    assert request.method == "POST"
    assert request.path == "/api/packages/transport_probe/releases?replace=false"
    assert request.headers["authorization"] == "loopback-test-key"
    assert request.headers["content-type"] == "application/octet-stream"
    assert request.sha256 == Identity.raw(package)
    assert request.body == package
    assert {:ok, {201, _, _}} = transport.write.(:docs, "transport_probe", "1.0.0", docs)
    assert_receive {:http_request, request}
    assert request.path == "/api/packages/transport_probe/releases/1.0.0/docs"
    assert request.sha256 == Identity.raw(docs)
    assert request.body == docs
  end

  test "credentials in destination URLs and non-loopback HTTP cannot establish trust" do
    for url <- [
          "https://user:secret@hex.pm/api",
          "http://hex.pm/api",
          "https://hex.pm/api?token=secret"
        ] do
      config = Map.put(:hex_core.default_config(), :api_url, url)
      assert_raise Error, ~r/untrusted Hex endpoint/, fn -> Hex.http_transport(config) end
    end
  end

  test "unsupported docs readback never equates a CDN tar to authenticated proof" do
    server =
      HTTPFixture.start(fn _ ->
        {200, %{"content-type" => "application/vnd.hex+erlang"},
         :erlang.term_to_binary(%{"has_docs" => true})}
      end)

    on_exit(fn -> HTTPFixture.stop(server) end)

    config =
      :hex_core.default_config()
      |> Map.merge(%{api_url: server.url <> "/api", api_key: "loopback", weld_loopback: true})

    assert {:ok, %{state: "unknown", authoritative: false}} =
             Hex.http_transport(config).read.(:docs, "probe", "1.0.0")
  end
end
