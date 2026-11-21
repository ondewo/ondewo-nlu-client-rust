# Release History

*****************

## Release ONDEWO NLU Rust Client 7.6.1

### Bug Fixes

* [[OND236-120]](https://ondewo.atlassian.net/browse/OND236-120) Keycloak token refresh: a failed refresh no longer ends the background refresher for the life of the process. A network error, a timeout, a non-2xx status, a body that is not a JSON object, a missing `access_token` and a non-numeric `expires_in` are all reported as the typed Keycloak authentication error with the underlying error attached, and are retried with ONE shared full-jitter backoff (5 s doubling up to 300 s) that the per-call refresh honours as well. During a Keycloak outage only one token request is in flight instead of one per RPC, and a success resets the backoff.
* [[OND236-120]](https://ondewo.atlassian.net/browse/OND236-120) A token that is still valid keeps being served when its refresh fails inside the 30 s expiry leeway; only an EXPIRED token raises. A malformed token response changes no provider state, and a login response without a `refresh_token` is accepted (the previous one is kept).

### Improvements

* [[OND236-120]](https://ondewo.atlassian.net/browse/OND236-120) Offline-token start-up: the client configuration takes `refresh_token` (a handed-off Keycloak OFFLINE refresh token, appended LAST to every positional surface so existing callers are not rebound). With it the client starts with a `grant_type=refresh_token` exchange and never sends a password grant; a refused token is never answered with a password login. A Keycloak configuration needs a password or a refresh token.
* [[OND236-120]](https://ondewo.atlassian.net/browse/OND236-120) The token-endpoint HTTP timeout is 10 s, quoted Keycloak error bodies are cut at 500 characters, no credential appears in any log line or error message, and providers are shared per credential set through a hashed registry key. The `token_expiration_in_s` window is armed on both start-up paths.
* [[OND236-120]](https://ondewo.atlassian.net/browse/OND236-120) Behaviour aligned with ondewo-nlu-client-python and pinned by the shared cross-language Keycloak test catalogue ported to this SDK.
* Tracking API Version [7.6.0](https://github.com/ondewo/ondewo-nlu-api/releases/tag/7.6.0) ( [Documentation](https://ondewo.github.io/ondewo-nlu-api/) )

*****************

## Release ONDEWO NLU Rust Client 7.6.0

### Improvements

* Tracking API Version [7.6.0](https://github.com/ondewo/ondewo-nlu-api/releases/tag/7.6.0) ( [Documentation](https://ondewo.github.io/ondewo-nlu-api/) )
* Generated with ondewo-proto-compiler 5.17.0 (protoc 35.1). New runtime floors: `prost` / `prost-types` 0.14.6 and `tonic` / `tonic-prost` 0.14.9.

*****************

## Release ONDEWO NLU Rust Client 7.4.0

### Improvements

* Tracking API Version [7.4.0](https://github.com/ondewo/ondewo-nlu-api/releases/tag/7.4.0) ( [Documentation](https://ondewo.github.io/ondewo-nlu-api/) )

*****************

## Release ONDEWO NLU Rust Client 7.3.1

### New Features

* TLS, mutual TLS and plaintext channels: the new hand-written module `channel` builds the tonic
  `Endpoint` / `Channel` from a `ClientConfig` (`endpoint()`, `connect()`, `connect_lazy()`).
  `grpc_cert`, `grpc_client_cert` and `grpc_client_key` take PEM **content**, not file paths.
  Without `grpc_cert` the platform trust store is used (tonic `tls-native-roots`).
* Refused with a `ChannelError` before tonic sees the config: half a client identity
  (`IncompleteClientIdentity`), a client identity on a plaintext channel
  (`ClientIdentityWithoutTls`) and a certificate field that holds no PEM certificate
  (`NotAPemCertificate`).
* A plaintext channel logs a `tracing` warning naming `host:port`. `Debug` redacts the client key
  and renders no PEM, and error messages name only the field and `host:port`. A bare IPv6 host is
  bracketed, and `tls_domain_name` overrides the name the server certificate is checked against.
* README section "TLS, mutual TLS and certificates": the modes, a test PKI built with openssl, TLS
  security notes and the channel defaults. Of the python SDK channel options, the message size
  limit is applied per client (`MAX_MESSAGE_LENGTH`); keepalive pings are not set (TCP keepalive
  detects a dropped idle connection instead), and tonic has no reconnect backoff or retry policy.

### Tests

* `tests/tls_channel.rs` runs real handshakes against an in-process tonic server with an
  openssl-generated test PKI: plain TLS, mutual TLS, missing and foreign client identities, wrong
  CA, platform roots, CRLF PEMs, SAN override and IPv6 loopback.
* `tests/release_notes.rs` pins the RELEASE.md slice the GitHub release body is cut from.

### Build

* `ondewo-proto-compiler` is pinned to 5.15.4, which pre-warms tonic `tls-native-roots` for the
  offline stub generation that `src/channel.rs` needs. The regenerated stubs under `src/api` are
  byte-identical.
* Tracking API Version [7.3.0](https://github.com/ondewo/ondewo-nlu-api/releases/tag/7.3.0) (unchanged)

*****************

## Release ONDEWO NLU Rust Client 7.3.0

### Improvements

* Tracking API Version [7.3.0](https://github.com/ondewo/ondewo-nlu-api/releases/tag/7.3.0) ( [Documentation](https://ondewo.github.io/ondewo-nlu-api/) )

*****************

## Release ONDEWO NLU Rust Client 7.2.0

### Improvements

* Tracking API Version [7.2.0](https://github.com/ondewo/ondewo-nlu-api/releases/tag/7.2.0) ( [Documentation](https://ondewo.github.io/ondewo-nlu-api/) )

*****************

## Release ONDEWO NLU Rust Client 7.1.0

### New Features

* Initial release of the ONDEWO NLU (Natural Language Understanding) gRPC client for rust. The crate
  ships the complete client surface of the [ondewo-nlu-api](https://github.com/ondewo/ondewo-nlu-api)
  protocol buffer definitions: [prost](https://crates.io/crates/prost) message types and
  [tonic](https://crates.io/crates/tonic) service clients for every RPC, generated by the
  `ondewo-rust-proto-compiler` image of
  [ondewo-proto-compiler](https://github.com/ondewo/ondewo-proto-compiler) 5.15.1.
* The generated module tree is confined to `src/api` and is re-exported from the crate root, so a
  message declared in `package ondewo.nlu;` is reachable as
  `ondewo_nlu_client::ondewo::nlu::<Message>` and each service as
  `ondewo::nlu::<service>_client::<Service>Client`. Hand-written modules live beside it
  under `src/` and are declared in the hand-written crate barrel `src/lib.rs`, which the
  generator leaves untouched.
* `make build` runs the whole pipeline - submodule checkout, compiler image build, stub
  generation and `cargo build` - and `make check_build` asserts that a generated stub exists for
  every proto package before a release is cut.

*****************
