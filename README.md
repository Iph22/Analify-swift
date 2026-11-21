# Analify for iPhone, iPad and Mac

Private, simple analytics for Swift apps: screens, events and signed-in users, on your [Analify](https://analify.dev) dashboard.

- One file, no dependencies. iOS 13+, iPadOS, macOS 10.15+, tvOS and watchOS.
- No advertising ID, no device identifiers, no tracking across apps. One random install ID stays in your app's own storage so a returning user is counted once.
- Works offline: events wait on the device (up to 7 days) and go out in small batches.

## Install

**Swift Package Manager:** in Xcode, choose **File → Add Package Dependencies…** and enter this repository's address. Or in `Package.swift`:

```swift
.package(url: "https://github.com/Iph22/Analify-swift", from: "0.2.0")
```

**Or copy one file:** download [Analify.swift](https://analify.dev/sdk/Analify.swift) into your project.

## Use

Add an app in Analify (**Add website → App**) to get its key, then:

```swift
import Analify

@main
struct MyApp: App {
    init() {
        Analify.start(key: "AN-XXXXXXXX")
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in Analify.openedFrom(url) }   // campaigns from links that open the app
        }
    }
}

// When a screen appears
.onAppear { Analify.screen("Home") }

// When something happens (text, numbers and true/false properties)
Analify.track("purchase", ["plan": "pro", "amount": 9.5])

// After sign-in, with your own user ID (Analify scrambles it before saving). nil on sign-out.
Analify.identify(user.id)
```

`Analify.start` also takes `appVersion:` (defaults to your app's version), `host:` (if you run Analify yourself) and `debug: true` to print what's sent.

## Privacy

What's sent: screen and event names, your properties, the app version, the operating system, and whether it's a phone, tablet or computer. The network address is used by Analify for a moment to estimate country and city, then discarded.

For Apple's App Privacy details, Analify collects **Usage Data → Product Interaction**, used for **Analytics**, **not linked** to the user's identity (linked only if you call `identify`), and **not used for tracking**.

More: [analify.dev/docs#apps](https://analify.dev/docs#apps) · [Data handling](https://analify.dev/data-handling)
