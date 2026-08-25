import Foundation

extension CostUsagePricing {
    static func modelProvider(
        for model: String,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil) -> CostUsageAttribution.ModelProvider
    {
        if self.isOpenAIModel(
            model,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot)
        {
            return .openAI
        }

        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("gemini-")
            || modelsDevCatalog?.pricing(providerID: "google", modelID: trimmed) != nil
            || ModelsDevPricingPipeline.lookup(
                providerID: "google",
                modelID: trimmed,
                cacheRoot: modelsDevCacheRoot) != nil
        {
            return .google
        }

        if self.claudeCostUSD(
            model: model,
            inputTokens: 0,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot) != nil
        {
            return .anthropic
        }

        return .unknown
    }
}
