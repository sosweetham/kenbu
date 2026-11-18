//! Qosmetics `.whacker` sabers: a zip holding `package.json`, a PC bundle, an Android bundle and a
//! thumbnail. CustomSabersLite 1.0.3 reads the first `.json`, refuses `config.isLegacy`, loads the
//! entry named `pcFileName` and the asset `_Whacker` (`Services/WhackerLoader.cs` 45-80); the
//! descriptor is `objectName`, `author`, `description`, `coverImage` (`Models/WhackerDescriptor.cs`).
//!
//! Only what that needs of the zip format is read: the central directory, stored and deflated
//! entries, CRC-32 checked, sizes bounded before inflating.

use anyhow::{Context, Result, anyhow, bail, ensure};
use serde_json::Value;

const MAX_ENTRY: usize = 512 << 20;

pub struct Package {
    pub json: Value,
    pub bundle: Vec<u8>,
    pub bundle_name: String,
    pub thumbnail: Option<Vec<u8>>,
}

pub fn is_zip(bytes: &[u8]) -> bool {
    bytes.starts_with(b"PK\x03\x04")
}

struct ZipEntry {
    name: String,
    method: u16,
    crc: u32,
    packed: usize,
    unpacked: usize,
    local_offset: usize,
}

fn u16_at(b: &[u8], at: usize) -> Result<u16> {
    Ok(u16::from_le_bytes(b.get(at..at + 2).context("truncated zip")?.try_into()?))
}

fn u32_at(b: &[u8], at: usize) -> Result<u32> {
    Ok(u32::from_le_bytes(b.get(at..at + 4).context("truncated zip")?.try_into()?))
}

fn entries(b: &[u8]) -> Result<Vec<ZipEntry>> {
    // The end-of-central-directory record is in the last 64 KiB + 22 bytes.
    let search_from = b.len().saturating_sub(65_557);
    let eocd = (search_from..b.len().saturating_sub(21))
        .rev()
        .find(|&i| b[i..].starts_with(b"PK\x05\x06"))
        .context("zip without a central directory")?;
    let count = u16_at(b, eocd + 10)? as usize;
    let mut at = u32_at(b, eocd + 16)? as usize;
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        ensure!(b.get(at..at + 4) == Some(b"PK\x01\x02"), "damaged zip directory");
        let flags = u16_at(b, at + 8)?;
        ensure!(flags & 1 == 0, "encrypted zip entries are not supported");
        let name_len = u16_at(b, at + 28)? as usize;
        let extra_len = u16_at(b, at + 30)? as usize;
        let comment_len = u16_at(b, at + 32)? as usize;
        let name_bytes = b.get(at + 46..at + 46 + name_len).context("truncated zip")?;
        let packed = u32_at(b, at + 20)?;
        let unpacked = u32_at(b, at + 24)?;
        ensure!(packed != u32::MAX && unpacked != u32::MAX, "zip64 entries are not supported");
        out.push(ZipEntry {
            name: String::from_utf8_lossy(name_bytes).into_owned(),
            method: u16_at(b, at + 10)?,
            crc: u32_at(b, at + 16)?,
            packed: packed as usize,
            unpacked: unpacked as usize,
            local_offset: u32_at(b, at + 42)? as usize,
        });
        at += 46 + name_len + extra_len + comment_len;
    }
    Ok(out)
}

fn read_entry(b: &[u8], e: &ZipEntry) -> Result<Vec<u8>> {
    ensure!(e.unpacked <= MAX_ENTRY, "zip entry {} unpacks to {} bytes", e.name, e.unpacked);
    let at = e.local_offset;
    ensure!(b.get(at..at + 4) == Some(b"PK\x03\x04"), "damaged zip entry {}", e.name);
    let start = at + 30 + u16_at(b, at + 26)? as usize + u16_at(b, at + 28)? as usize;
    let data = b
        .get(start..start.checked_add(e.packed).context("zip entry size overflows")?)
        .context("truncated zip entry")?;
    let out = match e.method {
        0 => data.to_vec(),
        8 => miniz_oxide::inflate::decompress_to_vec_with_limit(data, e.unpacked)
            .map_err(|err| anyhow!("inflating {}: {err:?}", e.name))?,
        m => bail!("zip entry {} uses compression method {m}", e.name),
    };
    ensure!(out.len() == e.unpacked, "zip entry {} unpacked to {} bytes, {} expected", e.name, out.len(), e.unpacked);
    ensure!(crc32fast::hash(&out) == e.crc, "zip entry {} fails its CRC", e.name);
    Ok(out)
}

pub fn read(bytes: &[u8]) -> Result<Package> {
    let list = entries(bytes)?;
    let json_entry =
        list.iter().find(|e| e.name.to_ascii_lowercase().ends_with(".json")).context("whacker without package.json")?;
    let json: Value = serde_json::from_slice(&read_entry(bytes, json_entry)?).context("whacker package.json")?;
    ensure!(
        json["config"]["isLegacy"].as_bool() != Some(true),
        "legacy whackers are not supported (CustomSabersLite refuses them too)"
    );
    let pc = json["pcFileName"].as_str().context("package.json names no pcFileName")?;
    let bundle_entry = list.iter().find(|e| e.name == pc).with_context(|| format!("whacker has no entry {pc}"))?;
    let bundle = read_entry(bytes, bundle_entry)?;
    let thumbnail = json["descriptor"]["coverImage"]
        .as_str()
        .and_then(|name| list.iter().find(|e| e.name == name))
        .and_then(|e| read_entry(bytes, e).ok());
    Ok(Package { bundle_name: pc.to_string(), json, bundle, thumbnail })
}

/// The Android bundle a package also carries (package.json `androidFileName`), whose shaders are
/// GLSL ES 3 programs; None when it names none.
// Only tools/kenbu-shader reads it (through src/lib.rs); the command line's copy of this module does not.
#[allow(dead_code)]
pub fn android_bundle(bytes: &[u8]) -> Result<Option<Vec<u8>>> {
    let list = entries(bytes)?;
    let json_entry =
        list.iter().find(|e| e.name.to_ascii_lowercase().ends_with(".json")).context("whacker without package.json")?;
    let json: Value = serde_json::from_slice(&read_entry(bytes, json_entry)?).context("whacker package.json")?;
    let Some(entry) = json["androidFileName"].as_str().and_then(|name| list.iter().find(|e| e.name == name)) else {
        return Ok(None);
    };
    Ok(Some(read_entry(bytes, entry)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A stored zip with the given entries, as a zip writer lays them out.
    fn zip(files: &[(&str, &[u8])]) -> Vec<u8> {
        let mut out = Vec::new();
        let mut central = Vec::new();
        for (name, data) in files {
            let offset = out.len() as u32;
            let crc = crc32fast::hash(data);
            let mut local = b"PK\x03\x04".to_vec();
            local.extend_from_slice(&[20, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
            local.extend_from_slice(&crc.to_le_bytes());
            local.extend_from_slice(&(data.len() as u32).to_le_bytes());
            local.extend_from_slice(&(data.len() as u32).to_le_bytes());
            local.extend_from_slice(&(name.len() as u16).to_le_bytes());
            local.extend_from_slice(&0u16.to_le_bytes());
            local.extend_from_slice(name.as_bytes());
            out.extend_from_slice(&local);
            out.extend_from_slice(data);
            let mut c = b"PK\x01\x02".to_vec();
            c.extend_from_slice(&[20, 0, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
            c.extend_from_slice(&crc.to_le_bytes());
            c.extend_from_slice(&(data.len() as u32).to_le_bytes());
            c.extend_from_slice(&(data.len() as u32).to_le_bytes());
            c.extend_from_slice(&(name.len() as u16).to_le_bytes());
            c.extend_from_slice(&[0; 12]);
            c.extend_from_slice(&offset.to_le_bytes());
            c.extend_from_slice(name.as_bytes());
            central.extend_from_slice(&c);
        }
        let dir_offset = out.len() as u32;
        out.extend_from_slice(&central);
        out.extend_from_slice(b"PK\x05\x06\0\0\0\0");
        out.extend_from_slice(&(files.len() as u16).to_le_bytes());
        out.extend_from_slice(&(files.len() as u16).to_le_bytes());
        out.extend_from_slice(&(central.len() as u32).to_le_bytes());
        out.extend_from_slice(&dir_offset.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out
    }

    #[test]
    fn reads_the_pc_bundle_and_thumbnail() {
        let json = br#"{"pcFileName": "s_pc", "descriptor": {"objectName": "S", "coverImage": "t.png"}, "config": {}}"#;
        let z = zip(&[("s_pc", b"bundle"), ("s_android", b"other"), ("package.json", json), ("t.png", b"png")]);
        assert!(is_zip(&z));
        let p = read(&z).unwrap();
        assert_eq!(p.bundle, b"bundle");
        assert_eq!(p.thumbnail.as_deref(), Some(&b"png"[..]));
        assert_eq!(p.json["descriptor"]["objectName"], "S");
    }

    #[test]
    fn refuses_legacy_and_damage() {
        let legacy = zip(&[("package.json", br#"{"pcFileName": "x", "config": {"isLegacy": true}}"#), ("x", b"b")]);
        assert!(read(&legacy).is_err());
        let good = zip(&[("package.json", br#"{"pcFileName": "x"}"#), ("x", b"b")]);
        for cut in 0..good.len() {
            let _ = read(&good[..cut]);
        }
        let mut bad_crc = good.clone();
        // The stored entry "x" is its name followed by its one data byte.
        let at = bad_crc.windows(2).position(|w| w == b"xb").unwrap() + 1;
        bad_crc[at] = b'c';
        assert!(read(&bad_crc).is_err());
    }
}
