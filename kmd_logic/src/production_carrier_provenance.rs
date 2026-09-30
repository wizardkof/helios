//! Pure policy applied after the WDK layer references a caller's Section
//! HANDLE and normalizes its Object Manager name and security descriptor.
//! This module does not establish object type or read kernel memory itself.

pub const CARRIER_RECORD_VERSION: u32 = 2;
pub const SECTION_MAP_READ: u32 = 0x0004;
pub const SECTION_QUERY: u32 = 0x0001;
pub const SECTION_ALL_ACCESS: u32 = 0x000f_001f;
pub const READER_ACCESS: u32 = SECTION_MAP_READ | SECTION_QUERY;
pub const SYSTEM_SID: [u8; 12] = [1, 1, 0, 0, 0, 0, 0, 5, 18, 0, 0, 0];
pub const AUTHENTICATED_USERS_SID: [u8; 12] = [1, 1, 0, 0, 0, 0, 0, 5, 11, 0, 0, 0];
const NAME_PREFIX: &[u8] = b"\\BaseNamedObjects\\HeliosP06Carrier_";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ObjectKind {
    Section,
    Other,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AceType {
    Allow,
    Other,
}

#[derive(Clone, Copy, Debug)]
pub struct Ace<'a> {
    pub kind: AceType,
    pub sid: &'a [u8],
    pub mask: u32,
    pub flags: u8,
}

#[derive(Clone, Copy, Debug)]
pub struct Metadata<'a> {
    pub kind: ObjectKind,
    pub name_utf16: &'a [u16],
    pub owner_sid: &'a [u8],
    pub dacl_present: bool,
    /// `None` with dacl_present=true is a NULL DACL; both states fail.
    pub dacl: Option<&'a [Ace<'a>]>,
    pub dacl_protected: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Refusal {
    WrongObjectType,
    InvalidIdentity,
    WrongName,
    CarrierIdMismatch,
    WrongOwner,
    WrongDacl,
    WrongRecord,
}

fn hex_digit(nibble: u8) -> u16 {
    b"0123456789abcdef"[nibble as usize] as u16
}

/// Writes the exact native Object Manager name from the KMD-generated ID.
pub fn write_name(id: &[u8; 16], out: &mut [u16; 128]) -> Result<usize, Refusal> {
    if id.iter().all(|byte| *byte == 0) {
        return Err(Refusal::InvalidIdentity);
    }
    for (index, byte) in NAME_PREFIX.iter().enumerate() {
        out[index] = *byte as u16;
    }
    for (index, byte) in id.iter().enumerate() {
        out[NAME_PREFIX.len() + index * 2] = hex_digit(byte >> 4);
        out[NAME_PREFIX.len() + index * 2 + 1] = hex_digit(byte & 0x0f);
    }
    let len = NAME_PREFIX.len() + 32;
    out[len] = 0;
    Ok(len)
}

fn exact_name(name: &[u16], id: &[u8; 16]) -> bool {
    let mut expected = [0u16; 128];
    let Ok(len) = write_name(id, &mut expected) else {
        return false;
    };
    name == &expected[..len] || name == &expected[..len + 1]
}

/// Check the normalized metadata and record identity. The WDK caller must
/// first use UserMode HANDLE access validation, require a Section object, and
/// release its temporary object/security references on every return path.
pub fn attest(metadata: &Metadata<'_>, expected_id: &[u8;16], expected_version: u32,
              record_id: &[u8;16], record_version: u32) -> Result<(),Refusal> {
    attest_observed(metadata, expected_id, expected_version, record_id, record_version, |_| {})
}

/// Identical policy with a bounded observer for the selected branch.
pub fn attest_observed(
    metadata: &Metadata<'_>,
    expected_id: &[u8; 16],
    expected_version: u32,
    record_id: &[u8; 16],
    record_version: u32,
    mut observer: impl FnMut(u32),
) -> Result<(), Refusal> {
    if metadata.kind != ObjectKind::Section {
        observer(21);
        return Err(Refusal::WrongObjectType);
    }
    if expected_id.iter().all(|byte| *byte == 0) {
        observer(22);
        return Err(Refusal::InvalidIdentity);
    }
    if expected_version != CARRIER_RECORD_VERSION
        || record_version != CARRIER_RECORD_VERSION
        || record_id != expected_id
    {
        observer(23);
        return Err(Refusal::WrongRecord);
    }
    if !exact_name(metadata.name_utf16, expected_id) {
        let name = metadata.name_utf16;
        let prefix_matches = name.len() >= NAME_PREFIX.len()
            && NAME_PREFIX
                .iter()
                .enumerate()
                .all(|(index, byte)| name[index] == *byte as u16);
        if prefix_matches
            && (name.len() == NAME_PREFIX.len() + 32
                || (name.len() == NAME_PREFIX.len() + 33 && name[name.len() - 1] == 0))
        {
            observer(24);
            return Err(Refusal::CarrierIdMismatch);
        }
        observer(25);
        return Err(Refusal::WrongName);
    }
    if metadata.owner_sid != SYSTEM_SID {
        observer(26);
        return Err(Refusal::WrongOwner);
    }
    if !metadata.dacl_present {
        observer(31);
        return Err(Refusal::WrongDacl);
    }
    let Some(aces) = metadata.dacl else {
        observer(32);
        return Err(Refusal::WrongDacl);
    };
    if !metadata.dacl_protected || aces.len() != 2 {
        observer(33);
        return Err(Refusal::WrongDacl);
    }
    let mut system = false;
    let mut readers = false;
    for ace in aces {
        if ace.kind != AceType::Allow || ace.flags != 0 {
            observer(34);
            return Err(Refusal::WrongDacl);
        }
        if ace.sid == SYSTEM_SID && ace.mask == SECTION_ALL_ACCESS && !system {
            system = true;
        } else if ace.sid == AUTHENTICATED_USERS_SID && ace.mask == READER_ACCESS && !readers {
            readers = true;
        } else {
            observer(35);
            return Err(Refusal::WrongDacl);
        }
    }
    if !system || !readers {
        observer(36);
        return Err(Refusal::WrongDacl);
    }
    observer(0);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    const ID: [u8; 16] = [0x12; 16];
    const OTHER_ID: [u8; 16] = [0x34; 16];
    const ACES: [Ace<'static>; 2] = [
        Ace {
            kind: AceType::Allow,
            sid: &SYSTEM_SID,
            mask: SECTION_ALL_ACCESS,
            flags: 0,
        },
        Ace {
            kind: AceType::Allow,
            sid: &AUTHENTICATED_USERS_SID,
            mask: READER_ACCESS,
            flags: 0,
        },
    ];

    fn genuine<'a>(name: &'a [u16]) -> Metadata<'a> {
        Metadata {
            kind: ObjectKind::Section,
            name_utf16: name,
            owner_sid: &SYSTEM_SID,
            dacl_present: true,
            dacl: Some(&ACES),
            dacl_protected: true,
        }
    }

    #[test]
    fn genuine_metadata_survives_lease_release_and_slot_reuse() {
        let mut name = [0u16; 128];
        let len = write_name(&ID, &mut name).unwrap();
        let old_handle_metadata = genuine(&name[..len]);
        // Attestation receives only the referenced old Section object; the
        // recycled slot and new carrier ID are deliberately absent.
        assert_eq!(attest(&old_handle_metadata, &ID, 2, &ID, 2), Ok(()));
        assert_ne!(ID, OTHER_ID);
    }

    #[test]
    fn wrong_prefix_and_foreign_mapping_with_copied_record_fail() {
        let name: [u16; 7] = [70, 111, 114, 101, 105, 103, 110];
        assert_eq!(
            attest(&genuine(&name), &ID, 2, &ID, 2),
            Err(Refusal::WrongName)
        );
    }

    #[test]
    fn wrong_identity_and_record_identity_fail() {
        let mut name = [0u16; 128];
        let len = write_name(&ID, &mut name).unwrap();
        let metadata = genuine(&name[..len]);
        assert_eq!(
            attest(&metadata, &OTHER_ID, 2, &OTHER_ID, 2),
            Err(Refusal::CarrierIdMismatch)
        );
        assert_eq!(
            attest(&metadata, &ID, 2, &OTHER_ID, 2),
            Err(Refusal::WrongRecord)
        );
        assert_eq!(attest(&metadata, &ID, 1, &ID, 2), Err(Refusal::WrongRecord));
    }

    #[test]
    fn non_system_owner_and_absent_dacl_fail() {
        let mut name = [0u16; 128];
        let len = write_name(&ID, &mut name).unwrap();
        let mut metadata = genuine(&name[..len]);
        metadata.owner_sid = &AUTHENTICATED_USERS_SID;
        assert_eq!(attest(&metadata, &ID, 2, &ID, 2), Err(Refusal::WrongOwner));
        metadata.owner_sid = &SYSTEM_SID;
        metadata.dacl_present = false;
        assert_eq!(attest(&metadata, &ID, 2, &ID, 2), Err(Refusal::WrongDacl));
        metadata.dacl_present = true;
        metadata.dacl = None;
        assert_eq!(attest(&metadata, &ID, 2, &ID, 2), Err(Refusal::WrongDacl));
    }

    #[test]
    fn unexpected_write_or_control_access_and_wrong_type_fail() {
        let mut name = [0u16; 128];
        let len = write_name(&ID, &mut name).unwrap();
        let mut metadata = genuine(&name[..len]);
        let permissive = [
            ACES[0],
            Ace {
                mask: READER_ACCESS | 0x0002_0000,
                ..ACES[1]
            },
        ];
        metadata.dacl = Some(&permissive);
        assert_eq!(attest(&metadata, &ID, 2, &ID, 2), Err(Refusal::WrongDacl));
        metadata = genuine(&name[..len]);
        metadata.kind = ObjectKind::Other;
        assert_eq!(
            attest(&metadata, &ID, 2, &ID, 2),
            Err(Refusal::WrongObjectType)
        );
    }

    #[test]
    fn zero_identity_and_unprotected_dacl_fail() {
        let mut name = [0u16; 128];
        let len = write_name(&ID, &mut name).unwrap();
        let mut metadata = genuine(&name[..len]);
        assert_eq!(
            attest(&metadata, &[0; 16], 2, &[0; 16], 2),
            Err(Refusal::InvalidIdentity)
        );
        metadata.dacl_protected = false;
        assert_eq!(attest(&metadata, &ID, 2, &ID, 2), Err(Refusal::WrongDacl));
    }

    #[test]
    fn missing_authenticated_users_and_missing_system_fail() {
        let mut name = [0u16; 128];
        let len = write_name(&ID, &mut name).unwrap();
        let mut metadata = genuine(&name[..len]);
        let system_only = [ACES[0]];
        metadata.dacl = Some(&system_only);
        assert_eq!(attest(&metadata, &ID, 2, &ID, 2), Err(Refusal::WrongDacl));
        let reader_only = [ACES[1]];
        metadata.dacl = Some(&reader_only);
        assert_eq!(attest(&metadata, &ID, 2, &ID, 2), Err(Refusal::WrongDacl));
    }

    #[test]
    fn reader_map_write_and_extra_broad_grant_fail() {
        let mut name = [0u16; 128];
        let len = write_name(&ID, &mut name).unwrap();
        let mut metadata = genuine(&name[..len]);
        let write = [
            ACES[0],
            Ace {
                mask: READER_ACCESS | 0x2,
                ..ACES[1]
            },
        ];
        metadata.dacl = Some(&write);
        assert_eq!(attest(&metadata, &ID, 2, &ID, 2), Err(Refusal::WrongDacl));
        let broad = [
            ACES[0],
            Ace {
                sid: &[1, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0],
                mask: SECTION_ALL_ACCESS,
                ..ACES[1]
            },
        ];
        metadata.dacl = Some(&broad);
        assert_eq!(attest(&metadata, &ID, 2, &ID, 2), Err(Refusal::WrongDacl));
    }
}

#[cfg(test)]
mod observation_tests {
 use super::*;
 #[test]
 fn observed_mask_refusal_preserves_policy_and_reports_actual_branch(){
  let id=[0x12;16];let name:[u16;NAME_PREFIX.len()+32]={let mut n=[0;NAME_PREFIX.len()+32];let mut i=0;while i<NAME_PREFIX.len(){n[i]=NAME_PREFIX[i]as u16;i+=1;}while i<NAME_PREFIX.len()+32{n[i]=if(i-NAME_PREFIX.len())%2==0{b'1' as u16}else{b'2' as u16};i+=1;}n};
  let aces=[Ace{kind:AceType::Allow,sid:&SYSTEM_SID,mask:SECTION_ALL_ACCESS,flags:0},Ace{kind:AceType::Allow,sid:&AUTHENTICATED_USERS_SID,mask:7,flags:0}];
  let metadata=Metadata{kind:ObjectKind::Section,name_utf16:&name,owner_sid:&SYSTEM_SID,dacl_present:true,dacl_protected:true,dacl:Some(&aces)};
  let expected=attest(&metadata,&id,2,&id,2);assert_eq!(expected,Err(Refusal::WrongDacl));
  let mut observed=None;assert_eq!(attest_observed(&metadata,&id,2,&id,2,|branch|observed=Some(branch)),expected);assert_eq!(observed,Some(35));
  // Exercise the actual observed policy with no-op and recording observers.
  for (m, expected_branch, refusal) in [
   (Metadata{kind:ObjectKind::Other,..metadata},21,Refusal::WrongObjectType),
   (Metadata{name_utf16:&[],..metadata},25,Refusal::WrongName),
   (Metadata{owner_sid:&AUTHENTICATED_USERS_SID,..metadata},26,Refusal::WrongOwner),
   (Metadata{dacl_present:false,..metadata},31,Refusal::WrongDacl),
   (Metadata{dacl:None,..metadata},32,Refusal::WrongDacl),
   (Metadata{dacl_protected:false,..metadata},33,Refusal::WrongDacl),
  ] {
   let mut seen=None;
   assert_eq!(attest_observed(&m,&id,2,&id,2,|b|seen=Some(b)),Err(refusal));
   assert_eq!(seen,Some(expected_branch));assert_eq!(attest(&m,&id,2,&id,2),Err(refusal));
  }
  let good=[aces[0],Ace{mask:5,..aces[1]}];let valid=Metadata{dacl:Some(&good),..metadata};
  let mut seen=None;assert_eq!(attest_observed(&valid,&id,2,&id,2,|b|seen=Some(b)),Ok(()));assert_eq!(seen,Some(0));

 }
}
