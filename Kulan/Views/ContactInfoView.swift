import SwiftUI
import FirebaseAuth
import FirebaseFirestore

// Conversation info — the screen you reach by tapping the chat header (Signal /
// iMessage pattern): large avatar, name, encryption, mute, block.
struct ContactInfoView: View {
    let cid: String
    let name: String
    let photoUrl: String?

    @State private var handle = ""
    @State private var muted = false
    @State private var blocked = false
    @State private var loaded = false

    private var otherUid: String {
        let me = AuthService.shared.uid ?? ""
        return cid.split(separator: "_").map(String.init).first { $0 != me } ?? ""
    }

    var body: some View {
        List {
            // Identity header (centered, like Signal's conversation settings top).
            Section {
                VStack(spacing: 10) {
                    AvatarView(name: name, photoUrl: photoUrl, size: 96)
                    Text(name).font(.title2.weight(.bold))
                    if !handle.isEmpty {
                        Text("@\(handle)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Label("End-to-end encrypted", systemImage: "lock.fill")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .listRowBackground(Color.clear)
            }

            Section {
                Toggle(isOn: $muted) {
                    Label("Mute", systemImage: "bell.slash")
                }
                .onChange(of: muted) { _, v in
                    if loaded { Task { await ChatService.setMuted(cid, v) } }
                }
            }

            Section {
                Toggle(isOn: $blocked) {
                    Label("Block \(name)", systemImage: "hand.raised").foregroundStyle(.red)
                }
                .onChange(of: blocked) { _, v in
                    if loaded { Task { await ChatService.setBlocked(cid, v) } }
                }
            }
        }
        .navigationTitle("Info")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        if let p = await ProfileStore.shared.fetch(otherUid) { handle = p.handle }
        if let snap = try? await Firestore.firestore().collection("conversations").document(cid).getDocument(),
           let d = snap.data() {
            let me = AuthService.shared.uid ?? ""
            let muteUntil = ((d["mutedBy"] as? [String: Any])?[me] as? NSNumber)?.doubleValue ?? 0
            muted = muteUntil > Date().timeIntervalSince1970 * 1000
            blocked = (d["blockedBy"] as? [String: Any])?[me] as? Bool ?? false
        }
        loaded = true
    }
}
