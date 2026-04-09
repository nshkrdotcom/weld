[
  workspace: [
    root: "../..",
    project_globs: ["core/*"]
  ],
  artifacts: [
    package_repo_bundle: [
      roots: ["core/store"],
      package: [
        name: "package_repo_bundle",
        otp_app: :package_repo_bundle,
        version: "0.1.0",
        description: "Fixture bundle for package-mode repo config verification"
      ],
      output: [
        docs: ["README.md"]
      ]
    ]
  ]
]
