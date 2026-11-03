import Foundation
#if !TASK08_HOST_CHECK
import Testing
@testable import LiveSubtitle
#endif

private func endpointProfile(
    url: String,
    model: String = "synthetic-model"
) -> CloudProfile {
    CloudProfile(
        id: UUID(),
        name: "Synthetic",
        endpoint: URL(string: url)!,
        model: model,
        revision: 1
    )
}

private func checkEndpointRejectsUnsafeConfiguration() throws {
    let unsafe = [
        "http://provider.example/v1/chat/completions",
        "ftp://provider.example/v1/chat/completions",
        "https://user:password@provider.example/v1/chat/completions",
        "https://provider.example/v1/chat/completions?api_key=not-a-real-key",
        "https://provider.example/v1/chat/completions?access-token=not-a-real-key",
        "https://provider.example/v1/chat/completions?signature=not-a-real-key",
        "https:///v1/chat/completions"
    ]
    for url in unsafe {
        guard EndpointValidator.validationFailure(for: endpointProfile(url: url)) == .invalidConfiguration else {
            throw EndpointTestFailure(message: "unsafe endpoint accepted: \(url)")
        }
    }
    guard EndpointValidator.validationFailure(for: endpointProfile(
        url: "https://provider.example/v1/chat/completions",
        model: " "
    )) == .invalidConfiguration else {
        throw EndpointTestFailure(message: "empty model accepted")
    }
}

private func checkEndpointAcceptsCompleteHTTPSURL() throws {
    let profile = endpointProfile(
        url: "https://provider.example/custom/chat/path?api-version=1"
    )
    guard EndpointValidator.validationFailure(for: profile) == nil else {
        throw EndpointTestFailure(message: "complete HTTPS endpoint rejected")
    }
    guard profile.endpoint.absoluteString == "https://provider.example/custom/chat/path?api-version=1" else {
        throw EndpointTestFailure(message: "test fixture did not preserve the full endpoint")
    }
}

private struct EndpointTestFailure: Error {
    let message: String
}

#if TASK08_HOST_CHECK
@main
private struct EndpointValidatorHostChecks {
    static func main() throws {
        try checkEndpointRejectsUnsafeConfiguration()
        try checkEndpointAcceptsCompleteHTTPSURL()
        print("2 endpoint host checks passed")
    }
}
#else
struct EndpointValidatorTests {
    @Test func testEndpointRejectsUnsafeConfiguration() throws {
        try checkEndpointRejectsUnsafeConfiguration()
    }

    @Test func testEndpointAcceptsCompleteHTTPSURL() throws {
        try checkEndpointAcceptsCompleteHTTPSURL()
    }
}
#endif
