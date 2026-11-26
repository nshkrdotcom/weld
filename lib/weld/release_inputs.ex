defmodule Weld.ReleaseInputs do
  @moduledoc false

  alias Weld.{Hash, Output, Receipt}

  @trust_settings ~w(unsafe_https unsafe_registry no_verify_repo_origin offline cacerts_path
                      policy_enforce_lock policy_locked_versions policy_filtered_versions config_home cache_home data_home ssl_version)a

  # Generic Mix projects can read inputs outside their source tree. The caller
  # opts in only when those inputs are covered by its reuse identity.
  def fingerprint(plan, revision, context)
      when is_binary(revision) and is_binary(context) and byte_size(context) > 0 do
    with %{mode: :source_project, roots: [project], verify: %{hex_publish: false}} <-
           plan.artifact,
         %{abs_path: source} <- Map.fetch!(plan.workspace.projects, project),
         lock_path = Output.source!(source, "mix.lock"),
         true <- File.regular?(lock_path),
         true <- "mix.lock" in Enum.map(plan.source_inventory, & &1.target),
         {:ok, trust} <- hex_trust() do
      lock = Hash.sha256_file(lock_path)

      input =
        Receipt.digest(
          {context, trust, revision, Weld.Projector.input_digest(plan, revision, :full)}
        )

      {input, lock}
    else
      _ -> nil
    end
  end

  def fingerprint(_plan, _revision, _context), do: nil

  defp hex_trust do
    with {:ok, _} <- Mix.Hex.start(),
         get_state = :erlang.make_fun(Module.concat(Hex, State), :get_all, 0),
         raw when is_map(raw) <- get_state.(),
         state = Map.new(raw, fn {name, {_source, value}} -> {name, value} end),
         false <- Enum.any?(~w(unsafe_https unsafe_registry no_verify_repo_origin)a, &state[&1]),
         repos when is_map(repos) <- state[:repos] do
      # Hex is loaded by Mix from its installed archive, outside Weld's dependencies.
      get_repo = :erlang.make_fun(Module.concat(Hex, Repo), :get_repo, 1)

      coordinates =
        repos
        |> Map.put_new("hexpm", nil)
        |> Map.keys()
        |> Enum.sort()
        |> Enum.map(fn name ->
          repo = get_repo.(name)
          {name, public_url(repo.url), repo.public_key, repo.trusted}
        end)

      active_ca = state[:cacerts_path]
      ca_digest = if active_ca && File.regular?(active_ca), do: Hash.sha256_file(active_ca)

      {:ok,
       {coordinates, Map.take(state, @trust_settings), ca_digest, public_url(state[:mirror_url]),
        public_url(state[:trusted_mirror_url]), Application.spec(:hex, :vsn), Mix.target()}}
    else
      _ -> :unavailable
    end
  rescue
    _error -> :unavailable
  end

  defp public_url(nil), do: nil

  defp public_url(value) do
    parsed = URI.parse(value)
    {parsed.scheme, parsed.host, parsed.port, parsed.path}
  end
end
