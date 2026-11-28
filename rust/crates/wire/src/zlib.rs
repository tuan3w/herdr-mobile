//! zlib for the two compression flags: independent frames (`deflate`) and one
//! continuous stream per `zctx` stream (`ContinuousDeflater` / `Inflater`).
//!
//! `flate2`'s `*_vec` calls write into spare capacity only, so every loop
//! reserves before it calls and stops when the call leaves capacity unused.

use crate::FrameError;
use flate2::{Compress, Compression, Decompress, FlushCompress, FlushDecompress, Status};

/// Nothing inflates to more than this (a frame is at most 1 MiB on the wire).
pub const MAX_INFLATED: usize = 64 << 20;

const LEVEL: u32 = 6;

fn compress_into(c: &mut Compress, data: &[u8], flush: FlushCompress) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len() / 2 + 64);
    let mut input = data;
    loop {
        if out.capacity() - out.len() < 256 {
            out.reserve(4096);
        }
        let (before_in, before_out) = (c.total_in(), c.total_out());
        let status = c
            .compress_vec(input, &mut out, flush)
            .expect("zlib does not fail on valid input");
        let used = usize::try_from(c.total_in() - before_in).unwrap_or(0);
        input = &input[used..];
        if matches!(status, Status::StreamEnd) {
            break;
        }
        let stuck = c.total_in() == before_in && c.total_out() == before_out;
        if input.is_empty() && out.len() < out.capacity() {
            break;
        }
        if stuck {
            out.reserve(4096);
        }
    }
    out
}

/// `data` as one complete zlib stream (level 6).
#[must_use]
pub fn deflate(data: &[u8]) -> Vec<u8> {
    compress_into(
        &mut Compress::new(Compression::new(LEVEL), true),
        data,
        FlushCompress::Finish,
    )
}

/// `data` deflated, when that is smaller than `data` and `data` is at least
/// `min` bytes; the sender then sets the `deflate` flag.
#[must_use]
pub fn deflate_if_smaller(data: &[u8], min: usize) -> Option<Vec<u8>> {
    if data.len() < min {
        return None;
    }
    let packed = deflate(data);
    (packed.len() < data.len()).then_some(packed)
}

/// One continuous zlib stream: each [`piece`](Self::piece) is sync-flushed so
/// the reader can inflate it the moment it arrives, and later pieces refer back
/// to earlier ones (ten near-identical events cost ~30 bytes each).
pub struct ContinuousDeflater(Compress);

impl Default for ContinuousDeflater {
    fn default() -> Self {
        Self::new()
    }
}

impl ContinuousDeflater {
    #[must_use]
    pub fn new() -> Self {
        Self(Compress::new(Compression::new(LEVEL), true))
    }

    /// The bytes `data` adds to the stream.
    pub fn piece(&mut self, data: &[u8]) -> Vec<u8> {
        compress_into(&mut self.0, data, FlushCompress::Sync)
    }
}

/// Inflates pieces of one stream in order (a continuous stream), or, used once
/// on a fresh value, one complete stream.
pub struct Inflater(Decompress);

impl Default for Inflater {
    fn default() -> Self {
        Self::new()
    }
}

impl Inflater {
    #[must_use]
    pub fn new() -> Self {
        Self(Decompress::new(true))
    }

    /// The bytes the next `piece` inflates to.
    ///
    /// # Errors
    /// [`FrameError::Inflate`] for bytes that are not zlib data, or output past
    /// [`MAX_INFLATED`].
    pub fn piece(&mut self, piece: &[u8]) -> Result<Vec<u8>, FrameError> {
        let mut out = Vec::with_capacity(piece.len().saturating_mul(4).max(256));
        let mut input = piece;
        loop {
            if out.capacity() - out.len() < 1024 {
                out.reserve(piece.len().max(4096));
            }
            let (before_in, before_out) = (self.0.total_in(), self.0.total_out());
            let status = self
                .0
                .decompress_vec(input, &mut out, FlushDecompress::Sync)
                .map_err(|e| FrameError::Inflate(e.to_string()))?;
            let used = usize::try_from(self.0.total_in() - before_in).unwrap_or(0);
            input = &input[used..];
            if out.len() > MAX_INFLATED {
                return Err(FrameError::Inflate(format!(
                    "more than {MAX_INFLATED} bytes"
                )));
            }
            if matches!(status, Status::StreamEnd) {
                break;
            }
            let stuck = self.0.total_in() == before_in && self.0.total_out() == before_out;
            if input.is_empty() && out.len() < out.capacity() {
                break;
            }
            if stuck && out.len() < out.capacity() {
                return Err(FrameError::Inflate("truncated zlib data".to_string()));
            }
        }
        Ok(out)
    }

    /// Inflates one complete stream.
    ///
    /// # Errors
    /// As [`piece`](Self::piece).
    pub fn once(data: &[u8]) -> Result<Vec<u8>, FrameError> {
        Self::new().piece(data)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(seed: u8, len: usize) -> Vec<u8> {
        (0..len)
            .map(|i| b'a' + ((i as u8).wrapping_mul(seed) % 23))
            .collect()
    }

    #[test]
    fn an_independent_frame_inflates_to_what_went_in() {
        for len in [0, 1, 511, 512, 100_000, 3_000_000] {
            let data = sample(7, len);
            assert_eq!(Inflater::once(&deflate(&data)).expect("inflates"), data);
        }
    }

    #[test]
    fn a_continuous_stream_inflates_piece_by_piece_and_later_pieces_are_smaller() {
        let mut tx = ContinuousDeflater::new();
        let mut rx = Inflater::new();
        let event = br#"{"event":"pane.updated","data":{"pane":{"id":"p1","agent":"omp","status":"working"}}}"#;
        let mut sizes = Vec::new();
        for _ in 0..10 {
            let piece = tx.piece(event);
            sizes.push(piece.len());
            assert_eq!(rx.piece(&piece).expect("inflates"), event);
        }
        assert!(
            sizes[9] * 2 < sizes[0],
            "context should shrink repeats: {sizes:?}"
        );
    }

    #[test]
    fn small_or_incompressible_payloads_are_not_deflated() {
        assert!(deflate_if_smaller(&sample(3, 100), 512).is_none());
        let noise: Vec<u8> = (0..4096u32)
            .map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8)
            .collect();
        let packed = deflate_if_smaller(&noise, 512);
        assert!(packed.is_none_or(|p| p.len() < noise.len()));
        assert!(deflate_if_smaller(&sample(1, 4096), 512).is_some());
    }

    #[test]
    fn garbage_and_truncated_data_are_errors_not_panics() {
        assert!(Inflater::once(b"not zlib at all").is_err());
        let packed = deflate(&sample(5, 10_000));
        assert!(Inflater::once(&packed[..packed.len() / 2]).is_ok_and(|v| v.len() < 10_000));
    }
}
