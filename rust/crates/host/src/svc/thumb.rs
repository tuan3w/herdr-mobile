//! `fs.thumb`: a small JPEG of a picture on the host, so a grid of photos costs
//! a few KB a cell instead of the whole files.
//!
//! The stack is pure Rust (a static musl binary stays static): `jpeg-decoder`
//! for JPEG, `png`, `image-webp` and `gif` for the rest, and `jpeg-encoder` for
//! the output. Nothing is written on the host.
//!
//! Memory is bounded without reading the file into memory: the header says how
//! many pixels there are (over [`MAX_PIXELS`] is refused before any decoding),
//! a JPEG is decoded at 1/2, 1/4 or 1/8 of its size (the decoder's own DCT
//! scaling, so a 12 MP photo costs the work of a 0.2 MP one), and PNG rows
//! are fed one at a time into an area-averaging [`Resizer`], so a big PNG
//! never exists in memory as a whole. WebP and GIF decode into one buffer of
//! the picture's size (at most 4 bytes a pixel).

use crate::service::{Class, MethodKind, MethodSpec};
use crate::session::{Compress, StreamCtx};
use crate::svc::fs::{io_error, mtime_ms, open_regular, parse_args, resolve, Identity};
use serde::Deserialize;
use serde_json::{json, Value};
use std::fs::File;
use std::io::{self, BufReader, Read, Seek, SeekFrom};
use wire::{ErrorCode, WireError};

/// The biggest source file `fs.thumb` opens.
pub const MAX_SOURCE_BYTES: u64 = 64 * 1024 * 1024;

/// The most pixels (width times height) of a source: 64 Mpx, counted as 64 * 2^20.
pub const MAX_PIXELS: u64 = 64 * 1024 * 1024;

pub const MIN_MAX_PX: i64 = 32;
pub const MAX_MAX_PX: i64 = 1024;
const DEFAULT_MAX_PX: i64 = 256;
pub const MIN_QUALITY: i64 = 30;
pub const MAX_QUALITY: i64 = 90;
const DEFAULT_QUALITY: i64 = 70;

pub(crate) const SPEC: MethodSpec = MethodSpec {
    name: "thumb",
    kind: MethodKind::Stream,
    class: Class::Bulk,
    summary: "A JPEG thumbnail of a picture (JPEG, PNG, WebP, GIF first frame; no HEIC, SVG or RAW). The longest edge is `max_px` (32..1024, default 256), never enlarged; `quality` is 30..90 (default 70); EXIF orientation is applied. First MSG {width,height,size,mtime_ms,format:\"jpeg\",source_size}: width and height of the thumbnail, size, mtime_ms and source_size of the source file. Then DATA (the JPEG bytes), then END {}. `if_match` differing from the file ends with error `changed` before anything is decoded. Errors not_found, permission, not_a_file, too_large (source over 64 MiB or 64 Mpx), changed, failed with a message starting `unsupported image` for anything that cannot be decoded. Nothing is cached or written on the host.",
    args_example: r#"{"path":"~/Pictures/cat.jpg","max_px":256,"quality":70,"if_match":{"size":2400000,"mtime_ms":1760000000000}}"#,
    result_example: r#"{}"#,
};

#[derive(Debug, Deserialize)]
pub(crate) struct ThumbArgs {
    pub path: String,
    #[serde(default = "default_max_px")]
    pub max_px: i64,
    #[serde(default = "default_quality")]
    pub quality: i64,
    #[serde(default)]
    pub if_match: Option<Identity>,
}

fn default_max_px() -> i64 {
    DEFAULT_MAX_PX
}

fn default_quality() -> i64 {
    DEFAULT_QUALITY
}

fn cancelled() -> WireError {
    WireError::new(ErrorCode::Cancelled, "the stream was closed")
}

/// `fs.thumb` on a stream.
pub(crate) fn thumb(ctx: &StreamCtx) -> Result<Value, WireError> {
    let args: ThumbArgs = parse_args(ctx.args())?;
    let path = resolve(ctx.home(), &args.path)?;
    // A JPEG does not compress: the writer would try and fail on every frame.
    ctx.set_compress(Compress::Never);
    let (file, meta) = open_regular(&path, &args.path)?;
    let (size, mtime) = (meta.len(), mtime_ms(&meta));
    if let Some(want) = &args.if_match {
        if want.size != size || want.mtime_ms != mtime {
            return Err(WireError::new(
                ErrorCode::Changed,
                format!("{}: the file changed", args.path),
            ));
        }
    }
    if size > MAX_SOURCE_BYTES {
        return Err(too_large(&args.path, "is over 64 MiB"));
    }
    let max_px = u32::try_from(args.max_px.clamp(MIN_MAX_PX, MAX_MAX_PX)).unwrap_or(256);
    let quality = u8::try_from(args.quality.clamp(MIN_QUALITY, MAX_QUALITY)).unwrap_or(70);
    let made = make(file, &args.path, max_px, quality, &|| ctx.cancelled())?;
    if ctx.cancelled() {
        return Err(cancelled());
    }
    ctx.send_msg(&json!({
        "width": made.width,
        "height": made.height,
        "size": size,
        "mtime_ms": mtime,
        "format": "jpeg",
        "source_size": size,
    }))?;
    ctx.send_data(&made.jpeg)?;
    Ok(json!({}))
}

fn too_large(given: &str, why: &str) -> WireError {
    WireError::new(ErrorCode::TooLarge, format!("{given}: {why}"))
}

/// A finished thumbnail.
#[derive(Debug)]
pub(crate) struct Made {
    pub width: u32,
    pub height: u32,
    pub jpeg: Vec<u8>,
}

/// Why a picture could not be made into a thumbnail, before it is worded.
#[derive(Debug)]
enum Fail {
    Cancelled,
    TooLarge(String),
    /// The bytes are not a picture this build decodes.
    Bad(String),
    Io(io::Error),
}

impl Fail {
    fn wire(self, given: &str) -> WireError {
        match self {
            Fail::Cancelled => cancelled(),
            Fail::TooLarge(why) => too_large(given, &why),
            Fail::Bad(why) => WireError::new(
                ErrorCode::Failed,
                format!("unsupported image: {given}: {why}"),
            ),
            Fail::Io(e) if e.kind() == io::ErrorKind::UnexpectedEof => WireError::new(
                ErrorCode::Failed,
                format!("unsupported image: {given}: the file ends early"),
            ),
            Fail::Io(e) => io_error(&e, given),
        }
    }
}

type Res<T> = Result<T, Fail>;

/// Reads through to the file, failing the read once the stream is cancelled so
/// a decoder stops between two blocks instead of finishing its picture.
struct CancelRead<'a> {
    inner: File,
    cancel: &'a dyn Fn() -> bool,
}

impl Read for CancelRead<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if (self.cancel)() {
            return Err(io::Error::other("cancelled"));
        }
        self.inner.read(buf)
    }
}

impl Seek for CancelRead<'_> {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        self.inner.seek(pos)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Format {
    Jpeg,
    Png,
    Webp,
    Gif,
}

fn sniff(head: &[u8]) -> Option<Format> {
    if head.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some(Format::Jpeg)
    } else if head.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        Some(Format::Png)
    } else if head.len() >= 12 && &head[..4] == b"RIFF" && &head[8..12] == b"WEBP" {
        Some(Format::Webp)
    } else if head.starts_with(b"GIF8") {
        Some(Format::Gif)
    } else {
        None
    }
}

/// Makes the thumbnail of the picture in `file`. `cancel` is polled between
/// reads, so a reset stream stops the work.
pub(crate) fn make(
    file: File,
    given: &str,
    max_px: u32,
    quality: u8,
    cancel: &dyn Fn() -> bool,
) -> Result<Made, WireError> {
    let mut source = CancelRead {
        inner: file,
        cancel,
    };
    let mut go = || -> Res<Made> {
        let mut head = [0u8; 12];
        let mut have = 0;
        while have < head.len() {
            match source.read(&mut head[have..]) {
                Ok(0) => break,
                Ok(n) => have += n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) => return Err(Fail::Io(e)),
            }
        }
        let Some(format) = sniff(&head[..have]) else {
            return Err(Fail::Bad("not a JPEG, PNG, WebP or GIF picture".into()));
        };
        source.seek(SeekFrom::Start(0)).map_err(Fail::Io)?;
        let reader = BufReader::with_capacity(32 * 1024, &mut source);
        let (rgb, w, h, orientation) = match format {
            Format::Jpeg => decode_jpeg(reader, max_px)?,
            Format::Png => decode_png(reader, max_px, cancel)?,
            Format::Webp => decode_webp(reader, max_px)?,
            Format::Gif => decode_gif(reader, max_px)?,
        };
        let (rgb, w, h) = orient(rgb, w, h, orientation);
        encode(&rgb, w, h, quality)
    };
    match go() {
        Ok(made) => Ok(made),
        // A decoder reports the failed read in its own words: say what
        // really happened.
        Err(_) if cancel() => Err(cancelled()),
        Err(e) => Err(e.wire(given)),
    }
}

fn encode(rgb: &[u8], w: u32, h: u32, quality: u8) -> Res<Made> {
    let (Ok(w16), Ok(h16)) = (u16::try_from(w), u16::try_from(h)) else {
        return Err(Fail::Bad("the picture is too wide to encode".into()));
    };
    let mut jpeg = Vec::with_capacity(8 * 1024);
    let encoder = jpeg_encoder::Encoder::new(&mut jpeg, quality);
    encoder
        .encode(rgb, w16, h16, jpeg_encoder::ColorType::Rgb)
        .map_err(|e| Fail::Bad(format!("cannot encode: {e}")))?;
    Ok(Made {
        width: w,
        height: h,
        jpeg,
    })
}

// ---- sizes ----

fn check_pixels(w: u32, h: u32) -> Res<()> {
    if w == 0 || h == 0 {
        return Err(Fail::Bad("the picture is empty".into()));
    }
    if u64::from(w) * u64::from(h) > MAX_PIXELS {
        return Err(Fail::TooLarge(format!(
            "is {w}x{h}, over {} megapixels",
            MAX_PIXELS / 1024 / 1024
        )));
    }
    Ok(())
}

/// The size of the thumbnail of a `w` by `h` picture: the longest edge is
/// `max_px` (exactly), the other keeps the ratio, never below 1, never larger
/// than the source.
pub(crate) fn target_size(w: u32, h: u32, max_px: u32) -> (u32, u32) {
    let longest = w.max(h);
    if longest <= max_px {
        return (w, h);
    }
    let shrink = |edge: u32| -> u32 {
        if edge == longest {
            max_px
        } else {
            let scaled =
                (u64::from(edge) * u64::from(max_px) + u64::from(longest) / 2) / u64::from(longest);
            u32::try_from(scaled).unwrap_or(1).max(1)
        }
    };
    (shrink(w), shrink(h))
}

// ---- EXIF orientation ----

/// The orientation (1..=8) in the EXIF block starting at its TIFF header; 1
/// (upright) when there is none or it makes no sense.
pub(crate) fn exif_orientation(tiff: &[u8]) -> u8 {
    let parse = || -> Option<u8> {
        let big = match tiff.get(..2)? {
            b"MM" => true,
            b"II" => false,
            _ => return None,
        };
        let u16_at = |at: usize| -> Option<u16> {
            let b: [u8; 2] = tiff.get(at..at + 2)?.try_into().ok()?;
            Some(if big {
                u16::from_be_bytes(b)
            } else {
                u16::from_le_bytes(b)
            })
        };
        let u32_at = |at: usize| -> Option<u32> {
            let b: [u8; 4] = tiff.get(at..at + 4)?.try_into().ok()?;
            Some(if big {
                u32::from_be_bytes(b)
            } else {
                u32::from_le_bytes(b)
            })
        };
        if u16_at(2)? != 42 {
            return None;
        }
        let ifd = usize::try_from(u32_at(4)?).ok()?;
        let count = usize::from(u16_at(ifd)?);
        for i in 0..count {
            let entry = ifd.checked_add(2)?.checked_add(i.checked_mul(12)?)?;
            if u16_at(entry)? == 0x0112 {
                let value = u16_at(entry.checked_add(8)?)?;
                return u8::try_from(value).ok().filter(|v| (1..=8).contains(v));
            }
        }
        None
    };
    parse().unwrap_or(1)
}

/// Turns the pixels so that what the camera meant as up is up. The picture is
/// already thumbnail-sized, so this costs nothing.
pub(crate) fn orient(rgb: Vec<u8>, w: u32, h: u32, orientation: u8) -> (Vec<u8>, u32, u32) {
    if orientation <= 1 || orientation > 8 {
        return (rgb, w, h);
    }
    let (w, h) = (w as usize, h as usize);
    let (nw, nh) = if orientation >= 5 { (h, w) } else { (w, h) };
    let mut out = vec![0u8; rgb.len()];
    for y in 0..nh {
        for x in 0..nw {
            let (sx, sy) = match orientation {
                2 => (w - 1 - x, y),
                3 => (w - 1 - x, h - 1 - y),
                4 => (x, h - 1 - y),
                5 => (y, x),
                6 => (y, h - 1 - x),
                7 => (w - 1 - y, h - 1 - x),
                _ => (w - 1 - y, x),
            };
            let from = (sy * w + sx) * 3;
            let to = (y * nw + x) * 3;
            out[to..to + 3].copy_from_slice(&rgb[from..from + 3]);
        }
    }
    (out, nw as u32, nh as u32)
}

// ---- resizing ----

/// What a source row holds per pixel.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Layout {
    Gray,
    GrayAlpha,
    Rgb,
    Rgba,
}

impl Layout {
    fn channels(self) -> usize {
        match self {
            Layout::Gray => 1,
            Layout::GrayAlpha => 2,
            Layout::Rgb => 3,
            Layout::Rgba => 4,
        }
    }
}

/// Area-averaging downscaler fed one source row at a time. Transparent pixels
/// are composited on white before averaging (so a PNG logo does not grow a
/// dark fringe). The output never exceeds the source: a `dw`/`dh` equal to
/// `sw`/`sh` copies.
struct Resizer {
    layout: Layout,
    sw: usize,
    sh: usize,
    dw: usize,
    dh: usize,
    /// For each destination column: the first source column and where its
    /// normalised weights start in `weights`.
    spans: Vec<(usize, usize)>,
    weights: Vec<f32>,
    rgb: Vec<u8>,
    hrow: Vec<f32>,
    acc: Vec<f32>,
    wsum: f32,
    vr: f64,
    y: usize,
    j: usize,
    out: Vec<u8>,
}

impl Resizer {
    fn new(layout: Layout, sw: u32, sh: u32, dw: u32, dh: u32) -> Self {
        let (sw, sh, dw, dh) = (sw as usize, sh as usize, dw as usize, dh as usize);
        let hr = sw as f64 / dw as f64;
        let mut spans = Vec::with_capacity(dw);
        let mut weights = Vec::with_capacity(sw + dw);
        for i in 0..dw {
            let start = i as f64 * hr;
            let end = ((i + 1) as f64 * hr).min(sw as f64);
            let first = start.floor() as usize;
            let last = (end.ceil() as usize).saturating_sub(1).min(sw - 1);
            let at = weights.len();
            let mut total = 0.0f64;
            for s in first..=last {
                let w = end.min((s + 1) as f64) - start.max(s as f64);
                let w = w.max(0.0);
                total += w;
                weights.push(w as f32);
            }
            if total > 0.0 {
                for w in &mut weights[at..] {
                    *w = (f64::from(*w) / total) as f32;
                }
            } else {
                weights[at] = 1.0;
            }
            spans.push((first, at));
        }
        Self {
            layout,
            sw,
            sh,
            dw,
            dh,
            spans,
            weights,
            rgb: vec![0; sw * 3],
            hrow: vec![0.0; dw * 3],
            acc: vec![0.0; dw * 3],
            wsum: 0.0,
            vr: sh as f64 / dh as f64,
            y: 0,
            j: 0,
            out: Vec::with_capacity(dw * dh * 3),
        }
    }

    /// Converts a source row to opaque RGB in `self.rgb`.
    fn fill_rgb(&mut self, row: &[u8]) {
        let ch = self.layout.channels();
        let px = row.chunks_exact(ch).take(self.sw);
        let white = |c: u8, a: u8| -> u8 {
            let (c, a) = (u32::from(c), u32::from(a));
            u8::try_from((c * a + 255 * (255 - a) + 127) / 255).unwrap_or(255)
        };
        let (out, _) = self.rgb.as_chunks_mut::<3>();
        for (p, o) in px.zip(out) {
            match self.layout {
                Layout::Gray => *o = [p[0]; 3],
                Layout::GrayAlpha => *o = [white(p[0], p[1]); 3],
                Layout::Rgb => o.copy_from_slice(p),
                Layout::Rgba => *o = [white(p[0], p[3]), white(p[1], p[3]), white(p[2], p[3])],
            }
        }
    }

    /// Takes the next source row (top to bottom).
    fn push(&mut self, row: &[u8]) {
        if self.y >= self.sh || row.len() < self.sw * self.layout.channels() {
            return;
        }
        self.fill_rgb(row);
        for (i, &(first, at)) in self.spans.iter().enumerate() {
            let next = self.spans.get(i + 1).map_or(self.weights.len(), |s| s.1);
            let (mut r, mut g, mut b) = (0.0f32, 0.0f32, 0.0f32);
            for (k, &w) in self.weights[at..next].iter().enumerate() {
                let p = (first + k) * 3;
                r += w * f32::from(self.rgb[p]);
                g += w * f32::from(self.rgb[p + 1]);
                b += w * f32::from(self.rgb[p + 2]);
            }
            self.hrow[i * 3] = r;
            self.hrow[i * 3 + 1] = g;
            self.hrow[i * 3 + 2] = b;
        }
        let y0 = self.y as f64;
        let y1 = y0 + 1.0;
        self.y += 1;
        while self.j < self.dh {
            let top = self.j as f64 * self.vr;
            let bottom = (self.j + 1) as f64 * self.vr;
            let w = (y1.min(bottom) - y0.max(top)) as f32;
            if w > 0.0 {
                for (a, h) in self.acc.iter_mut().zip(&self.hrow) {
                    *a += w * h;
                }
                self.wsum += w;
            }
            if y1 + 1e-9 >= bottom {
                self.flush_row();
            } else {
                break;
            }
        }
    }

    fn flush_row(&mut self) {
        let scale = if self.wsum > 0.0 {
            1.0 / self.wsum
        } else {
            0.0
        };
        for a in &mut self.acc {
            self.out.push((*a * scale + 0.5).clamp(0.0, 255.0) as u8);
            *a = 0.0;
        }
        self.wsum = 0.0;
        self.j += 1;
    }

    /// The RGB bytes, `dw * dh * 3`; an error when the source gave fewer rows
    /// than it promised.
    fn finish(mut self) -> Res<Vec<u8>> {
        if self.y < self.sh {
            return Err(Fail::Bad("the picture ends early".into()));
        }
        if self.j < self.dh && self.wsum > 0.0 {
            self.flush_row();
        }
        if self.out.len() != self.dw * self.dh * 3 {
            return Err(Fail::Bad("the picture could not be scaled".into()));
        }
        Ok(self.out)
    }
}

/// Feeds every row of a decoded buffer of `w` by `h` through a [`Resizer`]
/// down to `dw` by `dh`.
fn resize_buffer(
    layout: Layout,
    buf: &[u8],
    (w, h): (u32, u32),
    (dw, dh): (u32, u32),
) -> Res<Vec<u8>> {
    let mut rz = Resizer::new(layout, w, h, dw, dh);
    let stride = w as usize * layout.channels();
    for row in buf.chunks_exact(stride).take(h as usize) {
        rz.push(row);
    }
    rz.finish()
}

type Decoded = (Vec<u8>, u32, u32, u8);

// ---- decoders ----

fn jpeg_fail(e: jpeg_decoder::Error) -> Fail {
    match e {
        jpeg_decoder::Error::Io(e) => Fail::Io(e),
        jpeg_decoder::Error::Unsupported(f) => {
            Fail::Bad(format!("unsupported JPEG feature: {f:?}"))
        }
        other => Fail::Bad(other.to_string()),
    }
}

fn decode_jpeg<R: Read>(reader: R, max_px: u32) -> Res<Decoded> {
    let mut decoder = jpeg_decoder::Decoder::new(reader);
    decoder.read_info().map_err(jpeg_fail)?;
    let info = decoder
        .info()
        .ok_or_else(|| Fail::Bad("no header".into()))?;
    let (w, h) = (u32::from(info.width), u32::from(info.height));
    check_pixels(w, h)?;
    let (dw, dh) = target_size(w, h, max_px);
    // The decoder picks the smallest of 1/8, 1/4, 1/2, 1 that is still at
    // least the requested size in ONE axis; asking for the longest edge in
    // both axes makes that axis the longest one. The area average does the rest.
    let (sw, sh) = if (dw, dh) == (w, h) {
        (w, h)
    } else {
        let ask = u16::try_from(dw.max(dh)).unwrap_or(u16::MAX);
        let (a, b) = decoder.scale(ask, ask).map_err(jpeg_fail)?;
        (u32::from(a), u32::from(b))
    };
    let pixels = decoder.decode().map_err(jpeg_fail)?;
    let layout = match info.pixel_format {
        jpeg_decoder::PixelFormat::L8 => Layout::Gray,
        jpeg_decoder::PixelFormat::RGB24 => Layout::Rgb,
        jpeg_decoder::PixelFormat::L16 => return Err(Fail::Bad("16-bit JPEG".into())),
        jpeg_decoder::PixelFormat::CMYK32 => return Err(Fail::Bad("CMYK JPEG".into())),
    };
    let orientation = decoder.exif_data().map_or(1, exif_orientation);
    let (dw, dh) = (dw.min(sw), dh.min(sh));
    let rgb = resize_buffer(layout, &pixels, (sw, sh), (dw, dh))?;
    Ok((rgb, dw, dh, orientation))
}

fn decode_png<R: io::BufRead + Seek>(
    reader: R,
    max_px: u32,
    cancel: &dyn Fn() -> bool,
) -> Res<Decoded> {
    let png_fail = |e: png::DecodingError| match e {
        png::DecodingError::IoError(e) => Fail::Io(e),
        other => Fail::Bad(other.to_string()),
    };
    let mut decoder = png::Decoder::new(reader);
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    decoder.set_limits(png::Limits {
        bytes: usize::try_from(MAX_PIXELS)
            .unwrap_or(usize::MAX)
            .saturating_mul(8),
    });
    let mut reader = decoder.read_info().map_err(png_fail)?;
    let (w, h) = {
        let info = reader.info();
        (info.width, info.height)
    };
    check_pixels(w, h)?;
    let (color, depth) = reader.output_color_type();
    if depth != png::BitDepth::Eight {
        return Err(Fail::Bad("unexpected PNG bit depth".into()));
    }
    let layout = match color {
        png::ColorType::Grayscale => Layout::Gray,
        png::ColorType::GrayscaleAlpha => Layout::GrayAlpha,
        png::ColorType::Rgb => Layout::Rgb,
        png::ColorType::Rgba => Layout::Rgba,
        png::ColorType::Indexed => return Err(Fail::Bad("unexpanded palette".into())),
    };
    let orientation = reader
        .info()
        .exif_metadata
        .as_deref()
        .map_or(1, exif_orientation);
    let (dw, dh) = target_size(w, h, max_px);
    let mut rz = Resizer::new(layout, w, h, dw, dh);
    let mut rows = 0u32;
    while let Some(row) = reader.next_row().map_err(png_fail)? {
        rz.push(row.data());
        rows += 1;
        if rows.is_multiple_of(64) && cancel() {
            return Err(Fail::Cancelled);
        }
    }
    Ok((rz.finish()?, dw, dh, orientation))
}

fn decode_webp<R: io::BufRead + Seek>(reader: R, max_px: u32) -> Res<Decoded> {
    let webp_fail = |e: image_webp::DecodingError| match e {
        image_webp::DecodingError::IoError(e) => Fail::Io(e),
        other => Fail::Bad(other.to_string()),
    };
    let mut decoder = image_webp::WebPDecoder::new(reader).map_err(webp_fail)?;
    let (w, h) = decoder.dimensions();
    check_pixels(w, h)?;
    let layout = if decoder.has_alpha() {
        Layout::Rgba
    } else {
        Layout::Rgb
    };
    let size = decoder
        .output_buffer_size()
        .ok_or_else(|| Fail::TooLarge("is too large to decode".into()))?;
    let mut buf = vec![0u8; size];
    decoder.read_image(&mut buf).map_err(webp_fail)?;
    let orientation = decoder
        .exif_metadata()
        .ok()
        .flatten()
        .map_or(1, |e| exif_orientation(strip_exif_prefix(&e)));
    let (dw, dh) = target_size(w, h, max_px);
    let rgb = resize_buffer(layout, &buf, (w, h), (dw, dh))?;
    Ok((rgb, dw, dh, orientation))
}

/// An EXIF block may start with the `Exif\0\0` marker JPEG puts before the
/// TIFF header.
fn strip_exif_prefix(exif: &[u8]) -> &[u8] {
    exif.strip_prefix(b"Exif\0\0").unwrap_or(exif)
}

fn decode_gif<R: Read>(reader: R, max_px: u32) -> Res<Decoded> {
    let gif_fail = |e: gif::DecodingError| match e {
        gif::DecodingError::Io(e) => Fail::Io(e),
        other => Fail::Bad(other.to_string()),
    };
    let mut options = gif::DecodeOptions::new();
    options.set_color_output(gif::ColorOutput::RGBA);
    options.set_memory_limit(gif::MemoryLimit::Bytes(
        std::num::NonZeroU64::new(MAX_PIXELS.saturating_mul(4))
            .unwrap_or(std::num::NonZeroU64::MIN),
    ));
    let mut decoder = options.read_info(reader).map_err(gif_fail)?;
    let (w, h) = (u32::from(decoder.width()), u32::from(decoder.height()));
    check_pixels(w, h)?;
    let frame = decoder
        .read_next_frame()
        .map_err(gif_fail)?
        .ok_or_else(|| Fail::Bad("the GIF has no frames".into()))?;
    // The first frame may cover only part of the screen: put it on a
    // transparent canvas the size of the screen.
    let (fw, fh) = (usize::from(frame.width), usize::from(frame.height));
    let (left, top) = (usize::from(frame.left), usize::from(frame.top));
    let mut canvas = vec![0u8; w as usize * h as usize * 4];
    for y in 0..fh.min((h as usize).saturating_sub(top)) {
        let take = fw.min((w as usize).saturating_sub(left));
        let from = y * fw * 4;
        let to = ((top + y) * w as usize + left) * 4;
        canvas[to..to + take * 4].copy_from_slice(&frame.buffer[from..from + take * 4]);
    }
    let (dw, dh) = target_size(w, h, max_px);
    let rgb = resize_buffer(Layout::Rgba, &canvas, (w, h), (dw, dh))?;
    Ok((rgb, dw, dh, 1))
}

#[cfg(test)]
mod tests;
