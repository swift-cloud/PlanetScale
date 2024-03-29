import Compute
import Foundation

private let baseURL = "https://aws.connect.psdb.cloud/psdb.v1alpha1.Database"

public enum PlanetScaleError: Error, Sendable {
    case executeError(error: PlanetScaleClient.VitessError, response: PlanetScaleClient.ExecuteResponse)
    case requestFailed(response: FetchResponse)
}

public actor PlanetScaleClient {

    private let username: String

    private let password: String

    private lazy var basicAuthorizationHeader = buildBasicAuthorizationHeader()

    public private(set) var session: QuerySession.Session?

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    @discardableResult
    public func execute(_ query: String) async throws -> QueryResult {
        // Build request
        let req = ExecuteRequest(query: query, session: session)

        // Request a new session
        let res = try await fetch("\(baseURL)/Execute", .options(
            method: .post,
            body: .json(req),
            headers: [HTTPHeader.authorization.rawValue: basicAuthorizationHeader]
        ))

        // Ensure successful response
        guard res.status == HTTPStatus.ok.rawValue else {
            throw PlanetScaleError.requestFailed(response: res)
        }

        // Decode the session
        let response: ExecuteResponse = try await res.decode()

        // Save the session
        self.session = response.session

        // Check for an error
        if let error = response.error {
            throw PlanetScaleError.executeError(error: error, response: response)
        }

        return response.result!
    }

    @discardableResult
    public func transaction<T>(_ handler: (PlanetScaleClient) async throws -> T) async throws -> T {
        // Create a new client for the transaction
        let tx = PlanetScaleClient(username: username, password: password)
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

        // Ensure successful response
        guard res.status == HTTPStatus.ok.rawValue else {
            throw PlanetScaleError.requestFailed(response: res)
        }

        // Decode the session
        let data: QuerySession = try await res.decode()

        // Save the session
        self.session = data.session

        return data
    }

    private func buildBasicAuthorizationHeader() -> String {
        let value = "\(username):\(password)".base64Encoded()
        return "Basic \(value)"
    }
}

extension PlanetScaleClient {
    public struct ExecuteResponse: Codable, Sendable {
        public let session: QuerySession.Session
        public let result: QueryResult?
        public let error: VitessError?
    }

    public struct ExecuteRequest: Codable, Sendable {
        public let query: String
        public let session: QuerySession.Session?
    }
}

extension PlanetScaleClient {
    public struct QueryResult: Codable, Sendable {
        public struct Row: Codable, Sendable {
            public let lengths: [String]
            public let values: String?
        }

        public struct Field: Codable, Sendable {
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

extension PlanetScaleClient.QueryResult {

    public func decode<T: Decodable>() throws -> [T] {
        return try decode(T.self)
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> [T] {
        guard let rows = rows else {
            return []
        }
        guard let fields = fields else {
            return []
        }
        return try rows.map { row in
            let json = row.json(fields)
            let data = try JSONSerialization.data(withJSONObject: json)
            return try JSONDecoder().decode(type, from: data)
        }
    }

    public func json() -> [[String: Any]] {
        guard let rows = rows else {
            return []
        }
        guard let fields = fields else {
            return rows.map { _ in [:] }
        }
        return rows.map { row in
            row.json(fields)
        }
    }
}

extension PlanetScaleClient.QueryResult.Row {

    public func json(_ fields: [PlanetScaleClient.QueryResult.Field]) -> [String: Any] {
        let values = decode()
        return fields.enumerated().reduce(into: [:]) { dict, item in
            let value = values[item.offset]
            dict[item.element.name] = item.element.cast(value: value)
        }
    }

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

extension PlanetScaleClient.QueryResult.Field {

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

extension PlanetScaleClient {
    public struct VitessError: Codable, Sendable, Error {
        public let message: String
        public let code: String
    }
}

extension PlanetScaleClient {
    public struct QuerySession: Codable {
        public struct User: Codable, Sendable {
            public let username: String
            public let psid: String
            public let role: String
        }

        public struct Session: Codable, Sendable {
            public struct VitessSession: Codable, Sendable {
                public struct Options: Codable, Sendable {
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
