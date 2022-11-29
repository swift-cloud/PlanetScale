import Compute
import Foundation

private let baseURL = "https://aws.connect.psdb.cloud/psdb.v1alpha1.Database"

public struct PlanetscaleQuery {
    public let sql: String

    public let cachePolicy: CachePolicy

    public init(_ sql: String, cachePolicy: CachePolicy = .origin) {
        self.sql = sql
        self.cachePolicy = cachePolicy
    }
}

public actor PlanetscaleClient {

    private let username: String

    private let password: String

    private lazy var basicAuthorizationHeader = buildBasicAuthorizationHeader()

    public private(set) var session: QuerySession.Session?

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    @discardableResult
    public func execute(_ sql: String, cachePolicy: CachePolicy = .origin) async throws -> QueryResult {
        return try await execute(.init(sql, cachePolicy: cachePolicy))
    }

    @discardableResult
    public func execute(_ query: PlanetscaleQuery) async throws -> QueryResult {
        // Build request
        let req = ExecuteRequest(query: query.sql, session: session)

        // Request a new session
        let res = try await fetch("\(baseURL)/Execute", .options(
            method: .post,
            body: .json(req),
            headers: [HTTPHeader.authorization.rawValue: basicAuthorizationHeader],
            cachePolicy: query.cachePolicy,
            cacheKey: buildCacheKey(query)
        ))

        // Decode the session
        let response: ExecuteResponse = try await res.decode()

        // Save the session
        self.session = response.session

        // Check for an error
        if let error = response.error {
            throw error
        }

        return response.result!
    }

    @discardableResult
    public func transaction<T>(_ handler: (PlanetscaleClient) async throws -> T) async throws -> T {
        // Create a new client for the transaction
        let tx = PlanetscaleClient(username: username, password: password)
        do {
            // Begin the transaction
            try await tx.execute("BEGIN")
            // Execute the transaction
            let res = try await handler(tx)
            // Commit the transaction
            try await tx.execute("COMMIT")
            // Return response from handler
            return res
        } catch {
            // Rollback transaction on error
            try await tx.execute("ROLLBACK")
            // Rethrow error
            throw error
        }
    }

    public func boost(enabled: Bool = true) async throws {
        try await execute("SET @@boost_cached_queries = \(enabled);")
    }

    public func refresh() async throws -> QuerySession {
        // Request a new session
        let res = try await fetch("\(baseURL)/CreateSession", .options(
            method: .post,
            body: .json([:]),
            headers: [HTTPHeader.authorization.rawValue: basicAuthorizationHeader]
        ))

        // Decode the session
        let data: QuerySession = try await res.decode()

        // Save the session
        self.session = data.session

        return data
    }

    private func buildCacheKey(_ query: PlanetscaleQuery) -> String? {
        switch query.cachePolicy {
        case .ttl:
            return "\(username).\(query.sql.trimmingCharacters(in: .whitespacesAndNewlines).base64Encoded())"
        default:
            return nil
        }
    }

    private func buildBasicAuthorizationHeader() -> String {
        let value = "\(username):\(password)".base64Encoded()
        return "Basic \(value)"
    }
}

extension PlanetscaleClient {
    public struct ExecuteResponse: Codable {
        public let session: QuerySession.Session
        public let result: QueryResult?
        public let error: VitessError?
    }

    public struct ExecuteRequest: Codable {
        public let query: String
        public let session: QuerySession.Session?
    }
}

extension PlanetscaleClient {
    public struct QueryResult: Codable {
        public struct Row: Codable {
            public let lengths: [String]
            public let values: String?
        }

        public struct Field: Codable {
            public let name: String
            public let type: String
            public let table: String?
        }

        public let rowsAffected: String?
        public let insertId: String?
        public let fields: [Field]?
        public let rows: [Row]?
    }
}

extension PlanetscaleClient.QueryResult {

    public func decode<T: Decodable>() throws -> [T] {
        let values = json()
        let data = try JSONSerialization.data(withJSONObject: values)
        return try JSONDecoder().decode([T].self, from: data)
    }

    public func json() -> [[String: Any]] {
        guard let rows = rows else {
            return []
        }
        guard let fields = fields else {
            return rows.map { _ in [:] }
        }
        return rows.map { row in
            return fields.enumerated().reduce(into: [:]) { dict, item in
                dict[item.element.name] = item.element.cast(value: row.decode()[item.offset])
            }
        }
    }
}

extension PlanetscaleClient.QueryResult.Row {

    public func decode() -> [String?] {
        let data = values?.base64Decoded() ?? ""
        var offset = 0
        return lengths.map { size in
            let width = Int(size)!
            guard width >= 0 else {
                return nil
            }
            let value = String(data.dropFirst(offset).prefix(width))
            offset += width
            return value
        }
    }
}

extension PlanetscaleClient.QueryResult.Field {

    public func cast(value: String?) -> Any? {
        guard let value = value else {
            return nil
        }
        switch type {
        case "INT8",
            "INT16",
            "INT24",
            "INT32",
            "UINT8",
            "UINT16",
            "UINT24",
            "UINT32",
            "YEAR":
            return Int(value)!
        case "DECIMAL",
            "FLOAT32",
            "FLOAT64":
            return Double(value)!
        case "INT64",
            "UINT64",
            "DATE",
            "TIME",
            "DATETIME",
            "TIMESTAMP",
            "BLOB",
            "BIT",
            "VARBINARY",
            "BINARY":
            return value
        case "JSON":
            return value
        default:
            return value
        }
    }
}

extension PlanetscaleClient {
    public struct VitessError: Codable, Error {
        public let message: String
        public let code: String
    }
}

extension PlanetscaleClient {
    public struct QuerySession: Codable {
        public struct User: Codable {
            public let username: String
            public let psid: String
            public let role: String
        }

        public struct Session: Codable {
            public struct VitessSession: Codable {
                public struct Options: Codable {
                    public let includedFields: String
                    public let clientFoundRows: Bool
                }

                public let autocommit: Bool
                public let foundRows: String?
                public let rowCount: String?
                public let options: Options
                public let DDLStrategy: String
                public let SessionUUID: String
                public let enableSystemSettings: Bool
            }

            public let signature: String
            public let vitessSession: VitessSession
        }

        public let branch: String
        public let user: User
        public let session: Session
    }
}

extension String {

    func base64Encoded() -> String {
        return Data(self.utf8).base64EncodedString()
    }

    func base64Decoded() -> String? {
        guard let data = Data(base64Encoded: self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
