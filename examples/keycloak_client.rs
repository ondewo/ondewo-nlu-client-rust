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

//! Call an ONDEWO NLU server with an auto-refreshed Keycloak token.
//!
//! With `ONDEWO_NLU_OFFLINE_TOKEN` set, the client starts up from that offline refresh token and
//! never sends a password; otherwise it logs in with `ONDEWO_NLU_PASSWORD`.
//!
//! ```sh
//! ONDEWO_NLU_HOST=nlu.example.com ONDEWO_NLU_PORT=443 \
//! ONDEWO_KEYCLOAK_URL=https://keycloak.example.com/auth \
//! ONDEWO_KEYCLOAK_REALM=ondewo-ccai-platform \
//! ONDEWO_KEYCLOAK_CLIENT_ID=ondewo-nlu-cai-sdk-public \
//! ONDEWO_NLU_USERNAME=technical-user@example.com \
//! ONDEWO_NLU_OFFLINE_TOKEN=<offline refresh token> \
//! ONDEWO_NLU_SESSION_ID=projects/<project>/agent/sessions/<session> \
//!   cargo run --example keycloak_client
//! ```

use std::env;
use std::error::Error;

use ondewo_nlu_client::api::ondewo::nlu;
use ondewo_nlu_client::api::ondewo::nlu::contexts_client::ContextsClient;
use ondewo_nlu_client::channel::ClientConfig;
use ondewo_nlu_client::keycloak::{KeycloakConfig, KeycloakInterceptor};

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let config = KeycloakConfig::new(
        env::var("ONDEWO_KEYCLOAK_URL")?,
        env::var("ONDEWO_KEYCLOAK_REALM")?,
        env::var("ONDEWO_KEYCLOAK_CLIENT_ID")?,
        env::var("ONDEWO_NLU_USERNAME").unwrap_or_default(),
        env::var("ONDEWO_NLU_PASSWORD").unwrap_or_default(),
    )
    .with_refresh_token(env::var("ONDEWO_NLU_OFFLINE_TOKEN").unwrap_or_default());
    // Validates the config, then acquires the first token; the provider keeps it fresh.
    let interceptor = KeycloakInterceptor::new(&config)?;

    let channel = ClientConfig::new(
        env::var("ONDEWO_NLU_HOST")?,
        env::var("ONDEWO_NLU_PORT")?.parse()?,
    )
    .connect()
    .await?;
    let mut client = ContextsClient::with_interceptor(channel, interceptor);

    let response = client
        .list_contexts(nlu::ListContextsRequest {
            session_id: env::var("ONDEWO_NLU_SESSION_ID")?,
            page_token: String::new(),
        })
        .await?
        .into_inner();
    for context in response.contexts {
        println!("{} (lifespan {})", context.name, context.lifespan_count);
    }
    Ok(())
}
