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
