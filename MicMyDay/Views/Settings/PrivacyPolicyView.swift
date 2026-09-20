import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    private var policy: String {
        guard let url = Bundle.main.url(forResource: "Privacy", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Privacy information could not be loaded. Please contact the developer before using a network provider."
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Privacy & licenses").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                Text(policy)
                    .font(.system(size: 13))
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                Button("License") { openResource("LICENSE", extension: "txt") }
                Button("Third-party notices") { openResource("ThirdPartyNotices", extension: "txt") }
            }
        }
        .padding(24)
        .frame(width: 660, height: 580)
    }

    private func openResource(_ name: String, extension ext: String?) {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            NSWorkspace.shared.open(url)
        }
    }
}
