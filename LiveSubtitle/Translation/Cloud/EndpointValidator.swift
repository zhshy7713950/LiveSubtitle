import Foundation

enum EndpointValidator {
    private static let sensitiveQueryNames: Set<String> = [
        "key", "apikey", "accesskey", "secret", "token", "accesstoken",
        "authtoken", "authorization", "credential", "credentials",
        "signature", "sig", "password", "passwd", "subscriptionkey"
    ]

    static func validationFailure(for profile: CloudProfile) -> FailureCode? {
        guard profile.endpoint.scheme?.lowercased() == "https",
              let host = profile.endpoint.host, !host.isEmpty,
              !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              profile.endpoint.fragment == nil,
              let components = URLComponents(url: profile.endpoint, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil else {
            return .invalidConfiguration
        }
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased().filter { $0.isLetter || $0.isNumber }
            if sensitiveQueryNames.contains(name) {
                return .invalidConfiguration
            }
        }
        return nil
    }
}
