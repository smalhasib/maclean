/// The Ed25519 public key (base64 of the 32 raw bytes) that release zips are
/// signed with. In Core so the root helper's `install-update` mode verifies
/// with the same key as the app. The private half lives outside the repo
/// (`~/.config/maclean/update-key`); `scripts/update-key.swift` signs with it.
public enum UpdateKey {
    public static let publicKeyBase64 = "A+Tmxy700chSK0gB7p3o+fa6W4JmMUlvkEiaJl8ZuzA="
}
