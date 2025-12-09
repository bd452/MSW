import Foundation

/// Configuration for establishing a Spice stream connection.
public struct SpiceStreamConfiguration: Hashable {
    public enum Security {
        case plaintext
        case tls
    }

    public enum Transport: Hashable {
        case tcp(host: String, port: UInt16, security: Security, ticket: String?)
        case sharedMemory(descriptor: Int32, ticket: String?)
    }

    public var transport: Transport

    public init(transport: Transport = .tcp(host: "127.0.0.1", port: 5930, security: .plaintext, ticket: nil)) {
        self.transport = transport
    }

    public static func `default`() -> SpiceStreamConfiguration {
        SpiceStreamConfiguration()
    }

    public static func environmentDefault(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SpiceStreamConfiguration {
        if let fdValue = environment["WINRUN_SPICE_SHM_FD"], let fd = Int32(fdValue) {
            let ticket = environment["WINRUN_SPICE_TICKET"]
            return SpiceStreamConfiguration(transport: .sharedMemory(descriptor: fd, ticket: ticket))
        }

        let host = environment["WINRUN_SPICE_HOST"] ?? "127.0.0.1"
        let portValue = environment["WINRUN_SPICE_PORT"] ?? "5930"
        let port = UInt16(portValue) ?? 5930
        let tlsEnabled = environment["WINRUN_SPICE_TLS"] == "1"
        let ticket = environment["WINRUN_SPICE_TICKET"]
        return SpiceStreamConfiguration(
            transport: .tcp(
                host: host,
                port: port,
                security: tlsEnabled ? .tls : .plaintext,
                ticket: ticket
            )
        )
    }
}

extension SpiceStreamConfiguration.Transport {
    var summaryDescription: String {
        switch self {
        case let .tcp(host, port, security, _):
            let scheme = (security == .tls) ? "spice+tls" : "spice"
            return "\(scheme)://\(host):\(port)"
        case let .sharedMemory(descriptor, _):
            return "shm(fd:\(descriptor))"
        }
    }
}
