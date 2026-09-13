// Copyright 2021-2026 ONDEWO GmbH
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! End-to-end tests for the GENERATED tonic service stubs.
//!
//! The generated `ContextsServer` is served over a loopback socket and driven by the generated
//! `ContextsClient`, so a request really is encoded, routed by its `/ondewo.nlu.Contexts/<Method>`
//! path, decoded, answered and decoded again. That is what catches a service the generator wired
//! to the wrong path, a codec mismatch, or a method that silently went missing.
//!
//! No network beyond `127.0.0.1` and no ONDEWO server is involved.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ondewo_nlu_client::api::ondewo::nlu;
use ondewo_nlu_client::api::ondewo::nlu::contexts_client::ContextsClient;
use ondewo_nlu_client::api::ondewo::nlu::contexts_server::{Contexts, ContextsServer};
use ondewo_nlu_client::auth::{
    BearerTokenInterceptor, AUTHORIZATION_METADATA_KEY, CAI_TOKEN_METADATA_KEY,
};
use tokio::net::TcpListener;
use tokio_stream::wrappers::TcpListenerStream;
use tonic::transport::{Channel, Endpoint, Server};
use tonic::{Code, Request, Response, Status};

/// The name `get_context` answers with `not_found` for, so the error path is exercised too.
const MISSING_CONTEXT: &str = "does-not-exist";

/// Metadata the fake server captured from the last request it handled.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct SeenMetadata {
    authorization: Option<String>,
    cai_token: Option<String>,
}

/// A minimal in-process implementation of the generated `Contexts` service.
#[derive(Clone, Default)]
struct FakeContexts {
    seen: Arc<Mutex<SeenMetadata>>,
}

impl FakeContexts {
    fn record<T>(&self, request: &Request<T>) {
        let read = |key: &str| {
            request
                .metadata()
                .get(key)
                .map(|value| value.to_str().unwrap().to_string())
        };
        *self.seen.lock().unwrap() = SeenMetadata {
            authorization: read(AUTHORIZATION_METADATA_KEY),
            cai_token: read(CAI_TOKEN_METADATA_KEY),
        };
    }

    fn seen(&self) -> SeenMetadata {
        self.seen.lock().unwrap().clone()
    }
}

#[tonic::async_trait]
impl Contexts for FakeContexts {
    async fn list_contexts(
        &self,
        request: Request<nlu::ListContextsRequest>,
    ) -> Result<Response<nlu::ListContextsResponse>, Status> {
        self.record(&request);
        Ok(Response::new(nlu::ListContextsResponse {
            contexts: vec![nlu::Context {
                name: format!("{}/contexts/one", request.into_inner().session_id),
                lifespan_count: 1,
                ..Default::default()
            }],
            next_page_token: "current_index-1--page_size-20".to_string(),
        }))
    }

    async fn get_context(
        &self,
        request: Request<nlu::GetContextRequest>,
    ) -> Result<Response<nlu::Context>, Status> {
        self.record(&request);
        let name = request.into_inner().name;
        if name == MISSING_CONTEXT {
            return Err(Status::not_found(format!("no context named {name}")));
        }
        Ok(Response::new(nlu::Context {
            name,
            ..Default::default()
        }))
    }

    /// Echoes the context back with the presence field explicitly zeroed, so the round trip proves
    /// `Some(0.0)` survives a real gRPC hop and does not come back as `None`.
    async fn create_context(
        &self,
        request: Request<nlu::CreateContextRequest>,
    ) -> Result<Response<nlu::Context>, Status> {
        self.record(&request);
        let mut context = request
            .into_inner()
            .context
            .ok_or_else(|| Status::invalid_argument("context is required"))?;
        context.lifespan_time = Some(0.0);
        Ok(Response::new(context))
    }

    async fn update_context(
        &self,
        request: Request<nlu::UpdateContextRequest>,
    ) -> Result<Response<nlu::Context>, Status> {
        self.record(&request);
        request
            .into_inner()
            .context
            .map(Response::new)
            .ok_or_else(|| Status::invalid_argument("context is required"))
    }

    async fn delete_context(
        &self,
        request: Request<nlu::DeleteContextRequest>,
    ) -> Result<Response<()>, Status> {
        self.record(&request);
        Ok(Response::new(()))
    }

    async fn delete_all_contexts(
        &self,
        request: Request<nlu::DeleteAllContextsRequest>,
    ) -> Result<Response<()>, Status> {
        self.record(&request);
        Ok(Response::new(()))
    }
}

/// Start the generated server on an ephemeral loopback port and return it with its address.
///
/// The server task is detached; it ends when the test process does.
async fn start_server() -> (FakeContexts, SocketAddr) {
    let service = FakeContexts::default();
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let addr = listener.local_addr().expect("local_addr");

    let served = service.clone();
    tokio::spawn(async move {
        Server::builder()
            .add_service(ContextsServer::new(served))
            .serve_with_incoming(TcpListenerStream::new(listener))
            .await
            .expect("the in-process gRPC server must not fail");
    });

    (service, addr)
}

async fn connect(addr: SocketAddr) -> Channel {
    Endpoint::from_shared(format!("http://{addr}"))
        .expect("endpoint")
        .connect_timeout(Duration::from_secs(10))
        .connect()
        .await
        .expect("the in-process gRPC server must accept a connection")
}

#[tokio::test]
async fn a_unary_call_round_trips_through_the_generated_client_and_server() {
    let (_service, addr) = start_server().await;
    let mut client = ContextsClient::new(connect(addr).await);

    let response = client
        .list_contexts(nlu::ListContextsRequest {
            session_id: "projects/p/agent/sessions/s".to_string(),
            page_token: String::new(),
        })
        .await
        .expect("ListContexts must succeed")
        .into_inner();

    assert_eq!(response.contexts.len(), 1);
    assert_eq!(
        response.contexts[0].name,
        "projects/p/agent/sessions/s/contexts/one"
    );
    assert_eq!(response.contexts[0].lifespan_count, 1);
    assert_eq!(response.next_page_token, "current_index-1--page_size-20");
}

/// The explicit-presence guarantee of `tests/generated_messages.rs`, but over a real hop: the
/// client sends `Some(0.0)` in and gets `Some(0.0)` back, never `None`.
#[tokio::test]
async fn an_explicit_presence_field_survives_a_real_grpc_hop() {
    let (_service, addr) = start_server().await;
    let mut client = ContextsClient::new(connect(addr).await);

    let echoed = client
        .create_context(nlu::CreateContextRequest {
            session_id: "projects/p/agent/sessions/s".to_string(),
            context: Some(nlu::Context {
                name: "ctx".to_string(),
                lifespan_time: Some(0.0),
                ..Default::default()
            }),
        })
        .await
        .expect("CreateContext must succeed")
        .into_inner();

    assert_eq!(echoed.name, "ctx");
    assert_eq!(
        echoed.lifespan_time,
        Some(0.0),
        "an explicitly zeroed presence field must not come back unset"
    );
}

/// A server-side `Status` has to reach the caller as that same status, not as a transport error.
#[tokio::test]
async fn a_server_error_reaches_the_client_as_its_status() {
    let (_service, addr) = start_server().await;
    let mut client = ContextsClient::new(connect(addr).await);

    let error = client
        .get_context(nlu::GetContextRequest {
            name: MISSING_CONTEXT.to_string(),
        })
        .await
        .expect_err("GetContext must report the missing context");

    assert_eq!(error.code(), Code::NotFound);
    assert_eq!(error.message(), "no context named does-not-exist");
}

/// Every RPC the `Contexts` proto declares must exist on the generated client and be routable -
/// a method the generator dropped, or wired to the wrong path, fails here with `Unimplemented`.
#[tokio::test]
async fn every_declared_service_method_exists_and_is_routable() {
    let (_service, addr) = start_server().await;
    let channel = connect(addr).await;
    let mut client = ContextsClient::new(channel);

    client
        .list_contexts(nlu::ListContextsRequest::default())
        .await
        .expect("ListContexts");
    client
        .get_context(nlu::GetContextRequest {
            name: "ctx".to_string(),
        })
        .await
        .expect("GetContext");
    client
        .create_context(nlu::CreateContextRequest {
            session_id: "s".to_string(),
            context: Some(nlu::Context::default()),
        })
        .await
        .expect("CreateContext");
    client
        .update_context(nlu::UpdateContextRequest {
            context: Some(nlu::Context::default()),
            update_mask: None,
        })
        .await
        .expect("UpdateContext");
    client
        .delete_context(nlu::DeleteContextRequest {
            name: "ctx".to_string(),
        })
        .await
        .expect("DeleteContext");
    client
        .delete_all_contexts(nlu::DeleteAllContextsRequest {
            session_id: "s".to_string(),
        })
        .await
        .expect("DeleteAllContexts");
}

/// The hand-written [`BearerTokenInterceptor`] has to put its metadata on the wire, where the
/// server can actually read it - asserting on the `Request` it returns would not prove that.
#[tokio::test]
async fn the_bearer_interceptor_reaches_the_server() {
    let (service, addr) = start_server().await;
    let interceptor = BearerTokenInterceptor::new("access-token-abc")
        .expect("a plain ASCII token is valid")
        .with_cai_token("cai-token-xyz")
        .expect("a plain ASCII cai token is valid");
    let mut client = ContextsClient::with_interceptor(connect(addr).await, interceptor);

    client
        .delete_all_contexts(nlu::DeleteAllContextsRequest {
            session_id: "s".to_string(),
        })
        .await
        .expect("DeleteAllContexts");

    assert_eq!(
        service.seen(),
        SeenMetadata {
            authorization: Some("Bearer access-token-abc".to_string()),
            cai_token: Some("cai-token-xyz".to_string()),
        }
    );
}

/// Without the interceptor the client must send no credentials at all - the unauthenticated path
/// (plaintext server, or an ingress that injects the bearer token) has to stay usable.
#[tokio::test]
async fn a_client_without_an_interceptor_sends_no_credentials() {
    let (service, addr) = start_server().await;
    let mut client = ContextsClient::new(connect(addr).await);

    client
        .delete_all_contexts(nlu::DeleteAllContextsRequest {
            session_id: "s".to_string(),
        })
        .await
        .expect("DeleteAllContexts");

    assert_eq!(service.seen(), SeenMetadata::default());
}

/// A client built against an address nothing listens on must surface a transport error rather
/// than panic or hang - `connect_lazy` defers the connect to the first call.
#[tokio::test]
async fn a_call_to_an_unreachable_target_fails_as_a_status() {
    let channel = Endpoint::from_static("http://127.0.0.1:1")
        .connect_timeout(Duration::from_secs(2))
        .connect_lazy();
    let mut client = ContextsClient::new(channel);

    let error = client
        .get_context(nlu::GetContextRequest {
            name: "ctx".to_string(),
        })
        .await
        .expect_err("nothing listens on port 1");

    assert_eq!(error.code(), Code::Unavailable);
}
