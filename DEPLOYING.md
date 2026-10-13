# Deploying VexelRay

How the applications get from the sibling checkouts to the one-line installer. [README.md](README.md) is the
install page that users see; it is generated, so this file is the one to edit.

```
build.cmd ──► native exes in each app's target\ ──► deploy.ps1 ──► apps\<id>\, install.ps1, README.md   (git)
                                                              └──► assets\, exe\  ──► -Publish ──► GitHub releases
```

## What lives where

| Where | What |
| --- | --- |
| each app's `installer.json` (in its own repo) | the app's id, name, version, binary, icon, shortcuts and file types. `repo`, `repoPath` and `releasesRepo` point here |
| `installer-suite.json` (here) | which apps the suite installs, in order, and where each links to |
| `apps/<id>/` (here, committed) | each app's `install.ps1`, `uninstall.ps1`, `update.ps1`, `manifest.json` and install page |
| `install.ps1`, `README.md` (here, committed) | the suite: runs each app's installer in turn |
| releases on `sibarum/vexelray-dist` | the binaries, one release per app version, tagged `<id>-v<version>` (`pix-v0.1.0`) |
| `exe/`, `assets/`, `logs/` (here, ignored) | build output; never committed |

`install.ps1` never changes between releases. It reads the app's `manifest.json`, which names each file's
download URL and SHA-256, so publishing a version is: upload the files, then commit the manifests that name them.

The public install page is on the framework's GitHub Pages site,
[`vexelray-framework/docs/install/index.md`](https://github.com/sibarum/vexelray-framework/blob/main/docs/install/index.md),
written by hand. It only needs changing when the list of apps or the one-liner does.

## One-time setup

- Every repository checked out side by side in one folder, this one included.
- GraalVM 25 as `JAVA_HOME`, and Maven.
- Visual Studio 2026 (18) Community with the C++ workload: native-image links with MSVC's `link.exe` and the icons
  are compiled with `rc.exe`. `build.cmd` sets this up itself with `vcvars64.bat`.
- `imagelib-wrapper`'s native library, built once with a Rust toolchain: `./native/build.sh` in that repo.
- To publish: a **fine-grained** GitHub token, repository access *only* `sibarum/vexelray-dist`, permission
  **Contents: read and write**. Nothing else. `deploy.ps1 -Publish` asks for it; it is never stored.

## Releasing a new version of the apps

1. **Build.** From PowerShell, not Git Bash (under Git Bash `vcvars64.bat` fails and `link.exe` is Git's):
   ```powershell
   .\build.cmd
   ```
   Clean-installs the libraries in dependency order with their tests, then tests each app and builds its release
   native image. It stops at the first library that fails; an app that fails is reported and the rest carry on.
   Logs are in `logs\`.
2. **Bump the version** in the `installer.json` of each app that changed. A published version is final: its
   release exists, and every install that has it compares against it. An app whose version did not change is
   regenerated identically (only an `updatedAt` stamp moves; discard that with `git checkout -- apps`).
3. **Generate, and look before publishing.**
   ```powershell
   .\deploy.ps1
   git diff
   ```
   The diff should show only the apps you bumped: a new entry in their `manifest.json`, and their pages.
4. **Publish.** Creates each new release and uploads its exe and icon:
   ```powershell
   .\deploy.ps1 -Publish
   ```
5. **Commit and push.** Until the manifests are pushed, nobody sees the new version; once they are, the install
   command and every app's updater offer it. GitHub's raw host caches for a few minutes.
   ```powershell
   git add -A; git commit -m "Pix 0.1.1"; git push
   ```
6. **Try it** on a machine (or a user account) without the apps:
   ```powershell
   irm https://raw.githubusercontent.com/sibarum/vexelray-dist/main/install.ps1 | iex
   ```

## Adding an app to the suite

1. Give its repo an `installer.json` like the others: `"repo": "sibarum/vexelray-dist"`, `"repoPath": "apps/<id>"`,
   `"releasesRepo": "sibarum/vexelray-dist"`, `"tagFormat": "<id>-v{version}"`.
2. Add it to `installer-suite.json` (`config` is relative to this folder) and to the app list in `build.cmd`.
3. Add it to the table on the install page in `vexelray-framework/docs/install/index.md`, and to the home page.
4. Release as above.

## Source releases (tags on every repository)

Separate from the installers, and not needed for every app release. `release.py` cuts a release of all 24
repositories at once, from PowerShell:

```powershell
python release.py release
python release.py next
```

`release` turns each repository's `X-SNAPSHOT` into `X` (in its poms and in the framework's project template),
builds and tests all of them in order, and only when every one has passed commits `Release X` and tags `vX`.
`next` moves each to the next snapshot (`0.1.0` to `0.1.1-SNAPSHOT`), installs it locally and commits. Neither
pushes; push each repository's branch and tag afterwards, for example:

```bash
git push origin main v0.1.0
```

Nothing is deployed to a Maven repository. 0.1.0 (1.0 for atchung, kronometer, tactroller and cardinal; 0.2.0
for supirvast) was cut on 13 October 2026.

## When it goes wrong

- **`'vswhere.exe' is not recognized`** is printed by `vcvars64.bat` and is harmless when the build goes on. If
  native-image then fails to link, the build was started from Git Bash; use PowerShell.
- **`Unable to run 'WindowsDirectives.exe'`**: Windows Application Control blocked one of native-image's probes.
  Run the build again.
- **A test fails at a release version but passed at the snapshot**: something depends on the version ending in
  `-SNAPSHOT`. intrabuf's example did (its payloads are marked dev or release by the version); it now pins its
  snapshot flag instead.
- **A GPU timing test fails now and then**: supirvast's `CompletionTest` compares the fastest of seven runs, since
  an integrated GPU's clocks make single samples useless. If one still fails, it is worth a look, not a retry loop.
- **The suite skips an app as "not published"**: its `manifest.json` is not on `main` yet, or the raw host has not
  caught up. Check `https://raw.githubusercontent.com/sibarum/vexelray-dist/main/apps/<id>/manifest.json`.
