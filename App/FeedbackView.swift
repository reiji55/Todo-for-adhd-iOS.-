import SwiftUI
import UIKit

/// 設定 › ご意見・不具合の報告: what went wrong or what is wanted, sent to the developer with the app version and
/// the kind of device. Nothing else from Horme goes with it.
@MainActor
struct FeedbackView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case bug, request, other
        var id: String { rawValue }
        var label: String { ["不具合", "要望", "その他"][Self.allCases.firstIndex(of: self)!] }
        var prompt: String {
            switch self {
            case .bug: return "どの画面で、何をしたら、どうなったか"
            case .request: return "あったらいいなと思うこと"
            case .other: return "ご自由にどうぞ"
            }
        }
    }

    static let endpoint = URL(string: "https://vdufjfnhgkocccueqaws.supabase.co/functions/v1/horme-feedback")!

    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind = .bug
    @State private var text = Drafts.text("feedback")
    @State private var contact = ""
    @State private var sending = false
    @State private var sent = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                Picker("種類", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                TextField(kind.prompt, text: $text, axis: .vertical)
                    .lineLimit(6...16).focused($focused)
                    .onChange(of: text) { _, value in Drafts.save("feedback", value) }
                    .accessibilityIdentifier("feedbackText")
            } footer: {
                Text("\(Self.deviceLine) の情報が一緒に送られます。タスクなどの中身は送られません。")
            }
            Section {
                TextField("メールアドレスなど（任意）", text: $contact)
                    .textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
            } header: { Text("返信先") } footer: { Text("返事がほしいときだけ書いてください。") }
            Section {
                Button {
                    Task { await send() }
                } label: {
                    HStack {
                        Spacer()
                        if sending { ProgressView() } else { Text("送る").font(.body.weight(.bold)) }
                        Spacer()
                    }
                }
                .disabled(trimmed.isEmpty || sending)
                .accessibilityIdentifier("sendFeedback")
            }
        }
        .navigationTitle("ご意見・不具合の報告")
        .navigationBarTitleDisplayMode(.inline)
        .alert("送りました", isPresented: $sent) {
            Button("閉じる") { dismiss() }
        } message: { Text("ありがとうございます。いただいた内容は、今後の改善に使わせていただきます。") }
        .alert("送れませんでした", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("閉じる", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: String] = [
            "kind": kind.rawValue, "body": trimmed,
            "contact": contact.trimmingCharacters(in: .whitespacesAndNewlines),
            "app": Self.appVersion, "os": "iOS \(UIDevice.current.systemVersion)", "device": Self.deviceModel,
            "sender": Self.sender,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                Drafts.clear("feedback")
                text = ""
                sent = true
            case 429: failure = "続けて送られたため、少し時間をおいてからもう一度送ってください。"
            default: failure = "時間をおいて、もう一度送ってください。（\(status)）"
            }
        } catch {
            failure = "インターネットにつながっているか確かめて、もう一度送ってください。書いた内容は残っています。"
        }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
            + (Edition.full ? " full" : "")
    }

    /// "iPhone16,2": the model, without anything that identifies the person.
    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? UIDevice.current.model : machine
    }

    static var deviceLine: String { "アプリの版（\(appVersion)）・iOS \(UIDevice.current.systemVersion)・機種" }

    /// A random id for this install, only to hold back a flood of reports from one place.
    static var sender: String {
        let key = "horme.feedbackSender"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}
