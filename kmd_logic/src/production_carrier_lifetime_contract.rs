//! Pure ownership model for the GREEN-A external section contract.
//!
//! This is a specification test, not a KMD handle implementation. In
//! particular, an exported HANDLE is an Object Manager reference to the
//! section, while a publication reference is a separate KMD reference.

#[cfg(test)]
mod tests {
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    struct Identity(u64);

    #[derive(Debug)]
    struct Section {
        identity: Identity,
        external_handles: u32,
        producer_handle: bool,
        producer_lease: bool,
        publication_refs: u32,
        published_value: u64,
    }

    impl Section {
        fn new(identity: Identity) -> Self {
            Self {
                identity,
                external_handles: 0,
                producer_handle: true,
                producer_lease: true,
                publication_refs: 0,
                published_value: 0,
            }
        }

        fn export(&mut self) {
            assert!(self.producer_handle);
            self.external_handles += 1;
        }

        fn close_external(&mut self) {
            assert!(self.external_handles > 0);
            self.external_handles -= 1;
        }

        fn destroy_producer(&mut self) {
            self.producer_handle = false;
            self.producer_lease = false;
        }

        fn late_import(&self) -> Option<Identity> {
            (self.external_handles > 0).then_some(self.identity)
        }

        fn associate_publication(&mut self) {
            assert!(self.producer_lease);
            self.publication_refs += 1;
        }

        fn publish(&mut self, value: u64) {
            assert!(self.publication_refs > 0);
            self.published_value = self.published_value.max(value);
            self.publication_refs -= 1;
        }

        fn reclaimable(&self) -> bool {
            !self.producer_handle && self.external_handles == 0 && self.publication_refs == 0
        }
    }

    #[test]
    fn exported_handle_outlives_producer_and_lease() {
        let mut old = Section::new(Identity(41));
        old.export();
        old.destroy_producer();
        assert!(!old.producer_lease);
        assert_eq!(old.late_import(), Some(Identity(41)));
        assert!(!old.reclaimable());
    }

    #[test]
    fn slot_release_and_reuse_do_not_replace_old_payload_identity() {
        let mut old = Section::new(Identity(41));
        old.export();
        old.destroy_producer();
        // The next section may occupy the same internal KMD slot. No slot or
        // generation participates in external identity or late import.
        let new = Section::new(Identity(42));
        assert_eq!(old.late_import(), Some(Identity(41)));
        assert_ne!(old.identity, new.identity);
    }

    #[test]
    fn independent_exports_keep_payload_until_last_handle_closes() {
        let mut section = Section::new(Identity(43));
        section.export();
        section.export();
        section.destroy_producer();
        section.close_external();
        assert_eq!(section.late_import(), Some(Identity(43)));
        assert!(!section.reclaimable());
        section.close_external();
        assert_eq!(section.late_import(), None);
        assert!(section.reclaimable());
    }

    #[test]
    fn publication_reference_outlives_producer_and_reclaims_after_completion() {
        let mut section = Section::new(Identity(44));
        section.associate_publication();
        section.destroy_producer();
        assert!(!section.reclaimable());
        section.publish(9);
        assert_eq!(section.published_value, 9);
        assert!(section.reclaimable());
    }
}
