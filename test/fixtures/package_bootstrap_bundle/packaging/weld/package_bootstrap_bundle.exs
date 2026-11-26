[
  schema: 2,
  workspace: [
    root: "../..",
    projects: ["core/*"]
  ],
  artifacts: [
    package_bootstrap_bundle: [
      layout: :components,
      roots: ["core/bootstrap"],
      package: [
        name: "package_bootstrap_bundle",
        otp_app: :package_bootstrap_bundle,
        version: "0.1.0",
        description: "Fixture bundle for package-mode config bootstrap verification"
      ],
      files: [
        docs: ["README.md"]
      ],
      verify: [
        hex_publish_check: false,
        artifact_tests: ["packaging/weld/package_bootstrap_bundle/test"]
      ]
    ]
  ]
]
