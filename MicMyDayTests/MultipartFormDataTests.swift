import Foundation
import XCTest
@testable import MicMyDay

final class MultipartFormDataTests: XCTestCase {
    func testEncodesFieldsAndFile() throws {
        var form = MultipartFormData(boundary: "test-boundary")
        form.addField(name: "model", value: "whisper-1")
        form.addFile(
            name: "file",
            filename: "recording.wav",
            mimeType: "audio/wav",
            contents: Data([0x00, 0x01, 0x02])
        )
        form.finalize()

        let body = try XCTUnwrap(String(data: form.data, encoding: .isoLatin1))
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nwhisper-1"))
        XCTAssertTrue(body.contains("filename=\"recording.wav\""))
        XCTAssertTrue(body.contains("Content-Type: audio/wav"))
        XCTAssertTrue(body.hasSuffix("--test-boundary--\r\n"))
    }
}

