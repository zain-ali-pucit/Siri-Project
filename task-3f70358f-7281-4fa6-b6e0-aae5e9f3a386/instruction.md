# Add a reset button for the Experimental settings

## What to change

flo has an Experimental section in Preferences with a few switches and pickers. Once someone turns things on there, getting back to the normal setup means hunting down each option again. Add a "Reset experimental settings" button at the end of the Experimental section that puts these three settings back to their defaults in one tap:

- Enable Debug: off
- Library View V2: off
- Max Bitrate: Source

The work belongs in the Preferences screen (`flo/Navigation/PreferencesView.swift`) and whatever it needs from the existing settings code. Do not change the LRCLIB picker, the "Save login info" switch, the streaming cache options, the login flow, networking or playback.

## Entry point and project layout

The app is `flo.xcodeproj` with the `flo` scheme. `PreferencesView` builds the Preferences tab as a `Form`, and the Experimental section is one of its sections. Settings are kept in `UserDefaults`, through `UserDefaultsManager` (`flo/Shared/Services/UserDefaultsManager.swift`) and the keys in `flo/Shared/Utils/Constants.swift`. `ContentView` decides which tabs exist based on the Enable Debug and Library View V2 settings (see `availableTabs` in `flo/Shared/Utils/LibraryNavigation.swift`).

## Final behavior

Start with Enable Debug on, Library View V2 on and Max Bitrate set to 320. On an iPhone, the tab bar then shows Home, Library, Search, Preferences and Debug.

1. Open Preferences and tap "Reset experimental settings".
2. Right away, without leaving the screen or restarting the app:
   - the Debug tab goes away,
   - the tab bar goes back to the classic layout (Home, Downloads, Preferences), so Search is gone,
   - the Enable Debug and Library View V2 switches both show off.
3. After the app is closed and opened again, the reset holds: still no Debug or Search tab, the classic layout is still shown, and Max Bitrate in Preferences shows "Source".

The button does not ask for confirmation and works whether or not a user is logged in.

## Behavior to keep

- Turning Enable Debug or Library View V2 on or off by hand still works, and the tabs still follow those switches.
- Picking a Max Bitrate by hand still saves it and it stays after a relaunch.
- Every other row in Preferences looks and works as before.

## Accessibility identifiers

New or changed elements in Preferences must carry these accessibility identifiers:

- `resetExperimentalButton`: the new "Reset experimental settings" button
- `enableDebugToggle`: the Enable Debug switch
- `libraryViewV2Toggle`: the Library View V2 switch
- `maxBitratePicker`: the Max Bitrate picker

The tab bar items already exist and must keep their current accessibility identifiers, which are their titles or their icon names:

- Home: `Home` or `house`
- Library: `Library` or `circle.grid.2x2`
- Search: `Search` or `magnifyingglass`
- Downloads: `Downloads` or `arrow.down.circle`
- Preferences: `Preferences` or `gear`
- Debug: `Debug` or `terminal`
