//! The `Z` line: what a zipped command sends to the phone. A batch of at least
//! [`ATTACH_ZIP_MIN`] bytes travels as ONE line `Z<base64 of zlib data>`; all
//! batches of one command are ONE zlib stream, each ended with a sync flush so
//! the phone inflates it as it arrives (`ZippedLines`, `zipped_lines.dart`). A
//! small message stays plain. `Z` is unambiguous: a JSON-RPC line starts with
//! `{`. The plain and the `follow` records both cut at whole lines before
//! zipping, so a `Z` line always inflates to whole lines.
//!
//! The stream is a `flate2::Compress` with `FlushCompress::Sync` — the same
//! `zlib.compressobj(6)` + `flush(Z_SYNC_FLUSH)` the python keeper uses, so the
//! bytes the phone's `zlib` inflates are the python bytes. Each `compress_vec`
//! writes into the buffer's *spare capacity*, so the buffer is grown before
//! every batch.

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use flate2::Compress;
use flate2::Compression;
use flate2::FlushCompress;
use std::cell::RefCell;
use std::rc::Rc;

/// The smallest batch worth zipping (python `ATTACH_ZIP_MIN`).
pub const ATTACH_ZIP_MIN: usize = 512;

/// One zlib stream, shared by every batch of a command. `Rc<RefCell<..>>` so
/// the compressor's state (which carries on across batches) can be borrowed by
/// a closure the `follow` loop re-enters.
pub type Zlib = Rc<RefCell<Compress>>;

/// A fresh level-6 zlib stream (the phone's `zlib` inflates RFC 1950).
#[must_use]
pub fn new_stream() -> Zlib {
    Rc::new(RefCell::new(Compress::new(Compression::new(6), true)))
}

/// The bytes [data] adds to the stream: its compressed form plus a sync flush,
/// so the phone can inflate it the moment it arrives. The stream state stays in
/// [z] for the next batch.
fn compressed(z: &Zlib, data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len() + 64);
    // `compress_vec` writes into the buffer's spare capacity.
    z.borrow_mut()
        .compress_vec(data, &mut out, FlushCompress::Sync)
        .expect("zlib does not fail on valid input");
    out
}

/// `Z<base64 of the next piece of [z]>` for a whole-line batch [data], or [data]
/// as-is when it is not big enough to gain from zipping. [data] is the batch
/// without its trailing newline; the zipped case appends it.
pub fn zipped_batch(z: &Zlib, data: &[u8]) -> Vec<u8> {
    if data.len() < ATTACH_ZIP_MIN {
        return data.to_vec();
    }
    let mut out = b"Z".to_vec();
    out.extend_from_slice(B64.encode(compressed(z, data)).as_bytes());
    out.push(b'\n');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn small_batches_stay_plain() {
        let z = new_stream();
        let small = b"hello\n";
        assert_eq!(zipped_batch(&z, small), small);
    }

    #[test]
    fn big_batches_are_one_inflating_stream() {
        let z = new_stream();
        let a: Vec<u8> = (0..600u32).map(|i| b'a' + (i % 10) as u8).collect();
        let b: Vec<u8> = (0..600u32).map(|i| b'A' + (i % 10) as u8).collect();
        let la = zipped_batch(&z, &a);
        let lb = zipped_batch(&z, &b);
        assert!(la.starts_with(b"Z") && la.ends_with(b"\n"));
        assert!(lb.starts_with(b"Z") && lb.ends_with(b"\n"));
        // The phone reads each `Z` line as one piece of ONE zlib stream
        // (`ZippedLines`) and inflates it streaming — a `zlib` decompressor fed
        // piece by piece, never a finalized stream. Do the same. `decompress_vec`
        // writes into the buffer's spare capacity, so reserve for the inflated
        // size (a batch inflates back to its full length).
        let mut dec = flate2::Decompress::new(true);
        let mut out = Vec::new();
        for line in [&la, &lb] {
            let b64 = std::str::from_utf8(&line[1..line.len() - 1]).expect("a zipped line is utf8");
            let piece = B64.decode(b64).expect("a zipped line is valid base64");
            out.reserve(8192);
            dec.decompress_vec(&piece, &mut out, flate2::FlushDecompress::Sync)
                .expect("zlib does not fail on a stream it compressed");
        }
        assert_eq!(out, a.iter().chain(b.iter()).copied().collect::<Vec<_>>());
    }
}
