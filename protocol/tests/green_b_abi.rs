use helios_protocol::green_b::{
    E1Control, E1Submit, E1Target, CONTROL, CONTROL_QUERY, CONTROL_REGISTER, CONTROL_UNREGISTER,
    MAX_TARGETS, SUBMIT,
};

#[test]
fn wire_layout_is_identical_on_both_windows_abis() {
    assert_eq!(core::mem::size_of::<E1Control>(), 152);
    assert_eq!(core::mem::align_of::<E1Control>(), 8);
    assert_eq!(core::mem::size_of::<E1Submit>(), 112);
    assert_eq!(core::mem::align_of::<E1Submit>(), 8);
    assert_eq!(core::mem::size_of::<E1Target>(), 32);
    assert_eq!(core::mem::align_of::<E1Target>(), 8);
    assert_eq!(CONTROL, 0x1b);
    assert_eq!(SUBMIT, 0x1c);
    assert_eq!(MAX_TARGETS, 16);
    assert_eq!(core::mem::offset_of!(E1Control, request_id), 24);
    assert_eq!(core::mem::offset_of!(E1Control, carrier_handle), 40);
    assert_eq!(core::mem::offset_of!(E1Control, response_version), 96);
    assert_eq!(core::mem::offset_of!(E1Control, response_id), 112);
    assert_eq!(core::mem::offset_of!(E1Submit, request_id), 24);
    assert_eq!(core::mem::offset_of!(E1Submit, fence_id), 40);
    assert_eq!(core::mem::offset_of!(E1Submit, response_id), 96);
}

#[test]
fn control_query_register_unregister_have_separate_framing() {
    let id = [0x45; 16];
    let q = E1Control::query(id);
    assert!(q.valid_request(152));
    assert!(!q.valid_request(151));
    assert!(q.complete(1, 0, 0, 3, 256).unwrap().valid_response(&q, 152));

    let register = E1Control::register(id, 0x40, 0x80, 17, [0x51; 16]);
    assert_eq!(register.operation, CONTROL_REGISTER);
    assert!(register.valid_request(152));
    let response = register.complete(1, 0, 0x93, 3, 256).unwrap();
    assert!(response.valid_response(&register, 152));
    assert!(!response.valid_response(&q, 152));

    let unregister = E1Control::unregister(id, 0x93);
    assert_eq!(unregister.operation, CONTROL_UNREGISTER);
    assert!(unregister.valid_request(152));
    assert_eq!(q.operation, CONTROL_QUERY);
    assert!(!E1Control {
        response_token: 1,
        ..q
    }
    .valid_request(152));
    assert!(!E1Control {
        schema_version: 2,
        ..q
    }
    .valid_request(152));
    assert!(!E1Control { reserved: 1, ..q }.valid_request(152));
}

#[test]
fn submit_requires_exact_targets_stream_and_returned_identity() {
    let id = [0x53; 16];
    let target = E1Target {
        carrier_handle: 0x40,
        target_value: 17,
        carrier_id: [0x61; 16],
    };
    let req = E1Submit::request(id, 7, 1, 24, 1);
    assert!(req.valid_request(112 + 32 + 24, &[target]));
    assert!(!req.valid_request(112 + 32 + 23, &[target]));
    assert!(!req.valid_request(112 + 32 + 24, &[]));
    assert!(!E1Submit {
        stream_size: 0,
        ..req
    }
    .valid_request(112 + 32, &[target]));
    assert!(!E1Submit {
        schema_version: 2,
        ..req
    }
    .valid_request(112 + 32 + 24, &[target]));
    assert!(req.complete(123, 112 + 32 + 24, &[]).is_none());
    let response = req.complete(123, 112 + 32 + 24, &[target]).unwrap();
    assert!(response.valid_response(&req, 112));
    assert!(!E1Submit {
        response_id: [0; 16],
        ..response
    }
    .valid_response(&req, 112));
    assert!(!E1Submit {
        fence_id: 0,
        ..response
    }
    .valid_response(&req, 112));
    let invalid_request = E1Submit {
        stream_size: 0,
        ..req
    };
    let forged = E1Submit {
        stream_size: 0,
        ..response
    };
    assert!(!forged.valid_response(&invalid_request, 112));
    assert!(invalid_request.complete(123, 112 + 32, &[target]).is_none());
}

#[test]
fn e1_requires_gpu_completion_ring_not_cpu_decode() {
 let target = helios_protocol::green_b::E1Target {carrier_handle:5,target_value:1,carrier_id:[1;16]};
 for ring in [0,256,u32::MAX] { let req=helios_protocol::green_b::E1Submit::request([1;16],1,ring,8,1); assert!(!req.valid_request(152,&[target]),"ring {ring} cannot prove GPU completion"); }
 let req=helios_protocol::green_b::E1Submit::request([1;16],1,1,8,1);assert!(req.valid_request(152,&[target]));
}
