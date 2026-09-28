<div align="center">
  <table>
    <tr>
      <td>
        <a href="https://ondewo.com">
            <img width="400px" src="https://raw.githubusercontent.com/ondewo/ondewo-logos/master/ondewo_we_automate_your_phone_calls.png"/>
        </a>
      </td>
    </tr>
    <tr>
        <td align="center">
          <a href="https://www.linkedin.com/company/ondewo"><img width="40px" src="https://cdn-icons-png.flaticon.com/512/3536/3536505.png"></a>
          <a href="https://www.facebook.com/ondewo"><img width="40px" src="https://cdn-icons-png.flaticon.com/512/733/733547.png"></a>
          <a href="https://twitter.com/ondewo"><img width="40px" src="https://cdn-icons-png.flaticon.com/512/733/733579.png"></a>
          <a href="https://www.instagram.com/ondewo.ai/"><img width="40px" src="https://cdn-icons-png.flaticon.com/512/174/174855.png"></a>
        </td>
    </tr>
  </table>
  <h1>
  ONDEWO NLU Client Rust Library
  </h1>
</div>

This library gives a rust application typed, async access to the ONDEWO NLU
(Natural Language Understanding) gRPC API.

It is generated code plus a thin hand-written surface around it. The interface itself is defined
by the protocol buffer files of the [ONDEWO NLU API](https://github.com/ondewo/ondewo-nlu-api),
which can be compiled into 10+ high-level languages; the
[ONDEWO PROTO COMPILER](https://github.com/ondewo/ondewo-proto-compiler) turns them into the
[prost](https://crates.io/crates/prost) message types and [tonic](https://crates.io/crates/tonic)
service clients that this crate publishes.

## Rust Installation

The library is published to [crates.io](https://crates.io/crates/ondewo-nlu-client) as
**`ondewo-nlu-client`**, with the API documentation on
[docs.rs](https://docs.rs/ondewo-nlu-client). Nothing else is needed to consume it - the stubs are
generated before publishing and ship inside the crate, so installing it needs neither `docker`,
nor `protoc`, nor the proto definitions.

```bash
cargo add ondewo-nlu-client
```

or declare it in your `Cargo.toml`:

```toml
[dependencies]
ondewo-nlu-client = "~7.1"
tonic = "0.14"
tokio = { version = "1", features = ["full"] }
```

The generated clients are `async`, so an async runtime is needed to drive them -
[tokio](https://crates.io/crates/tokio) is the one tonic is built against.

A few things worth knowing before pinning a version:

* The crate needs **rust 1.88 or newer** (`rust-version` in `Cargo.toml`).
* Its version tracks the **ONDEWO NLU API** it was generated from in major and minor - a crate
  `X.Y.*` speaks the API `X.Y.*` - so pin the minor of the server you talk to.
* `tonic` and `prost` types appear in the public API. Depend on the **same `tonic` 0.14 and
  `prost` 0.14** the crate does, or the two sets of types will not line up.
* The crate ships no default features and pulls in `tonic`'s `tls-ring` and `gzip`, so a TLS
  endpoint (`https://`) works out of the box.

To work on the library itself, clone it with its two submodules and set up the toolchain:

```bash
git clone --recurse-submodules git@github.com:ondewo/ondewo-nlu-client-rust.git
cd ondewo-nlu-client-rust
make setup_developer_environment_locally
```

The local rust toolchain is only needed by the plain cargo targets (`make test`, `make coverage`,
...). `make build`, `make release` and every `*_via_docker` target run cargo in the utils image
built from `Dockerfile.utils`, so for those `docker`, `git`, `make`, `perl` and `curl` are enough.

## Usage

Every gRPC service in the API becomes one client type, and every message becomes one struct. The
module path mirrors the proto package: `package ondewo.nlu;` is reachable as
`ondewo_nlu_client::ondewo::nlu`. Run `cargo doc --open` to browse the exact service
and message names of the API version this crate was generated from.

```rust
use ondewo_nlu_client::ondewo::nlu::*;
use tonic::transport::Channel;
use tonic::Request;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // 1. A channel to the NLU server. `Channel` handles TLS, reconnects and
    //    connection pooling; the generated clients accept any tonic service.
    let channel = Channel::from_static("https://grpc-nlu.ondewo.com:443")
        .connect()
        .await?;

    // 2. One client per gRPC service - replace `Example` with a service of the API, e.g. the
    //    service `Foo` generates `foo_client::FooClient`.
    let mut client = example_client::ExampleClient::new(channel);

    // 3. ONDEWO servers authenticate with a bearer token in the request metadata.
    let token = std::env::var("ONDEWO_NLU_TOKEN")?;
    let mut request = Request::new(ExampleRequest::default());
    request
        .metadata_mut()
        .insert("authorization", format!("Bearer {token}").parse()?);

    let response = client.example_rpc(request).await?;
    println!("{:?}", response.into_inner());

    Ok(())
}
```

## Repository Structure

```text
.
├── ondewo-nlu-api                <----- submodule: the proto definitions to compile
├── ondewo-proto-compiler     <----- submodule: builds the ondewo-rust-proto-compiler image
├── src
│   ├── api                   <----- GENERATED - one <proto.package>.rs per package + mod.rs
│   │   ├── mod.rs
│   │   └── ondewo.nlu.rs
│   ├── auth.rs               <----- hand-written bearer-token interceptor
│   └── lib.rs                <----- hand-written crate barrel
├── examples
│   └── authenticated_client.rs   <----- the crate's usage snippet, compiled by `cargo test`
├── tests                     <----- integration tests over the generated stubs
│   ├── auth_interceptor.rs
│   ├── generated_grpc.rs
│   └── generated_messages.rs
├── Cargo.toml                <----- crate manifest AND the generator's crate template
├── Cargo.lock
├── Dockerfile.utils          <----- the utils image: rust toolchain + GitHub CLI for build and release
├── Makefile
└── README.md
```

Only `src/api` is generated. Everything beside it under `src/` is hand-written and is declared in
`src/lib.rs`; a module that is compiled into the crate but missing from that barrel is unreachable
for consumers of the crate.

## Regenerating the Stubs

Regeneration needs `docker`, `git`, `make` and `perl` - `protoc` and the protoc plugins live inside
the compiler image, the rust toolchain inside the utils image, and generation itself needs no
network once the compiler image is built.

```bash
make build
```

is the whole pipeline:

1. `update_submodules` - `git submodule update --init --recursive`
1. `checkout_defined_submodule_versions` - checks out the pins at the top of the `Makefile`
   (`ONDEWO_NLU_API_GIT_BRANCH` and `ONDEWO_PROTO_COMPILER_GIT_BRANCH`)
1. `build_compiler` - builds `ondewo-rust-proto-compiler:latest` from the submodule
1. `update_cargo_version` - writes `ONDEWO_NLU_VERSION` into `Cargo.toml`, the crate's own entry
   in `Cargo.lock` and the install snippet above
1. `generate_ondewo_protos` - runs the image over `ondewo-nlu-api/ondewo` and writes `src/api`,
   `Cargo.toml`, `Cargo.lock` and `crate-dist/` back into this repository
1. `check_build` - asserts that a generated stub exists for every proto package
1. `cargo_build_via_docker` - builds the utils image (`ondewo-nlu-client-utils-rust:<version>`, rust
   toolchain + GitHub CLI) and compiles the crate in it

The image tag is the only contract between this repository and the compiler, so a compiler change
can be tried out without touching the submodule pin: build the tag from a compiler working tree
(`docker build -t ondewo-rust-proto-compiler:latest rust` in that repository) and run
`make generate_ondewo_protos` here.

`make help` lists every documented target.

## Testing and Linting

```bash
make test              # cargo test --all-targets
make test_via_docker   # the same in the utils image - no local rust toolchain needed
make coverage          # hand-written line coverage, gated at 100%
make cargo_fmt_check   # rustfmt over the HAND-WRITTEN sources only
make cargo_doc         # cargo doc --no-deps
make precommit_hooks_run_all_files
```

The suite under `tests/` exercises the **generated** stubs the way a broken generator would be
noticed: messages are serialized and re-parsed field by field, an explicit-presence field is
checked to stay distinguishable from its zero value, enum discriminants are pinned, and the
generated `ContextsServer` is served over a loopback socket and driven by the generated
`ContextsClient`, so every declared RPC really is encoded, routed by its
`/ondewo.nlu.Contexts/<Method>` path, answered and decoded again. No ONDEWO server is involved.

`make coverage` measures the **hand-written** sources only - `src/api`, `tests/` and `examples/`
are excluded, because generated code is machine output rather than authored logic - and fails
below 100%. The same gate runs in CI. The generated stubs are deliberately not held to a coverage
number; they are covered by the behavioural tests above.

`src/api` is outside the rustfmt gate on purpose: it is written by the generator on every run, so
a formatter that rewrote it would only produce a diff that the next generation discards. Doctests
are off crate-wide (`doctest = false`): the protos document their RPCs with indented proto and
HTTP snippets that prost copies into doc comments and rustdoc then tries to compile as rust. The
hand-written usage snippet therefore lives in `examples/`, where `cargo test` still compiles it.

## Release

A release runs entirely on the release host, driven by the `Makefile`. CI
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) only tests and lints: it never packages,
publishes or reads a secret. Bump `ONDEWO_NLU_VERSION`, add the matching entry to `RELEASE.md`,
then:

```bash
make ondewo_release
```

It writes the version into `Cargo.toml`, `Cargo.lock` and the install snippet
(`update_cargo_version`), checks that the release branch and tag do not exist yet and that
`Cargo.toml` carries the version (`spc`), clones the `ondewo-devops-accounts` repository and runs
`make release` with exactly two credentials from it. That repository is the only place they live:

| Variable | File in `ondewo-devops-accounts` | Used for |
| --- | --- | --- |
| `GITHUB_GH_TOKEN` | `account_github.env` | the GitHub release (`gh`) |
| `CARGO_REGISTRY_TOKEN` | `account_cargo.env` | the crates.io upload (`cargo publish`) - needs the **publish-update** scope |

`make release` then runs, in this order:

1. **Checks, before anything is pushed** - both tokens are set; GitHub accepts `GITHUB_GH_TOKEN`
   and it may push to this repository (`gh auth login` and `gh api` in the utils image,
   `validate_release_credentials`); crates.io does not have the version yet (its public API, no
   credential); `RELEASE.md` has the entry.
1. **Build, tests and packaging dry run**, in docker - `make build`, `make test_via_docker` and
   `make publish_crate_dry_run_via_docker`.
1. **Commit** `PREPARING FOR RELEASE <version>`, `Cargo.lock` included, and a check that nothing
   was left uncommitted: `cargo publish` uploads only a committed tree.
1. **Push** `master`, the `release/<version>` branch and the `<version>` tag.
1. **crates.io upload** - `cargo publish --locked` in the utils image, from the tagged commit and the
   `Cargo.lock` it carries.
1. **GitHub release** - last, so that one only exists for a complete release.

`make release_all_clients` in [ondewo-nlu-api](https://github.com/ondewo/ondewo-nlu-api) runs this
same `make ondewo_release` after it has added the `RELEASE.md` entry and set `ONDEWO_NLU_VERSION`
and both submodule pins in the `Makefile`.

The release host needs only `make`, `git` (with SSH access to GitHub and Bitbucket), `docker`,
`perl` and `curl`. The stubs are generated in the compiler image; cargo and the GitHub CLI run in
the utils image built from `Dockerfile.utils`, as the invoking user and with this repository
mounted, so every build output lands in the working tree and none of it is owned by root.

### When a release stops after its tag push

`CARGO_REGISTRY_TOKEN` is only checked for presence before the push: crates.io documents no
read-only endpoint that accepts a publish-scoped token, so an expired token, or one without the
publish-update scope, first fails at the upload - after the tag is out. A GitHub outage can do the
same to the GitHub release. `spc` then refuses to run `make ondewo_release` again, because the
branch and the tag exist. Fix the cause, then run this in the checkout the release left behind
(on `release/<version>`), or in a fresh clone of the release tag:

```bash
make ondewo_release_publish   # the crates.io upload, then the GitHub release, with the devops-accounts credentials
```

It is the same code path as the end of `make release`, and it can be run again: a version
crates.io already has is skipped, not uploaded twice.

### Checking the packaging without releasing

The whole packaging path except the upload runs without any credential:

```bash
make check_crate_metadata               # the manifest fields crates.io requires
make publish_crate_dry_run              # + the file list, a full package/verify build, the 10 MiB limit
make publish_crate_dry_run_via_docker   # the same in the utils image - no local rust toolchain needed
```

## Support

Reach out to the ONDEWO team at [office@ondewo.com](mailto:office@ondewo.com), or open an issue in
this repository. Contributions are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache License 2.0 — see [LICENSE](LICENSE).
