// swift-tools-version: 5.9
//
// SDK version: 4.15.1
// Swift Package Manager resolves the actual version from git tags, not
// from this file. The marker above documents the current source state
// so casual readers don't have to cross-reference the latest tag.
// 4.15.1: Live Chat privacy on shared phones. identify(_:) with a different
//   user (no logout() in between) forgets the last person's chat first, as
//   logout() does; signing in from anonymous keeps the person's own thread.
//   A thread key the open chat hands over after a sign-out is no longer
//   saved again. The chat page runs in a private web data store, and
//   logout() removes whatever an older version left in web storage for
//   Affiliateo's host, so no key or transcript copy stays on the phone.
// 4.15.0: Live Chat opens as a sheet that slides up over the app (with its
//   handle; pulled down or the page's close button closes it), and the
//   owner's new "Glass" bubble style: Liquid Glass on iOS 26 and later,
//   frosted glass before. setChatBubblePadding(bottom:) keeps the bubble
//   above the app's own tab bar or floating button. The bubble shows at once
//   on launch from the last answer the phone kept, then checks the server.
// 4.14.2: logout() forgets the person's chat, so the next person on the
//   phone starts a new thread; the speech bubble fills 60% of the circle.
// 4.14.1: Live Chat's "auto" bubble size: small on an iPhone, medium on an
//   iPad, the size a new app starts with. The red number and the green dot
//   now scale with the bubble, so a small bubble keeps the same look.
// 4.14.0: Live Chat. Affiliateo.showChatBubble() draws a draggable chat
//   bubble over the app's screens and Affiliateo.openChat() opens the chat
//   from the app's own button; the business answers from the Live Chat inbox
//   in its dashboard. The chat screen is Affiliateo's hosted chat page in a
//   web view, full screen. Nothing shows until the app calls one of them, nor
//   while the business has the chat off for the app. The bubble shows unread
//   replies and whether the team is online; chatAvailable() answers whether
//   the chat is on, hideChatBubble() takes the bubble away. The owner picks,
//   per app in the dashboard, the corner it starts in, its size, a greeting
//   that counts as one unread message until the chat is first opened, and the
//   screens it shows on (matched against the names sent with page(_:)). The
//   red number is live while the app is open (a socket on the thread). iOS
//   only.
// 4.13.0: the App Store's own price for the app's products. Once a day, in
//   the background, a phone on the US App Store reads the products
//   Affiliateo asks about (StoreKit 2, the product's own price, never an
//   intro offer) and reports them, so the app's product cards on Affiliateo
//   show the store's exact price without any App Store key. Nothing about
//   the person is sent, nothing to call, never blocks or throws, and
//   nothing while opted out.
// 4.12.0: free access for apps that sell without RevenueCat (StoreKit,
//   Google Play Billing, Adapty, Stripe). identify(_:email:) takes the
//   signed-in person's email and sends only its SHA-256 (trimmed and
//   lowercased first), never the address. New Affiliateo.freeAccess() asks
//   whether the app owner gave that person free access and answers
//   { active, productId, expiresAt }; it never throws, saves each answer on
//   the phone, and when offline uses the saved one while its end is ahead and
//   it is at most 7 days old. logout() forgets it. First test target.
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
        .testTarget(
            name: "AffiliateoTests",
            dependencies: ["Affiliateo"],
            path: "Tests/AffiliateoTests"
        ),
    ]
)
