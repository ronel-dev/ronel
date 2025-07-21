# Ronel

**Ronel** ("Really Obvious Native Expression Language", or "Remotely-Operated Native Expression Language") uses HTML-over-the-wire to build native Flutter layouts.

## Features

Ronel provides a powerful and flexible way to build server-driven UI in Flutter, giving you the speed of web development with the performance of native code.

- **Ship at the Speed of the Web, with Native Power**  
Leverage your existing web app to radically accelerate development. Ronel embraces the "HTML-over-the-wire" paradigm, where your server remains the single source of truth for your application's views.

- **Fast, Stateful Navigation**

- **Choose either single-screen app or tabbed app**

- **Includes `RonelAuth` for authenticated experiences**

- Example app in `/example` directory 

## Getting started

Simply add Ronel to your project by running `flutter pub add ronel` in your project directory.

## Usage

In you `main.dart` add Ronel to you app's build method:

```dart
const ronelApp = Ronel(
        url: "https://ronel.dev/example",
        appTitle: 'Ronel Example',
        useAutoPlatformDetection: false,
        uiDesign: 'Material',
        appBarColor: Colors.redAccent,
      );
    return ronelApp;
```

## Additional information

We're just getting started. I'm working on the website and documentation pages as you read this, so stay tuned!
-Mark
