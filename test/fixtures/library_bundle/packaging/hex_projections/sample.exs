%{
  package_name: "fixture_bundle",
  otp_app: :fixture_bundle,
  version: "0.1.0",
  mode: :library_bundle,
  source_projects: [
    "core/contracts",
    "runtime/local"
  ],
  public_entry_modules: [
    WeldFixture.Runtime
  ],
  copy: %{
    docs: [
      "README.md",
      "CHANGELOG.md",
      "guides/architecture.md",
      "guides/getting_started.md"
    ],
    assets: [],
    priv: :auto
  },
  docs: %{
    main: "readme"
  }
}
