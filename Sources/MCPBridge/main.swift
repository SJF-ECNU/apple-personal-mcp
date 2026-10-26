import Foundation
import MCP
import PersonalCore

@main struct Bridge {
    static func main() async {
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            let readOnly = args.contains("--read-only"); args.removeAll { $0 == "--read-only" }
            guard let index = args.firstIndex(of: "--credential-file"), index + 1 < args.count else { throw ServiceError("credentials_required", "Configure --credential-file using the App's Agent management") }
            let credential = try AgentCredential.load(URL(fileURLWithPath: args[index + 1]))
            args.removeSubrange(index...index + 1)
            let client = try HostClient()
            if args.first == "doctor" || args.first == "call" {
                let tool = args.first == "doctor" ? "system_status" : args.dropFirst().first ?? ""
                let values = args.count > 2 ? try JSONDecoder().decode([String: PersonalCore.JSON].self, from: Data(args[2].utf8)) : [:]
                let data = try await client.send(HostRequest(method: "call", tool: tool, arguments: values, readOnly: readOnly, credential: credential))
                FileHandle.standardOutput.write(data + Data([10]))
                let reply = try JSONDecoder().decode(ToolReply.self, from: data)
                if reply.isError { exit(1) }; return
            }
            guard args.isEmpty else { throw ServiceError("invalid_arguments", "Usage: apple-personal-mcp --credential-file PATH [--read-only] [doctor | call TOOL JSON]") }
            @Sendable func definitions() async throws -> [ToolDefinition] {
                let data = try await client.send(HostRequest(method: "tools", readOnly: readOnly, credential: credential))
                if let error = try? JSONDecoder().decode(ToolReply.self, from: data), error.isError { throw ServiceError("access_denied", error.body["error"]["code"].string ?? "Host denied access") }
                return try JSONDecoder().decode([ToolDefinition].self, from: data)
            }
            _ = try await definitions()
            @Sendable func extensionCall(_ method: String, _ arguments: [String: PersonalCore.JSON] = [:]) async throws -> PersonalCore.JSON {
                let data = try await client.send(HostRequest(method: method, arguments: arguments, readOnly: readOnly, credential: credential))
                let reply = try JSONDecoder().decode(ToolReply.self, from: data)
                guard !reply.isError else { throw MCPError.invalidParams(reply.body["error"]["code"].string ?? "Host denied access") }
                return reply.body
            }
            let server = Server(name: "apple-personal-mcp", version: AppIdentity.version, capabilities: .init(prompts: .init(listChanged: false), resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: false)))
            await server.withMethodHandler(ListResources.self) { params in
                guard params.cursor == nil || Int(params.cursor!) != nil else { throw MCPError.invalidParams("Invalid resource cursor") }
                let result = try await extensionCall("resources", ["offset": .int(Int(params.cursor ?? "0") ?? 0)])
                return try JSONDecoder().decode(ListResources.Result.self, from: result.data())
            }
            await server.withMethodHandler(ReadResource.self) { params in
                try await JSONDecoder().decode(ReadResource.Result.self, from: extensionCall("resource", ["uri": .string(params.uri)]).data())
            }
            await server.withMethodHandler(ListPrompts.self) { _ in
                try await JSONDecoder().decode(ListPrompts.Result.self, from: extensionCall("prompts").data())
            }
            await server.withMethodHandler(GetPrompt.self) { params in
                guard params.arguments?.isEmpty != false else { throw MCPError.invalidParams("This prompt has no arguments") }
                return try await JSONDecoder().decode(GetPrompt.Result.self, from: extensionCall("prompt", ["name": .string(params.name)]).data())
            }
            await server.withMethodHandler(ListTools.self) { _ in
                let tools = try await definitions().map { d in
                    Tool(name: d.name, description: d.description, inputSchema: try JSONDecoder().decode(Value.self, from: d.inputSchema.data()), annotations: .init(readOnlyHint: d.readOnly))
                }
                return ListTools.Result(tools: tools)
            }
            await server.withMethodHandler(CallTool.self) { params in
                let values = try JSONDecoder().decode([String: PersonalCore.JSON].self, from: JSONEncoder().encode(params.arguments ?? [:]))
                let data = try await client.send(HostRequest(method: "call", tool: params.name, arguments: values, readOnly: readOnly, credential: credential))
                let reply = try JSONDecoder().decode(ToolReply.self, from: data)
                let structured = try JSONDecoder().decode(Value.self, from: reply.body.data())
                return CallTool.Result(content: [.text(text: reply.body.text(), annotations: nil, _meta: nil)], structuredContent: Optional.some(structured), isError: reply.isError)
            }
            try await server.start(transport: StdioTransport())
            await server.waitUntilCompleted()
        } catch {
            FileHandle.standardError.write(Data("ApplePersonalMCP: \(error)\n".utf8)); exit(1)
        }
    }
}
