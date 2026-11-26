# Architecture

Weld 0.20.0 separates semantic decisions from their effects. `Weld.Core.Manifest` validates evaluated schema 2 terms; workspace discovery supplies Mix metadata; the graph describes dependency relationships. `Weld.Plan` selects artifact members and invokes layout policy. The components and flat layout policies emit file plans using shared support functions; preserve consumes existing Mix configuration. `Weld.Core.Inventory` provides validated inventory views, comparison and project identity. `Weld.Projector` materializes plans, `Weld.Verifier` qualifies an isolated copy, and `Weld.Release` prepares immutable bundles. The Hex transport accepts frozen archive bytes. Production writes require transport qualification. `Weld.Output` owns managed state and locking.

The intended dependency direction is workspace facts -> plan -> inventory -> materialize -> qualify -> bundle -> publish. Pure identity and inventory operations have no filesystem or Mix dependency. Discovery, rendering, subprocesses, filesystem writes, Git and network operations belong at the boundary. Paths are relative in portable identity inputs; qualification and cache keys are not interchangeable.

The implementation still requires qualification of the boundary invariants and recovery behavior. See the release process.
