# dial

> _The Talkative Command Line Companion for Amusing Dialogues_

`dial` is a command line tool to interact with [openai](https://openai.com/)'s chat api. It supports custom [function calling](https://platform.openai.com/docs/guides/gpt/function-calling) plugins written in any language that can expose a C api. It is released under the [MIT Licence](LICENSE).

## Build

Currently only tested on MacOS and zig version `0.11.0-dev.3803+7ad104227`. The only dependency is [`curl`](https://curl.se/).

```sh
$ zig build -Doptimize=ReleaseSafe
```

The executable will be found in `zig-out/bin/dial` and you can move it to your `$PATH`.

## Usage

```
$ dial
Welcome to dial v0.0.1 (gpt-3.5-turbo-0613)
Type ".help" for more information.
user> .help

.help         Print this help message
.exit         Exit the program
.clear        Clear the message history and start over
.editor .e    Open an editor for prompt editing

More information on https://github.com/jonase/dial

user> Say this is a test
This is a test.
user> .exit
```

## Configuration

### credentials.json

You will need an [openai api key](https://platform.openai.com/overview). Create a file `~/.dial/credentials.json` with the content

```json
{
  "openai_api_key": "YOUR API KEY",
  "openai_organization_id": "YOUR ORG ID"
}
```

`openai_organization_id` is optional.

### config.json

You can also create a `~/.dial/config.json` file with the content

```json
{
  "model": "gpt-3.5-turbo-0613",
  "editor": ["emacs"]
}
```

This file (including all top level keys) is optional.

## Plugins

### Configuration

The default plugin search path is `~/.dial/plugins` and you can add additional search paths to your configuration file using the `plugin_search_paths` key:

```json
...
"plugin_search_paths": ["/absolute-path-to/my-plugin/out", ...]
...
```

To enable a plugin, add the shared library (`.dll`, `.so` or `.dylib`) to one of the folders in your `plugin_search_paths` and add an entry in your configuration file:

```json
...
"plugins": [
  ...
  {
    // Required. Omit the file-extension and the "lib" prefix.  For example, if your
    // plugin file is named 'libmy-plugin.dylib' the correct value would be 'my-plugin'
    "name": "my-plugin",
    // Optional, default null. Arguments passed to the plugin on initialization.
    // Check the plugin's documentation for details
    "args": {},
    // Optional, default true. Set to false to disable this plugin, but keep it in the
    // configuration file
    "enabled": true,
    // Optional, default false. Set to true to make dial not ask for confirmation before
    // running a plugin function.
    "auto_confirm": false,
  }
  ...
]
...
```

### Creating plugins

A plugin is a dynamic library implementing the C API as described in [`include/dial-plugin.h`](include/dial-plugin.h). You can find a minimal example (in C) at [`example/c_example_plugin.c`](example/c_example_plugin.c) and an example (in zig) at [`example/zig_example_plugin.zig`](example/zig_example_plugin.zig)
