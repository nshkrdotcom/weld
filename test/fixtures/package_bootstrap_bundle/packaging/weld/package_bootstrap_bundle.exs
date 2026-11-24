[
  workspace: [
    root: "../..",
    project_globs: ["core/*"]
  ],
  artifacts: [
    package_bootstrap_bundle: [
      roots: ["core/bootstrap"],
      package: [
        name: "package_bootstrap_bundle",
        otp_app: :package_bootstrap_bundle,
        version: "0.1.0",
        description: "Fixture bundle for package-mode config bootstrap verification"
      ],
      output: [
        docs: ["README.md"]
      ],
      verify: [
        artifact_tests: ["packaging/weld/package_bootstrap_bundle/test"]
      ]
    ]
  ]
]
