//! The closed set of error codes a stream can end with, and the body that
//! carries one (`END {"error":{…}}`, `RESET {…}`).

use serde_json::{json, Value};

macro_rules! codes {
    ($($variant:ident => $text:literal,)*) => {
        /// What went wrong, as the app can act on it. Closed: a new code is a
        /// protocol change.
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
        pub enum ErrorCode { $($variant,)* }

        impl ErrorCode {
            /// The wire spelling.
            #[must_use]
            pub fn as_str(self) -> &'static str {
                match self { $(Self::$variant => $text,)* }
            }

            /// The code spelled `text`, if it is one of ours.
            #[must_use]
            pub fn parse(text: &str) -> Option<Self> {
                match text { $($text => Some(Self::$variant),)* _ => None }
            }

            /// Every code, for tests.
            pub const ALL: &'static [ErrorCode] = &[$(Self::$variant,)*];
        }
    };
}

codes! {
    BadRequest => "bad_request",
    UnknownService => "unknown_service",
    UnknownMethod => "unknown_method",
    Unavailable => "unavailable",
    NotFound => "not_found",
    Permission => "permission",
    NotAFile => "not_a_file",
    NotADirectory => "not_a_directory",
    Exists => "exists",
    Changed => "changed",
    TooLarge => "too_large",
    AgentExited => "agent_exited",
    AgentMissing => "agent_missing",
    Failed => "failed",
    Busy => "busy",
    Stalled => "stalled",
    Cancelled => "cancelled",
    ProtoMismatch => "proto_mismatch",
    Internal => "internal",
}

/// An error as it travels: a code, words for the person, and whether trying
/// again later can work (set by the host, never guessed by the client).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WireError {
    pub code: ErrorCode,
    pub message: String,
    pub retryable: bool,
}

impl WireError {
    #[must_use]
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        let retryable = matches!(code, ErrorCode::Busy | ErrorCode::Stalled);
        Self {
            code,
            message: message.into(),
            retryable,
        }
    }

    /// The same error, marked retryable.
    #[must_use]
    pub fn retryable(mut self) -> Self {
        self.retryable = true;
        self
    }

    /// `{"code","message","retryable"}`: the body inside `END {"error":…}` and the
    /// whole body of `RESET`.
    #[must_use]
    pub fn to_body(&self) -> Value {
        json!({"code": self.code.as_str(), "message": self.message, "retryable": self.retryable})
    }

    /// `{"error":{…}}`: the payload of an `END` that ends a stream in failure.
    #[must_use]
    pub fn to_end(&self) -> Value {
        json!({"error": self.to_body()})
    }

    /// Reads an error body. An unknown code reads as `internal`, so a newer
    /// host's code never makes an older reader fail twice.
    #[must_use]
    pub fn from_body(body: &Value) -> Self {
        let code = body
            .get("code")
            .and_then(Value::as_str)
            .and_then(ErrorCode::parse)
            .unwrap_or(ErrorCode::Internal);
        Self {
            code,
            message: body
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            retryable: body
                .get("retryable")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        }
    }

    /// The error an `END` payload carries, or `None` when it ends in success.
    #[must_use]
    pub fn from_end(payload: &Value) -> Option<Self> {
        payload.get("error").map(Self::from_body)
    }
}

impl std::fmt::Display for WireError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code.as_str(), self.message)
    }
}

impl std::error::Error for WireError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_code_round_trips_through_its_spelling() {
        for code in ErrorCode::ALL {
            assert_eq!(ErrorCode::parse(code.as_str()), Some(*code));
        }
        assert_eq!(ErrorCode::ALL.len(), 19);
    }

    #[test]
    fn an_unknown_code_reads_as_internal_and_keeps_the_message() {
        let e = WireError::from_body(&json!({"code":"from_the_future","message":"hm"}));
        assert_eq!(e.code, ErrorCode::Internal);
        assert_eq!(e.message, "hm");
    }

    #[test]
    fn end_carries_an_error_only_when_it_failed() {
        let e = WireError::new(ErrorCode::NotFound, "no such keeper");
        assert_eq!(WireError::from_end(&e.to_end()), Some(e));
        assert_eq!(WireError::from_end(&json!({"path":"/x"})), None);
        assert_eq!(WireError::from_end(&json!({})), None);
    }

    #[test]
    fn busy_and_stalled_are_retryable_by_default() {
        assert!(WireError::new(ErrorCode::Busy, "").retryable);
        assert!(WireError::new(ErrorCode::Stalled, "").retryable);
        assert!(!WireError::new(ErrorCode::NotFound, "").retryable);
        assert!(
            WireError::new(ErrorCode::Unavailable, "")
                .retryable()
                .retryable
        );
    }
}
