//! The two `HELLO` bodies and the `OPEN` body.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::BTreeMap;

/// The only protocol version this crate speaks.
pub const PROTO: u32 = 1;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClientInfo {
    pub name: String,
    pub version: String,
}

/// Where the client wants herdr looked for.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HerdrHello {
    #[serde(default = "default_session")]
    pub session: String,
    /// An explicit socket path; `null` means derive it from `session`.
    #[serde(default)]
    pub socket: Option<String>,
}

fn default_session() -> String {
    "default".to_string()
}

impl Default for HerdrHello {
    fn default() -> Self {
        Self {
            session: default_session(),
            socket: None,
        }
    }
}

/// The client's first frame.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClientHello {
    pub proto: u32,
    pub client: ClientInfo,
    #[serde(default)]
    pub herdr: HerdrHello,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostInfo {
    pub version: String,
    pub os: String,
    pub arch: String,
    pub home: String,
    pub hostname: String,
    pub user: String,
}

/// What the host will accept.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Limits {
    pub max_msg: u32,
    pub max_data: u32,
    pub window: u32,
    pub max_streams: u32,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_msg: u32::try_from(crate::MAX_PAYLOAD).unwrap_or(u32::MAX),
            max_data: u32::try_from(crate::MAX_DATA).unwrap_or(u32::MAX),
            window: 1 << 20,
            max_streams: 64,
        }
    }
}

/// One service's availability on this host, with the reason when it is not.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServiceStatus {
    pub available: bool,
    #[serde(default)]
    pub reason: Option<String>,
    /// Service-specific facts (`socket`, `source`, …).
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

impl ServiceStatus {
    #[must_use]
    pub fn available() -> Self {
        Self {
            available: true,
            reason: None,
            extra: Map::new(),
        }
    }

    #[must_use]
    pub fn unavailable(reason: impl Into<String>) -> Self {
        Self {
            available: false,
            reason: Some(reason.into()),
            extra: Map::new(),
        }
    }

    /// Adds a service-specific fact.
    #[must_use]
    pub fn with(mut self, key: &str, value: Value) -> Self {
        self.extra.insert(key.to_string(), value);
        self
    }
}

/// The host's first frame.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostHello {
    pub proto: u32,
    pub host: HostInfo,
    pub limits: Limits,
    pub services: BTreeMap<String, ServiceStatus>,
}

/// The body of `OPEN`: which method to run, with what arguments.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Open {
    pub svc: String,
    pub method: String,
    #[serde(default = "empty_object")]
    pub args: Value,
    /// Compress this stream's host-to-client frames as one continuous zlib stream.
    #[serde(default)]
    pub zctx: bool,
}

fn empty_object() -> Value {
    Value::Object(Map::new())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_client_hello_without_herdr_means_the_default_session() {
        let h: ClientHello = serde_json::from_value(
            json!({"proto":1,"client":{"name":"herdr-mobile","version":"0.1.68"}}),
        )
        .expect("parses");
        assert_eq!(h.herdr.session, "default");
        assert_eq!(h.herdr.socket, None);
    }

    #[test]
    fn service_status_keeps_unknown_facts_next_to_availability() {
        let s: ServiceStatus =
            serde_json::from_value(json!({"available":true,"reason":null,"source":"proc"}))
                .expect("parses");
        assert!(s.available);
        assert_eq!(s.extra["source"], "proc");
        let back = serde_json::to_value(&s).expect("serializes");
        assert_eq!(back["source"], "proc");
    }

    #[test]
    fn open_defaults_to_no_args_and_plain_frames() {
        let o: Open = serde_json::from_value(json!({"svc":"fs","method":"stat"})).expect("parses");
        assert_eq!(o.args, json!({}));
        assert!(!o.zctx);
    }
}
