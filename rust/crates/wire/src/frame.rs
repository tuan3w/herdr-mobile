//! Frames: `len:u32le` · `kind:u8` · `stream:u32le` · payload, where `len`
//! counts everything after itself (1 + 4 + payload). The high bits of `kind`
//! are flags (see [`Flags`]).

use std::io::{self, Read, Write};

/// What the host writes first, before any frame. 14 bytes. A client skips
/// whatever precedes it (a login shell's noise) up to a cap.
pub const MAGIC: &[u8; 14] = b"\xFFHERDR-HOST/1\n";

/// Largest wire payload of any frame but DATA.
pub const MAX_PAYLOAD: usize = 1 << 20;

/// Largest wire payload of a DATA frame.
pub const MAX_DATA: usize = 32 * 1024;

const HEADER: usize = 5;

/// The seven frame types.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Kind {
    Hello = 1,
    Open = 2,
    Msg = 3,
    Data = 4,
    Credit = 5,
    End = 6,
    Reset = 7,
}

impl Kind {
    fn from_u8(b: u8) -> Option<Self> {
        Some(match b {
            1 => Self::Hello,
            2 => Self::Open,
            3 => Self::Msg,
            4 => Self::Data,
            5 => Self::Credit,
            6 => Self::End,
            7 => Self::Reset,
            _ => return None,
        })
    }

    /// Whether a frame of this kind may carry compressed payloads.
    fn may_deflate(self) -> bool {
        matches!(self, Self::Msg | Self::Data | Self::End)
    }

    /// The name vectors and logs use.
    #[must_use]
    pub fn name(self) -> &'static str {
        match self {
            Self::Hello => "hello",
            Self::Open => "open",
            Self::Msg => "msg",
            Self::Data => "data",
            Self::Credit => "credit",
            Self::End => "end",
            Self::Reset => "reset",
        }
    }
}

/// How a payload is compressed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Flags {
    /// Plain bytes.
    None,
    /// The payload is one complete zlib stream (`0x80`).
    Deflate,
    /// The payload is the next sync-flushed piece of the stream's one
    /// continuous zlib stream for that direction (`0x40`; only on a stream
    /// opened with `zctx`, each direction having its own zlib stream).
    DeflateCtx,
}

impl Flags {
    fn bits(self) -> u8 {
        match self {
            Self::None => 0,
            Self::Deflate => 0x80,
            Self::DeflateCtx => 0x40,
        }
    }

    /// The name vectors use.
    #[must_use]
    pub fn name(self) -> &'static str {
        match self {
            Self::None => "",
            Self::Deflate => "deflate",
            Self::DeflateCtx => "deflate_ctx",
        }
    }
}

/// One frame. `payload` is the bytes on the wire: compressed when `flags` says
/// so; inflating is the caller's step (it needs the stream's state).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Frame {
    pub kind: Kind,
    pub flags: Flags,
    pub stream: u32,
    pub payload: Vec<u8>,
}

impl Frame {
    #[must_use]
    pub fn new(kind: Kind, stream: u32, payload: Vec<u8>) -> Self {
        Self {
            kind,
            flags: Flags::None,
            stream,
            payload,
        }
    }

    /// A frame whose payload is already compressed as `flags` says.
    #[must_use]
    pub fn compressed(kind: Kind, flags: Flags, stream: u32, payload: Vec<u8>) -> Self {
        Self {
            kind,
            flags,
            stream,
            payload,
        }
    }

    /// A frame carrying `value` as JSON.
    #[must_use]
    pub fn json(kind: Kind, stream: u32, value: &serde_json::Value) -> Self {
        Self::new(kind, stream, value.to_string().into_bytes())
    }

    /// A `CREDIT` frame granting `bytes`.
    #[must_use]
    pub fn credit(stream: u32, bytes: u32) -> Self {
        Self::new(Kind::Credit, stream, bytes.to_le_bytes().to_vec())
    }

    /// The bytes a `CREDIT` frame grants, if this is a well-formed one.
    #[must_use]
    pub fn credit_bytes(&self) -> Option<u32> {
        (self.kind == Kind::Credit)
            .then(|| <[u8; 4]>::try_from(self.payload.as_slice()).ok())
            .flatten()
            .map(u32::from_le_bytes)
    }
}

/// Why bytes are not a frame, or a frame is not acceptable.
#[derive(Debug)]
pub enum FrameError {
    Io(io::Error),
    /// The stream ended inside a frame.
    Truncated,
    /// `len` is smaller than the header.
    BadLength(u32),
    /// The payload exceeds what its kind allows.
    TooLarge(usize),
    UnknownKind(u8),
    /// A flag that its kind does not take.
    BadFlags {
        kind: u8,
    },
    /// A compressed payload that does not inflate, or inflates past the cap.
    Inflate(String),
}

impl FrameError {
    /// The name vectors use.
    #[must_use]
    pub fn name(&self) -> &'static str {
        match self {
            Self::Io(_) => "io",
            Self::Truncated => "truncated",
            Self::BadLength(_) => "bad_length",
            Self::TooLarge(_) => "too_large",
            Self::UnknownKind(_) => "unknown_kind",
            Self::BadFlags { .. } => "bad_flags",
            Self::Inflate(_) => "inflate",
        }
    }
}

impl std::fmt::Display for FrameError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "i/o error: {e}"),
            Self::Truncated => write!(f, "the stream ended inside a frame"),
            Self::BadLength(n) => write!(f, "frame length {n} is smaller than its header"),
            Self::TooLarge(n) => write!(f, "frame payload of {n} bytes is over the limit"),
            Self::UnknownKind(k) => write!(f, "unknown frame kind {k:#04x}"),
            Self::BadFlags { kind } => write!(f, "flags not allowed on frame kind {kind:#04x}"),
            Self::Inflate(why) => write!(f, "a compressed payload does not inflate: {why}"),
        }
    }
}

impl std::error::Error for FrameError {}

/// Appends `frame`'s bytes to `out`.
///
/// # Panics
/// When the payload exceeds its kind's limit: the sender splits first.
pub fn encode_frame(frame: &Frame, out: &mut Vec<u8>) {
    let limit = if frame.kind == Kind::Data {
        MAX_DATA
    } else {
        MAX_PAYLOAD
    };
    assert!(
        frame.payload.len() <= limit,
        "a {} payload of {} bytes is over {limit}",
        frame.kind.name(),
        frame.payload.len()
    );
    // `len` counts the header after itself plus the payload: at most 1 MiB + 5.
    let len = u32::try_from(HEADER + frame.payload.len()).expect("limit keeps len in u32");
    out.reserve(4 + HEADER + frame.payload.len());
    out.extend_from_slice(&len.to_le_bytes());
    out.push(frame.kind as u8 | frame.flags.bits());
    out.extend_from_slice(&frame.stream.to_le_bytes());
    out.extend_from_slice(&frame.payload);
}

/// Writes `frame` with one `write_all`, so concurrent writers that each hold the
/// lock for a whole frame never interleave.
///
/// # Errors
/// The writer's.
pub fn write_frame<W: Write>(w: &mut W, frame: &Frame) -> io::Result<()> {
    let mut bytes = Vec::new();
    encode_frame(frame, &mut bytes);
    w.write_all(&bytes)
}

/// Reads one frame. `Ok(None)` is a clean end of stream between frames.
///
/// # Errors
/// [`FrameError`] for a stream that is not valid `hostwire/1`.
pub fn read_frame<R: Read>(r: &mut R) -> Result<Option<Frame>, FrameError> {
    let mut len_bytes = [0u8; 4];
    loop {
        match r.read(&mut len_bytes[..1]) {
            Ok(0) => return Ok(None),
            Ok(_) => break,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(FrameError::Io(e)),
        }
    }
    read_rest(r, &mut len_bytes[1..])?;
    let len = u32::from_le_bytes(len_bytes);
    if (len as usize) < HEADER {
        return Err(FrameError::BadLength(len));
    }
    // Refuse before allocating: a hostile length must not cost memory.
    let payload_len = len as usize - HEADER;
    if payload_len > MAX_PAYLOAD {
        return Err(FrameError::TooLarge(payload_len));
    }
    let mut head = [0u8; HEADER];
    read_rest(r, &mut head)?;
    let raw_kind = head[0];
    let flags = match raw_kind & 0xC0 {
        0 => Flags::None,
        0x80 => Flags::Deflate,
        0x40 => Flags::DeflateCtx,
        _ => return Err(FrameError::BadFlags { kind: raw_kind }),
    };
    let kind = Kind::from_u8(raw_kind & 0x3F).ok_or(FrameError::UnknownKind(raw_kind & 0x3F))?;
    if flags != Flags::None && !kind.may_deflate() {
        return Err(FrameError::BadFlags { kind: raw_kind });
    }
    if kind == Kind::Data && payload_len > MAX_DATA {
        return Err(FrameError::TooLarge(payload_len));
    }
    let stream = u32::from_le_bytes([head[1], head[2], head[3], head[4]]);
    let mut payload = vec![0u8; payload_len];
    read_rest(r, &mut payload)?;
    Ok(Some(Frame {
        kind,
        flags,
        stream,
        payload,
    }))
}

fn read_rest<R: Read>(r: &mut R, buf: &mut [u8]) -> Result<(), FrameError> {
    r.read_exact(buf).map_err(|e| {
        if e.kind() == io::ErrorKind::UnexpectedEof {
            FrameError::Truncated
        } else {
            FrameError::Io(e)
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round(frame: &Frame) -> Frame {
        let mut bytes = Vec::new();
        encode_frame(frame, &mut bytes);
        read_frame(&mut bytes.as_slice())
            .expect("decodes")
            .expect("one frame")
    }

    #[test]
    fn the_layout_is_len_kind_stream_payload_little_endian() {
        // END {} on stream 5: len = 1 + 4 + 2 = 7.
        let mut bytes = Vec::new();
        encode_frame(&Frame::new(Kind::End, 5, b"{}".to_vec()), &mut bytes);
        assert_eq!(bytes, [7, 0, 0, 0, 6, 5, 0, 0, 0, b'{', b'}']);
        // A deflate flag sets the top bit of the kind byte.
        let mut bytes = Vec::new();
        encode_frame(
            &Frame::compressed(Kind::Msg, Flags::Deflate, 0x0102_0304, vec![9]),
            &mut bytes,
        );
        assert_eq!(bytes, [6, 0, 0, 0, 0x83, 4, 3, 2, 1, 9]);
    }

    #[test]
    fn every_kind_and_flag_survives_a_round_trip() {
        for kind in [
            Kind::Hello,
            Kind::Open,
            Kind::Msg,
            Kind::Data,
            Kind::Credit,
            Kind::End,
            Kind::Reset,
        ] {
            let f = Frame::new(kind, 7, vec![1, 2, 3]);
            assert_eq!(round(&f), f);
        }
        for flags in [Flags::Deflate, Flags::DeflateCtx] {
            let f = Frame::compressed(Kind::Data, flags, 9, vec![4, 5]);
            assert_eq!(round(&f), f);
        }
    }

    #[test]
    fn credit_carries_a_u32() {
        let f = Frame::credit(3, 524_288);
        assert_eq!(round(&f).credit_bytes(), Some(524_288));
        assert_eq!(Frame::new(Kind::Credit, 3, vec![1, 2]).credit_bytes(), None);
    }

    #[test]
    fn a_clean_end_between_frames_is_none_and_a_cut_frame_is_an_error() {
        assert!(read_frame(&mut [].as_slice()).expect("ok").is_none());
        let mut bytes = Vec::new();
        encode_frame(&Frame::new(Kind::Msg, 1, b"{}".to_vec()), &mut bytes);
        for cut in 1..bytes.len() {
            let err = read_frame(&mut &bytes[..cut]).expect_err("cut frame");
            assert_eq!(err.name(), "truncated", "cut at {cut}");
        }
    }

    #[test]
    fn hostile_headers_are_refused_before_any_allocation() {
        let too_big = u32::try_from(HEADER + MAX_PAYLOAD + 1).expect("fits");
        let err = read_frame(&mut too_big.to_le_bytes().as_slice()).expect_err("too large");
        assert_eq!(err.name(), "too_large");
        let err = read_frame(&mut 4u32.to_le_bytes().as_slice()).expect_err("short len");
        assert_eq!(err.name(), "bad_length");
        let mut unknown = vec![5, 0, 0, 0, 0x2A, 0, 0, 0, 0];
        assert_eq!(
            read_frame(&mut unknown.as_slice())
                .expect_err("unknown kind")
                .name(),
            "unknown_kind"
        );
        // Both compression bits at once, and a flag on a kind that takes none.
        unknown[4] = 0xC3;
        assert_eq!(
            read_frame(&mut unknown.as_slice())
                .expect_err("both flags")
                .name(),
            "bad_flags"
        );
        unknown[4] = 0x82;
        assert_eq!(
            read_frame(&mut unknown.as_slice())
                .expect_err("flag on open")
                .name(),
            "bad_flags"
        );
    }

    #[test]
    fn data_is_capped_lower_than_other_frames() {
        let mut bytes = Vec::new();
        let len = u32::try_from(HEADER + MAX_DATA + 1).expect("fits");
        bytes.extend_from_slice(&len.to_le_bytes());
        bytes.push(Kind::Data as u8);
        bytes.extend_from_slice(&1u32.to_le_bytes());
        bytes.resize(bytes.len() + MAX_DATA + 1, 0);
        assert_eq!(
            read_frame(&mut bytes.as_slice())
                .expect_err("big data")
                .name(),
            "too_large"
        );
    }

    #[test]
    #[should_panic(expected = "over")]
    fn encoding_an_oversize_data_frame_is_a_bug_in_the_sender() {
        let mut out = Vec::new();
        encode_frame(&Frame::new(Kind::Data, 1, vec![0; MAX_DATA + 1]), &mut out);
    }
}
