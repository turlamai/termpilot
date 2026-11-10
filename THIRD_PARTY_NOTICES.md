# Third-party notices

TermPilot builds on the components below. Each entry names where the
component enters the shipped artifacts and the license it is
distributed under; consult the upstream license files for full terms.
The Glaze toolchain and Switchboard are first-party TurLamAI projects
consumed as pinned packages — not third-party code — so they are not
listed here.

## Racket CS runtime

Every platform package embeds the statically linked Racket CS runtime
([racket/racket](https://github.com/racket/racket), 9.x). Racket is
distributed under the MIT license and the Apache License 2.0, at your
option; the Racket CS runtime system additionally embeds Chez Scheme,
distributed under the Apache License 2.0 (per Racket's `LICENSE.txt`).

## OpenSSH (system sidecar)

SSH sessions, tunnels, port forwarding, SFTP and key generation
execute the system OpenSSH binaries (`ssh`, `sftp`, `ssh-keygen`)
that the user's OS ships — TermPilot bundles no SSH implementation.
OpenSSH is licensed under the BSD 2-Clause license (with ISC and BSD
components per its `LICENCE` file).

## WebKitGTK and GTK (Linux)

The Linux host renders in a native WebKitGTK window. WebKitGTK and
GTK are licensed under the GNU Lesser General Public License, version
2.1 or later, and are not bundled: every Linux shape takes them from
the distribution as runtime dependencies.

## WebView2 (Windows)

The Windows host renders in the system's Microsoft Edge WebView2
runtime (an evergreen OS component, not shipped here) and packages
the WebView2Loader.dll from the Microsoft Windows App SDK
([microsoft/WindowsAppSDK](https://github.com/microsoft/WindowsAppSDK)),
licensed under the MIT license. The WiX toolset builds the MSI at
release time and does not ship inside it.

## xterm.js and addons

The terminal UI renders with
[xterm.js](https://github.com/xtermjs/xterm.js) plus its fit, search
and web-links addons (`@xterm/*`), all licensed under the MIT license.
The built bundles ship inside the packaged app.

## React, React DOM and Zustand

The frontend is a React application; the built assets are served
inside the packaged app. React and React DOM
([facebook/react](https://github.com/facebook/react)) and Zustand
([pmndrs/zustand](https://github.com/pmndrs/zustand)) are licensed
under the MIT license.

## Build-time tooling (not shipped)

Vite, TypeScript and the React type definitions (all MIT) run only at
build time and contribute no code to the release artifacts.
