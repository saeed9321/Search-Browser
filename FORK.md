# Search-Browser — what this fork adds

This is a fork of [Search](https://github.com/driceroland/Search) by Office Commun (MIT).
Everything here is upstream's work except the changes below, which are all in
**Settings › Passwords › Bring things over**, for Chromium browsers (Chrome,
Dia, Arc, Brave, Edge, Vivaldi, …), plus pointer lock for 3D pages (section 3),
an end to repeated keychain dialogs on sign-in pages (section 4) and two
changes to the tab row (section 5).

"Search" and its icon belong to Office Commun. This fork publishes source only;
if you ship builds of it, rename the app first, as upstream's README asks.

## 1. Cookies and sign-ins import

Bring a Chromium profile's cookies into Search so you stay signed in to your
sites, alongside the passwords, bookmarks and history Search already imports.

- Reads the profile's `Cookies` database (`Network/Cookies` on newer
  Chromium), from a copy, never the live file.
- Decrypts `v10` values with the browser's own key from the macOS keychain. The
  key is the one passwords already use, so macOS asks only once.
- Handles cookie schema version 24 and later, where every value starts with
  the SHA-256 of its domain. That hash is checked and then removed, so a value
  that fails it is skipped instead of being imported corrupted.
- Keeps the Secure, HttpOnly, SameSite and expiry attributes. Session cookies
  stay session cookies.
- Skips partitioned cookies (CHIPS, which have a non-empty `top_frame_site_key`)
  because `HTTPCookie` cannot represent them, and skips expired cookies.
- Never overwrites a cookie Search already has. If a site's sign-in exists in
  both browsers, Search's own wins. The result line reports cookies imported,
  cookies already here, cookies skipped and any WebKit refused.
- Goes into the Space on screen. It needs one profile chosen rather than
  "All profiles", so accounts from different profiles don't mix.

**Chromium detail worth knowing:** Chromium writes `has_cross_site_ancestor = 1`
on *every unpartitioned* cookie as a placeholder. Only `top_frame_site_key`
says whether a cookie is partitioned. Filtering on `has_cross_site_ancestor`
drops almost every real cookie, which is the "0 cookies imported, all expired
or unsupported" symptom. The tests use rows shaped the way Chromium really
writes them, so they catch this.

Code: `Sources/Search/ImportCookies.swift`, with small hooks in
`Import.swift` (cookie counts in the preview, a shared keychain key) and
`ImportPanel.swift`.

## 2. Each profile as a Space

One switch turns every profile of a multi-profile browser into its own
**Space**, named after the profile, with its own cookies and sign-ins:

- Each profile gets a Space with the name the browser gives it in
  `Local State` (for example "Work" or "Personal"), with its own WebKit
  website-data store and its own icon.
- The profile used most recently goes into the first Space, where its
  sign-ins already are, so it isn't duplicated.
- A Space that already has the profile's name (in any letter case) is reused,
  so running the import again adds to the existing Spaces instead of creating
  copies.
- Spaces are turned on if they were off. The keychain is asked once for every
  profile together.
- Passwords, bookmarks, history and extensions stay shared across Spaces, as
  Search always shares them. They still follow the Profile picker.

Code: `Browser.spaces(forProfiles:usual:)` in `Sources/Search/Spaces.swift`,
and the "Each profile as a Space" option in `ImportPanel.swift`.

## 3. Pointer lock for games and 3D pages

3D games and viewers that steer with the mouse call `requestPointerLock()`:
the cursor is hidden and the page reads raw mouse movement. In a `WKWebView`
the host app has to grant this through WebKit's private UI delegate
(`_webViewDidRequestPointerLock:completionHandler:`). Upstream Search never
answered, so WebKit refused every request and mouse-look didn't work, though
it does in Safari, Chrome and Dia.

- Granted only to the tab in front, in the window in front. WebKit itself
  only asks after a click on the page.
- **Esc** gives the pointer back before any of Search's own Esc actions run,
  as in Safari, so the cursor can't be stranded.
- `_webViewDidLosePointerLock:` clears the state when the page lets go itself.

Code: `askedForPointer`, `lostPointer` and `releasePointer` in
`Sources/Search/Browser.swift`, and the Esc handling in `App.swift`.

## 4. One keychain dialog per account, not one per account per click

On a sign-in page, a build of your own could put up "Search wants to use your
confidential information stored in “Search” in your keychain" over and over,
and Deny, Allow and Always Allow all brought the next one. Two things together:

- **The list under a sign-in box read every account's password before it was
  drawn.** Each read is a dialog wherever the keychain doesn't trust this
  build, and every item is labelled "Search", so they all look the same: 23
  in a row on one site with many subdomains, all over again whenever the caret
  came back into the box. The list is now made from the items' names alone,
  and only the account you pick is read. Saving after a sign-in reads only
  that account's password, and marking one as just used rewrites only its
  date, not the password.
- **An ad-hoc signature is a stranger after every rebuild.** The keychain
  knows an ad-hoc app by the hash of that one build, so "Always Allow" lasted
  until the next `./build.sh`. Without a Developer ID, `build.sh` now signs
  with an Apple Development certificate when there is one, a signature that
  stays the same app from build to build. `SEARCH_LOCAL_IDENTITY` names the
  certificate; keep it the same, because a different one is a stranger too.

Passwords kept by an earlier build still ask once each, the first time each
account is picked; Always Allow then holds across rebuilds.

Code: `kept(for:)`, `kept(matching:)` and `touch(_:)` in
`Sources/Search/Vault.swift`, `hang`, `choose` and `onCredentials` in
`Sources/Search/Browser.swift`, and the signing step in `build.sh`.

## 5. The tab row

- **Reload sits right before the pinned tabs**, after the Space's icon,
  wherever back and forward are. Settings › Tabs' switch is now "Back and
  forward on the left" and moves only those two.
- **A double-click on the empty part of the row does what a title bar's
  does** (zoom, unless System Settings › Desktop & Dock says otherwise), as the
  corner left of the tabs already did, rather than open a new tab. The plus
  and ⌘T open tabs. The empty space below the tabs in the sidebar still opens
  one.

Code: `ReloadDoor` and `Helm(reloads:)` in `Sources/Search/TabBar.swift`.

## Tests

- `Tests/SearchTests/ImportCookiesTests.swift` covers the domain-hash check and
  its removal (including empty values), expired and partitioned rows with
  realistic `has_cross_site_ancestor` values, cookie attributes, how a cookie
  is identified as "the same" one, and installing into WebKit without
  replacing an existing sign-in.
- `testChromiumProfilesBecomeNamedSpacesWithSeparateSignIns` in
  `ImportFileTests.swift` covers profile names becoming Spaces, the most
  recent profile mapping to the first Space, reuse on a second run, and a
  cookie set in one profile's Space not being visible in another Space or in
  the first one.

- `Tests/SearchTests/PointerLockTests.swift` checks that WebKit can find the
  pointer-lock answers by their exact Objective-C names, that a page outside
  the front tab is refused, and that pages are offered `requestPointerLock`.

```sh
swift test --filter "ImportCookiesTests|ImportFileTests|PointerLockTests"
```

## Other

- `build.sh`: `SEARCH_BUILD_DISABLE_SANDBOX=1` passes `--disable-sandbox` to
  SwiftPM, for building inside an environment that is already sandboxed.
- `build.sh`: `SEARCH_LOCAL_IDENTITY` names the Apple Development certificate
  a local build is signed with (section 4).
