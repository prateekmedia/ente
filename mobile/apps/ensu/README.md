# Ensu

Ensu is Ente's end-to-end encrypted chat app. It is local-first (works offline),
can sync across devices when you sign in, and ships with an on-device LLM for
local assistant responses.

To know more about Ente, see [our main README](../../../README.md) or visit
[ente.io](https://ente.io).

If you're looking for Ente Photos or Ente Auth instead, see
[../photos/README.md](../photos/README.md) or [../auth/README.md](../auth/README.md).

## Build from source

1. Install [Flutter v3.32.8](https://flutter.dev/docs/get-started/install).

2. Pull in all submodules with `git submodule update --init --recursive`

3. Install dependencies using one of these methods:
   - Using Melos (recommended): Install Melos with `dart pub global activate melos`,
     then from any folder inside `mobile/`, run `melos bootstrap`.
   - Using Flutter directly: Run `flutter pub get` in `packages/strings` and this
     folder.

4. For Android, set up your keystore and run
   `flutter build apk --release --flavor independent`

5. For iOS, run `flutter build ios`

## Develop

For Android, use

```sh
flutter run -t lib/main.dart --flavor independent
```

For iOS, use `flutter run`.

To point the app at a custom server, open the drawer and tap the "ensu" title
five times to open Developer Settings, then update the endpoint.

## On-device LLM

Ensu includes an on-device LLM that is downloaded on first use.


## Contribute

For more ways to contribute, see [../../../CONTRIBUTING.md](../../../CONTRIBUTING.md).
