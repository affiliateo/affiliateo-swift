# Affiliateo Swift SDK

Mobile affiliate attribution and session tracking for iOS apps (SwiftUI & UIKit).

## Installation

In Xcode: **File → Add Package Dependencies** → paste this URL:

```
https://github.com/affiliateo/affiliateo-swift
```

## Usage (SwiftUI)

Wrap your app with `AffiliateoProvider`:

```swift
import SwiftUI
import Affiliateo

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            AffiliateoProvider(appId: "YOUR_APP_ID") {
                ContentView()
            }
        }
    }
}
```

Access the attribution state from any view:

```swift
struct ContentView: View {
    @EnvironmentObject var affiliateo: AffiliateoManager

    var body: some View {
        if affiliateo.state.isMatched {
            Text("Referred by: \(affiliateo.state.refCode ?? "")")
        }
    }
}
```

## Track screens (manual)

Screens are tracked when you call `Affiliateo.page(name)` per screen. This matches the Mixpanel / Amplitude model. predictable, no ghost events polluting funnels.

```swift
struct HomeScreen: View {
    var body: some View {
        YourScreenUI()
            .onAppear {
                Affiliateo.page("HomeScreen")
            }
    }
}
```

## Track custom events

For buttons or other moments that matter (signup, trial start, etc.):

```swift
Button("Continue") {
    Affiliateo.track("signup_completed")
    onNext()
}
```

## Report purchases to your ad networks

When you run app campaigns on Meta, TikTok or Snapchat through Affiliateo,
Affiliateo tells those networks each time somebody FIRST pays (a
subscription's first charge, or a one-time purchase), so the campaigns learn
who pays rather than who installs. Set it up in Affiliateo: your ad network's
settings, **Send app sales**, then paste the network's id for your app.

There are two ways a payment reaches Affiliateo, and you can use either or
both. Affiliateo sends each payment once.

1. **Your payment provider (nothing to add here).** If RevenueCat, Apple
   In-App Purchase or Adapty is connected to your app in Affiliateo, first
   payments are reported on their own.
2. **One line on your paywall.** Right after a purchase succeeds:

```swift
// RevenueCat
let result = try await Purchases.shared.purchase(package: package)
if !result.userCancelled, let transaction = result.transaction {
    Affiliateo.purchase(
        transactionId: transaction.transactionIdentifier,
        productId: transaction.productIdentifier,
        price: package.storeProduct.price,
        currency: package.storeProduct.currencyCode ?? "USD"
    )
}

// StoreKit 2
if case .success(.verified(let transaction)) = try await product.purchase() {
    Affiliateo.purchase(transaction)
    await transaction.finish()
}
```

The paywall line is quicker and carries the phone's network address, which
the networks match on. It records no sale and moves no money: revenue and
commissions still come only from your payment provider.

**Tracking permission.** The SDK never shows the "Allow tracking?" prompt. If
your app shows it and the person taps Allow, the SDK includes the advertising
id, which makes the networks' matching much better. Without it, purchases are
still reported, marked as not allowed, and the networks treat them by their
privacy rules. On Meta, the people who decline are measured through the Meta
SDK, so add it to your app too if you run Meta app campaigns, with its
automatic purchase logging turned off (the SDK finds it and links the two on
its own).

**Send each network your sales one way only.** If your app also reports
purchases to Meta, TikTok or Snapchat with that network's own SDK (Meta's SDK
does it by itself while its automatic purchase logging is on), turn that
purchase reporting off, or leave **Send app sales** off for that network.
Otherwise the network counts every sale twice: it only matches two reports of
one sale when both carry the same id, and its own SDK doesn't send the store's
transaction id. Affiliateo's own two ways are matched on it and go out once.

## What it does

- **Identifies the device** using Apple's built-in IDFV (no permissions needed)
- **Tracks sessions** automatically (app foreground)
- **Matches affiliate referrals** via fingerprint matching
- **Sets RevenueCat attributes** automatically if RevenueCat is installed
- **IAP attribution** via StoreKit 2 `appAccountToken`

## Giving affiliates free access

App owners can switch complimentary access on for an individual affiliate from
their Affiliateo dashboard, which grants a promotional entitlement in their own
RevenueCat project.

**Nothing to add to your code.** As of 4.7.0 the SDK reads your RevenueCat App
User ID itself, after its first identify and on every foreground after that. It
finds RevenueCat dynamically, so there is no dependency to add and nothing at
all happens in apps that don't use RevenueCat.

Before 4.7.0 this needed a call you had to write yourself. It still exists if
you want to control the timing:

```swift
import RevenueCat

// after Purchases.configure(...) — optional, the SDK already does this
Affiliateo.setRevenueCatUser(Purchases.shared.appUserID)
```

Sending the same id repeatedly is a no-op. RevenueCat issues an anonymous
placeholder until your app calls `Purchases.logIn()`; the SDK re-reads on
foreground and the server accepts exactly one upgrade from that placeholder to
the real id.

An affiliate still has to have opened your app through their own referral link
at least once, because that link is what tells us which device is theirs. Until
then the owner sees a disabled switch reading "hasn't opened your app yet".

Notes:

- Separate from `identify()` on purpose. Sign-in and RevenueCat setup happen at
  different moments, and your app may do one without the other.
- Write-once per device. Sending a different ID for a device that is already
  bound is rejected, so a tampered client cannot repoint a device at another
  customer.
- No email or other PII is sent, same as `identify()`.

## Requirements

- iOS 15+
- Swift 5.9+
