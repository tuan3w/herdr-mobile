//! The services `serve` offers besides the herdr mux (`mux.rs`): one module per
//! service, each a [`crate::Service`] registered in [`crate::registry`].

pub mod fs;
pub mod keeper;
pub mod made;
pub mod ports;
pub mod search;
pub mod thumb;
pub mod transfer;
