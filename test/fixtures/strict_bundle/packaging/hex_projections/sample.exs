%{
  package_name: "strict_fixture_bundle",
  otp_app: :strict_fixture_bundle,
  version: "0.1.0",
  mode: :strict_library_bundle,
  source_projects: [
    "apps/problem_child"
  ],
  public_entry_modules: [
    WeldFixture.ProblemChild
  ],
  copy: %{
    docs: [
      "README.md",
      "CHANGELOG.md",
      "guides/architecture.md"
    ],
    assets: [],
    priv: :auto
  },
  docs: %{
    main: "readme"
  }
}
