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

//! Wire-level tests for the GENERATED prost messages under `src/api`.
//!
//! These are the cases that catch a broken generator: a dropped field, a shifted tag number, a
//! presence field silently coerced to its zero value, an enum whose discriminants moved. They are
//! pure encode/decode - no runtime, no socket. The gRPC plumbing is covered by
//! `tests/generated_grpc.rs`.

use std::collections::HashMap;

use ondewo_nlu_client::api::google;
use ondewo_nlu_client::api::ondewo::nlu;
use ondewo_nlu_client::api::ondewo::qa;
use prost::Message;
use prost_types::Timestamp;

/// A fully populated [`nlu::Context`] - scalar, map, message and presence fields at once.
fn sample_context() -> nlu::Context {
    let mut parameters = HashMap::new();
    parameters.insert(
        "city".to_string(),
        nlu::context::Parameter {
            name: "city".to_string(),
            display_name: "City".to_string(),
            value: "Vienna".to_string(),
            value_original: "vienna".to_string(),
            created_at: Some(Timestamp {
                seconds: 1_700_000_000,
                nanos: 0,
            }),
            ..Default::default()
        },
    );

    nlu::Context {
        name: "greeting-context".to_string(),
        lifespan_count: 5,
        parameters,
        lifespan_time: Some(42.5),
        created_at: Some(Timestamp {
            seconds: 1_700_000_000,
            nanos: 123,
        }),
        ..Default::default()
    }
}

#[test]
fn context_survives_a_serialize_parse_round_trip() {
    let original = sample_context();

    let bytes = original.encode_to_vec();
    assert!(
        !bytes.is_empty(),
        "a populated Context must not encode to zero bytes"
    );
    assert_eq!(
        bytes.len(),
        original.encoded_len(),
        "encoded_len must agree with the bytes actually written"
    );

    let parsed =
        nlu::Context::decode(bytes.as_slice()).expect("re-parsing our own bytes must work");
    assert_eq!(parsed, original);

    // Spot-check the individual fields too: a PartialEq on two identically broken values would
    // still pass above.
    assert_eq!(parsed.name, "greeting-context");
    assert_eq!(parsed.lifespan_count, 5);
    assert_eq!(parsed.lifespan_time, Some(42.5));
    assert_eq!(parsed.created_at.unwrap().nanos, 123);
    assert_eq!(parsed.parameters["city"].value, "Vienna");
}

#[test]
fn a_default_context_round_trips_to_zero_bytes() {
    let empty = nlu::Context::default();

    assert_eq!(empty.lifespan_count, 0);
    assert_eq!(empty.lifespan_time, None);
    assert!(empty.parameters.is_empty());

    let bytes = empty.encode_to_vec();
    assert!(
        bytes.is_empty(),
        "proto3 must not put unset fields on the wire, got {bytes:?}"
    );
    assert_eq!(nlu::Context::decode(bytes.as_slice()).unwrap(), empty);
}

/// `Context.lifespan_time` is a proto3 `optional` (explicit presence) field. An unset field and a
/// field explicitly set to `0.0` are two DIFFERENT values and must stay distinguishable across the
/// wire - a generator that collapses them makes `0.0` unsendable.
#[test]
fn an_explicit_presence_field_distinguishes_unset_from_zero() {
    let unset = nlu::Context {
        name: "ctx".to_string(),
        lifespan_time: None,
        ..Default::default()
    };
    let explicit_zero = nlu::Context {
        name: "ctx".to_string(),
        lifespan_time: Some(0.0),
        ..Default::default()
    };

    let unset_bytes = unset.encode_to_vec();
    let zero_bytes = explicit_zero.encode_to_vec();
    assert_ne!(
        unset_bytes, zero_bytes,
        "an explicitly set 0.0 must occupy the wire, an unset field must not"
    );

    assert_eq!(
        nlu::Context::decode(unset_bytes.as_slice())
            .unwrap()
            .lifespan_time,
        None
    );
    assert_eq!(
        nlu::Context::decode(zero_bytes.as_slice())
            .unwrap()
            .lifespan_time,
        Some(0.0)
    );
}

/// Decoding tolerates fields it does not know: an unknown tag is skipped, not an error.
#[test]
fn decoding_skips_an_unknown_field() {
    let mut bytes = nlu::GetContextRequest {
        name: "ctx".to_string(),
    }
    .encode_to_vec();
    // tag 999, wire type 0 (varint), value 1
    bytes.extend_from_slice(&[0xB8, 0x3E, 0x01]);

    let parsed = nlu::GetContextRequest::decode(bytes.as_slice())
        .expect("an unknown field must be skipped, not rejected");
    assert_eq!(parsed.name, "ctx");
}

#[test]
fn decoding_rejects_a_truncated_message() {
    let bytes = sample_context().encode_to_vec();
    let truncated = &bytes[..bytes.len() - 1];

    assert!(
        nlu::Context::decode(truncated).is_err(),
        "a truncated message must not decode silently"
    );
}

/// The zero value of an enum is the one a default-constructed message carries, so it must be the
/// variant the proto declares as `= 0`.
#[test]
fn the_enum_zero_value_is_the_unspecified_variant() {
    assert_eq!(nlu::IntentView::Unspecified as i32, 0);
    assert_eq!(
        nlu::IntentView::try_from(0),
        Ok(nlu::IntentView::Unspecified)
    );
    assert_eq!(
        nlu::ListIntentsRequest::default().intent_view,
        nlu::IntentView::Unspecified as i32,
        "a default message must carry the enum's zero value"
    );

    assert_eq!(
        nlu::IntentView::Unspecified.as_str_name(),
        "INTENT_VIEW_UNSPECIFIED"
    );
    assert_eq!(
        nlu::IntentView::from_str_name("INTENT_VIEW_UNSPECIFIED"),
        Some(nlu::IntentView::Unspecified)
    );
    assert_eq!(nlu::IntentView::from_str_name("NOT_A_VARIANT"), None);
    assert!(
        nlu::IntentView::try_from(9_999).is_err(),
        "an out-of-range discriminant must not map to a variant"
    );
}

/// A non-zero enum value has to travel as its discriminant, not as the zero value.
#[test]
fn a_non_zero_enum_value_round_trips() {
    let request = nlu::ListIntentsRequest {
        parent: "projects/p".to_string(),
        language_code: "de".to_string(),
        intent_view: nlu::IntentView::Minimum as i32,
        ..Default::default()
    };

    let parsed = nlu::ListIntentsRequest::decode(request.encode_to_vec().as_slice()).unwrap();
    assert_eq!(parsed, request);
    assert_eq!(
        nlu::IntentView::try_from(parsed.intent_view),
        Ok(nlu::IntentView::Minimum)
    );
}

/// Repeated and nested message fields have to nest, not flatten.
#[test]
fn a_nested_and_repeated_message_round_trips() {
    let response = nlu::ListContextsResponse {
        contexts: vec![
            sample_context(),
            nlu::Context {
                name: "second".to_string(),
                ..Default::default()
            },
        ],
        next_page_token: "current_index-1--page_size-20".to_string(),
    };

    let parsed = nlu::ListContextsResponse::decode(response.encode_to_vec().as_slice()).unwrap();
    assert_eq!(parsed, response);
    assert_eq!(parsed.contexts.len(), 2);
    assert_eq!(parsed.contexts[1].name, "second");
}

/// The generator emits one module per proto PACKAGE. Messages of the secondary ONDEWO package and
/// of the vendored `google.*` packages have to be reachable and usable too, including a message
/// that references a type declared in another package.
#[test]
fn messages_of_every_generated_package_are_reachable() {
    let request = qa::GetAnswerRequest {
        session_id: "projects/p/agent/sessions/s".to_string(),
        text: Some(nlu::TextInput {
            text: "where is the exit?".to_string(),
            language_code: "en".to_string(),
        }),
        max_num_answers: 3,
        threshold_overall: 0.75,
        ..Default::default()
    };
    let parsed = qa::GetAnswerRequest::decode(request.encode_to_vec().as_slice()).unwrap();
    assert_eq!(parsed, request);
    assert_eq!(parsed.text.unwrap().text, "where is the exit?");

    let status = google::rpc::Status {
        code: 5,
        message: "not found".to_string(),
        details: vec![],
    };
    let parsed = google::rpc::Status::decode(status.encode_to_vec().as_slice()).unwrap();
    assert_eq!(parsed, status);
}
