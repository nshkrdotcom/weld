# Testing strategy

Run `mix format --check-formatted`, `mix compile --warnings-as-errors`, the complete ExUnit suite including all isolated integration lanes in `scripts/test_ci.exs`, `MIX_ENV=test mix credo --strict`, `mix dialyzer`, and `mix docs --warnings-as-errors`. `mix ci` combines these checks. Test compilation and test execution must be warning-free. Do not remove regression tests to achieve a green result.

Pure tests cover canonical identities, manifest validation, graph selection, inventory collisions and comparison. Integration cases cover all three layouts, source relocation, generated configs, component tests, native inputs, detached consumers, package contents, cache invalidation, isolated qualification, Git tracking, state corruption, interrupted operations and remote outcome classification. Use a fake or test transport for publication tests; never upload from QC. The exact archived package and docs must be verified independently of the working tree.
