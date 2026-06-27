//  Crypto.swift
//  Kulan — native E2EE, wire-compatible with the React Native tweetnacl client.
//
//  This is a faithful Swift port of src/utils/crypto.ts. It uses libsodium
//  (via swift-sodium), whose crypto_box_easy / crypto_secretbox_easy are
//  byte-for-byte compatible with tweetnacl's nacl.box / nacl.secretbox:
//
//    nacl.box(msg, nonce, theirPub, mySecret)  ==  crypto_box_easy(msg, nonce, theirPub, mySecret)
//    nacl.secretbox(msg, nonce, key)           ==  crypto_secretbox_easy(msg, nonce, key)
//
//  Both produce: 24-byte nonce (separate) + (16-byte Poly1305 MAC ‖ ciphertext).
//  tweetnacl-util base64 is STANDARD, PADDED base64 — we use Foundation's
//  Data.base64EncodedString(), which matches exactly (do NOT use Sodium.Utils
//  base64, which defaults to a URL-safe / unpadded variant).
//
//  Wire format (identical to the RN client):
//    text  -> "enc1:<b64 nonce>:<b64 box>"
//    image -> ciphertext bytes in Storage + EncMeta { v:1, n, k, kn }
//
//  Dependencies (SPM):  https://github.com/jedisct1/swift-sodium  (product: "Sodium")
//                       Firebase (FirebaseFirestore, FirebaseAuth)

import Foundation
import Security
import Sodium
import FirebaseFirestore
import FirebaseAuth

/// Thrown when the recipient has not published a public key yet. Callers MUST
/// queue / halt — never fall back to sending plaintext (the "queue, don't leak" rule).
struct MissingRecipientKeyError: Error {
    let uid: String
}

/// Per-attachment envelope stored alongside an encrypted file. Mirrors EncMeta in crypto.ts.
struct EncMeta: Codable, Equatable, Hashable {
    let v: Int       // always 1
    let n: String    // b64 secretbox nonce (the file data)
    let k: String    // b64 file key, wrapped to the recipient with box
    let kn: String   // b64 nonce used to wrap the file key
}

final class Crypto {
    static let shared = Crypto()
    private init() {}

    private let sodium = Sodium()
    private let db = Firestore.firestore()
    private static let skKeychainKey = "kulan_secret_key_v1"
    private static let pkKeychainKey = "kulan_public_key_v1"

    // In-memory key state (set by ensureReady / preloadKey; read by the sync `decrypt`).
    private var myPublicKey: Bytes?
    private var mySecretKey: Bytes?
    private var pubCache: [String: Bytes] = [:]
    private let lock = NSLock()                 // guards pubCache for the sync decrypt path
    private var readyTask: Task<Void, Error>?

    var isReady: Bool { mySecretKey != nil }

    private func currentUid() -> String? { Auth.auth().currentUser?.uid }

    // MARK: - Setup

    /// Generate/load this device's key pair and publish the public key. Idempotent.
    func ensureReady() async throws {
        if let task = readyTask { return try await task.value }
        let task = Task { try await self.initKeys() }
        readyTask = task
        do { try await task.value }
        catch { readyTask = nil; throw error }   // allow retry after failure
    }

    private func initKeys() async throws {
        guard let uid = currentUid() else {
            throw NSError(domain: "Crypto", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "ensureReady() called before sign-in"])
        }

        // Load existing keypair from Keychain, or generate + persist a new one.
        if let skB64 = Keychain.get(Self.skKeychainKey),
           let pkB64 = Keychain.get(Self.pkKeychainKey),
           let sk = Data(base64Encoded: skB64),
           let pk = Data(base64Encoded: pkB64),
           sk.count == sodium.box.SecretKeyBytes {
            mySecretKey = Bytes(sk)
            myPublicKey = Bytes(pk)
        } else {
            guard let kp = sodium.box.keyPair() else {
                throw NSError(domain: "Crypto", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "key generation failed"])
            }
            mySecretKey = kp.secretKey
            myPublicKey = kp.publicKey
            Keychain.set(Self.skKeychainKey, Data(kp.secretKey).base64EncodedString())
            Keychain.set(Self.pkKeychainKey, Data(kp.publicKey).base64EncodedString())
        }

        lock.withLock { pubCache[uid] = myPublicKey }

        // Publish my public key so others can encrypt to me.
        let myPubB64 = Data(myPublicKey!).base64EncodedString()
        do {
            let snap = try await db.collection("users").document(uid).getDocument()
            if (snap.data()?["publicKey"] as? String) != myPubB64 {
                try await db.collection("users").document(uid)
                    .setData(["publicKey": myPubB64], merge: true)
            }
        } catch {
            print("crypto: publishing public key failed:", error)
        }
    }

    /// Re-publish my public key (idempotent, self-healing). Safe to call on every
    /// launch AFTER the profile doc exists — recovers accounts whose key publish
    /// failed earlier (e.g. the write lost a race with profile creation), which
    /// otherwise leaves them permanently unmessageable.
    func publishPublicKey() async {
        do { try await ensureReady() } catch { return }
        guard let uid = currentUid(), let pk = myPublicKey else { return }
        let b64 = Data(pk).base64EncodedString()
        do {
            let snap = try await db.collection("users").document(uid).getDocument()
            if (snap.data()?["publicKey"] as? String) != b64 {
                try await db.collection("users").document(uid)
                    .setData(["publicKey": b64], merge: true)
            }
        } catch {
            print("crypto: publishPublicKey failed:", error)
        }
    }

    /// Fetch + cache another user's public key. Returns nil if they have none yet.
    @discardableResult
    func preloadKey(_ uid: String) async -> Bytes? {
        guard !uid.isEmpty else { return nil }
        if let cached = lock.withLock({ pubCache[uid] }) { return cached }
        do {
            let snap = try await db.collection("users").document(uid).getDocument()
            if let b64 = snap.data()?["publicKey"] as? String,
               let data = Data(base64Encoded: b64) {
                let key = Bytes(data)
                lock.withLock { pubCache[uid] = key }
                return key
            }
        } catch {
            print("crypto: preloadKey failed:", error)
        }
        return nil
    }

    // MARK: - cid helpers (cid = "uidA_uidB")

    private func otherUid(_ cid: String) -> String {
        let me = currentUid() ?? ""
        let parts = cid.split(separator: "_").map(String.init)
        guard parts.count == 2 else { return "" }
        return parts[0] == me ? parts[1] : parts[0]
    }

    // MARK: - Text

    /// Encrypt plaintext for a conversation. Returns "enc1:<nonce>:<cipher>".
    /// NEVER returns plaintext; throws MissingRecipientKeyError if the recipient has no key.
    func encryptForConversation(_ cid: String, _ text: String) async throws -> String {
        try await ensureReady()
        guard let sk = mySecretKey else {
            throw NSError(domain: "Crypto", code: 3, userInfo: [NSLocalizedDescriptionKey: "keys not ready"])
        }
        let other = otherUid(cid)
        guard let otherPub = await preloadKey(other) else { throw MissingRecipientKeyError(uid: other) }

        // box.seal(...) -> (authenticatedCipherText = MAC‖ct, nonce) ; matches nacl.box output.
        guard let sealed: (authenticatedCipherText: Bytes, nonce: Box.Nonce) =
                sodium.box.seal(message: Bytes(text.utf8), recipientPublicKey: otherPub, senderSecretKey: sk) else {
            throw NSError(domain: "Crypto", code: 4, userInfo: [NSLocalizedDescriptionKey: "seal failed"])
        }
        let nonceB64 = Data(sealed.nonce).base64EncodedString()
        let boxB64 = Data(sealed.authenticatedCipherText).base64EncodedString()
        return "enc1:\(nonceB64):\(boxB64)"
    }

    /// True once my keys and the recipient's public key are both available.
    func recipientReady(_ cid: String) async -> Bool {
        do {
            try await ensureReady()
            return await preloadKey(otherUid(cid)) != nil
        } catch { return false }
    }

    /// Decrypt a stored value SYNCHRONOUSLY (keys must already be cached via
    /// ensureReady + preloadKey). Mirrors crypto.ts `decrypt`:
    ///   - not "enc1:"           -> returned as-is (plaintext / preview)
    ///   - "enc:" (legacy fake)  -> "[old message]"
    ///   - keys not ready        -> "…"
    ///   - tampered / wrong key  -> "🔒"
    func decrypt(_ raw: String, cid: String) -> String {
        if raw.hasPrefix("enc:") { return "[old message]" }
        guard raw.hasPrefix("enc1:") else { return raw }
        guard let sk = mySecretKey else { return "…" }
        guard let otherPub = lock.withLock({ pubCache[otherUid(cid)] }) else { return "…" }

        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let nonce = Data(base64Encoded: parts[1]),
              let box = Data(base64Encoded: parts[2]) else { return "🔒" }

        guard let opened = sodium.box.open(authenticatedCipherText: Bytes(box),
                                           senderPublicKey: otherPub,
                                           recipientSecretKey: sk,
                                           nonce: Bytes(nonce)),
              let text = String(bytes: opened, encoding: .utf8) else { return "🔒" }
        return text
    }

    // Memoized decrypt for hot, repeatedly-rendered text — the chat-list last-message
    // preview decrypts on EVERY row render/scroll. The same (cid, raw) always yields the
    // same plaintext, so caching it avoids re-running libsodium box.open per frame (a
    // real scroll-smoothness win, Signal-style "decrypt once, reuse"). NSCache is
    // thread-safe and self-evicting under memory pressure.
    private let previewCache = NSCache<NSString, NSString>()
    func decryptCached(_ raw: String, cid: String) -> String {
        let key = "\(cid)|\(raw)" as NSString
        if let hit = previewCache.object(forKey: key) { return hit as String }
        let out = decrypt(raw, cid: cid)
        previewCache.setObject(out as NSString, forKey: key)
        return out
    }

    // MARK: - Files / images

    /// Encrypt raw file bytes. The file is sealed with a fresh secretbox key; that
    /// key is wrapped to the recipient with box. Mirrors crypto.ts `encryptBytes`.
    func encryptBytes(_ cid: String, _ data: Data) async throws -> (cipher: Data, meta: EncMeta) {
        try await ensureReady()
        guard let sk = mySecretKey else {
            throw NSError(domain: "Crypto", code: 5, userInfo: [NSLocalizedDescriptionKey: "keys not ready"])
        }
        let other = otherUid(cid)
        guard let otherPub = await preloadKey(other) else { throw MissingRecipientKeyError(uid: other) }

        let fileKey = sodium.secretBox.key()                       // random 32-byte key
        guard let sealedFile: (authenticatedCipherText: Bytes, nonce: SecretBox.Nonce) =
                sodium.secretBox.seal(message: Bytes(data), secretKey: fileKey) else {
            throw NSError(domain: "Crypto", code: 6, userInfo: [NSLocalizedDescriptionKey: "secretbox seal failed"])
        }
        guard let wrapped: (authenticatedCipherText: Bytes, nonce: Box.Nonce) =
                sodium.box.seal(message: fileKey, recipientPublicKey: otherPub, senderSecretKey: sk) else {
            throw NSError(domain: "Crypto", code: 7, userInfo: [NSLocalizedDescriptionKey: "key wrap failed"])
        }

        let meta = EncMeta(
            v: 1,
            n: Data(sealedFile.nonce).base64EncodedString(),
            k: Data(wrapped.authenticatedCipherText).base64EncodedString(),
            kn: Data(wrapped.nonce).base64EncodedString()
        )
        return (Data(sealedFile.authenticatedCipherText), meta)
    }

    /// Reverse of encryptBytes. Returns nil if keys are missing or auth fails.
    func decryptBytes(_ cid: String, cipher: Data, meta: EncMeta) async -> Data? {
        do {
            try await ensureReady()
            _ = await preloadKey(otherUid(cid))
        } catch { /* checks below return nil if not ready */ }

        guard let sk = mySecretKey, meta.v == 1 else { return nil }
        guard let otherPub = lock.withLock({ pubCache[otherUid(cid)] }) else { return nil }
        guard let wrappedKey = Data(base64Encoded: meta.k),
              let keyNonce = Data(base64Encoded: meta.kn),
              let dataNonce = Data(base64Encoded: meta.n) else { return nil }

        guard let fileKey = sodium.box.open(authenticatedCipherText: Bytes(wrappedKey),
                                            senderPublicKey: otherPub,
                                            recipientSecretKey: sk,
                                            nonce: Bytes(keyNonce)) else { return nil }
        guard let opened = sodium.secretBox.open(authenticatedCipherText: Bytes(cipher),
                                                 secretKey: fileKey,
                                                 nonce: Bytes(dataNonce)) else { return nil }
        return Data(opened)
    }

    // MARK: - Group text (sender-key-per-message)
    //
    // Generalizes the file-wrap pattern to N members: the body is sealed ONCE under a
    // random message key, and that key is wrapped to EVERY member's public key (including
    // the author, so the author can read their own message back on reload / another device).
    // Each member opens their own wrap with the AUTHOR's public key — NaCl box's DH secret
    // is symmetric, so author↔member both derive the same key. Wire format:
    //   "encg1:" + base64( JSON{ n: dataNonce, c: ciphertext, w: { uid: "wrapB64.nonceB64" } } )

    /// Encrypt text for a group. `members` should be the full member list (self included).
    /// Throws MissingRecipientKeyError if any member has no published key (never leaks plaintext).
    func encryptForGroup(_ text: String, members: [String]) async throws -> String {
        try await ensureReady()
        guard let sk = mySecretKey else {
            throw NSError(domain: "Crypto", code: 8, userInfo: [NSLocalizedDescriptionKey: "keys not ready"])
        }
        let msgKey = sodium.secretBox.key()
        guard let sealed: (authenticatedCipherText: Bytes, nonce: SecretBox.Nonce) =
                sodium.secretBox.seal(message: Bytes(text.utf8), secretKey: msgKey) else {
            throw NSError(domain: "Crypto", code: 9, userInfo: [NSLocalizedDescriptionKey: "group seal failed"])
        }
        var wraps: [String: String] = [:]
        for uid in Set(members) {
            guard let pub = await preloadKey(uid) else { throw MissingRecipientKeyError(uid: uid) }
            guard let w: (authenticatedCipherText: Bytes, nonce: Box.Nonce) =
                    sodium.box.seal(message: msgKey, recipientPublicKey: pub, senderSecretKey: sk) else {
                throw NSError(domain: "Crypto", code: 10, userInfo: [NSLocalizedDescriptionKey: "group wrap failed"])
            }
            wraps[uid] = Data(w.authenticatedCipherText).base64EncodedString()
                       + "." + Data(w.nonce).base64EncodedString()
        }
        let payload: [String: Any] = [
            "n": Data(sealed.nonce).base64EncodedString(),
            "c": Data(sealed.authenticatedCipherText).base64EncodedString(),
            "w": wraps,
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)
        return "encg1:" + json.base64EncodedString()
    }

    /// Decrypt a group message. Needs the AUTHOR's uid (sender pubkey) — opens my own wrap.
    func decryptGroup(_ raw: String, authorId: String) -> String {
        guard raw.hasPrefix("encg1:") else { return raw }
        guard let sk = mySecretKey, let me = currentUid() else { return "…" }
        guard let authorPub = lock.withLock({ pubCache[authorId] }) else { return "…" }
        let b64 = String(raw.dropFirst("encg1:".count))
        guard let jsonData = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let nB64 = obj["n"] as? String, let cB64 = obj["c"] as? String,
              let wraps = obj["w"] as? [String: String],
              let myWrap = wraps[me],
              let dataNonce = Data(base64Encoded: nB64),
              let ct = Data(base64Encoded: cB64) else { return "🔒" }
        let wp = myWrap.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard wp.count == 2,
              let wrappedKey = Data(base64Encoded: wp[0]),
              let keyNonce = Data(base64Encoded: wp[1]) else { return "🔒" }
        guard let msgKey = sodium.box.open(authenticatedCipherText: Bytes(wrappedKey),
                                           senderPublicKey: authorPub, recipientSecretKey: sk,
                                           nonce: Bytes(keyNonce)) else { return "🔒" }
        guard let opened = sodium.secretBox.open(authenticatedCipherText: Bytes(ct),
                                                 secretKey: msgKey, nonce: Bytes(dataNonce)),
              let text = String(bytes: opened, encoding: .utf8) else { return "🔒" }
        return text
    }

    /// Routing decrypt: group envelopes need the author's key; 1:1 uses the cid pair.
    func decrypt(_ raw: String, cid: String, authorId: String) -> String {
        if raw.hasPrefix("encg1:") { return decryptGroup(raw, authorId: authorId) }
        return decrypt(raw, cid: cid)
    }
}

// MARK: - Minimal Keychain (replaces expo-secure-store)

enum Keychain {
    private static let service = "com.kulan.messenger.crypto"

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String) {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        // Available after first unlock; survives reboot, stays on this device only.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
