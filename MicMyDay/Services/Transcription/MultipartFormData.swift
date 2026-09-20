import Foundation

struct MultipartFormData {
    let boundary: String
    private(set) var data = Data()

    init(boundary: String = "MicMyDay-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    mutating func addField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(escaped(name))\"\r\n\r\n")
        append(value)
        append("\r\n")
    }

    mutating func addFile(name: String, filename: String, mimeType: String, contents: Data) {
        append("--\(boundary)\r\n")
        append(
            "Content-Disposition: form-data; name=\"\(escaped(name))\"; filename=\"\(escaped(filename))\"\r\n"
        )
        append("Content-Type: \(mimeType)\r\n\r\n")
        data.append(contents)
        append("\r\n")
    }

    mutating func finalize() {
        append("--\(boundary)--\r\n")
    }

    private mutating func append(_ string: String) {
        data.append(Data(string.utf8))
    }

    private func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}

