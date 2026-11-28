use super::*;

fn gradient(w: u32, h: u32) -> Vec<u8> {
    let mut v = Vec::with_capacity((w * h * 3) as usize);
    for y in 0..h {
        for x in 0..w {
            v.extend([(x * 255 / w) as u8, (y * 255 / h) as u8, 128]);
        }
    }
    v
}

/// Left half red, right half blue.
fn halves(w: u32, h: u32) -> Vec<u8> {
    let mut v = Vec::with_capacity((w * h * 3) as usize);
    for _ in 0..h {
        for x in 0..w {
            v.extend(if x < w / 2 { [255, 0, 0] } else { [0, 0, 255] });
        }
    }
    v
}

fn jpeg(rgb: &[u8], w: u32, h: u32) -> Vec<u8> {
    let mut out = Vec::new();
    jpeg_encoder::Encoder::new(&mut out, 90)
        .encode(rgb, w as u16, h as u16, jpeg_encoder::ColorType::Rgb)
        .expect("encode jpeg");
    out
}

/// An APP1 EXIF segment holding only the orientation, spliced after SOI.
fn with_exif(jpeg: &[u8], orientation: u16) -> Vec<u8> {
    let mut tiff = b"II\x2A\x00\x08\x00\x00\x00\x01\x00".to_vec();
    tiff.extend([0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00]);
    tiff.extend(orientation.to_le_bytes());
    tiff.extend([0, 0, 0, 0, 0, 0]);
    let len = u16::try_from(2 + 6 + tiff.len()).expect("fits");
    let mut out = jpeg[..2].to_vec();
    out.extend([0xFF, 0xE1]);
    out.extend(len.to_be_bytes());
    out.extend(b"Exif\0\0");
    out.extend(&tiff);
    out.extend(&jpeg[2..]);
    out
}

fn png(rgb: &[u8], w: u32, h: u32, color: png::ColorType) -> Vec<u8> {
    let mut out = Vec::new();
    let mut enc = png::Encoder::new(&mut out, w, h);
    enc.set_color(color);
    enc.set_depth(png::BitDepth::Eight);
    let mut writer = enc.write_header().expect("png header");
    let data: Vec<u8> = match color {
        png::ColorType::Rgb => rgb.to_vec(),
        png::ColorType::Rgba => rgb
            .chunks(3)
            .flat_map(|p| [p[0], p[1], p[2], 255])
            .collect(),
        png::ColorType::Grayscale => rgb.chunks(3).map(|p| p[0]).collect(),
        other => panic!("not used: {other:?}"),
    };
    writer.write_image_data(&data).expect("png data");
    writer.finish().expect("png end");
    out
}

fn webp(rgb: &[u8], w: u32, h: u32) -> Vec<u8> {
    let mut out = Vec::new();
    image_webp::WebPEncoder::new(&mut out)
        .encode(rgb, w, h, image_webp::ColorType::Rgb8)
        .expect("webp");
    out
}

fn gif(rgb: &[u8], w: u16, h: u16) -> Vec<u8> {
    // A 3-3-2 bit palette: 256 colours, the index is the colour.
    let palette: Vec<u8> = (0..=255u32)
        .flat_map(|i| {
            [
                (i >> 5) * 255 / 7,
                ((i >> 2) & 7) * 255 / 7,
                (i & 3) * 255 / 3,
            ]
        })
        .map(|c| c as u8)
        .collect();
    let indices: Vec<u8> = rgb
        .chunks(3)
        .map(|p| (p[0] & 0xE0) | ((p[1] >> 5) << 2) | (p[2] >> 6))
        .collect();
    let mut out = Vec::new();
    {
        let mut enc = gif::Encoder::new(&mut out, w, h, &palette).expect("gif header");
        let frame = gif::Frame::from_indexed_pixels(w, h, indices, None);
        enc.write_frame(&frame).expect("gif frame");
    }
    out
}

fn file_with(bytes: &[u8]) -> (tempfile::TempDir, File) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("picture");
    std::fs::write(&path, bytes).expect("write");
    let file = File::open(&path).expect("open");
    (dir, file)
}

fn thumb_of(bytes: &[u8], max_px: u32) -> Result<Made, WireError> {
    let (_dir, file) = file_with(bytes);
    make(file, "~/picture", max_px, 70, &|| false)
}

/// Decodes a thumbnail: (width, height, rgb).
fn open_jpeg(bytes: &[u8]) -> (u32, u32, Vec<u8>) {
    assert_eq!(&bytes[..3], &[0xFF, 0xD8, 0xFF], "JPEG magic");
    let mut d = jpeg_decoder::Decoder::new(bytes);
    let px = d.decode().expect("the thumbnail decodes");
    let info = d.info().expect("info");
    (u32::from(info.width), u32::from(info.height), px)
}

fn pixel(rgb: &[u8], w: u32, x: u32, y: u32) -> [u8; 3] {
    let i = ((y * w + x) * 3) as usize;
    [rgb[i], rgb[i + 1], rgb[i + 2]]
}

fn near(got: [u8; 3], want: [u8; 3]) -> bool {
    got.iter().zip(want).all(|(g, w)| g.abs_diff(w) < 48)
}

#[test]
fn the_catalog_arguments_have_defaults_and_clamps() {
    let a: ThumbArgs =
        serde_json::from_value(serde_json::json!({"path": "~/a.jpg"})).expect("args");
    assert_eq!((a.max_px, a.quality), (256, 70));
    assert!(a.if_match.is_none());
}

#[test]
fn a_jpeg_comes_back_with_its_longest_edge_at_max_px() {
    for (w, h, want) in [
        (800u32, 600u32, (256u32, 192u32)),
        (600, 800, (192, 256)),
        (1000, 100, (256, 26)),
        (3, 2000, (1, 256)),
    ] {
        let made = thumb_of(&jpeg(&gradient(w, h), w, h), 256).expect("thumb");
        assert_eq!((made.width, made.height), want, "{w}x{h}");
        let (ow, oh, _) = open_jpeg(&made.jpeg);
        assert_eq!((ow, oh), want, "the bytes agree with the header");
    }
}

#[test]
fn a_smaller_picture_is_never_enlarged() {
    let made = thumb_of(&jpeg(&gradient(64, 48), 64, 48), 256).expect("thumb");
    assert_eq!((made.width, made.height), (64, 48));
    let made = thumb_of(&png(&gradient(100, 50), 100, 50, png::ColorType::Rgb), 1024).expect("png");
    assert_eq!((made.width, made.height), (100, 50));
    let made = thumb_of(&gif(&gradient(20, 10), 20, 10), 256).expect("gif");
    assert_eq!((made.width, made.height), (20, 10));
}

#[test]
fn png_in_every_colour_layout_and_webp_and_gif_make_thumbnails() {
    let rgb = gradient(400, 300);
    for (what, bytes) in [
        ("rgb", png(&rgb, 400, 300, png::ColorType::Rgb)),
        ("rgba", png(&rgb, 400, 300, png::ColorType::Rgba)),
        ("gray", png(&rgb, 400, 300, png::ColorType::Grayscale)),
        ("webp", webp(&rgb, 400, 300)),
        ("gif", gif(&rgb, 400, 300)),
    ] {
        let made = thumb_of(&bytes, 128).unwrap_or_else(|e| panic!("{what}: {e:?}"));
        assert_eq!((made.width, made.height), (128, 96), "{what}");
        let (w, h, px) = open_jpeg(&made.jpeg);
        assert_eq!((w, h), (128, 96), "{what}");
        if what != "gray" {
            // The gradient survives: red grows to the right, green downwards.
            assert!(
                pixel(&px, w, 100, 48)[0] > pixel(&px, w, 20, 48)[0] + 60,
                "{what}"
            );
            assert!(
                pixel(&px, w, 64, 80)[1] > pixel(&px, w, 64, 10)[1] + 60,
                "{what}"
            );
        }
    }
}

#[test]
fn a_transparent_png_is_laid_on_white() {
    let mut out = Vec::new();
    let mut enc = png::Encoder::new(&mut out, 64, 64);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    let mut w = enc.write_header().expect("header");
    w.write_image_data(&vec![0u8; 64 * 64 * 4]).expect("data");
    w.finish().expect("end");
    let made = thumb_of(&out, 32).expect("thumb");
    let (w, _, px) = open_jpeg(&made.jpeg);
    assert!(
        near(pixel(&px, w, 10, 10), [255, 255, 255]),
        "{:?}",
        pixel(&px, w, 10, 10)
    );
}

#[test]
fn exif_orientation_turns_the_picture_and_swaps_its_dimensions() {
    let upright = jpeg(&halves(400, 200), 400, 200);
    let made = thumb_of(&upright, 256).expect("plain");
    assert_eq!((made.width, made.height), (256, 128));

    // 6: the camera was turned; the picture must rotate 90 degrees clockwise,
    // so the red left half ends up on top.
    let made = thumb_of(&with_exif(&upright, 6), 256).expect("rotated");
    assert_eq!((made.width, made.height), (128, 256));
    let (w, h, px) = open_jpeg(&made.jpeg);
    assert!(near(pixel(&px, w, w / 2, h / 4), [255, 0, 0]), "top is red");
    assert!(
        near(pixel(&px, w, w / 2, 3 * h / 4), [0, 0, 255]),
        "bottom is blue"
    );

    // 8: counterclockwise, the red half ends up at the bottom.
    let made = thumb_of(&with_exif(&upright, 8), 256).expect("rotated");
    let (w, h, px) = open_jpeg(&made.jpeg);
    assert_eq!((w, h), (128, 256));
    assert!(near(pixel(&px, w, w / 2, h / 4), [0, 0, 255]));
    assert!(near(pixel(&px, w, w / 2, 3 * h / 4), [255, 0, 0]));

    // 3: upside down keeps the size and swaps the halves.
    let made = thumb_of(&with_exif(&upright, 3), 256).expect("180");
    let (w, h, px) = open_jpeg(&made.jpeg);
    assert_eq!((w, h), (256, 128));
    assert!(near(pixel(&px, w, w / 4, h / 2), [0, 0, 255]));
    assert!(near(pixel(&px, w, 3 * w / 4, h / 2), [255, 0, 0]));
}

#[test]
fn orient_is_each_of_the_eight_exif_transforms() {
    // 3 wide, 2 high:  A B C / D E F
    let src: Vec<u8> = b"ABCDEF".iter().flat_map(|&c| [c, c, c]).collect();
    let rows =
        |bytes: &[u8]| -> String { bytes.chunks(3).map(|p| p[0] as char).collect::<String>() };
    for (o, want, dims) in [
        (1u8, "ABCDEF", (3u32, 2u32)),
        (2, "CBAFED", (3, 2)),
        (3, "FEDCBA", (3, 2)),
        (4, "DEFABC", (3, 2)),
        (5, "ADBECF", (2, 3)),
        (6, "DAEBFC", (2, 3)),
        (7, "FCEBDA", (2, 3)),
        (8, "CFBEAD", (2, 3)),
    ] {
        let (out, w, h) = orient(src.clone(), 3, 2, o);
        assert_eq!(
            ((w, h), rows(&out).as_str()),
            (dims, want),
            "orientation {o}"
        );
    }
    let (out, w, h) = orient(src.clone(), 3, 2, 0);
    assert_eq!((w, h, out), (3, 2, src.clone()));
    let (out, ..) = orient(src.clone(), 3, 2, 9);
    assert_eq!(out, src);
}

#[test]
fn the_exif_block_is_read_in_both_byte_orders_and_garbage_means_upright() {
    let le = |o: u16| -> Vec<u8> {
        let mut t = b"II\x2A\x00\x08\x00\x00\x00\x02\x00".to_vec();
        // Another tag first, then the orientation.
        t.extend([
            0x0F, 0x01, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00, b'x', 0, 0, 0,
        ]);
        t.extend([0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00]);
        t.extend(o.to_le_bytes());
        t.extend([0, 0]);
        t
    };
    let be = |o: u16| -> Vec<u8> {
        let mut t = b"MM\x00\x2A\x00\x00\x00\x08\x00\x01".to_vec();
        t.extend([0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01]);
        t.extend(o.to_be_bytes());
        t.extend([0, 0]);
        t
    };
    for o in 1..=8u16 {
        assert_eq!(exif_orientation(&le(o)), o as u8, "LE {o}");
        assert_eq!(exif_orientation(&be(o)), o as u8, "BE {o}");
    }
    assert_eq!(exif_orientation(&le(0)), 1);
    assert_eq!(exif_orientation(&le(9)), 1);
    assert_eq!(exif_orientation(&le(6)[..14]), 1, "cut short");
    assert_eq!(exif_orientation(b""), 1);
    assert_eq!(exif_orientation(b"XX\x2A\x00\x08\x00\x00\x00"), 1);
    assert_eq!(exif_orientation(&[0xFF; 64]), 1);
    // An IFD offset far outside the block does not panic.
    assert_eq!(exif_orientation(b"II\x2A\x00\xFF\xFF\xFF\xFF"), 1);
}

#[test]
fn target_sizes_keep_the_ratio_and_never_grow() {
    assert_eq!(target_size(4000, 3000, 256), (256, 192));
    assert_eq!(target_size(3000, 4000, 256), (192, 256));
    assert_eq!(target_size(100, 50, 256), (100, 50));
    assert_eq!(target_size(256, 10, 256), (256, 10));
    assert_eq!(target_size(10_000, 1, 256), (256, 1));
    assert_eq!(target_size(5, 10_000, 32), (1, 32));
}

#[test]
fn the_resizer_averages_areas_and_copies_when_nothing_shrinks() {
    // 2x2 down to 1x1: the mean.
    let mut rz = Resizer::new(Layout::Rgb, 2, 2, 1, 1);
    rz.push(&[0, 0, 0, 100, 100, 100]);
    rz.push(&[100, 100, 100, 200, 200, 200]);
    assert_eq!(rz.finish().expect("done"), [100, 100, 100]);

    // Same size: a copy.
    let src = gradient(7, 5);
    let mut rz = Resizer::new(Layout::Rgb, 7, 5, 7, 5);
    for row in src.chunks(21) {
        rz.push(row);
    }
    assert_eq!(rz.finish().expect("copy"), src);

    // A flat colour stays flat whatever the odd ratio, and the count is exact.
    for (sw, sh, dw, dh) in [
        (7u32, 5u32, 3u32, 2u32),
        (1000, 3, 32, 1),
        (33, 1001, 1, 32),
        (640, 480, 33, 25),
    ] {
        let flat = vec![77u8; (sw * sh * 3) as usize];
        let mut rz = Resizer::new(Layout::Rgb, sw, sh, dw, dh);
        for row in flat.chunks((sw * 3) as usize) {
            rz.push(row);
        }
        let out = rz.finish().expect("scaled");
        assert_eq!(out.len(), (dw * dh * 3) as usize, "{sw}x{sh}");
        assert!(out.iter().all(|&v| v == 77), "{sw}x{sh}");
    }

    // Too few rows is an error, not a short picture.
    let mut rz = Resizer::new(Layout::Rgb, 2, 2, 1, 1);
    rz.push(&[0; 6]);
    assert!(matches!(rz.finish(), Err(Fail::Bad(_))));
}

#[test]
fn a_file_that_is_not_a_picture_is_unsupported_image() {
    for bytes in [
        b"just some text, not a picture\n".as_slice(),
        b"",
        b"<svg xmlns=\"http://www.w3.org/2000/svg\"/>",
        b"\x00\x00\x00\x18ftypheic",
    ] {
        let e = thumb_of(bytes, 256).expect_err("not a picture");
        assert_eq!(e.code, ErrorCode::Failed);
        assert!(e.message.contains("unsupported image"), "{}", e.message);
        assert!(
            e.message.contains("~/picture"),
            "names the path: {}",
            e.message
        );
    }
    let full = png(&gradient(200, 200), 200, 200, png::ColorType::Rgb);
    let e = thumb_of(&full[..full.len() / 2], 64).expect_err("cut in half");
    assert_eq!(e.code, ErrorCode::Failed);
    assert!(e.message.contains("unsupported image"), "{}", e.message);
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = !0u32;
    for &b in bytes {
        crc ^= u32::from(b);
        for _ in 0..8 {
            crc = if crc & 1 == 1 {
                (crc >> 1) ^ 0xEDB8_8320
            } else {
                crc >> 1
            };
        }
    }
    !crc
}

fn png_chunk(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
    let mut body = kind.to_vec();
    body.extend(data);
    let mut out = u32::try_from(data.len())
        .expect("fits")
        .to_be_bytes()
        .to_vec();
    out.extend(&body);
    out.extend(crc32(&body).to_be_bytes());
    out
}

/// A PNG that only has a header saying `w` by `h` (the data is never read).
fn png_header_only(w: u32, h: u32) -> Vec<u8> {
    png_header(w, h, 2, 0)
}

fn png_header(w: u32, h: u32, color_type: u8, interlace: u8) -> Vec<u8> {
    let mut ihdr = w.to_be_bytes().to_vec();
    ihdr.extend(h.to_be_bytes());
    ihdr.extend([8, color_type, 0, 0, interlace]);
    let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
    out.extend(png_chunk(b"IHDR", &ihdr));
    out.extend(png_chunk(b"IDAT", &[0x78, 0x9C]));
    out
}

fn jpeg_header_only(w: u16, h: u16) -> Vec<u8> {
    let mut out = vec![0xFF, 0xD8];
    // DQT: one table of 64 ones.
    out.extend([0xFF, 0xDB, 0x00, 0x43, 0x00]);
    out.extend([1u8; 64]);
    // SOF0: 8 bits, h, w, 3 components.
    out.extend([0xFF, 0xC0, 0x00, 0x11, 0x08]);
    out.extend(h.to_be_bytes());
    out.extend(w.to_be_bytes());
    out.extend([3, 1, 0x22, 0, 2, 0x11, 0, 3, 0x11, 0]);
    out
}

fn webp_header_only(w: u32, h: u32) -> Vec<u8> {
    // VP8L: signature 0x2F, then 14 bits of width-1, 14 of height-1, alpha, version.
    let bits = (w - 1) | ((h - 1) << 14);
    let mut chunk = vec![0x2F];
    chunk.extend(bits.to_le_bytes());
    chunk.extend([0; 8]);
    let mut out = b"RIFF".to_vec();
    out.extend(
        u32::try_from(4 + 8 + chunk.len())
            .expect("fits")
            .to_le_bytes(),
    );
    out.extend(b"WEBPVP8L");
    out.extend(u32::try_from(chunk.len()).expect("fits").to_le_bytes());
    out.extend(chunk);
    out
}

fn gif_header_only(w: u16, h: u16) -> Vec<u8> {
    let mut out = b"GIF89a".to_vec();
    out.extend(w.to_le_bytes());
    out.extend(h.to_le_bytes());
    // An image descriptor, so the header is complete.
    out.extend([0, 0, 0, 0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0]);
    out
}

#[test]
fn a_picture_over_64_megapixels_is_too_large_from_its_header_alone() {
    for (what, bytes) in [
        ("png", png_header_only(9000, 8000)),
        ("png tall", png_header_only(1, 70_000_000)),
        ("jpeg", jpeg_header_only(60_000, 2_000)),
        ("webp", webp_header_only(16_000, 16_000)),
        ("gif", gif_header_only(60_000, 2_000)),
    ] {
        let e = thumb_of(&bytes, 256).err_or(what);
        assert_eq!(e.code, ErrorCode::TooLarge, "{what}: {}", e.message);
    }
}

trait ErrOr {
    fn err_or(self, what: &str) -> WireError;
}

impl ErrOr for Result<Made, WireError> {
    fn err_or(self, what: &str) -> WireError {
        match self {
            Err(e) => e,
            Ok(_) => panic!("{what}: expected an error"),
        }
    }
}

#[test]
fn a_cancelled_stream_stops_the_work_with_cancelled() {
    let mut noise = Vec::new();
    let mut x = 0x2545_F491_4F6C_DD1Du64;
    for _ in 0..(300 * 300 * 3) {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        noise.push((x >> 24) as u8);
    }
    let formats = [
        ("png", png(&noise, 300, 300, png::ColorType::Rgb)),
        ("jpeg", jpeg(&noise, 300, 300)),
        ("webp", webp(&noise, 300, 300)),
    ];
    for (what, bytes) in &formats {
        // Cancelled before the first read.
        let (_dir, file) = file_with(bytes);
        let e = make(file, "~/p", 64, 70, &|| true).err_or(what);
        assert_eq!(e.code, ErrorCode::Cancelled, "{what}");

        // Cancelled partway: the third look at the flag says so.
        let polls = std::cell::Cell::new(0u32);
        let (_dir, file) = file_with(bytes);
        let result = make(file, "~/p", 64, 70, &|| {
            polls.set(polls.get() + 1);
            polls.get() > 2
        });
        if polls.get() > 2 {
            assert_eq!(result.err_or(what).code, ErrorCode::Cancelled, "{what}");
        }
    }
}

#[test]
fn the_decoders_fit_the_2_mib_stack_of_a_stream_thread() {
    // The same stack the session gives a handler, in a debug build.
    let rgb = gradient(1200, 900);
    for bytes in [
        jpeg(&rgb, 1200, 900),
        png(&rgb, 1200, 900, png::ColorType::Rgb),
        webp(&rgb, 1200, 900),
        gif(&rgb, 1200, 900),
    ] {
        let (_dir, file) = file_with(&bytes);
        let handle = std::thread::Builder::new()
            .stack_size(2 * 1024 * 1024)
            .spawn(move || make(file, "~/p", 1024, 70, &|| false).map(|m| (m.width, m.height)))
            .expect("spawn");
        assert_eq!(
            handle.join().expect("no overflow").expect("thumb"),
            (1024, 768)
        );
    }
}

#[test]
fn a_truncated_jpeg_is_an_error_or_a_picture_never_a_panic() {
    let full = jpeg(&gradient(300, 200), 300, 200);
    for cut in [full.len() / 4, full.len() / 2, full.len() - 3] {
        match thumb_of(&full[..cut], 100) {
            Ok(m) => assert_eq!((m.width, m.height), (100, 67)),
            Err(e) => assert_eq!(e.code, ErrorCode::Failed, "{}", e.message),
        }
    }
}

/// An RGB PNG whose rows are stored in Adam7 order (seven passes of growing
/// detail); the encoder of the `png` crate writes none, so it is built by hand.
fn adam7_png(rgb: &[u8], w: u32, h: u32) -> Vec<u8> {
    const PASSES: [(u32, u32, u32, u32); 7] = [
        (0, 0, 8, 8),
        (4, 0, 8, 8),
        (0, 4, 4, 8),
        (2, 0, 4, 4),
        (0, 2, 2, 4),
        (1, 0, 2, 2),
        (0, 1, 1, 2),
    ];
    let mut raw = Vec::new();
    for (x0, y0, dx, dy) in PASSES {
        if x0 >= w || y0 >= h {
            continue;
        }
        let mut y = y0;
        while y < h {
            raw.push(0); // filter: none
            let mut x = x0;
            while x < w {
                let i = ((y * w + x) * 3) as usize;
                raw.extend(&rgb[i..i + 3]);
                x += dx;
            }
            y += dy;
        }
    }
    let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    std::io::Write::write_all(&mut z, &raw).expect("deflate");
    let idat = z.finish().expect("zlib");
    let mut ihdr = w.to_be_bytes().to_vec();
    ihdr.extend(h.to_be_bytes());
    ihdr.extend([8, 2, 0, 0, 1]); // 8-bit RGB, Adam7
    let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
    out.extend(png_chunk(b"IHDR", &ihdr));
    out.extend(png_chunk(b"IDAT", &idat));
    out.extend(png_chunk(b"IEND", &[]));
    out
}

/// `next_row` of an interlaced PNG yields the narrow rows of one pass, so the
/// thumbnail was cut short and the file was reported as ending early.
#[test]
fn an_interlaced_png_makes_the_whole_thumbnail() {
    for (w, h) in [(200, 100), (13, 9), (3, 1), (1, 5)] {
        let bytes = adam7_png(&halves(w, h), w, h);
        let (cw, ch) = target_size(w, h, 64);
        let made = thumb_of(&bytes, 64).unwrap_or_else(|e| panic!("{w}x{h}: {e:?}"));
        assert_eq!((made.width, made.height), (cw, ch), "{w}x{h}");
        let (tw, th, rgb) = open_jpeg(&made.jpeg);
        assert_eq!((tw, th), (cw, ch));
        // The colours only survive the JPEG's chroma subsampling in a picture
        // that is not a few pixels across.
        if w.min(h) >= 8 {
            assert!(
                near(pixel(&rgb, tw, 0, th / 2), [255, 0, 0]),
                "{w}x{h}: left stays red"
            );
            assert!(
                near(pixel(&rgb, tw, tw - 1, th / 2), [0, 0, 255]),
                "{w}x{h}: right stays blue"
            );
        }
    }
}

/// A progressive JPEG header (SOF2) of `w` by `h`, 4:4:4.
fn progressive_jpeg_header_only(w: u16, h: u16) -> Vec<u8> {
    let mut bytes = jpeg_header_only(w, h);
    let sof = bytes
        .windows(2)
        .position(|p| p == [0xFF, 0xC0])
        .expect("SOF0");
    bytes[sof + 1] = 0xC2;
    // 4:4:4: every component sampled 1x1.
    let comps = sof + 10;
    for i in 0..3 {
        bytes[comps + i * 3 + 1] = 0x11;
    }
    bytes
}

/// The decoder keeps every coefficient of a progressive JPEG (6 bytes a
/// pixel at 4:4:4), so a 64 MP one costs 384 MB although a baseline one of the
/// same size is decoded at 1/8 and costs next to nothing.
#[test]
fn a_progressive_444_jpeg_is_refused_by_the_bytes_it_needs_not_its_pixels() {
    let e = thumb_of(&progressive_jpeg_header_only(8000, 8000), 256).err_or("progressive");
    assert_eq!(e.code, ErrorCode::TooLarge, "{}", e.message);
    assert!(e.message.contains("MiB"), "{}", e.message);
    // The same size, baseline: not refused for its size (the header-only file
    // then ends early, which is another error).
    let e = thumb_of(&jpeg_header_only(8000, 8000), 256).err_or("baseline");
    assert_ne!(e.code, ErrorCode::TooLarge, "{}", e.message);
}

/// A WebP whose EXIF chunk announces about 4 GiB and holds nothing: the
/// picture still decodes, upright (the `serve` process test proves nothing
/// that size is allocated).
#[test]
fn a_webp_with_a_huge_empty_exif_block_is_decoded_upright() {
    let (w, h) = (60u32, 40u32);
    let plain = webp(&halves(w, h), w, h);
    let u24 = |n: u32| n.to_le_bytes()[..3].to_vec();
    let mut body = b"WEBPVP8X".to_vec();
    body.extend(10u32.to_le_bytes());
    body.push(0x08);
    body.extend([0, 0, 0]);
    body.extend(u24(w - 1));
    body.extend(u24(h - 1));
    body.extend(&plain[12..]);
    body.extend(b"EXIF");
    body.extend(0xFFFF_FF00u32.to_le_bytes());
    let mut bytes = b"RIFF".to_vec();
    bytes.extend(u32::try_from(body.len()).expect("fits").to_le_bytes());
    bytes.extend(body);
    let made = thumb_of(&bytes, 30).expect("decodes");
    assert_eq!((made.width, made.height), (30, 20));
}

// ---- the decode gate and the byte estimates ----

const FOR_EVER: std::time::Duration = std::time::Duration::from_secs(3600);
const TICK: std::time::Duration = std::time::Duration::from_millis(1);
const NO_WAIT: std::time::Duration = std::time::Duration::ZERO;

#[test]
fn the_gate_hands_out_its_permits_and_takes_them_back_when_they_drop() {
    let gate = Gate::new(2);
    let first = gate.acquire(NO_WAIT, TICK, &|| false).expect("first");
    let second = gate.acquire(NO_WAIT, TICK, &|| false).expect("second");
    assert_eq!(
        gate.acquire(NO_WAIT, TICK, &|| false).err(),
        Some(NoPermit::Busy),
        "a third finds none and, with no patience, says so at once"
    );
    drop(first);
    let third = gate
        .acquire(NO_WAIT, TICK, &|| false)
        .expect("one came back");
    drop((second, third));
    let both = (
        gate.acquire(NO_WAIT, TICK, &|| false).expect("again"),
        gate.acquire(NO_WAIT, TICK, &|| false).expect("and again"),
    );
    drop(both);
}

#[test]
fn a_waiter_gets_the_permit_when_the_holder_is_done() {
    let gate = Gate::new(1);
    let held = gate.acquire(NO_WAIT, TICK, &|| false).expect("held");
    std::thread::scope(|s| {
        // Whether it starts waiting before or after the drop, it gets it.
        let waiter = s.spawn(|| gate.acquire(FOR_EVER, TICK, &|| false).map(|_| ()));
        drop(held);
        assert_eq!(waiter.join().expect("no panic"), Ok(()));
    });
}

#[test]
fn a_waiting_stream_stays_cancellable_and_leaves_no_permit_taken() {
    let gate = Gate::new(1);
    let held = gate.acquire(NO_WAIT, TICK, &|| false).expect("held");
    let polls = std::cell::Cell::new(0u32);
    let result = gate.acquire(FOR_EVER, TICK, &|| {
        polls.set(polls.get() + 1);
        polls.get() > 3
    });
    assert_eq!(result.err(), Some(NoPermit::Cancelled));
    assert!(
        polls.get() > 3,
        "it waited, looking, until it was cancelled"
    );
    drop(held);
    gate.acquire(NO_WAIT, TICK, &|| false)
        .expect("the cancelled waiter took nothing");

    // Cancelled before it even asks: no permit is taken although one is free.
    let free = Gate::new(1);
    assert_eq!(
        free.acquire(FOR_EVER, TICK, &|| true).err(),
        Some(NoPermit::Cancelled)
    );
    free.acquire(NO_WAIT, TICK, &|| false).expect("still free");
}

#[test]
fn a_permit_comes_back_when_its_holder_panics() {
    let gate = Gate::new(1);
    let died = std::thread::scope(|s| {
        s.spawn(|| {
            let _permit = gate.acquire(NO_WAIT, TICK, &|| false).expect("held");
            panic!("a decoder bug");
        })
        .join()
    });
    assert!(died.is_err());
    gate.acquire(NO_WAIT, TICK, &|| false)
        .expect("the permit of the dead decode is back");
}

#[test]
fn the_estimates_count_bytes_per_format_and_the_cap_is_256_mib() {
    let mib = 1024 * 1024u64;
    assert_eq!(MAX_DECODE_BYTES, 256 * mib);
    // A progressive 4:4:4 JPEG keeps 6 bytes a pixel of coefficients; the
    // same size as baseline, decoded at 1/8, needs next to nothing.
    let progressive = jpeg_decode_bytes((8000, 8000), (1000, 1000), 3, true);
    assert_eq!(progressive, 8000 * 8000 * 6 + 2 * 1000 * 1000 * 3);
    assert!(progressive > MAX_DECODE_BYTES);
    assert!(jpeg_decode_bytes((8000, 8000), (1000, 1000), 3, false) < 8 * mib);
    // A 12 MP progressive photo (the common big one) is fine.
    assert!(jpeg_decode_bytes((4000, 3000), (500, 375), 3, true) < MAX_DECODE_BYTES / 3);

    // WebP: output plus what the decoder keeps next to it.
    let px = 1_000_000;
    assert_eq!(webp_decode_bytes(1000, 1000, false, false, true), px * 6);
    assert_eq!(webp_decode_bytes(1000, 1000, false, false, false), px * 7);
    assert_eq!(webp_decode_bytes(1000, 1000, true, false, false), px * 4);
    assert_eq!(webp_decode_bytes(1000, 1000, true, true, true), px * 14);
    assert!(
        webp_decode_bytes(6500, 6500, false, false, false) > MAX_DECODE_BYTES,
        "a 42 MP lossless WebP is 296 MB, over the cap that 25 MP (175 MB) is under"
    );
    assert!(webp_decode_bytes(5000, 5000, false, false, false) < MAX_DECODE_BYTES);

    // GIF: a frame and a canvas, 8 bytes a pixel.
    assert_eq!(gif_decode_bytes(1000, 1000), px * 8);
    assert!(gif_decode_bytes(8000, 8000) > MAX_DECODE_BYTES);

    // PNG: rows when they can stream, the whole picture when interlaced.
    assert_eq!(png_rows_decode_bytes(1000, 4), 12_000);
    assert_eq!(png_interlaced_decode_bytes(1000, 1000, 4), (px + 3000) * 4);
    assert!(png_interlaced_decode_bytes(8000, 8000, 4) < MAX_DECODE_BYTES);
    assert!(png_interlaced_decode_bytes(10_000, 10_000, 4) > MAX_DECODE_BYTES);
}

#[test]
fn a_picture_that_needs_too_many_bytes_is_too_large_from_its_header_alone() {
    // 8000 x 8000 is under the 64 MP cap, but each of these needs over 256 MiB.
    for (what, bytes) in [
        ("gif", gif_header_only(8000, 8000)),
        ("webp", webp_header_only(8000, 8000)),
        // RGBA, Adam7: the whole picture is decoded, 4 bytes a pixel.
        ("interlaced png", png_header(8192, 8192, 6, 1)),
    ] {
        let e = thumb_of(&bytes, 256).err_or(what);
        assert_eq!(e.code, ErrorCode::TooLarge, "{what}: {}", e.message);
    }
}
