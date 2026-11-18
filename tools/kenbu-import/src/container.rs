//! UnityFS archives, Unity's AssetBundle container, read as UnityPy 1.25.4 reads them
//! (`files/BundleFile.py` `read_fs`, lines 96-186): a big-endian header, a block table (usually
//! LZ4HC), data blocks (LZMA, LZ4 or stored) and a directory of the files inside.
//!
//! The files are untrusted downloads, so every size is checked against the input and the limits
//! below before anything is allocated.

use anyhow::{Context, Result, bail, ensure};
use std::io::Read;

/// Largest total of uncompressed data accepted (the biggest model on BeatMods unpacks to ~400 MB).
pub const MAX_UNPACKED: u64 = 2 << 30;
/// Largest block table accepted.
const MAX_BLOCK_INFO: u32 = 64 << 20;
const MAX_BLOCKS: usize = 1 << 20;
const MAX_ENTRIES: usize = 1 << 16;

/// Directory flag of a serialized file (UnityPy `File.py`, `flags & 4`).
const ENTRY_SERIALIZED: u32 = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Compression {
    None,
    Lzma,
    Lz4,
    Lz4Hc,
}

impl Compression {
    fn from_flags(flags: u32) -> Result<Compression> {
        Ok(match flags & 0x3F {
            0 => Compression::None,
            1 => Compression::Lzma,
            2 => Compression::Lz4,
            3 => Compression::Lz4Hc,
            4 => bail!("LZHAM-compressed bundles are not supported"),
            other => bail!("unknown bundle compression {other}"),
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            Compression::None => "none",
            Compression::Lzma => "lzma",
            Compression::Lz4 => "lz4",
            Compression::Lz4Hc => "lz4hc",
        }
    }
}

pub struct Entry {
    pub path: String,
    pub flags: u32,
    pub data: Vec<u8>,
}

impl Entry {
    pub fn is_serialized(&self) -> bool {
        self.flags & ENTRY_SERIALIZED != 0
    }
}

pub struct Archive {
    pub format: u32,
    pub player_version: String,
    pub engine_version: String,
    /// Compression of the data blocks (the block table's own is not recorded).
    pub compression: Compression,
    pub flags: u32,
    pub entries: Vec<Entry>,
}

/// A big-endian cursor that fails instead of reading past the end.
struct Cursor<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        let end = self.pos.checked_add(n).filter(|&e| e <= self.data.len());
        let Some(end) = end else { bail!("truncated: needs {n} bytes at {}, has {}", self.pos, self.data.len()) };
        let out = &self.data[self.pos..end];
        self.pos = end;
        Ok(out)
    }

    fn u16(&mut self) -> Result<u16> {
        Ok(u16::from_be_bytes(self.take(2)?.try_into()?))
    }

    fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_be_bytes(self.take(4)?.try_into()?))
    }

    fn i32(&mut self) -> Result<i32> {
        Ok(i32::from_be_bytes(self.take(4)?.try_into()?))
    }

    fn i64(&mut self) -> Result<i64> {
        Ok(i64::from_be_bytes(self.take(8)?.try_into()?))
    }

    fn cstr(&mut self, max: usize) -> Result<String> {
        let rest = &self.data[self.pos.min(self.data.len())..];
        let len = rest.iter().take(max).position(|&b| b == 0).context("unterminated string")?;
        let s = String::from_utf8_lossy(&rest[..len]).into_owned();
        self.pos += len + 1;
        Ok(s)
    }

    fn align16(&mut self) {
        self.pos = self.pos.div_ceil(16) * 16;
    }
}

/// `major.minor.patch` of a version string such as "2019.4.15f1"; zeros for parts it lacks.
pub fn version_triple(version: &str) -> (u32, u32, u32) {
    let mut parts =
        version.split(|c: char| !c.is_ascii_digit()).filter(|p| !p.is_empty()).map(|p| p.parse::<u32>().unwrap_or(0));
    (parts.next().unwrap_or(0), parts.next().unwrap_or(0), parts.next().unwrap_or(0))
}

/// Whether the header flags use the pre-2020.3.34 meaning, where 0x200 marks encryption rather
/// than block-info padding (UnityPy `BundleFile.py` 113-121).
fn old_flag_layout(version: (u32, u32, u32)) -> bool {
    version < (2020, 0, 0)
        || (version.0 == 2020 && version < (2020, 3, 34))
        || (version.0 == 2021 && version < (2021, 3, 2))
        || (version.0 == 2022 && version < (2022, 1, 1))
}

pub fn read(bytes: &[u8]) -> Result<Archive> {
    let mut c = Cursor { data: bytes, pos: 0 };
    let signature = c.cstr(16)?;
    match signature.as_str() {
        "UnityFS" => {}
        "UnityWeb" | "UnityRaw" | "UnityArchive" => bail!("{signature} bundles (Unity 4 and older) are not supported"),
        _ => bail!("not a Unity bundle"),
    }
    let format = c.u32()?;
    let player_version = c.cstr(64)?;
    let engine_version = c.cstr(64)?;
    let _file_size = c.i64()?;
    let info_packed = c.u32()?;
    let info_size = c.u32()?;
    let flags = c.u32()?;
    let version = version_triple(&engine_version);
    let old_flags = old_flag_layout(version);
    let encrypted = if old_flags { flags & 0x200 != 0 } else { flags & 0x1400 != 0 };
    ensure!(!encrypted, "encrypted bundles are not supported");
    // Format 7 and later align the block table to 16; so do some 2019.4.15+ bundles that still
    // say format 6 (UnityPy `BundleFile.py` 126-131).
    if format >= 7 || (version.0 == 2019 && version >= (2019, 4, 15)) {
        c.align16();
    }
    ensure!(info_size <= MAX_BLOCK_INFO, "block table of {info_size} bytes");
    let info_packed_bytes = if flags & 0x80 != 0 {
        let start = bytes.len().checked_sub(info_packed as usize).context("block table outside the file")?;
        &bytes[start..]
    } else {
        c.take(info_packed as usize)?
    };
    let info =
        decompress(info_packed_bytes, info_size as usize, Compression::from_flags(flags)?).context("block table")?;

    let mut ic = Cursor { data: &info, pos: 0 };
    ic.take(16)?;
    let block_count = ic.i32()?;
    ensure!((0..=MAX_BLOCKS as i32).contains(&block_count), "{block_count} data blocks");
    let mut blocks = Vec::with_capacity(block_count as usize);
    let mut unpacked_total: u64 = 0;
    for _ in 0..block_count {
        let unpacked = ic.u32()?;
        let packed = ic.u32()?;
        let block_flags = ic.u16()?;
        unpacked_total += u64::from(unpacked);
        blocks.push((unpacked, packed, block_flags));
    }
    ensure!(unpacked_total <= MAX_UNPACKED, "bundle unpacks to {unpacked_total} bytes");
    let entry_count = ic.i32()?;
    ensure!((0..=MAX_ENTRIES as i32).contains(&entry_count), "{entry_count} bundle entries");
    let mut directory = Vec::with_capacity(entry_count as usize);
    for _ in 0..entry_count {
        let offset = ic.i64()?;
        let size = ic.i64()?;
        let entry_flags = ic.u32()?;
        let path = ic.cstr(1024)?;
        directory.push((offset, size, entry_flags, path));
    }
    if !old_flags && flags & 0x200 != 0 {
        c.align16();
    }

    let mut data = Vec::with_capacity(unpacked_total as usize);
    let mut compression = Compression::None;
    for (i, &(unpacked, packed, block_flags)) in blocks.iter().enumerate() {
        let block_compression = Compression::from_flags(u32::from(block_flags))?;
        if block_compression != Compression::None {
            compression = block_compression;
        }
        let packed_bytes = c.take(packed as usize).with_context(|| format!("data block {i}"))?;
        let block = decompress(packed_bytes, unpacked as usize, block_compression)
            .with_context(|| format!("data block {i}"))?;
        data.extend_from_slice(&block);
    }

    let mut entries = Vec::with_capacity(directory.len());
    for (offset, size, entry_flags, path) in directory {
        let range = usize::try_from(offset)
            .ok()
            .zip(usize::try_from(size).ok())
            .and_then(|(o, s)| Some(o..o.checked_add(s)?))
            .filter(|r| r.end <= data.len());
        let Some(range) = range else { bail!("entry {path} lies outside the bundle's data") };
        entries.push(Entry { path, flags: entry_flags, data: data[range].to_vec() });
    }
    Ok(Archive { format, player_version, engine_version, compression, flags, entries })
}

/// Unity's LZMA blocks are 5 property bytes followed by the raw stream, without the size field of
/// an .lzma file (UnityPy `CompressionHelper.py` `decompress_lzma`).
fn decompress(packed: &[u8], unpacked: usize, compression: Compression) -> Result<Vec<u8>> {
    ensure!(unpacked as u64 <= MAX_UNPACKED, "block unpacks to {unpacked} bytes");
    let out = match compression {
        Compression::None => {
            ensure!(packed.len() == unpacked, "stored block of {} bytes, {unpacked} expected", packed.len());
            packed.to_vec()
        }
        Compression::Lz4 | Compression::Lz4Hc => {
            lz4_flex::block::decompress(packed, unpacked).map_err(|e| anyhow::anyhow!("LZ4: {e}"))?
        }
        Compression::Lzma => {
            ensure!(packed.len() >= 5, "LZMA block without properties");
            let props = packed[0];
            let dict = u32::from_le_bytes(packed[1..5].try_into()?);
            // A window larger than the output is never used; capping it keeps a forged header
            // from allocating gigabytes.
            let dict = dict.min((unpacked as u32).max(4096));
            let mut reader = lzma_rust2::LzmaReader::new_with_props(&packed[5..], unpacked as u64, props, dict, None)
                .map_err(|e| anyhow::anyhow!("LZMA: {e}"))?;
            let mut out = Vec::with_capacity(unpacked);
            reader.read_to_end(&mut out).map_err(|e| anyhow::anyhow!("LZMA: {e}"))?;
            out
        }
    };
    ensure!(out.len() == unpacked, "block unpacked to {} bytes, {unpacked} expected", out.len());
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A minimal UnityFS archive with one stored file, in the 2018 (format 6) layout.
    pub fn archive(format: u32, engine: &str, block_flags: u16, payload: &[u8], packed: &[u8]) -> Vec<u8> {
        let mut info = vec![0u8; 16];
        info.extend_from_slice(&1i32.to_be_bytes());
        info.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        info.extend_from_slice(&(packed.len() as u32).to_be_bytes());
        info.extend_from_slice(&block_flags.to_be_bytes());
        info.extend_from_slice(&1i32.to_be_bytes());
        info.extend_from_slice(&0i64.to_be_bytes());
        info.extend_from_slice(&(payload.len() as i64).to_be_bytes());
        info.extend_from_slice(&4u32.to_be_bytes());
        info.extend_from_slice(b"CAB-test\0");
        let mut out = b"UnityFS\0".to_vec();
        out.extend_from_slice(&format.to_be_bytes());
        out.extend_from_slice(b"5.x.x\0");
        out.extend_from_slice(engine.as_bytes());
        out.push(0);
        out.extend_from_slice(&0i64.to_be_bytes());
        out.extend_from_slice(&(info.len() as u32).to_be_bytes());
        out.extend_from_slice(&(info.len() as u32).to_be_bytes());
        out.extend_from_slice(&0x40u32.to_be_bytes());
        if format >= 7 {
            out.resize(out.len().div_ceil(16) * 16, 0);
        }
        out.extend_from_slice(&info);
        out.extend_from_slice(packed);
        out
    }

    #[test]
    fn reads_a_stored_format_6_archive() {
        let bytes = archive(6, "2018.1.6f1", 0, b"hello", b"hello");
        let a = read(&bytes).unwrap();
        assert_eq!(a.format, 6);
        assert_eq!(a.engine_version, "2018.1.6f1");
        assert_eq!(a.entries.len(), 1);
        assert_eq!(a.entries[0].path, "CAB-test");
        assert!(a.entries[0].is_serialized());
        assert_eq!(a.entries[0].data, b"hello");
    }

    #[test]
    fn aligns_format_8_and_reads_lz4() {
        let payload = b"abcabcabcabcabcabcabcabc".repeat(10);
        let packed = lz4_flex::block::compress(&payload);
        let bytes = archive(8, "2021.3.16f1", 2, &payload, &packed);
        let a = read(&bytes).unwrap();
        assert_eq!(a.compression, Compression::Lz4);
        assert_eq!(a.entries[0].data, payload);
    }

    #[test]
    fn rejects_damage_without_panicking() {
        let bytes = archive(6, "2018.1.6f1", 0, b"hello", b"hello");
        for cut in 0..bytes.len() {
            assert!(read(&bytes[..cut]).is_err(), "truncated at {cut}");
        }
        let mut bad = bytes.clone();
        let n = bad.len();
        bad[n - 6] ^= 0xFF;
        let _ = read(&bad);
        assert!(read(b"UnityWeb\0").is_err());
        assert!(read(b"").is_err());
    }

    #[test]
    fn rejects_oversized_blocks() {
        let mut bytes = archive(6, "2018.1.6f1", 0, b"hello", b"hello");
        // The block's uncompressed size sits right after the 16-byte hash and the block count.
        let header = bytes.len() - 5 - (16 + 4 + 10 + 4 + 8 + 8 + 4 + 9);
        let at = header + 16 + 4;
        bytes[at..at + 4].copy_from_slice(&u32::MAX.to_be_bytes());
        assert!(read(&bytes).is_err());
    }

    #[test]
    fn versions() {
        assert_eq!(version_triple("2019.4.15f1"), (2019, 4, 15));
        assert_eq!(version_triple("6000.0.40f1"), (6000, 0, 40));
        assert_eq!(version_triple("5.x.x"), (5, 0, 0));
        assert!(old_flag_layout((2019, 3, 15)));
        assert!(!old_flag_layout((2021, 3, 16)));
        assert!(old_flag_layout((2021, 3, 1)));
    }
}
