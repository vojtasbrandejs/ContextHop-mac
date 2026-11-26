# ContextHop

Continue a Claude Code conversation in Codex, or the other way around, from the macOS menu bar.

## Install

[Download from GitHub Releases](https://github.com/vojtasbrandejs/ContextHop-mac/releases/latest). The installer requires macOS 14.5 or later and Apple Command Line Tools with Swift 6 or newer.

```sh
curl -fL -o install.sh https://github.com/vojtasbrandejs/ContextHop-mac/releases/download/v1.0.2/install.sh && bash install.sh
```

The installer builds the app on your Mac for Apple silicon and Intel, then opens it. Run it again to update.

macOS may ask for Accessibility permission again after an update.

## Use

Open a conversation, click the two bubbles in the menu bar, and choose **Copy context**. Paste the prompt into the other tool on the same Mac. Grant Accessibility for visible-chat detection, or pick from **Recent chats**.

## Build from source

```sh
CONTEXTHOP_PACKAGE_DISTRIBUTION=0 ./scripts/make-app.sh
./scripts/run-tests.sh
```

[Privacy](PRIVACY.md) · [Security](SECURITY.md) · [MIT License](LICENSE)
