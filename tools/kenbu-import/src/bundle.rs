//! One AssetBundle's serialized file (read through its own type trees by rabex) and the resource
//! files beside it (`.resS` streamed mesh and texture data, `.resource` audio).

use anyhow::{Context, Result, anyhow, bail, ensure};
use rabex::files::SerializedFile;
use rabex::files::serializedfile::ObjectInfo;
use rabex::objects::ClassId;
use rabex::tpk::TpkTypeTreeBlob;
use rabex::typetree::typetree_cache::TypeTreeCache;
use serde::de::DeserializeOwned;
use std::collections::HashMap;
use std::io::Cursor;

use crate::container::{self, Archive};
use crate::unity::{MonoScript, PPtr, StreamingInfo};

pub struct Bundle {
    pub archive_format: u32,
    pub archive_flags: u32,
    pub player_version: String,
    pub engine_version: String,
    pub compression: &'static str,
    pub serialized_name: String,
    pub file: SerializedFile,
    pub version: (u32, u32, u32),
    data: Vec<u8>,
    resources: HashMap<String, Vec<u8>>,
    tpk: TypeTreeCache<TpkTypeTreeBlob>,
    index: HashMap<i64, usize>,
    infos: Vec<ObjectInfo>,
}

impl Bundle {
    pub fn from_archive(archive: Archive) -> Result<Bundle> {
        let mut serialized: Option<(String, Vec<u8>)> = None;
        let mut resources = HashMap::new();
        for entry in archive.entries {
            // Old bundles may not flag their serialized file; it is the entry without an extension.
            let serialized_entry = entry.is_serialized()
                || !(entry.path.ends_with(".resS") || entry.path.ends_with(".resource") || entry.path.contains('.'));
            if serialized_entry {
                if serialized.is_some() {
                    bail!("bundle holds more than one serialized file ({})", entry.path);
                }
                serialized = Some((entry.path, entry.data));
            } else {
                let name = entry.path.rsplit('/').next().unwrap_or(&entry.path).to_string();
                resources.insert(name, entry.data);
            }
        }
        let (serialized_name, data) = serialized.ok_or_else(|| anyhow!("bundle holds no serialized file"))?;
        let file = SerializedFile::from_reader(&mut Cursor::new(&data)).context("serialized file")?;
        let version = match &file.m_UnityVersion {
            Some(v) if v.major > 0 => (u32::from(v.major), u32::from(v.minor), u32::from(v.build)),
            _ => container::version_triple(&archive.engine_version),
        };
        ensure!(version.0 >= 5, "Unity {}.{} files are not supported", version.0, version.1);
        let infos: Vec<ObjectInfo> = file.objects().cloned().collect();
        let index = infos.iter().enumerate().map(|(i, o)| (o.m_PathID, i)).collect();
        Ok(Bundle {
            archive_format: archive.format,
            archive_flags: archive.flags,
            player_version: archive.player_version,
            engine_version: archive.engine_version,
            compression: archive.compression.name(),
            serialized_name,
            file,
            version,
            data,
            resources,
            tpk: TypeTreeCache::embedded(),
            index,
            infos,
        })
    }

    pub fn infos(&self) -> &[ObjectInfo] {
        &self.infos
    }

    pub fn info(&self, path_id: i64) -> Option<&ObjectInfo> {
        self.index.get(&path_id).map(|&i| &self.infos[i])
    }

    pub fn class_of(&self, path_id: i64) -> Option<ClassId> {
        self.info(path_id).map(|o| o.m_ClassID)
    }

    pub fn read<T: DeserializeOwned>(&self, path_id: i64) -> Result<T> {
        let info = self.info(path_id).ok_or_else(|| anyhow!("no object {path_id}"))?;
        let end = (info.m_Offset as u64).checked_add(u64::from(info.m_Size));
        ensure!(
            info.m_Offset >= 0 && end.is_some_and(|e| e <= self.data.len() as u64),
            "object {path_id} lies outside the serialized file"
        );
        let mut cursor = Cursor::new(self.data.as_slice());
        self.file
            .read::<T>(info, &self.tpk, &mut cursor)
            .with_context(|| format!("reading {:?} {path_id}", info.m_ClassID))
    }

    pub fn of_class(&self, class: ClassId) -> impl Iterator<Item = i64> + '_ {
        self.infos.iter().filter(move |o| o.m_ClassID == class).map(|o| o.m_PathID)
    }

    /// Bytes of streamed data (mesh vertices, texture mips) kept in a resource file.
    pub fn stream(&self, info: &StreamingInfo) -> Result<&[u8]> {
        // Paths look like "archive:/CAB-x/CAB-x.resS"; the bundle lists the file by its last part.
        let name = info.path.rsplit('/').next().unwrap_or(&info.path);
        let file = self.resources.get(name).ok_or_else(|| anyhow!("missing resource file {}", info.path))?;
        let start = usize::try_from(info.offset)?;
        let end = start.checked_add(info.size as usize).ok_or_else(|| anyhow!("stream size overflows"))?;
        file.get(start..end)
            .ok_or_else(|| anyhow!("stream {start}..{end} outside {} ({} bytes)", info.path, file.len()))
    }

    /// The MonoScript a MonoBehaviour runs, as (namespace, class, assembly).
    pub fn script(&self, script: PPtr) -> Option<MonoScript> {
        let id = script.local()?;
        self.read::<MonoScript>(id).ok()
    }

    pub fn external_path(&self, file_id: i32) -> Option<&str> {
        let idx = usize::try_from(file_id).ok()?.checked_sub(1)?;
        self.file.m_Externals.get(idx).map(|e| e.pathName.as_str())
    }
}
