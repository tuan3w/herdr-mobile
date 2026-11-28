//! `herdr-host`'s library: the `serve` session, the service registry and the
//! services themselves. The keeper's command line (`start`, `attach`, …) lives
//! in the binary and in `keeper`; `serve` is what the app talks to.

pub mod backend;
pub mod install;
pub mod mux;
pub mod serve;
pub mod service;
pub mod session;
pub mod svc;

pub use service::{Class, MethodKind, MethodSpec, Registry, Service};
pub use session::{Compress, Incoming, SendError, SessionOptions, StreamCtx};

use std::sync::Arc;

/// The version this binary reports: the app's, from `app/pubspec.yaml`.
pub const VERSION: &str = env!("HERDR_HOST_VERSION");

/// Every service `serve` offers on this host.
#[must_use]
pub fn registry() -> Registry {
    Registry::new(vec![
        Arc::new(mux::MuxService::new(backend::herdr::HerdrBackend::new())),
        Arc::new(svc::ports::PortsService::new()),
        Arc::new(svc::made::MadeService::new()),
        Arc::new(svc::fs::FsService::new()),
        Arc::new(svc::transfer::TransferService::new()),
        Arc::new(svc::keeper::KeeperService::new()),
    ])
}
