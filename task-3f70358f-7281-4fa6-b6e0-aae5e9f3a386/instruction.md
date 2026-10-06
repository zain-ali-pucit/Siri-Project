# Add Reset Experimental Settings

`PreferencesView.swift` mein Experimental section ke end par **"Reset experimental settings"** ka button add karna hai.

Button press karne par ye settings apni default values par reset ho jani chahiye:

* **Enable Debug** → Off
* **Library View V2** → Off
* **Max Bitrate** → Source

Changes **immediately** apply hon, app restart karne ki zaroorat na ho. Debug aur Search tabs remove ho jayein aur tab bar wapas classic layout mein aa jaye:

**Home, Downloads, Preferences**

App close karke dobara open karne ke baad bhi reset settings same rehni chahiye.

**Max Bitrate** ka existing manual behavior bilkul same rehna chahiye.

Ye accessibility identifiers add karein:

* Reset button: `resetExperimentalButton`
* Enable Debug: `enableDebugToggle`
* Library View V2: `libraryViewV2Toggle`
* Max Bitrate: `maxBitratePicker`

