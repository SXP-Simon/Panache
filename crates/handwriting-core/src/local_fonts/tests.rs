use super::*;
use tempfile::tempdir;

const HANDLEE: &[u8] = include_bytes!("../../assets/latin/Handlee-Regular.ttf");
const INDIE: &[u8] = include_bytes!("../../assets/latin/IndieFlower-Regular.ttf");

// Two genuinely different faces. TTC table offsets are relative to the entire collection.
fn collection() -> Vec<u8> {
    let mut out = b"ttcf\0\x01\0\0\0\0\0\x02".to_vec();
    out.resize(20, 0);
    for (idx, font) in [HANDLEE, INDIE].into_iter().enumerate() {
        let start = out.len();
        out[12 + 4 * idx..16 + 4 * idx].copy_from_slice(&(start as u32).to_be_bytes());
        out.extend_from_slice(font);
        let tables = u16::from_be_bytes([font[4], font[5]]) as usize;
        for i in 0..tables {
            let field = &mut out[start + 20 + 16 * i..start + 24 + 16 * i];
            let offset = u32::from_be_bytes(field.try_into().unwrap()) + start as u32;
            field.copy_from_slice(&offset.to_be_bytes());
        }
        out.resize(out.len().next_multiple_of(4), 0);
    }
    out
}

#[test]
fn search_pages_sources_and_collection_face_bytes() {
    let home = tempdir().unwrap();
    let user = home.path().join("my-fonts");
    let system = home.path().join("system");
    fs::create_dir_all(&system).unwrap();
    fs::create_dir_all(&user).unwrap();
    fs::write(system.join("sample.ttf"), HANDLEE).unwrap();
    fs::write(user.join("sample.ttf"), INDIE).unwrap();
    fs::write(user.join("collection.ttc"), collection()).unwrap();
    fs::write(user.join("bad.ttf"), b"not a font").unwrap();
    let catalog = LocalFonts {
        user_dir: Some(user.clone()),
        ..LocalFonts::new(vec!["sample.ttf".to_owned()], 110_000)
    };
    let index = catalog.scan(|db| db.load_fonts_dir(&system));
    *catalog.index.lock().unwrap() = Some(index);

    let first = catalog
        .search(&FontSearch {
            limit: Some(2),
            ..Default::default()
        })
        .unwrap();
    assert_eq!((first.total, first.next_offset), (5, Some(2)));
    assert_eq!(first.fonts[0].id, "sample.ttf");
    let last = catalog
        .search(&FontSearch {
            offset: 2,
            ..Default::default()
        })
        .unwrap();
    assert_eq!((last.fonts.len(), last.next_offset), (3, None));
    let query = |q: &str, source| {
        catalog
            .search(&FontSearch {
                query: q.into(),
                source: Some(source),
                ..Default::default()
            })
            .unwrap()
            .fonts
    };
    let twins = query("SAMPLE", FontSource::System);
    assert_eq!(twins.len(), 1);
    let personal = query("sample", FontSource::User);
    assert_ne!(personal[0].id, twins[0].id);
    assert_eq!(catalog.read(&personal[0].id).unwrap().1, INDIE);
    assert!(catalog.read("../sample.ttf").is_err());
    assert!(catalog.read("sample.ttf").is_err());
    let faces = query("COLLECTION", FontSource::User);
    assert_eq!(faces.len(), 2);
    for face in faces {
        assert!(face.filename.ends_with(".ttf"));
        let bytes = catalog.read(&face.id).unwrap().1;
        assert!(!bytes.starts_with(b"ttcf"));
        assert_eq!(display_name(&bytes, 0).as_ref(), Some(&face.name));
        let expected = if face.filename.ends_with("-2.ttf") {
            INDIE
        } else {
            HANDLEE
        };
        assert_eq!(display_name(expected, 0), display_name(&bytes, 0));
    }
    assert!(
        catalog
            .search(&FontSearch {
                limit: Some(101),
                ..Default::default()
            })
            .is_err()
    );
    fs::remove_file(user.join("sample.ttf")).unwrap();
    assert!(catalog.read(&personal[0].id).is_err());
}

#[test]
fn unavailable_personal_directory_keeps_other_sources_usable() {
    let home = tempdir().unwrap();
    let system_font = home.path().join("system.ttf");
    fs::write(&system_font, HANDLEE).unwrap();
    // An existing regular file prevents the personal directory from being created.
    for path in [None, Some(system_font.join("fonts"))] {
        let catalog = LocalFonts {
            user_dir: path,
            ..LocalFonts::new(vec!["bundled.ttf".into()], 50_000)
        };
        let index = catalog.scan(|db| db.load_font_file(&system_font).unwrap());
        *catalog.index.lock().unwrap() = Some(index);
        let results = catalog.search(&FontSearch::default()).unwrap();
        assert_eq!(results.total, 2);
        assert!(results.user_dir.is_none());
        assert_eq!(results.fonts[0].id, "bundled.ttf");
        let system = catalog
            .search(&FontSearch {
                source: Some(FontSource::System),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(catalog.read(&system.fonts[0].id).unwrap().1, HANDLEE);
        let personal = catalog.search(&FontSearch {
            source: Some(FontSource::User),
            ..Default::default()
        });
        let error = personal.err().unwrap();
        assert!(error.message.contains("directory"));
        assert_eq!(
            catalog.read("user:missing").err().unwrap().message,
            error.message
        );
    }
}
