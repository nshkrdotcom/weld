defmodule Weld.MonolithOtpAppIdentityTest do
  use ExUnit.Case, async: false

  alias Weld.{Commands, Error, FixtureCase, Plan}

  setup do
    root = FixtureCase.copy_fixture("monolith_bundle")
    manifest = Path.join(root, "packaging/weld/monolith_bundle.exs")

    File.write!(
      manifest,
      manifest
      |> File.read!()
      |> String.replace("otp_app: :monolith_bundle", "otp_app: :fixture_api")
    )

    %{root: root, manifest: manifest}
  end

  test "allows Application.app_dir/2 for the surviving monolith OTP app in runtime and tests after relocation",
       %{root: root, manifest: manifest} do
    asset_relative = "priv/static/exam_bundle.js"
    asset_bytes = "window.__EXAM_READY__ = true;\n"
    asset_source = Path.join([root, "runtime/api", asset_relative])
    File.mkdir_p!(Path.dirname(asset_source))
    File.write!(asset_source, asset_bytes)

    File.write!(
      Path.join(root, "runtime/api/lib/fixture/api/application.ex"),
      """
      defmodule Fixture.Api.Application do
        @moduledoc false
        use Application

        def start(_type, _args) do
          path = Application.app_dir(:fixture_api, #{inspect(asset_relative)})

          unless File.regular?(path) do
            raise "missing packaged monolith asset at startup: \#{path}"
          end

          Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__.Supervisor)
        end
      end
      """
    )

    File.write!(
      Path.join(root, "runtime/api/lib/fixture/api.ex"),
      """
      defmodule Fixture.Api do
        @moduledoc false

        def source do
          {Fixture.Store.source(), Application.get_env(:fixture_api, :source)}
        end

        def read_asset! do
          path = Application.app_dir(:fixture_api, #{inspect(asset_relative)})
          piped_path = :fixture_api |> Application.app_dir(#{inspect(asset_relative)})
          assert_equal!(path, piped_path)
          File.read!(path)
        end

        defp assert_equal!(same, same), do: :ok
      end
      """
    )

    File.write!(
      Path.join(root, "runtime/api/test/fixture/api_test.exs"),
      """
      defmodule Fixture.ApiTest do
        use ExUnit.Case, async: true

        test "reads packaged asset through surviving OTP app in runtime and test code" do
          assert Fixture.Api.source() == {:store, :api}
          assert Fixture.Api.read_asset!() == #{inspect(asset_bytes)}

          test_lookup = Application.app_dir(:fixture_api, #{inspect(asset_relative)})
          assert File.read!(test_lookup) == #{inspect(asset_bytes)}
        end
      end
      """
    )

    result = Commands.project!(manifest)
    assert asset_relative in result.package_files

    relocated_parent = FixtureCase.unique_tmp_dir("relocated_surviving_monolith")
    relocated = Path.join(relocated_parent, "artifact")
    File.cp_r!(result.build_path, relocated)
    File.rm_rf!(root)
    refute File.exists?(asset_source)

    {output, status} =
      System.cmd("mix", ["test", "--warnings-as-errors"],
        cd: relocated,
        stderr_to_stdout: true,
        env: [
          {"MIX_ENV", "test"},
          {"MIX_BUILD_PATH", nil},
          {"MIX_BUILD_ROOT", nil},
          {"MIX_DEPS_PATH", nil}
        ]
      )

    assert status == 0, output
    assert output =~ ~r/(?:2 tests, 0 failures|Result: 2 passed)/
  end

  test "continues rejecting Application.app_dir/2 for absorbed component OTP apps in runtime and tests",
       %{root: root, manifest: manifest} do
    File.write!(
      Path.join(root, "core/store/lib/fixture/store.ex"),
      """
      defmodule Fixture.Store do
        @moduledoc false
        def source, do: Application.app_dir(:fixture_store, "priv/store.txt")
      end
      """
    )

    File.write!(
      Path.join(root, "runtime/api/test/fixture/api_test.exs"),
      """
      defmodule Fixture.ApiTest do
        use ExUnit.Case, async: true

        test "absorbed app lookup is rejected" do
          assert is_binary(Application.app_dir(:fixture_store, "priv/store.txt"))
        end
      end
      """
    )

    error =
      assert_raise Error, fn ->
        Plan.build!(manifest)
      end

    assert Exception.message(error) =~
             "core/store/lib/fixture/store.ex uses Application.app_dir(:fixture_store)"

    assert Exception.message(error) =~
             "runtime/api/test/fixture/api_test.exs uses Application.app_dir(:fixture_store)"
  end

  test "keeps Application.ensure_all_started/1 and Application.app_dir/1 rejected for the surviving OTP app",
       %{root: root, manifest: manifest} do
    File.write!(
      Path.join(root, "runtime/api/lib/fixture/api.ex"),
      """
      defmodule Fixture.Api do
        @moduledoc false
        def boot, do: Application.ensure_all_started(:fixture_api)
        def root_dir, do: Application.app_dir(:fixture_api)
      end
      """
    )

    error =
      assert_raise Error, fn ->
        Plan.build!(manifest)
      end

    assert Exception.message(error) =~
             "runtime/api/lib/fixture/api.ex uses Application.ensure_all_started(:fixture_api)"

    assert Exception.message(error) =~
             "runtime/api/lib/fixture/api.ex uses Application.app_dir(:fixture_api)"
  end
end
