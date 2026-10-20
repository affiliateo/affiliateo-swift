import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

/// The App Store's own price for the app's products, as this phone sees it
/// (4.13.0).
///
/// The app's product cards on Affiliateo show each product's US price. An
/// app on RevenueCat or Adapty alone gives Affiliateo no way to read the App
/// Store's price list, so the phones report it: once a day, in the
/// background, only on a phone whose App Store is the US one, and only for
/// the products Affiliateo asks about (the app's own store products). A
/// price shows once enough phones agree, so one phone never decides it.
///
/// Nothing about the person is sent: the product ids, their prices and
/// currency, and the store's country. It never blocks the app, never
/// prompts, never throws, and does nothing while tracking is opted out.
/// Display only: commission is always computed off the amount paid.
enum AffiliateoStorePrices {
    /// At most once a day per app on this phone.
    static let interval: TimeInterval = 24 * 60 * 60

    static func checkedKey(_ campaignId: String) -> String {
        "affiliateo_store_prices_checked_at:\(campaignId)"
    }

    /// Whether a day has passed since this app's last check on this phone.
    static func isDue(lastChecked: Date?, now: Date = Date()) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= interval || now < lastChecked
    }

    /// A store price in whole cents ("6.99" -> 699), or nil for none.
    static func cents(_ price: Decimal) -> Int? {
        var scaled = price * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        let value = NSDecimalNumber(decimal: rounded).intValue
        return value > 0 ? value : nil
    }

    /// Check and report, when due. Runs detached at background priority.
    static func reportIfDue(client: AffiliateoClient, campaignId: String, deviceId: String) {
        #if canImport(StoreKit)
        let defaults = UserDefaults.standard
        let key = checkedKey(campaignId)
        let last = (defaults.object(forKey: key) as? Double).map { Date(timeIntervalSince1970: $0) }
        guard isDue(lastChecked: last) else { return }
        Task.detached(priority: .background) {
            guard await report(client: client, campaignId: campaignId, deviceId: deviceId) else { return }
            // Only a finished check waits a day: a failed one is tried again
            // on the next launch.
            defaults.set(Date().timeIntervalSince1970, forKey: key)
        }
        #endif
    }

    #if canImport(StoreKit)
    /// True once this phone's check is done for the day (reported, or
    /// nothing to report); false on a failure worth trying again.
    private static func report(client: AffiliateoClient, campaignId: String, deviceId: String) async -> Bool {
        // The US App Store only: Affiliateo shows the US price.
        guard let storefront = await Storefront.current else { return false }
        guard storefront.countryCode == "USA" else { return true }
        do {
            let asked = try await client.storePriceProducts(campaignId: campaignId, deviceId: deviceId)
            guard asked.report, !asked.productIds.isEmpty else { return true }
            let products = try await Product.products(for: asked.productIds)
            let prices: [AffiliateoStorePrice] = products.compactMap { product in
                // The product's own price, never an intro offer's.
                let currency = product.priceFormatStyle.currencyCode.uppercased()
                guard currency == "USD", let cents = cents(product.price) else { return nil }
                return AffiliateoStorePrice(productId: product.id, priceCents: cents, currency: currency)
            }
            guard !prices.isEmpty else { return true }
            try await client.reportStorePrices(campaignId: campaignId, deviceId: deviceId, storefront: storefront.countryCode, prices: prices)
            return true
        } catch {
            return false
        }
    }
    #endif
}

/// One product's price as this phone's store lists it.
struct AffiliateoStorePrice: Equatable {
    let productId: String
    let priceCents: Int
    let currency: String
}
