use mpx_lottie::mpx_lottie_abi_version;

#[test]
fn abi_version_is_one() {
    assert_eq!(mpx_lottie_abi_version(), 1);
}
