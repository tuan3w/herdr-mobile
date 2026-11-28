//! `hostwire/1`: the protocol on the one SSH exec channel between the app and
//! `herdr-host serve`. The spec is in the plan this crate was built from; the
//! golden vectors in `tests/vectors.json` pin the byte layout for both the
//! Rust host and the Dart client (`app/lib/data/host/wire.dart`).
//!
//! This crate does no I/O of its own: [`read_frame`] and [`write_frame`] take
//! any `Read`/`Write`, and everything else is data.

mod error;
mod frame;
mod hello;
mod zlib;

pub use error::{ErrorCode, WireError};
pub use frame::{
    encode_frame, read_frame, write_frame, Flags, Frame, FrameError, Kind, MAGIC, MAX_DATA,
    MAX_PAYLOAD,
};
pub use hello::{
    ClientHello, ClientInfo, HerdrHello, HostHello, HostInfo, Limits, Open, ServiceStatus, PROTO,
};
pub use zlib::{deflate, deflate_if_smaller, ContinuousDeflater, Inflater, MAX_INFLATED};
