import SwiftUI

// Add a contact by their @username — Kulan is handle-based (no phone numbers), so this is
// the honest equivalent of Telegram's "New Contact": find the user and open a chat with them
// (which saves them to your chat list). Clean sheet, real Liquid Glass.
struct NewContactView: View {
    var onOpen: (ChatTarget) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var handle = ""
    @State private var working = false
    @State private var notFound = false
    @FocusState private var focused: Bool
    private var me: String { AuthService.shared.uid ?? "" }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                                .frame(width: 40, height: 40).liquidGlass(Circle(), interactive: true)
                        }
                        Spacer()
                        Text("New Contact").font(.headline)
                        Spacer()
                        Button { Task { await add() } } label: {
                            Image(systemName: working ? "ellipsis" : "checkmark")
                                .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(handle.isEmpty ? AnyShapeStyle(Color.gray.opacity(0.4))
                                                           : AnyShapeStyle(Color.blue), in: Circle())
                        }
                        .disabled(handle.isEmpty || working)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 1) {
                            Text("@").foregroundStyle(.secondary)
                            TextField("username", text: $handle)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused)
                                .onChange(of: handle) { _, v in
                                    let c = ChatService.sanitizeHandle(v); if c != v { handle = c }
                                }
                                .onSubmit { Task { await add() } }
                        }
                        .padding(.horizontal, 18).frame(height: 52)
                        .liquidGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        Text("Enter their @username to add them. Kulan uses usernames, not phone numbers.")
                            .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                    }
                    .padding(16)
                    Spacer()
                }
            }
            .alert("Sorry, this user doesn't seem to exist.", isPresented: $notFound) {
                Button("OK", role: .cancel) {}
            }
            .onAppear { focused = true }
        }
    }

    private func add() async {
        let h = ChatService.sanitizeHandle(handle)
        guard !h.isEmpty else { return }
        working = true
        if let u = await ChatService.findByHandle(h), u.id != me {
            let cid = ChatService.convId(me, u.id)
            try? await ChatService.openConversation(other: u)
            working = false
            onOpen(ChatTarget(id: cid, name: u.name.isEmpty ? u.handle : u.name, photo: u.photoUrl))
        } else {
            working = false
            notFound = true
        }
    }
}
