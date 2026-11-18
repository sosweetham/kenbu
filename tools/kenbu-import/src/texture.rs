//! Texture2D and Cubemap. Block-compressed and floating-point formats keep their stored blocks and
//! mips in a DDS file that Godot loads with `Image.load_dds_from_buffer`; every other format is
//! decoded to RGBA8 (texture2ddecoder for crunch, ETC, EAC, ASTC, PVRTC and ATC) and written as a
//! PNG, whose mips Kenbu regenerates when Unity had them.
//!
//! Rows stay in Unity's order (the first stored row is the bottom of the artwork) and UVs stay as
//! Unity wrote them: both put v = 0 on the first stored row, so sampling matches without flipping
//! either. A PNG therefore looks upside down in an image viewer; covers (`write_cover`) are the
//! exception, flipped to be shown upright.
//!
//! A Cubemap is six faces (+X, -X, +Y, -Y, +Z, -Z) stored one after another, each with its own mip
//! chain (`m_CompleteImageSize` bytes per face).

use anyhow::{Context, Result, anyhow, bail, ensure};

use crate::bundle::Bundle;
use crate::unity::Texture2D;

/// Larger than any texture on BeatMods (8192).
const MAX_DIMENSION: i32 = 16384;

/// Unity TextureFormat names (UnityPy `enums/TextureFormat.py`).
pub fn format_name(f: i32) -> &'static str {
    match f {
        1 => "Alpha8",
        2 => "ARGB4444",
        3 => "RGB24",
        4 => "RGBA32",
        5 => "ARGB32",
        7 => "RGB565",
        8 => "BGR24",
        9 => "R16",
        10 => "DXT1",
        11 => "DXT3",
        12 => "DXT5",
        13 => "RGBA4444",
        14 => "BGRA32",
        15 => "RHalf",
        16 => "RGHalf",
        17 => "RGBAHalf",
        18 => "RFloat",
        19 => "RGFloat",
        20 => "RGBAFloat",
        21 => "YUY2",
        22 => "RGB9e5Float",
        24 => "BC6H",
        25 => "BC7",
        26 => "BC4",
        27 => "BC5",
        28 => "DXT1Crunched",
        29 => "DXT5Crunched",
        30..=33 => "PVRTC",
        34 => "ETC_RGB4",
        35 => "ATC_RGB4",
        36 => "ATC_RGBA8",
        41 => "EAC_R",
        42 => "EAC_R_SIGNED",
        43 => "EAC_RG",
        44 => "EAC_RG_SIGNED",
        45 => "ETC2_RGB",
        46 => "ETC2_RGBA1",
        47 => "ETC2_RGBA8",
        48..=59 => "ASTC",
        60 => "ETC_RGB4_3DS",
        61 => "ETC_RGBA8_3DS",
        62 => "RG16",
        63 => "R8",
        64 => "ETC_RGB4Crunched",
        65 => "ETC2_RGBA8Crunched",
        66..=71 => "ASTC_HDR",
        72 => "RG32",
        73 => "RGB48",
        74 => "RGBA64",
        _ => "unknown",
    }
}

/// How a format's blocks are laid out in a DDS file: FourCC or DXGI, bytes per 4x4 block or per
/// pixel.
#[derive(Clone, Copy)]
struct DdsLayout {
    fourcc: &'static [u8; 4],
    dxgi: u32,
    block_bytes: usize,
    pixel_bytes: usize,
}

fn dds_layout(f: i32) -> Option<DdsLayout> {
    let block = |fourcc, dxgi, block_bytes| Some(DdsLayout { fourcc, dxgi, block_bytes, pixel_bytes: 0 });
    let pixels = |dxgi, pixel_bytes| Some(DdsLayout { fourcc: b"DX10", dxgi, block_bytes: 0, pixel_bytes });
    match f {
        10 => block(b"DXT1", 0, 8),
        11 => block(b"DXT3", 0, 16),
        12 => block(b"DXT5", 0, 16),
        26 => block(b"ATI1", 0, 8),
        27 => block(b"ATI2", 0, 16),
        // DXGI_FORMAT_BC6H_UF16, DXGI_FORMAT_BC7_UNORM (Godot reads sRGB from the sampler hint).
        24 => block(b"DX10", 95, 16),
        25 => block(b"DX10", 98, 16),
        // DXGI R16_FLOAT, R16G16_FLOAT, R16G16B16A16_FLOAT, R32_FLOAT, R32G32_FLOAT,
        // R32G32B32A32_FLOAT, R9G9B9E5_SHAREDEXP.
        15 => pixels(54, 2),
        16 => pixels(34, 4),
        17 => pixels(10, 8),
        18 => pixels(41, 4),
        19 => pixels(16, 8),
        20 => pixels(2, 16),
        22 => pixels(67, 4),
        _ => None,
    }
}

impl DdsLayout {
    fn level_size(&self, w: usize, h: usize) -> usize {
        if self.block_bytes > 0 { w.div_ceil(4) * h.div_ceil(4) * self.block_bytes } else { w * h * self.pixel_bytes }
    }
}

/// Bytes per pixel of the formats decoded by hand.
fn raw_pixel_bytes(f: i32) -> Option<usize> {
    match f {
        1 | 63 => Some(1),
        2 | 7 | 9 | 13 | 62 => Some(2),
        3 | 8 => Some(3),
        4 | 5 | 14 | 72 => Some(4),
        73 => Some(6),
        74 => Some(8),
        _ => None,
    }
}

pub fn full_mip_count(w: usize, h: usize) -> usize {
    (usize::BITS - w.max(h).max(1).leading_zeros()) as usize
}

/// One image (a 2D texture, or one cubemap face) ready to be written.
pub enum Image {
    Dds(Vec<u8>),
    Png { width: usize, height: usize, rgba: Vec<u8> },
}

pub struct Converted {
    pub format: &'static str,
    pub width: usize,
    pub height: usize,
    /// Mip levels of the result: those stored in a DDS, or Unity's count for a PNG (Kenbu
    /// regenerates them).
    pub mips: usize,
    /// One image, or six for a cubemap.
    pub images: Vec<Image>,
    pub note: Option<String>,
}

/// The stored data of every image of the texture (one, or six cubemap faces).
fn image_data<'a>(bundle: &'a Bundle, tex: &'a Texture2D) -> Result<&'a [u8]> {
    if !tex.image_data.is_empty() {
        Ok(&tex.image_data)
    } else if tex.m_StreamData.size > 0 {
        bundle.stream(&tex.m_StreamData)
    } else {
        bail!("texture {} has no data", tex.m_Name)
    }
}

fn dimensions(tex: &Texture2D) -> Result<(usize, usize)> {
    ensure!(
        (1..=MAX_DIMENSION).contains(&tex.m_Width) && (1..=MAX_DIMENSION).contains(&tex.m_Height),
        "texture {} is {}x{}",
        tex.m_Name,
        tex.m_Width,
        tex.m_Height
    );
    Ok((tex.m_Width as usize, tex.m_Height as usize))
}

pub fn convert(bundle: &Bundle, tex: &Texture2D) -> Result<Converted> {
    let (w, h) = dimensions(tex)?;
    let f = tex.m_TextureFormat;
    let data = image_data(bundle, tex)?;
    let images = usize::try_from(tex.m_ImageCount).unwrap_or(1).max(1);
    ensure!(images == 1 || images == 6, "texture {} has {images} images", tex.m_Name);
    let stored_mips = usize::try_from(tex.m_MipCount).unwrap_or(1).clamp(1, full_mip_count(w, h));
    let per_image = if images == 1 { data.len() } else { data.len() / 6 };
    let mut out =
        Converted { format: format_name(f), width: w, height: h, mips: stored_mips, images: Vec::new(), note: None };

    if let Some(layout) = dds_layout(f) {
        let chain: usize = (0..stored_mips).map(|m| layout.level_size((w >> m).max(1), (h >> m).max(1))).sum();
        ensure!(chain <= per_image, "{}: mip chain needs {chain} bytes, has {per_image}", tex.m_Name);
        // Godot's Image wants all mips down to 1x1 or none; a partial chain falls back to a PNG
        // of the top level, whose mips Godot regenerates.
        if stored_mips == 1 || stored_mips == full_mip_count(w, h) {
            for i in 0..images {
                let face = &data[i * per_image..i * per_image + chain];
                out.images.push(Image::Dds(dds(layout, w, h, stored_mips, face)));
            }
            return Ok(out);
        }
        out.note = Some(format!("{} mips of {}: decoded", stored_mips, full_mip_count(w, h)));
    }
    for i in 0..images {
        let face = &data[i * per_image..(i + 1) * per_image];
        let rgba = decode_rgba(bundle.version, f, w, h, face).with_context(|| tex.m_Name.clone())?;
        out.images.push(Image::Png { width: w, height: h, rgba });
    }
    Ok(out)
}

/// The top mip of the first image as RGBA8 in Unity's row order.
pub fn decode_top(bundle: &Bundle, tex: &Texture2D) -> Result<(usize, usize, Vec<u8>)> {
    let (w, h) = dimensions(tex)?;
    let data = image_data(bundle, tex)?;
    let rgba = decode_rgba(bundle.version, tex.m_TextureFormat, w, h, data).with_context(|| tex.m_Name.clone())?;
    Ok((w, h, rgba))
}

fn decode_rgba(version: (u32, u32, u32), f: i32, w: usize, h: usize, data: &[u8]) -> Result<Vec<u8>> {
    let pixels = w * h;
    if let Some(bpp) = raw_pixel_bytes(f) {
        ensure!(data.len() >= pixels * bpp, "{} needs {} bytes, has {}", format_name(f), pixels * bpp, data.len());
        let d = &data[..pixels * bpp];
        let expand4 = |x: u16| ((x & 0xF) * 17) as u8;
        let u16le = |c: &[u8]| u16::from_le_bytes([c[0], c[1]]);
        return Ok(match f {
            // Single-channel formats sample as D3D11 does: A8 as (0, 0, 0, a), R8 and R16 as (r, 0, 0, 1).
            1 => d.iter().flat_map(|&a| [0, 0, 0, a]).collect(),
            63 => d.iter().flat_map(|&r| [r, 0, 0, 255]).collect(),
            9 => d.chunks_exact(2).flat_map(|c| [c[1], 0, 0, 255]).collect(),
            62 => d.chunks_exact(2).flat_map(|c| [c[0], c[1], 0, 255]).collect(),
            72 => d.chunks_exact(4).flat_map(|c| [c[1], c[3], 0, 255]).collect(),
            3 => d.chunks_exact(3).flat_map(|c| [c[0], c[1], c[2], 255]).collect(),
            8 => d.chunks_exact(3).flat_map(|c| [c[2], c[1], c[0], 255]).collect(),
            4 => d.to_vec(),
            5 => d.chunks_exact(4).flat_map(|c| [c[1], c[2], c[3], c[0]]).collect(),
            14 => d.chunks_exact(4).flat_map(|c| [c[2], c[1], c[0], c[3]]).collect(),
            73 => d.chunks_exact(6).flat_map(|c| [c[1], c[3], c[5], 255]).collect(),
            74 => d.chunks_exact(8).flat_map(|c| [c[1], c[3], c[5], c[7]]).collect(),
            // 16-bit packed formats (AssetStudio Texture2DConverter): ARGB4444 is a<<12|r<<8|g<<4|b,
            // RGBA4444 r<<12|g<<8|b<<4|a, RGB565 r<<11|g<<5|b.
            2 => d
                .chunks_exact(2)
                .flat_map(|c| {
                    let p = u16le(c);
                    [expand4(p >> 8), expand4(p >> 4), expand4(p), expand4(p >> 12)]
                })
                .collect(),
            13 => d
                .chunks_exact(2)
                .flat_map(|c| {
                    let p = u16le(c);
                    [expand4(p >> 12), expand4(p >> 8), expand4(p >> 4), expand4(p)]
                })
                .collect(),
            7 => d
                .chunks_exact(2)
                .flat_map(|c| {
                    let p = u16le(c);
                    let (r, g, b) = ((p >> 11) & 31, (p >> 5) & 63, p & 31);
                    [((r << 3) | (r >> 2)) as u8, ((g << 2) | (g >> 4)) as u8, ((b << 3) | (b >> 2)) as u8, 255]
                })
                .collect(),
            _ => unreachable!("raw_pixel_bytes lists only the formats above"),
        });
    }
    let mut px = vec![0u32; pixels];
    let td = |r: Result<(), &'static str>| r.map_err(|e| anyhow!("{}: {e}", format_name(f)));
    match f {
        10 => td(texture2ddecoder::decode_bc1(data, w, h, &mut px))?,
        11 => td(texture2ddecoder::decode_bc2(data, w, h, &mut px))?,
        12 => td(texture2ddecoder::decode_bc3(data, w, h, &mut px))?,
        26 => td(texture2ddecoder::decode_bc4(data, w, h, &mut px))?,
        27 => td(texture2ddecoder::decode_bc5(data, w, h, &mut px))?,
        24 => td(texture2ddecoder::decode_bc6_unsigned(data, w, h, &mut px))?,
        25 => td(texture2ddecoder::decode_bc7(data, w, h, &mut px))?,
        28 | 29 | 64 | 65 => {
            // Unity 2017.3 changed its crunch encoder (UnityPy Texture2DConverter).
            if version >= (2017, 3, 0) {
                td(texture2ddecoder::decode_unity_crunch(data, w, h, &mut px))?
            } else {
                td(texture2ddecoder::decode_crunch(data, w, h, &mut px))?
            }
        }
        34 | 60 => td(texture2ddecoder::decode_etc1(data, w, h, &mut px))?,
        45 => td(texture2ddecoder::decode_etc2_rgb(data, w, h, &mut px))?,
        46 => td(texture2ddecoder::decode_etc2_rgba1(data, w, h, &mut px))?,
        47 | 61 => td(texture2ddecoder::decode_etc2_rgba8(data, w, h, &mut px))?,
        41 => td(texture2ddecoder::decode_eacr(data, w, h, &mut px))?,
        42 => td(texture2ddecoder::decode_eacr_signed(data, w, h, &mut px))?,
        43 => td(texture2ddecoder::decode_eacrg(data, w, h, &mut px))?,
        44 => td(texture2ddecoder::decode_eacrg_signed(data, w, h, &mut px))?,
        35 => td(texture2ddecoder::decode_atc_rgb4(data, w, h, &mut px))?,
        36 => td(texture2ddecoder::decode_atc_rgba8(data, w, h, &mut px))?,
        30 | 32 => td(texture2ddecoder::decode_pvrtc(data, w, h, &mut px, f == 30))?,
        31 | 33 => td(texture2ddecoder::decode_pvrtc(data, w, h, &mut px, f == 31))?,
        48..=59 | 66..=71 => {
            let size = [4, 5, 6, 8, 10, 12][((f - 48) % 6) as usize];
            td(texture2ddecoder::decode_astc(data, w, h, size, size, &mut px))?
        }
        _ => bail!("texture format {f} ({}) is not supported", format_name(f)),
    }
    // texture2ddecoder writes BGRA in a u32 (src/color.rs).
    Ok(px
        .iter()
        .flat_map(|p| {
            let [b, g, r, a] = p.to_le_bytes();
            [r, g, b, a]
        })
        .collect())
}

pub fn write_png(path: &std::path::Path, w: usize, h: usize, rgba: &[u8]) -> Result<()> {
    let file = std::io::BufWriter::new(std::fs::File::create(path)?);
    let mut enc = png::Encoder::new(file, w as u32, h as u32);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    enc.set_compression(png::Compression::Fast);
    enc.write_header()?.write_image_data(rgba)?;
    Ok(())
}

/// A cover or icon for menus: the rectangle (in Unity's bottom-up pixel coordinates) cropped and
/// flipped to be upright.
pub fn write_cover(path: &std::path::Path, w: usize, h: usize, rgba: &[u8], rect: Option<[f32; 4]>) -> Result<()> {
    let [x, y, rw, rh] = rect.unwrap_or([0.0, 0.0, w as f32, h as f32]);
    let x0 = (x.max(0.0) as usize).min(w);
    let y0 = (y.max(0.0) as usize).min(h);
    let cw = (rw.max(0.0) as usize).min(w - x0);
    let ch = (rh.max(0.0) as usize).min(h - y0);
    ensure!(cw > 0 && ch > 0, "empty cover rectangle");
    let mut out = Vec::with_capacity(cw * ch * 4);
    for row in (y0..y0 + ch).rev() {
        out.extend_from_slice(&rgba[(row * w + x0) * 4..(row * w + x0 + cw) * 4]);
    }
    write_png(path, cw, ch, &out)
}

/// The stored levels in a DDS container (Microsoft "DDS file layout for textures"; a DX10 header
/// for BC6H, BC7 and the float formats).
fn dds(layout: DdsLayout, w: usize, h: usize, mips: usize, levels: &[u8]) -> Vec<u8> {
    let mut o = Vec::with_capacity(148 + levels.len());
    let u = |o: &mut Vec<u8>, v: u32| o.extend_from_slice(&v.to_le_bytes());
    let compressed = layout.block_bytes > 0;
    o.extend_from_slice(b"DDS ");
    u(&mut o, 124);
    // CAPS | HEIGHT | WIDTH | PIXELFORMAT | MIPMAPCOUNT, and LINEARSIZE or PITCH.
    u(&mut o, 0x1 | 0x2 | 0x4 | 0x1000 | 0x20000 | if compressed { 0x80000 } else { 0x8 });
    u(&mut o, h as u32);
    u(&mut o, w as u32);
    u(&mut o, if compressed { layout.level_size(w, h) as u32 } else { (w * layout.pixel_bytes) as u32 });
    u(&mut o, 0);
    u(&mut o, mips as u32);
    for _ in 0..11 {
        u(&mut o, 0);
    }
    u(&mut o, 32);
    u(&mut o, 0x4); // DDPF_FOURCC
    o.extend_from_slice(layout.fourcc);
    for _ in 0..5 {
        u(&mut o, 0);
    }
    u(&mut o, 0x1000 | if mips > 1 { 0x400008 } else { 0 }); // TEXTURE | MIPMAP | COMPLEX
    for _ in 0..4 {
        u(&mut o, 0);
    }
    if layout.fourcc == b"DX10" {
        u(&mut o, layout.dxgi);
        u(&mut o, 3); // D3D10_RESOURCE_DIMENSION_TEXTURE2D
        u(&mut o, 0);
        u(&mut o, 1);
        u(&mut o, 0);
    }
    o.extend_from_slice(levels);
    o
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mip_counts() {
        assert_eq!(full_mip_count(1024, 1024), 11);
        assert_eq!(full_mip_count(256, 64), 9);
        assert_eq!(full_mip_count(1, 1), 1);
        assert_eq!(full_mip_count(6900, 10), 13);
    }

    #[test]
    fn dds_headers() {
        let l = dds_layout(10).unwrap();
        assert_eq!(l.level_size(256, 256), 32768);
        assert_eq!(l.level_size(2, 2), 8);
        let d = dds(l, 8, 8, 4, &[0u8; 32 + 8 + 8 + 8]);
        assert_eq!(&d[0..4], b"DDS ");
        assert_eq!(u32::from_le_bytes(d[28..32].try_into().unwrap()), 4);
        assert_eq!(&d[84..88], b"DXT1");
        assert_eq!(d.len(), 128 + 56);
        let f = dds(dds_layout(17).unwrap(), 2, 2, 1, &[0u8; 32]);
        assert_eq!(&f[84..88], b"DX10");
        assert_eq!(u32::from_le_bytes(f[128..132].try_into().unwrap()), 10);
        assert_eq!(f.len(), 148 + 32);
    }

    #[test]
    fn packed_pixels_follow_assetstudio() {
        // ARGB4444 a=0xF r=0x8 g=0x4 b=0x2 -> 0xF842 little-endian.
        let px = decode_rgba((2019, 3, 0), 2, 1, 1, &0xF842u16.to_le_bytes()).unwrap();
        assert_eq!(px, vec![0x88, 0x44, 0x22, 0xFF]);
        // RGBA4444 r=0x8 g=0x4 b=0x2 a=0xF -> 0x842F.
        let px = decode_rgba((2019, 3, 0), 13, 1, 1, &0x842Fu16.to_le_bytes()).unwrap();
        assert_eq!(px, vec![0x88, 0x44, 0x22, 0xFF]);
        // RGB565 pure green.
        let px = decode_rgba((2019, 3, 0), 7, 1, 1, &(63u16 << 5).to_le_bytes()).unwrap();
        assert_eq!(px, vec![0, 255, 0, 255]);
        assert_eq!(decode_rgba((2019, 3, 0), 1, 1, 1, &[7]).unwrap(), vec![0, 0, 0, 7]);
        assert_eq!(decode_rgba((2019, 3, 0), 63, 1, 1, &[9]).unwrap(), vec![9, 0, 0, 255]);
        assert!(decode_rgba((2019, 3, 0), 4, 2, 2, &[0; 15]).is_err());
        assert!(decode_rgba((2019, 3, 0), 10, 4, 4, &[0; 7]).is_err());
    }

    #[test]
    fn cover_is_cropped_and_flipped() {
        let dir = std::env::temp_dir().join(format!("kenbu-cover-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("c.png");
        // 2x2: bottom row red, top row blue (Unity order: first row is the bottom).
        let rgba = [255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255];
        write_cover(&path, 2, 2, &rgba, None).unwrap();
        let decoder = png::Decoder::new(std::io::BufReader::new(std::fs::File::open(&path).unwrap()));
        let mut reader = decoder.read_info().unwrap();
        let mut buf = vec![0; reader.output_buffer_size().unwrap()];
        reader.next_frame(&mut buf).unwrap();
        assert_eq!(&buf[0..4], &[0, 0, 255, 255], "the top row of the PNG is the top of the artwork");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
