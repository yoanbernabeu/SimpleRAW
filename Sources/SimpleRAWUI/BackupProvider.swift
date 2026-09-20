import Foundation

/// The storage services the settings window knows by name, so that nobody has to look up
/// what an endpoint is. A new service is a new case here.
public enum BackupProvider: String, CaseIterable, Identifiable, Sendable {
    case amazonS3, scaleway, backblazeB2, cloudflareR2, ovhcloud, wasabi
    /// A server of one's own (MinIO, a NAS) or a service that is not listed: the address is typed.
    case other

    public var id: Self { self }

    public var name: String {
        switch self {
        case .amazonS3: "Amazon S3"
        case .scaleway: "Scaleway"
        case .backblazeB2: "Backblaze B2"
        case .cloudflareR2: "Cloudflare R2"
        case .ovhcloud: "OVHcloud"
        case .wasabi: "Wasabi"
        case .other: "MinIO / Other"
        }
    }

    /// The host of the service, with the place of the region or of the account left open.
    private var hostTemplate: (prefix: String, suffix: String)? {
        switch self {
        case .amazonS3: ("s3.", ".amazonaws.com")
        case .scaleway: ("s3.", ".scw.cloud")
        case .backblazeB2: ("s3.", ".backblazeb2.com")
        case .cloudflareR2: ("", ".r2.cloudflarestorage.com")
        case .ovhcloud: ("s3.", ".io.cloud.ovh.net")
        case .wasabi: ("s3.", ".wasabisys.com")
        case .other: nil
        }
    }

    /// Cloudflare names the account in the address, and has no regions.
    public var needsAccount: Bool { self == .cloudflareR2 }

    /// The regions proposed. Empty when the region is typed.
    public var regions: [String] {
        switch self {
        case .amazonS3:
            ["us-east-1", "us-east-2", "us-west-1", "us-west-2", "ca-central-1", "sa-east-1",
             "eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1", "eu-north-1", "eu-south-1",
             "ap-south-1", "ap-southeast-1", "ap-southeast-2", "ap-northeast-1", "ap-northeast-2"]
        case .scaleway: ["fr-par", "nl-ams", "pl-waw"]
        case .backblazeB2: ["us-west-000", "us-west-001", "us-west-002", "us-west-004", "us-east-005", "eu-central-003"]
        case .cloudflareR2: ["auto"]
        case .ovhcloud: ["gra", "rbx", "sbg", "eu-west-par", "de", "uk", "waw", "bhs"]
        case .wasabi:
            ["us-east-1", "us-east-2", "us-central-1", "us-west-1", "ca-central-1",
             "eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1", "eu-central-2", "eu-south-1",
             "ap-northeast-1", "ap-northeast-2", "ap-southeast-1", "ap-southeast-2"]
        case .other: []
        }
    }

    public var defaultRegion: String { regions.first ?? "us-east-1" }

    /// The proposed regions, plus the one in use when the table does not know it.
    public func regions(including current: String) -> [String] {
        regions.contains(current) || current.isEmpty ? regions : [current] + regions
    }

    /// The address of the service, as text for `S3Endpoint.validate`; `nil` when it has to be
    /// typed, or when what would go in the host name is not a plain name.
    public func endpoint(region: String, account: String) -> String? {
        guard let hostTemplate else { return nil }
        let name = needsAccount ? account : region
        guard Self.isPlainName(name) else { return nil }
        return "https://\(hostTemplate.prefix)\(name)\(hostTemplate.suffix)"
    }

    /// Which service an address belongs to, and the account it names if it names one.
    public static func matching(endpoint: URL) -> (provider: BackupProvider, account: String) {
        guard endpoint.scheme == "https", endpoint.port == nil, let host = endpoint.host?.lowercased() else { return (.other, "") }
        for provider in allCases {
            guard let template = provider.hostTemplate, host.hasPrefix(template.prefix), host.hasSuffix(template.suffix),
                  host.count > template.prefix.count + template.suffix.count else { continue }
            let name = String(host.dropFirst(template.prefix.count).dropLast(template.suffix.count))
            guard isPlainName(name) else { continue }
            return (provider, provider.needsAccount ? name : "")
        }
        return (.other, "")
    }

    /// Letters, digits and dashes: all a region or an account is made of, and nothing that
    /// could turn the host name into another one.
    private static func isPlainName(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
}
