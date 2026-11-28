//! What a multiplexer backend (herdr today, rex later) gives the generic mux:
//! its own JSON request/response vocabulary and its own event feed. Pipelining,
//! projection pruning, row deltas and compression live in [`crate::mux`] and
//! work over any backend; a new backend is one module here, one line in
//! [`crate::registry`] and a client adapter.

pub mod herdr;

use serde_json::Value;
use std::fmt;
use wire::{ClientHello, ServiceStatus};

/// Whether a backend can serve this client on this host right now.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Availability {
    Available,
    Unavailable { reason: String },
}

impl Availability {
    /// The HELLO entry for the service this backend powers.
    #[must_use]
    pub fn status(self) -> ServiceStatus {
        match self {
            Self::Available => ServiceStatus::available(),
            Self::Unavailable { reason } => ServiceStatus::unavailable(reason),
        }
    }
}

/// Why a backend call failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BackendError {
    /// The backend is not there (no socket, connection refused).
    Unavailable(String),
    /// It was there and the exchange failed (hang-up, timeout, bad answer).
    Failed(String),
}

impl fmt::Display for BackendError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unavailable(m) | Self::Failed(m) => f.write_str(m),
        }
    }
}

impl std::error::Error for BackendError {}

/// A multiplexer the host can reach: one request/response API and an event
/// subscription, both in the backend's own JSON.
pub trait Backend: Send + Sync + 'static {
    /// Also the name of the service it powers (`herdr`).
    fn id(&self) -> &'static str;

    /// Whether this backend is reachable for `hello` (its `herdr` section names
    /// the session or socket the client wants). Cheap: called for every HELLO
    /// and every OPEN.
    fn discover(&self, hello: &ClientHello) -> Availability;

    /// The same backend pointed where `hello` says it is: a stream opened with
    /// its own session or socket gets its own copy. Not part of the plan's
    /// trait text, which has no way to carry the OPEN's target to `call`.
    fn bind(&self, hello: &ClientHello) -> Self
    where
        Self: Sized;

    /// One native request object to its native response object.
    ///
    /// # Errors
    /// [`BackendError`] when the exchange did not complete.
    fn call(&self, request: &Value) -> Result<Value, BackendError>;

    /// Opens an event feed. `request` is `{"subscriptions": […]}`, the part of
    /// the OPEN's args that is the backend's own; the backend builds its
    /// subscribe request from it.
    ///
    /// # Errors
    /// [`BackendError`] when the feed could not be opened.
    fn subscribe(&self, request: &Value) -> Result<Box<dyn EventSource>, BackendError>;
}

/// A live event feed.
pub trait EventSource: Send {
    /// The backend's acknowledgement of the subscription.
    fn ack(&self) -> Value;

    /// The next event; `None` when the feed ended (the backend hung up, or
    /// [`closer`](Self::closer) was called). A line that is not JSON arrives as
    /// a JSON string.
    fn next_event(&mut self) -> Option<Result<Value, BackendError>>;

    /// Something that makes a blocked [`next_event`](Self::next_event) return
    /// `None`; callable from another thread, any number of times. (Not in the
    /// plan's trait text: without it a cancelled stream would sit in a blocking
    /// read until the backend next speaks.)
    fn closer(&self) -> Box<dyn Fn() + Send + Sync>;
}
