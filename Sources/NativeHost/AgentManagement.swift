import PersonalCore

/// Local owner administration. Deliberately absent from the MCP tool catalog.
enum AgentAdministration {
    static func run(_ args: [String]) throws -> JSON {
        let registry = try AgentRegistry()
        let command = args.first ?? ""
        let permissions: () throws -> Set<String> = {
            guard let i = args.firstIndex(of: "--permissions"), i + 1 < args.count else { throw ServiceError("invalid_arguments", "Specify --permissions mail.read,... (empty string grants no applications)") }
            return Set(args[i + 1].split(separator: ",").map(String.init))
        }
        if command == "--agent-list" { return try .encoded(registry.list()) }
        guard args.count >= 2 else { throw ServiceError("invalid_arguments", "Agent name or ID required") }
        switch command {
        case "--agent-create":
            let agent = try registry.create(name: args[1], permissions: permissions())
            return .object(["agent": try .encoded(agent), "credential_file": .string(registry.credentialURL(agent.id).path), "configuration": registry.configuration(agent)])
        case "--agent-update": try registry.update(args[1], permissions: permissions())
        case "--agent-revoke": try registry.revoke(args[1])
        case "--agent-config":
            guard let agent = try registry.list().first(where: { $0.id == args[1] && !$0.revoked }) else { throw ServiceError("not_found", "Active Agent not found") }
            return registry.configuration(agent)
        default: throw ServiceError("invalid_arguments", "Unknown local Agent management command")
        }
        return .object(["updated": .bool(true)])
    }
}
