import SwiftUI
import FirebaseAuth
import FirebaseFirestore

// Conversation info — reached by tapping the chat header. Our take on the
// WhatsApp/Telegram/Signal contact screen: identity, shared media, mute, block,
// clear chat. (Calls/search/disappearing-msgs omitted until those features exist.)
struct ContactInfoView: View {
    let cid: String
    let name: String
    let photoUrl: String?

    @State private var handle = ""
    @State private var muted = false
    @State private var blocked = false
    @State private var loaded = false
    @State private var media: [Message] = []
    @State private var viewerImage: Message?
    @State private var showClear = false
    @State private var showBlock = false

    private var otherUid: String {
        let me = AuthService.shared.uid ?? ""
        return cid.split(separator: "_").map(String.init).first { $0 != me } ?? ""
    }

    var body: some View {
        List {
            // Identity header (centered).
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

            // Shared media strip (real — the encrypted images shared in this chat).
            if !media.isEmpty {
                Section("Shared Media") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(media) { m in
                                if let url = m.imageUrl {
                                    SecureImageView(imageUrl: url, enc: m.enc, cid: cid)
                                        .frame(width: 80, height: 80)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .onTapGesture { viewerImage = m }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
            }

            Section {
                Toggle(isOn: $muted) { Label("Mute", systemImage: "bell.slash") }
                    .onChange(of: muted) { _, v in if loaded { Task { await ChatService.setMuted(cid, v) } } }
            }

            Section {
                if blocked {
                    Button { Task { await ChatService.setBlocked(cid, false); blocked = false } } label: {
                        Label("Unblock \(name)", systemImage: "hand.raised.slash")
                    }
                } else {
                    Button(role: .destructive) { showBlock = true } label: {
                        Label("Block \(name)", systemImage: "hand.raised")
                    }
                }
                Button(role: .destructive) { showClear = true } label: {
                    Label("Clear my messages", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Info")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .fullScreenCover(item: $viewerImage) { msg in ImageViewerView(message: msg, cid: cid) }
        .alert("Clear your messages?", isPresented: $showClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                Task { await ChatService.clearMyMessages(cid); media = await ChatService.sharedMedia(cid) }
            }
        } message: {
            Text("This deletes the messages you sent in this chat. It can't be undone.")
        }
        .alert("Block \(name)?", isPresented: $showBlock) {
            Button("Cancel", role: .cancel) {}
            Button("Block", role: .destructive) {
                Task { await ChatService.setBlocked(cid, true); blocked = true }
            }
        } message: {
            Text("You won't be able to send messages in this chat until you unblock. \(name) won't be told they were blocked.")
        }
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
        media = await ChatService.sharedMedia(cid)
        loaded = true
    }
}
