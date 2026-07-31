import Foundation

struct RPCRateLimitResetCreditsSummary: Decodable, Encodable {
    let availableCount: Int
    let credits: [RPCRateLimitResetCredit]?
}

struct RPCRateLimitResetCredit: Decodable, Encodable {
    let id: String
    let resetType: String
    let status: String
    let grantedAt: Int64
    let expiresAt: Int64?
    let title: String?
    let description: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case resetType
        case status
        case grantedAt
        case expiresAt
        case title
        case description
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(CodexRateLimitResetCredit.stableID(forProviderID: self.id), forKey: .id)
        try container.encode(self.resetType, forKey: .resetType)
        try container.encode(self.status, forKey: .status)
        try container.encode(self.grantedAt, forKey: .grantedAt)
        try container.encodeIfPresent(self.expiresAt, forKey: .expiresAt)
        try container.encodeIfPresent(self.title, forKey: .title)
        try container.encodeIfPresent(self.description, forKey: .description)
    }
}

struct RPCRateLimitResetCreditConsumeResponse: Decodable {
    let outcome: CodexRateLimitResetCreditConsumeOutcome
}

extension UsageFetcher {
    public func consumeRateLimitResetCredit(
        creditID: String,
        idempotencyKey: UUID,
        expectedAccountEmail: String) async throws -> CodexRateLimitResetCreditConsumeOutcome
    {
        try Task.checkCancellation()
        let stableCreditID = creditID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stableCreditID.isEmpty else {
            throw RPCWireError.malformed("reset credit ID is empty")
        }
        guard let expectedAccountEmail = CodexIdentityResolver.normalizeEmail(expectedAccountEmail) else {
            throw RPCWireError.malformed("expected reset credit account email is empty")
        }

        let rpc = try CodexRPCClient(
            arguments: self.codexArguments,
            environment: self.environment,
            initializeTimeoutSeconds: self.initializeTimeoutSeconds,
            requestTimeoutSeconds: self.requestTimeoutSeconds,
            resolveExecutable: self.codexExecutableResolver)
        defer { rpc.shutdown() }
        try await rpc.initialize(clientName: "codexbar", clientVersion: "0.5.4")
        try Task.checkCancellation()
        let providerCreditID = try await rpc.resolveAvailableResetCreditProviderID(stableID: stableCreditID)
        guard let providerCreditID else {
            throw RPCWireError.resetCreditUnavailable
        }
        try Task.checkCancellation()
        let currentAccountEmail = try await rpc.fetchAccountEmail()
        guard currentAccountEmail == expectedAccountEmail else {
            throw RPCWireError.accountMismatch
        }
        try Task.checkCancellation()
        return try await rpc.consumeRateLimitResetCredit(
            creditID: providerCreditID,
            idempotencyKey: idempotencyKey)
    }

    static func makeResetCredits(
        from rpc: RPCRateLimitResetCreditsSummary?) -> CodexRateLimitResetCreditsSnapshot?
    {
        guard let rpc, rpc.availableCount >= 0 else { return nil }
        let updatedAt = Date()
        let credits = (rpc.credits ?? []).map { credit in
            CodexRateLimitResetCredit(
                id: credit.id,
                resetType: credit.resetType,
                status: Self.makeResetCreditStatus(credit.status),
                grantedAt: Date(timeIntervalSince1970: TimeInterval(credit.grantedAt)),
                expiresAt: credit.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                redeemStartedAt: nil,
                redeemedAt: nil,
                title: credit.title,
                description: credit.description)
        }
        return CodexRateLimitResetCreditsSnapshot(
            credits: credits,
            availableCount: rpc.availableCount,
            updatedAt: updatedAt)
    }

    private static func makeResetCreditStatus(_ status: String) -> CodexRateLimitResetCreditStatus {
        switch status {
        case "available": .available
        case "redeeming": .redeeming
        case "redeemed": .redeemed
        case "expired": .expired
        default: .unknown(status)
        }
    }
}
