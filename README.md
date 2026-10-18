# Swiftify

> ## spotify-accurate
> this branch is a modified version of Swiftify built for **Spotify feature and
> design accuracy**: it looks, navigates and behaves like the official Spotify
> desktop app, keeps Swiftify's light Rust and Qt core, and fixes the Windows
> build and window handling along the way. [what changed](#whats-different-on-spotify-accurate)

<table border="0">
  <tr>
    <td><img src="/docs/screenshots/spotify-accurate/home.png" alt="home with the spotify-style sidebar and top bar" width="400"/></td>
    <td><img src="/docs/screenshots/spotify-accurate/playlist.png" alt="a playlist" width="400"/></td>
  </tr>
  <tr>
    <td><img src="/docs/screenshots/spotify-accurate/song-menu.png" alt="a song's menu with Go to Song Radio" width="400"/></td>
    <td><img src="/docs/screenshots/spotify-accurate/radio.png" alt="a song radio page" width="400"/></td>
  </tr>
  <tr>
    <td><img src="/docs/screenshots/spotify-accurate/profile.png" alt="the profile page" width="400"/></td>
    <td><img src="/docs/screenshots/spotify-accurate/whats-new.png" alt="what's new" width="400"/></td>
  </tr>
</table>

a spotify player for desktop, built with Qt Quick on top of a Rust core that
wraps [librespot](https://github.com/librespot-org/librespot). it follows
Material 3 Expressive (heavy inspo from end4) and has an immersive player,
synced lyrics, visualizers, an equalizer, and local files with local playlists
where u can edit the tracks metadata.
![Alt text](/assets/home.png)
this apps purpose is to replace spotifys heavy webview client, but its also mostly eyecandy lol
it runs significantly lighter than the spotify client.

**EVEN WITH THE EYECANDY TURNED ON....** it is lighter than spotify + spotifys renderers both on cpu AND ram!!!!!

id recommend turning the visualizers and background off if the app runs in the background tho lol

***anyways runs on linux (made for wayland and hyprland) macos, and windows.***

## previews
first image shows equalizer, tempo and pitch settings. second picture shows how the immersive player and the visualizer/lyrics look
<table border="0">
  <tr>
    <td><img src="/assets/eq.png" alt="equalizer and tempo" width="400"/></td>
    <td><img src="/assets/immersive.png" alt="immersive player with visualizers" width="400"/></td>
  </tr>
</table>

> ### Note
> i will probably not be maintaining it, if you are interested in taking over this project you can send me an email

- [Before you start](#before-you-start)
- [Building from source](#building-from-source)
  - [Build requirements](#build-requirements)
  - [macOS](#macos)
  - [Linux](#linux)
  - [Windows](#windows)
- [Command line](#command-line)

## Before you start

- **spotify premium.** playback goes through librespot, and that only works with premium.
- **a spotify client id.** your library, playlists and search come from the spotify
  web api through your own developer app. the first launch walks u through it:
  make an app in the [spotify developer dashboard](https://developer.spotify.com/dashboard),
  add `http://127.0.0.1:8898/login` as a redirect uri, and paste the apps client id
  into swiftify. you dont need the client secret.

## Building from source

### Build requirements

- Qt 6.9 or newer: Qt Base, Qt Declarative and Qt Shader Tools
- QtKeychain and QCoro 0.10 or newer, both built for Qt 6
- CMake 3.24 or newer, Ninja, and a C++20 compiler
- Rust (stable, from [rustup](https://rustup.rs))

the first cmake run needs internet: it pulls [Corrosion](https://github.com/corrosion-rs/corrosion)
(which builds the rust core as part of the cmake build) and two fonts, Material Symbols
Rounded and Google Sans Flex, each checked against a pinned hash.

the builds below skip the tests with `-DBUILD_TESTING=OFF`. for a manual CMake
build, drop that and run `ctest --test-dir build` if u want them.

### macOS

u need [homebrew](https://brew.sh) and apple's command line tools (`xcode-select --install`, or full xcode). then:

```sh
brew install qtbase qtdeclarative qtshadertools qtkeychain qcoro6 cmake ninja
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

git clone https://github.com/shredos67/swiftify.git
cd swiftify
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF
cmake --build build
ditto build/swiftify.app /Applications/Swiftify.app
```

it's signed ad hoc, so no developer account needed.
with full xcode installed the icon gets compiled with `actool` and picks up macos 26's glass,
dark and tinted looks; with just the command line tools it's built from the PNGs.

### Linux

on arch either build a proper package, which installs to `/usr`:

```sh
git clone https://github.com/shredos67/swiftify.git
cd swiftify/packaging/arch
makepkg -si
```
or use cmake:

```sh
# replace with your package manager if not on arch
sudo pacman -S --needed git qt6-base qt6-declarative qt6-shadertools qt6-wayland qtkeychain-qt6 qcoro libpulse alsa-lib openssl cmake ninja rust pkgconf

git clone https://github.com/shredos67/swiftify.git
cd swiftify
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DCMAKE_INSTALL_PREFIX="$HOME/.local"
cmake --build build
cmake --install build
```

on debian/ubuntu (or derivatives with Qt 6.8), use the build script that handles
compatibility patches automatically:

```sh
sudo apt-get install git qt6-base-dev qt6-declarative-dev qt6-shader-baker \
    qt6-shadertools-dev qt6-wayland qtkeychain-qt6-dev qcoro-qt6-dev \
    libpulse-dev libasound2-dev libssl-dev cmake ninja-build pkg-config
# install rust from https://rustup.rs if you dont have it

git clone https://github.com/shredos67/swiftify.git
cd swiftify
./tools/build-debian.sh
```

or with `--install-deps` to install the dependencies automatically:

```sh
git clone https://github.com/shredos67/swiftify.git
cd swiftify
./tools/build-debian.sh --install-deps
```

anywhere else, install the same reqs (Qt 6.9+ with D-Bus, OpenGL and Wayland, QtKeychain
and QCoro for Qt 6, libpulse, plus the ALSA, OpenSSL and pkg-config dev packages), then
run the cmake commands above. if you have Qt 6.8, use `tools/build-debian.sh` which
applies the necessary compatibility patches.

`cmake --install` drops `swiftify` in `~/.local/bin` (make sure that's on your `PATH`)
and the desktop entry, icons and fonts in `~/.local/share`. 

your login gets saved in the secret service through QtKeychain, so u need something
providing one: gnome-keyring, kwallet or keepassxc.

on linux it also hooks into MPRIS (media keys, `playerctl`, shell media widgets),
logind (pauses before the machine sleeps), pipewire/pulseaudio device changes, and
the tray. `-DSWIFTIFY_DESKTOP_INTEGRATION=OFF` turns those off.

### Windows

**because most Windows users cant even use their own OS, i made a script that handles building so it's as simple as possible :)**

first install Qt 6.9+ with *Qt Shader Tools*, CMake and Ninja from the Qt online installer,
Rust from [rustup](https://rustup.rs), and Git. choose either Qt for *MSVC 2022 64-bit*
with Visual Studio 2022 17.1+ (or Build Tools) and its *Desktop development with C++*
workload, or Qt for *MinGW 64-bit* with its matching MinGW toolchain.

then run this in Windows PowerShell:

```powershell
git clone https://github.com/shredos67/swiftify.git
Set-Location swiftify
.\tools\build-windows.ps1
```

for a different Qt kit, toolchain location or install directory, pass overrides:

```powershell
.\tools\build-windows.ps1 -QtPath 'C:\Qt\6.11.2\msvc2022_64'
.\tools\build-windows.ps1 -QtPath 'C:\Qt\6.9.3\mingw_64' -MingwPath 'C:\Qt\Tools\mingw1310_64\bin' -InstallPrefix "$env:LOCALAPPDATA\Programs\Swiftify"
```

adjust the example paths to your installed versions, MinGW must match your Qt
kit, not just the example folder name. 

quit a running installed copy through its tray menu before updating it.

if PowerShell blocks the script, review it first, then run
`powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build-windows.ps1`.
this applies only to that process, not your machine's execution policy.

start the installed app with:

```powershell
& "$env:LOCALAPPDATA\Programs\Swiftify\bin\swiftify.exe"
```

font downloads are hash-checked on every configure; on Windows, a failed CMake
download is retried with `curl.exe` using the system certificate store.

## Command line

only one swiftify runs at a time. launching it again just passes the command to the one
that's already running, so these work great as keybinds:

| flag | |
|---|---|
| `--immersive` | open the immersive player |
| `--play-pause` | play or pause |
| `--next` | next song |
| `--previous` | previous song |

on hyprland for example:

```ini
bind = SUPER SHIFT, M, exec, swiftify --immersive
bind = , XF86AudioPlay, exec, swiftify --play-pause
```

## What's different on spotify-accurate

### Spotify features
- **Spotify Connect device.** Swiftify registers with Spotify as a Connect device named "Swiftify" and reports the song, position and play/pause. Spotify then counts it as the account's playing device, so Discord's Spotify connection shows "Listening to Spotify" automatically. You don't need an SDK or a Discord app ID.
- **Song radio.** "Go to Song Radio" in a song's menu opens a radio page for that song, the way Spotify does: the song first, then up to 50 similar songs from Spotify's radio, with Play and Shuffle.
- **Autoplay.** When the queue runs out, similar songs keep playing. This is on by default and can be switched off in Settings → Playback.
- **Your Library sidebar.** Favourite Songs, pinned playlists, your playlists and the artists you follow sit in one list, each with its cover and "Playlist • owner" or "Artist". Playlists and Artists filter chips narrow the list, and the sort button switches between Spotify's order and A to Z.
- **Search in the sidebar.** The Search entry is now a real search field. Typing opens the results, and a focused, empty field shows your recent searches. Clearing the field goes back to the page you were on before.
- **A top bar across the whole window**, as in Spotify: the playback menu and back on the left, and What's New, Friend Activity, your account and the window buttons on the right.
- **What's New.** The bell lists the last four weeks of releases from the artists you follow. Results are cached for 12 hours, and Spotify's rate limit is respected.
- **Friend Activity.** Shows what the people you follow are listening to, through Spotify's own buddylist endpoint. Clicking a song plays it.
- **Profile page.** Your picture, name, playlists, the artists you follow and what you played last, all inside the app.
- **Spotify icon.** The Spotify logo is used for the executable, the window, the taskbar and the installer.

### Design
- All button and icon shapes are plain circles or rounded squares instead of Material's cookies, clovers and bursts. Round artwork is a plain circle, not a squiggle, and buttons no longer have wavy outlines.
- Home and Search are the same size and line up in the sidebar. The spacing in the library header is even.
- Pages without a toolbar start closer to the top. Only playlists keep room for their toolbar.
- The bell and friends popups grow out of their buttons and stay put while the pointer moves.
- Mouse-wheel scrolling moves further per notch.
- New defaults: visualizers off, shapes off, reduced motion on, window controls on the right.

### Windows fixes
- Builds with MSVC and Qt 6.10. The code needs Qt 6.10 for `final` properties, not 6.9.
- material-color-utilities: compound literals `(Vec3){...}` became `Vec3{...}`, which MSVC accepts.
- The album title in the system media controls goes through `IMusicDisplayProperties2`.
- The frameless window gets native behaviour. The empty parts of the top bar are a real Windows title bar, so dragging, Aero Snap, restoring from maximized under the cursor and double-click maximize all work. Maximize fills only the monitor's work area, so the taskbar stays visible, including an auto-hidden one. The window buttons use Windows' own maximize, restore and minimize.
- The "Window controls on right" setting works again: off puts them on the left.

### Under the hood
- `spotify-core/src/connect_presence.rs`: the Connect device and its state reports (dealer connection, `PutStateRequest`).
- `spotify-core`: `station_json` (radio and autoplay through `radio-apollo`), `friends_json` (buddylist).
- Library: followed artists (`user-follow-read`). The library authorization version is now 3, so existing logins are asked to reconnect once.
