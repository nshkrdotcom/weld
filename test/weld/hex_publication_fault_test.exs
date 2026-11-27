defmodule Weld.HexPublicationFaultTest do
  use ExUnit.Case, async: true
  alias Weld.Core.Identity
  alias Weld.{Error, FixtureCase, HTTPFixture}
  alias Weld.Shell.Hex

  test "a known pre-send failure is retryable and does not submit docs" do
    {selector, bundle} = fixture!()
    {:ok, remote} = Agent.start_link(fn -> %{attempts: 0, bytes: %{}} end)

    transport =
      fake_transport(remote, fn part, bytes ->
        attempt = Agent.get_and_update(remote, &{&1.attempts, %{&1 | attempts: &1.attempts + 1}})

        if attempt == 0 do
          {:error, :not_sent}
        else
          Agent.update(remote, &put_in(&1.bytes[part], bytes))
          {:ok, {201, %{}, %{}}}
        end
      end)

    assert %{state: "not_sent"} =
             Hex.publish!(selector, bundle.bundle_path, bundle.metadata,
               yes: true,
               transport: transport
             )

    assert Agent.get(remote, & &1.attempts) == 1

    assert %{state: "confirmed"} =
             Hex.publish!(selector, bundle.bundle_path, bundle.metadata,
               yes: true,
               transport: transport
             )

    assert Agent.get(remote, & &1.attempts) == 3
  end

  test "a real HTTP close after received package bytes is unknown and cannot repeat" do
    {selector, bundle} = fixture!()
    server = HTTPFixture.start(fn _ -> :close end)
    on_exit(fn -> HTTPFixture.stop(server) end)

    config =
      :hex_core.default_config()
      |> Map.merge(%{api_url: server.url <> "/api", api_key: "loopback", weld_loopback: true})

    transport = %{
      Hex.http_transport(config)
      | read: fn _, _, _ -> {:ok, %{state: "absent", authoritative: true}} end
    }

    opts = [yes: true, transport: transport]
    assert %{state: "unknown"} = Hex.publish!(selector, bundle.bundle_path, bundle.metadata, opts)
    assert_receive {:http_request, request}
    assert request.sha256 == bundle.metadata["archive_sha256"]

    assert_raise Error, ~r/unresolved/, fn ->
      Hex.publish!(selector, bundle.bundle_path, bundle.metadata, opts)
    end

    refute_receive {:http_request, _}
    latest = Hex.local_status(selector, bundle.bundle_path, bundle.metadata, opts)
    assert latest["package_state"] == "unknown"
    assert latest["docs_state"] == "not_sent"
  end

  test "staging persists, reconciliation only queries, then docs continue without package reupload" do
    {selector, bundle} = fixture!()
    {:ok, remote} = Agent.start_link(fn -> %{bytes: %{}, attempts: []} end)
    destination = "http://127.0.0.1:56789"

    transport =
      fake_transport(remote, fn part, bytes ->
        Agent.update(remote, &%{&1 | attempts: &1.attempts ++ [part]})

        case part do
          :package ->
            {:ok,
             {202, %{"location" => destination <> "/api/staged/one"}, %{"status" => "staged"}}}

          :docs ->
            Agent.update(remote, &put_in(&1, [:bytes, :docs], bytes))
            {:ok, {201, %{}, %{}}}
        end
      end)
      |> Map.put(:read_staged, fn _ -> {:ok, {200, %{}, %{"status" => "staged"}}} end)

    plain_read = transport.read

    transport = %{
      transport
      | read: fn part, name, version ->
          staged? = Agent.get(remote, &(:package in &1.attempts and is_nil(&1.bytes[:package])))

          if part == :package and staged?,
            do: {:ok, %{state: "unknown", authoritative: false}},
            else: plain_read.(part, name, version)
        end
    }

    opts = [yes: true, transport: transport]
    assert %{state: "staged"} = Hex.publish!(selector, bundle.bundle_path, bundle.metadata, opts)

    assert_raise Error, ~r/unresolved/, fn ->
      Hex.publish!(selector, bundle.bundle_path, bundle.metadata, opts)
    end

    read_only = %{
      transport
      | write: fn _, _, _, _ -> flunk("reconciliation must never upload") end
    }

    assert %{state: "staged"} =
             Hex.reconcile!(selector, bundle.bundle_path, bundle.metadata, transport: read_only)

    Agent.update(remote, &put_in(&1, [:bytes, :package], File.read!(bundle.tarball_path)))

    assert %{state: "not_sent"} =
             Hex.reconcile!(selector, bundle.bundle_path, bundle.metadata, transport: read_only)

    assert %{state: "confirmed"} =
             Hex.publish!(selector, bundle.bundle_path, bundle.metadata, opts)

    assert Agent.get(remote, & &1.attempts) == [:package, :docs]
  end

  test "conflicting trusted digests block every write and URL-bearing observations never leak secrets" do
    {selector, bundle} = fixture!()

    transport = %{
      read: fn _, _, _ ->
        {:ok,
         %{
           state: "confirmed",
           authoritative: true,
           sha256: Identity.raw("other"),
           source: "https://user:secret@host/?token=private"
         }}
      end,
      write: fn _, _, _, _ -> flunk("conflict must not upload") end,
      trust: trust()
    }

    assert_raise Error, ~r/conflicting/, fn ->
      Hex.publish!(selector, bundle.bundle_path, bundle.metadata, yes: true, transport: transport)
    end

    status = Hex.status(selector, bundle.bundle_path, bundle.metadata, transport: transport)
    refute inspect(status) =~ "secret"
    refute inspect(status) =~ "private"
    assert status.remote["package"]["state"] == "conflict"
  end

  test "unsafe verification policy and unqualified production transport cannot authorize writes" do
    for key <- [:repo_verify, :repo_verify_origin] do
      config = Map.put(:hex_core.default_config(), key, false)
      assert_raise Error, ~r/unsafe Hex/, fn -> Hex.http_transport(config) end
    end

    {selector, bundle} = fixture!()

    transport = %{
      read: fn _, _, _ -> flunk("unqualified transport must fail before querying") end,
      write: fn _, _, _, _ -> flunk("unqualified transport must never upload") end,
      trust: %{
        trust()
        | destination: "https://private.example.test/api",
          conformance: :unqualified
      }
    }

    assert_raise Error, ~r/writes disabled/, fn ->
      Hex.publish!(selector, bundle.bundle_path, bundle.metadata, yes: true, transport: transport)
    end
  end

  defp fixture! do
    root = FixtureCase.copy_fixture("library_bundle")
    FixtureCase.init_git!(root)
    manifest = Path.join(root, "packaging/weld/fixture_bundle.exs")
    bundle = FixtureCase.write_tracking_fixture!(root, manifest, hex: true)
    {%{repo_root: root, artifact: "fixture_bundle"}, bundle}
  end

  defp fake_transport(remote, write) do
    %{
      trust: trust(),
      read: fn part, _, _ ->
        case Agent.get(remote, & &1.bytes[part]) do
          nil ->
            {:ok, %{state: "absent", authoritative: true}}

          bytes ->
            {:ok,
             %{
               state: "confirmed",
               authoritative: true,
               sha256: Identity.raw(bytes),
               source: "loopback_fixture"
             }}
        end
      end,
      write: fn part, _, _, bytes -> write.(part, bytes) end
    }
  end

  defp trust,
    do: %{
      authenticated: true,
      authoritative: true,
      destination: "http://127.0.0.1:56789",
      adapter: "hex_core/0.21.1",
      conformance: :loopback
    }
end
