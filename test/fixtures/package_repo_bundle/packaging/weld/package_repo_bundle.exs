[
  schema: 2,
  workspace: [
    root: "../..",
    projects: ["core/*"]
  ],
  artifacts: [
    package_repo_bundle: [
      layout: :components,
      roots: ["core/store"],
      package: [
        name: "package_repo_bundle",
        otp_app: :package_repo_bundle,
        version: "0.1.0",
        description: "Fixture bundle for package-mode repo config verification"
      ],
      files: [
        docs: ["README.md"]
      ],
      verify: [hex_publish_check: false]
    ]
  ]
]
