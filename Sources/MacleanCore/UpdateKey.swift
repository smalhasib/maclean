/// The Ed25519 public key (base64 of the 32 raw bytes) that release zips are
/// signed with. In Core so the root helper's `install-update` mode verifies
/// with the same key as the app.
///
/// Placeholder until the release key is generated: 32 zero bytes, which
/// `UpdateSignature` refuses (an all-zero key is a small-order point that
/// would accept forged signatures), so nothing installs until it is set.
public enum UpdateKey {
    public static let publicKeyBase64 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
}
