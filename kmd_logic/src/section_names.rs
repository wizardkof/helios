//! Deterministic P06 section name construction shared by the KMD and host tests.

const BASE_PREFIX: &str = "HeliosP06Section_";
const WIN32_PREFIX: &str = "Global\\";
const NATIVE_PREFIX: &str = "\\BaseNamedObjects\\";

#[derive(Debug, PartialEq, Eq)]
pub struct SectionNames<const N: usize> {
    pub object_base_name: [u16; N],
    pub object_base_name_len: usize,
    pub win32_name: [u16; N],
    pub win32_name_len: usize,
    pub native_name: [u16; N],
    pub native_name_len: usize,
}

fn append(output: &mut [u16], len: &mut usize, value: &str) -> Option<()> {
    for unit in value.encode_utf16() {
        *output.get_mut(*len)? = unit;
        *len += 1;
    }
    Some(())
}

fn append_hex(output: &mut [u16], len: &mut usize, value: u64, digits: usize) -> Option<()> {
    for shift in (0..digits).rev() {
        let nibble = ((value >> (shift * 4)) & 0xF) as u8;
        let unit = if nibble < 10 {
            b'0' + nibble
        } else {
            b'A' + nibble - 10
        };
        *output.get_mut(*len)? = unit as u16;
        *len += 1;
    }
    Some(())
}

/// Build a common base name and its Win32 and Object Manager namespace spellings.
pub fn make<const N: usize>(probe_id: u32, generation: u64) -> Option<SectionNames<N>> {
    let mut names = SectionNames {
        object_base_name: [0; N],
        object_base_name_len: 0,
        win32_name: [0; N],
        win32_name_len: 0,
        native_name: [0; N],
        native_name_len: 0,
    };
    append(
        &mut names.object_base_name,
        &mut names.object_base_name_len,
        BASE_PREFIX,
    )?;
    append_hex(
        &mut names.object_base_name,
        &mut names.object_base_name_len,
        probe_id as u64,
        8,
    )?;
    append(
        &mut names.object_base_name,
        &mut names.object_base_name_len,
        "_",
    )?;
    append_hex(
        &mut names.object_base_name,
        &mut names.object_base_name_len,
        generation,
        16,
    )?;
    *names.object_base_name.get_mut(names.object_base_name_len)? = 0;

    append(
        &mut names.win32_name,
        &mut names.win32_name_len,
        WIN32_PREFIX,
    )?;
    for unit in names
        .object_base_name
        .iter()
        .copied()
        .take(names.object_base_name_len)
    {
        *names.win32_name.get_mut(names.win32_name_len)? = unit;
        names.win32_name_len += 1;
    }
    *names.win32_name.get_mut(names.win32_name_len)? = 0;

    append(
        &mut names.native_name,
        &mut names.native_name_len,
        NATIVE_PREFIX,
    )?;
    for unit in names
        .object_base_name
        .iter()
        .copied()
        .take(names.object_base_name_len)
    {
        *names.native_name.get_mut(names.native_name_len)? = unit;
        names.native_name_len += 1;
    }
    *names.native_name.get_mut(names.native_name_len)? = 0;
    Some(names)
}

#[cfg(test)]
mod tests {
    extern crate std;

    use super::make;

    fn string(units: &[u16], len: usize) -> std::string::String {
        std::string::String::from_utf16(&units[..len]).unwrap()
    }

    #[test]
    fn names_use_the_same_base_with_distinct_namespace_prefixes() {
        let names = make::<128>(0x12AB, 0x34).unwrap();
        assert_eq!(
            string(&names.object_base_name, names.object_base_name_len),
            "HeliosP06Section_000012AB_0000000000000034"
        );
        assert_eq!(
            string(&names.win32_name, names.win32_name_len),
            "Global\\HeliosP06Section_000012AB_0000000000000034"
        );
        let native = string(&names.native_name, names.native_name_len);
        assert_eq!(
            native,
            "\\BaseNamedObjects\\HeliosP06Section_000012AB_0000000000000034"
        );
        assert!(!native.contains("\\BaseNamedObjects\\Global\\"));
    }

    #[test]
    fn object_manager_name_is_not_reconstructed_from_win32_spelling() {
        let names = make::<128>(0x12AB, 0x34).unwrap();
        let win32 = string(&names.win32_name, names.win32_name_len);
        let native = string(&names.native_name, names.native_name_len);

        // The kernel receives native_name directly. Prefixing the public name
        // would create the invalid \BaseNamedObjects\Global\... object.
        let reconstructed = std::format!("\\BaseNamedObjects\\{win32}");
        assert_ne!(native, reconstructed);
        assert!(!native.contains("\\BaseNamedObjects\\Global\\"));
    }

    #[test]
    fn names_fail_when_any_output_cannot_fit_with_nul_terminator() {
        assert!(make::<32>(1, 1).is_none());
        assert!(make::<96>(1, 1).is_some());
    }
}
