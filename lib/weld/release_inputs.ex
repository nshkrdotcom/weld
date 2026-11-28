defmodule Weld.ReleaseInputs do
  @moduledoc "Public qualification context and trust observations shared with explicit proof reuse."
  alias Weld.Core.Identity
  alias Weld.Plan
  alias Weld.Shell.Runner

  @unsafe ~w(unsafe_https unsafe_registry no_verify_repo_origin)a

  def observations(%Plan{} = plan, context, opts \\ []) do
    _ = Mix.Hex.start()
    compiler = plan.facts.compiler_id

    toolchain = %{
      "compiler_id" => compiler,
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "erts" => to_string(:erlang.system_info(:version)),
      "architecture" => to_string(:erlang.system_info(:system_architecture)),
      "os" => :os.type() |> Tuple.to_list() |> Enum.map(&to_string/1),
      "target" => "host",
      "hex" => application_version(:hex),
      "hex_core" => application_version(:hex_core),
      "hex_core_modules" =>
        module_fingerprints([
          :hex_api_release,
          :hex_api,
          :hex_tarball,
          :hex_repo,
          :hex_http_httpc
        ]),
      "native_inputs" => Map.new(Runner.native_env!(opts[:native_env]))
    }

    trust = registry_trust(opts)
    declared = Enum.sort(plan.artifact.verify.context)
    public_context = qualification_context!(opts[:qualification_context])

    context_digest =
      if declared == [] and is_nil(context) and public_context == %{},
        do: nil,
        else:
          Identity.raw(
            Identity.canonical(%{
              "declared" => declared,
              "selection" => context,
              "facts" => public_context
            })
          )

    %{toolchain: toolchain, trust: trust, context_digest: context_digest}
  end

  defp qualification_context!(nil), do: %{}
  defp qualification_context!(facts) when is_map(facts), do: facts

  defp qualification_context!(_),
    do: raise(Weld.Error, "qualification_context must be a map of public facts")

  def eligible(%Plan{} = plan, context, opts \\ []) do
    facts = observations(plan, context, opts)
    reasons = []

    reasons =
      if not is_binary(context) or context == "",
        do: ["explicit_context_required" | reasons],
        else: reasons

    reasons =
      if facts.trust["verified"] != true,
        do: ["registry_trust_unavailable" | reasons],
        else: reasons

    reasons =
      if facts.toolchain["hex_core"] != "0.21.1",
        do: ["unqualified_hex_core" | reasons],
        else: reasons

    reasons =
      case compiler_reuse() do
        :ok -> reasons
        reason -> [reason | reasons]
      end

    if reasons == [], do: {:ok, facts}, else: {:ineligible, Enum.sort(reasons)}
  end

  defp compiler_reuse do
    source = __MODULE__.module_info(:compile)[:source]

    if (is_list(source) or is_binary(source)) and File.regular?(to_string(source)) do
      development_compiler_reuse(Path.dirname(to_string(source)))
    else
      if is_list(:code.which(__MODULE__)), do: :ok, else: "unidentified_compiler"
    end
  rescue
    _ -> "unidentified_development_compiler"
  end

  defp development_compiler_reuse(directory) do
    case Weld.Git.root(directory) do
      nil -> "unidentified_development_compiler"
      root -> if Weld.Git.dirty?(root), do: "dirty_development_compiler", else: :ok
    end
  end

  @doc false
  def registry_trust(opts \\ []) do
    get_state = :erlang.make_fun(Module.concat(Hex, State), :get_all, 0)

    state =
      get_state.()
      |> Map.new(fn
        {name, {_source, value}} -> {name, value}
        {name, value} -> {name, value}
      end)

    secure =
      not Enum.any?(@unsafe, &state[&1]) and is_nil(state[:mirror_url]) and
        is_nil(state[:trusted_mirror_url])

    case Runner.candidate_registry!(opts) do
      nil -> default_trust(secure)
      registry -> candidate_trust(secure, registry)
    end
  rescue
    _ ->
      %{
        "verified" => false,
        "reason" => "trust_observation_unavailable",
        "policy" => "unavailable"
      }
  end

  defp default_trust(secure) do
    config = :hex_core.default_config()
    ca = ca_digest()
    verified = secure and is_binary(ca)

    %{
      "verified" => verified,
      "reason" =>
        cond do
          not secure -> "unsafe_registry_settings"
          is_nil(ca) -> "trust_observation_unavailable"
          true -> nil
        end,
      "repository" => "hexpm",
      "endpoint" => config.repo_url,
      "signature_verification" => true,
      "origin_verification" => true,
      "tls_peer_verification" => true,
      "public_key_sha256" => Identity.raw(config.repo_public_key),
      "ca_sha256" => ca,
      "policy" => "isolated-default-hex/2"
    }
  end

  defp candidate_trust(secure, registry) do
    %{
      "verified" => secure,
      "reason" => if(secure, do: nil, else: "unsafe_registry_settings"),
      "repository" => "hexpm",
      "endpoint" => "loopback",
      "signature_verification" => true,
      "origin_verification" => true,
      "tls_peer_verification" => false,
      "public_key_sha256" => Identity.raw(registry.public_key),
      "ca_sha256" => nil,
      "policy" => "isolated-signed-candidate-hex/1"
    }
  end

  defp ca_digest do
    certificates =
      Enum.map(:public_key.cacerts_get(), fn
        der when is_binary(der) -> der
        {:cert, der, _decoded} when is_binary(der) -> der
      end)

    if certificates == [], do: raise("no CA certificates")

    certificates
    |> Enum.map(&Base.encode64/1)
    |> Enum.sort()
    |> Identity.canonical()
    |> Identity.raw()
  rescue
    _ -> nil
  end

  defp module_fingerprints(modules) do
    Map.new(modules, fn module ->
      {:module, ^module} = :code.ensure_loaded(module)
      {^module, bytes, _path} = :code.get_object_code(module)
      {:ok, {^module, stripped}} = :beam_lib.strip(bytes)
      {to_string(module), Identity.raw(stripped)}
    end)
  end

  defp application_version(app) do
    _ = Application.load(app)

    case Application.spec(app, :vsn) do
      nil -> nil
      version -> to_string(version)
    end
  end
end
