// swift-tools-version: 5.9
//
// SDK version: 4.11.0
// Swift Package Manager resolves the actual version from git tags, not
// from this file. The marker above documents the current source state
// so casual readers don't have to cross-reference the latest tag.
// 4.11.0: sign-in and sign-out follow Affiliateo's customers (one person per
//   app, the RevenueCat model). New logout() for sign-out: the device starts
//   over as anonymous and tracking carries on with the same device id,
//   visitor id and appAccountToken. reset() is now the same as logout() (it
//   used to clear appAccountToken until the app relaunched). identify(_:)
//   does nothing while opted out, skips placeholder ids ("null", "guest",
//   "0", $RCAnonymousID:...), stores the id and re-sends it once per launch,
//   and retries a sign-in that raced ahead of the launch's first identify.
//   A different user signing in on the same device now switches it.
// 4.10.0: every user gets the purchase tag (the Affiliateo visitor id), so
//   sales from people who did not come through an affiliate are tied to their
//   phone too. state.appAccountToken is now the visitor id for every device
//   (it was only set for affiliate matches, from a per-affiliate token the SDK
//   minted and registered). Same name, no code changes in the app.
// 4.9.0: app sales to the ad networks. Affiliateo.purchase(...) reports a
//   purchase from the paywall (plus a StoreKit 2 overload), and identify now
//   carries the advertising ids the person allowed: the IDFA only after
//   "Allow" on the app's own tracking prompt (the SDK never prompts), the
//   tracking answer itself, the Meta SDK's anonymous id when the app ships
//   it, and the bundle id. A changed tracking answer is sent when the app
//   comes back to the front. Additive, no API changes.
// 4.8.0: a dedup key on every event, so a retry cannot double-count.
// 4.7.0: the SDK now READS the RevenueCat App User ID itself (on identify and
//   on foreground) instead of waiting for the host app to call
//   setRevenueCatUser. That call remains for apps that want to control the
//   timing. Powers the owner-granted free-access switch in the dashboard.
// 4.6.0: setRevenueCatUser(_:) added — report the RevenueCat App User ID so an
//   app owner can grant an affiliate complimentary access.
// 4.5.0: campaigns are now apps — init(appId:) is the documented spelling,
//   init(campaignId:) still works (deprecated).
// 4.4.1: RevenueCat attributes now include affiliateo_visitor_id on every
//        identify (not just affiliate-matched), so purchases link back to the
//        tracked visitor (per-buyer spend, funnels, ad ROAS).
// 4.4.0: version alignment — every Affiliateo SDK (web, React Native,
// Swift, Kotlin, Flutter) now ships the same version number. Identical
// source to 3.2.0.
// 3.2.0: Apple Search Ads attribution — the SDK grabs the AdServices
// token once per install (iOS 14.3+, no ATT prompt) and hands it to the
// backend, which redeems it with Apple for campaign/ad-group/keyword
// attribution. Additive, no API changes.

import PackageDescription

let package = Package(
    name: "Affiliateo",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "Affiliateo",
            targets: ["Affiliateo"]
        ),
    ],
    targets: [
        .target(
            name: "Affiliateo",
            path: "Sources/Affiliateo"
        ),
    ]
)
