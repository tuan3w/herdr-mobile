//! What a service is to the session: a name, a table of methods, an
//! availability check for the HELLO, and a handler that runs on the stream's
//! own thread.

use crate::session::StreamCtx;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::sync::Arc;
use wire::{ClientHello, ErrorCode, ServiceStatus, WireError, PROTO};

/// Whether a method answers once or runs until one side ends it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MethodKind {
    /// `OPEN` → one `MSG` → `END`. The handler returns the result.
    Call,
    /// Runs until it returns or the client ends or resets it. The handler
    /// sends through the [`StreamCtx`] and returns the `END` payload.
    Stream,
}

/// How the writer schedules the stream: interactive frames go first, bulk
/// gets one frame after every eight interactive ones so a download cannot
/// starve a permission answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Class {
    Interactive,
    Bulk,
}

/// One row of the catalog `herdr-host api` prints. The examples are JSON text
/// so the table can be a `const`.
#[derive(Debug)]
pub struct MethodSpec {
    pub name: &'static str,
    pub kind: MethodKind,
    pub class: Class,
    pub summary: &'static str,
    pub args_example: &'static str,
    pub result_example: &'static str,
}

impl MethodSpec {
    fn to_json(&self) -> Value {
        json!({
            "name": self.name,
            "kind": match self.kind { MethodKind::Call => "call", MethodKind::Stream => "stream" },
            "class": match self.class { Class::Interactive => "interactive", Class::Bulk => "bulk" },
            "summary": self.summary,
            "args": serde_json::from_str::<Value>(self.args_example).unwrap_or(Value::Null),
            "result": serde_json::from_str::<Value>(self.result_example).unwrap_or(Value::Null),
        })
    }
}

/// A group of methods under one name (`fs`, `keeper`, `herdr`, …).
pub trait Service: Send + Sync + 'static {
    /// The `svc` of `OPEN`.
    fn name(&self) -> &'static str;

    fn methods(&self) -> &'static [MethodSpec];

    /// Whether this service can work on this host for this client, with the
    /// reason when not. Called once, for the HELLO.
    fn availability(&self, hello: &ClientHello) -> ServiceStatus;

    /// Runs `method` (one of [`methods`](Self::methods)) for the stream `ctx`.
    ///
    /// # Errors
    /// The error the stream ends with.
    fn open(&self, method: &str, ctx: &StreamCtx) -> Result<Value, WireError>;
}

/// The services of one `serve`.
pub struct Registry {
    services: Vec<Arc<dyn Service>>,
}

impl Registry {
    #[must_use]
    pub fn new(services: Vec<Arc<dyn Service>>) -> Self {
        Self { services }
    }

    /// The service and method an `OPEN` names.
    ///
    /// # Errors
    /// `unknown_service` or `unknown_method`.
    pub fn find(
        &self,
        svc: &str,
        method: &str,
    ) -> Result<(Arc<dyn Service>, &'static MethodSpec), WireError> {
        let service = self
            .services
            .iter()
            .find(|s| s.name() == svc)
            .ok_or_else(|| {
                WireError::new(ErrorCode::UnknownService, format!("no service named {svc}"))
            })?;
        let spec = service
            .methods()
            .iter()
            .find(|m| m.name == method)
            .ok_or_else(|| {
                WireError::new(
                    ErrorCode::UnknownMethod,
                    format!("{svc} has no method {method}"),
                )
            })?;
        Ok((Arc::clone(service), spec))
    }

    /// Every service's availability, for the HELLO.
    #[must_use]
    pub fn status(&self, hello: &ClientHello) -> BTreeMap<String, ServiceStatus> {
        self.services
            .iter()
            .map(|s| (s.name().to_string(), s.availability(hello)))
            .collect()
    }

    /// The catalog `herdr-host api` prints and `docs/host-api.json` checks in.
    #[must_use]
    pub fn catalog(&self) -> Value {
        let mut services: Vec<&Arc<dyn Service>> = self.services.iter().collect();
        services.sort_by_key(|s| s.name());
        json!({
            "proto": PROTO,
            "services": services.iter().map(|s| json!({
                "name": s.name(),
                "methods": s.methods().iter().map(MethodSpec::to_json).collect::<Vec<_>>(),
            })).collect::<Vec<_>>(),
        })
    }
}
