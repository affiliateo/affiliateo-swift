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

## Sign-in and sign-out

Say who is signed in after sign-in (and on launch while someone is), and call
`logout()` on sign-out:

```swift
// after sign-in (email is optional, see Giving affiliates free access)
Affiliateo.identify(user.id, email: user.email)

// on sign-out
Affiliateo.logout()
```

The same person then counts as one customer across their devices. After
`logout()` the phone counts as a new anonymous customer, so whoever signs in
next (or nobody) isn't counted as the person who just left; everything already
recorded stays with them. Tracking carries on as before: same device, same
visitor id, same `appAccountToken`, no relaunch needed. If a different user
signs in without a sign-out in between, the phone switches to them on its own,
and the last person's Live Chat thread is forgotten first (4.15.1).

The SDK remembers the signed-in id and sends it again once per launch. Ids that
mean "nobody" (`"null"`, `"guest"`, `"0"`, an empty string, RevenueCat's
`$RCAnonymousID:...`, anything over 128 characters) are skipped, and nothing is
sent while the person has opted out. **No email address is ever sent:** when
you pass `email`, the SDK sends only its SHA-256 (see below), and nothing else
about the person.

### What changed in 4.12.0

- `identify(_:email:)` takes the signed-in person's email, for free access.
  Only its SHA-256 leaves the phone.
- New `Affiliateo.freeAccess()`, so apps that sell without RevenueCat can give
  affiliates free access (see Giving affiliates free access).

### What changed in 4.11.0

- New `logout()`, for sign-out (see above).
- `reset()` is now the same as `logout()`. It used to try to give the phone a
  new device id, which iOS doesn't allow, and left `appAccountToken` nil until
  the app relaunched.
- `identify()` does nothing while opted out (it used to send anyway), stores
  the id, re-sends it once per launch, retries a sign-in that raced ahead of
  the first launch call, and skips placeholder ids.
- A different user signing in on the same phone now switches it to them. It
  used to be refused, so a shared phone stayed its first user forever.

## Tag every purchase

`affiliateo.state.appAccountToken` is the purchase tag for this phone (its
Affiliateo visitor id). Every user gets one, whether or not they came through
an affiliate, so always pass it to the purchase call. Apple stamps it onto the
sale and on every renewal and refund after it, and Affiliateo ties each one to
this phone, and to the affiliate when there is one.

```swift
// StoreKit 2
let token = affiliateo.state.appAccountToken
let options: Set<Product.PurchaseOption> = token.map { [.appAccountToken($0)] } ?? []
let result = try await product.purchase(options: options)
```

It is nil only until the SDK's first identify succeeds. Signing out keeps it.

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
id, which makes the networks' matching much better. Your app doesn't need
the prompt: without Allow (declined, or never asked) the purchase still goes,
marked as not allowed to track and without Apple's device ids, and each network
uses it only in its limited, privacy-safe way. If your app has the Meta SDK,
this SDK finds it and sends its anonymous id with each payment, so Meta ties
the payment to the install its SDK saw, including for people who don't tap
Allow.

**Installs come from the network's own SDK.** Affiliateo sends payments, not
installs. To run app campaigns on Meta, TikTok or Snapchat, add that network's
SDK (or a measurement partner like AppsFlyer) for installs, and keep **Send app
sales** on for payments.

**Send each network your sales one way only.** Keep that SDK's installs but turn
its purchase reporting off, or leave **Send app sales** off for that network.
Otherwise the network counts every sale twice: it only matches two reports of
one sale when both carry the same id, and its own SDK doesn't send the store's
transaction id. Affiliateo's own two ways are matched on it and go out once.

- **Meta:** in your app on Meta for Developers, under Settings > Basic, set the
  switch that logs in-app purchases automatically to No on the iOS card. Leave
  `FacebookAutoLogAppEventsEnabled` on: turning it off stops installs too.
- **TikTok:** call `disablePaymentTracking()` on your `TikTokConfig`.
- **Snapchat:** don't send purchases from its SDK.
- **A measurement partner** (AppsFlyer, Adjust, Branch, Singular, Kochava) that
  forwards purchases to the network counts too: stop forwarding them, or leave
  **Send app sales** off for that network.

## Live Chat (4.14.0)

Let the people using your app chat with you in real time. You answer from the
**Live Chat** inbox in your Affiliateo dashboard: add Live Chat from the App
Store there, then switch it on for this app under its settings (the gear).

```swift
// The chat bubble on every screen
ContentView()
    .onAppear { Affiliateo.showChatBubble() }

// Or open the chat from your own button
Button("Chat with us") { Affiliateo.openChat() }

// Show your own button only while the chat is on
let available = await Affiliateo.chatAvailable()

// Take the bubble away again
Affiliateo.hideChatBubble()

// Keep it above your own tab bar or floating button (4.15.0)
Affiliateo.setChatBubblePadding(bottom: 72)

// Your own look, over the dashboard's (4.15.0); leave out what the dashboard should decide
Affiliateo.setChatBubbleLook(color: "#7C3AED", iconColor: "#FFFFFF", sendColor: "#007AFF", style: .glass, corner: .bottomLeft, size: 56)

// The message box text in your own words and language (4.15.0): pass your own translation
Affiliateo.setChatPlaceholder(String(localized: "Ask us anything"))
```

- Nothing shows until your code calls `showChatBubble()` or `openChat()`, so
  App Review sees every feature your app has. Nothing shows either while Live
  Chat is off for this app in your dashboard.
- The bubble is for your app's pages: anything you present over them (a
  sheet, a full-screen cover, an alert) covers it, also after the app comes
  back to the front (4.15.2; on iOS 26 and later from 4.15.3). People can drag it and it stays where they leave
  it. VoiceOver reads it in the phone's language, with the unread count. It shows a red number
  for replies they have not read, live while the app is open, and a green dot
  while someone on your team is online. On launch it shows at once from the
  last answer the phone kept, then checks with the server (4.15.0).
- In the Live Chat settings of your dashboard you choose, per app, the corner
  it starts in, its size, its style (the blue circle, or "Glass": Liquid Glass
  on iOS 26 and later, 4.15.0), a greeting that shows as one unread message (a red
  1) until the person first opens the chat, and the screens it shows on.
  Screen rules match the names you send with `Affiliateo.page(_:)` or
  `.trackedScreen(_:)` (`Settings`, `Paywall*`), so send them if you use
  rules.
- The chat screen is Affiliateo's hosted chat page in the person's language,
  in a sheet that slides up over the app (4.15.0; it was full screen). Pulled
  down or the page's close button closes it. Links you send open in Safari
  when the person taps them (4.15.4).
- The person needs no account. Their first message opens a thread, and the
  key to it is kept in the Keychain, on this phone only and never in a backup
  (4.15.4; deleting the app starts a new thread). Your
  inbox labels the thread with the device, the Affiliateo visitor and, after
  `identify(_:)`, your user id; none of them while the person has opted out.
- App Store privacy: chat messages are **Customer Support** data (under User
  Content).

## What it does

- **Identifies the device** using Apple's built-in IDFV (no permissions needed)
- **Tracks sessions** automatically (app foreground)
- **Matches affiliate referrals** via fingerprint matching
- **Sets RevenueCat attributes** automatically if RevenueCat is installed
- **IAP attribution** via StoreKit 2 `appAccountToken`, for every user (see Tag every purchase)
- **Store prices** (4.13.0): once a day, in the background, a phone on the US
  App Store reports the App Store's own price for the app's products, so your
  product cards on Affiliateo show the exact price with no App Store key.
  Only the product ids, prices, currency and store country are sent; nothing
  about the person. Nothing to call.

## Giving affiliates free access

App owners can switch free access on for an individual affiliate from the
Affiliates table in their Affiliateo dashboard, choosing a plan and, if they
like, an end date.

### Apps on StoreKit, Google Play Billing, Adapty or Stripe (4.12.0)

Apple and Google have no way for anyone but the person to start a
subscription, so your app asks Affiliateo instead and unlocks itself:

```swift
// after sign-in: pass the email the person signed in with
Affiliateo.identify(user.id, email: user.email)

// wherever you decide what is unlocked (launch, paywall)
let access = await Affiliateo.freeAccess()
if access.active { unlockPaidFeatures(access.productId) } // nil means full access
```

- `active`: unlock when true.
- `productId`: the store product id of the plan the owner chose. `nil` means
  full access.
- `expiresAt`: when the free access ends. `nil` means no end date.

The affiliate is recognised by email: the address the owner typed when
switching it on, or else the one the affiliate uses on Affiliateo. **The
address never leaves the phone.** The SDK sends only its SHA-256 (trimmed and
lowercased first), and Affiliateo compares it with the same hash of the
owner's address.

`freeAccess()` never throws. It waits (up to 10 seconds) for the sign-in to
reach Affiliateo first, so calling it right after `identify` works. Each
answer is saved on the phone: when Affiliateo can't be reached, the saved one
is used while its end date is still ahead and it is at most 7 days old,
otherwise the answer is no access. `logout()`, or a different user signing in,
forgets it.

### Apps on RevenueCat

Switching free access on grants a promotional entitlement in the owner's own
RevenueCat project.

**Nothing to add to your code.** As of 4.7.0 the SDK reads your RevenueCat App
User ID itself, after its first identify and on every foreground after that. It
finds RevenueCat dynamically, so there is no dependency to add and nothing at
all happens in apps that don't use RevenueCat.

Before 4.7.0 this needed a call you had to write yourself. It still exists if
you want to control the timing:

```swift
import RevenueCat

// after Purchases.configure(...), optional: the SDK already does this
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
- No email or other PII is sent.

## Requirements

- iOS 15+
- Swift 5.9+
