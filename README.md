# Tcl/Tk Packages Registry
<div align="center">
  <img src="metadata/assets/packages.svg" alt="description" width="65%" height="65%">
</div>

Central registry of third-party packages and extensions for `Tcl/Tk`.

![Packages](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/tcltk-pkgs/registry/master/metadata/packages-meta.json&query=$%5B0%5D.total_packages&label=📦%20Packages&color=informational)
![Contributors](https://img.shields.io/github/contributors/tcltk-pkgs/registry?label=👥%20Contributors&color=success)
![Version](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/tcltk-pkgs/registry/master/metadata/packages-meta.json&query=$%5B0%5D.version&label=📝%20Version&color=orange)

## Browse Packages

Visit the **[web](https://tcltk-pkgs.pages.dev)** interface

Search, filter and explore all available packages with an easy-to-use interface.
- Full-text search
- Filter by tags
- Sort by popularity, recent updates, or name
- Direct links to repositories and documentation

## Adding a Package

Submit a PR adding your package to packages.json. The registry is automatically rebuilt daily.

| Field                  | Type            | Description                         |
| -------------------    | --------------- | ----------------------------------- |
| `name`                 | string          | Package name (no spaces)            |
| `sources`              | array           | Array of source objects             |
| `sources[].url`        | string          | Repository URL                      |
| `sources[].method`     | string          | `git` or `fossil` (optional)        |
| `sources[].web`        | string          | Documentation URL (optional)        |
| `sources[].artifacts`  | string          | This specifies the URL where the built releases, tarballs, or binaries are hosted. (optional) |
| `sources[].author`     | string \| array | Package author(s). Single name as string, or multiple as array of strings (`["author1" , "author2", "..."]`) |
| `sources[].extension`  | boolean         | `true` if this is a compiled (C/C++/etc...) extension (requires build or binaries), `false` or omit for pure Tcl scripts (optional) |
| `sources[].license`    | string          | SPDX license identifier             |
| `tags`                 | array           | Keywords for categorization         |
| `description`          | string          | Short description                   |

### Examples:
```json
{
  "name": "mypackage",
  "sources": [
    {
      "url": "https://github.com/user/mypackage",
      "method": "git",
      "web": "https://user.github.io/mypackage",
      "author": "John Doe",
      "license": "MIT"
    }
  ],
  "tags": ["json", "parser", "utility"],
  "description": "Fast JSON parser for Tcl"
}
```

#### Multiple sources (mirrors):
```json
{
  "name": "mypackage",
  "sources": [
    {
      "url": "https://github.com/tcltk/mypackage",
      "method": "git",
      "author": "Tcl Community",
      "license": "BSD-3-Clause"
    },
    {
      "url": "https://core.tcl-lang.org/mypackage",
      "method": "fossil",
      "author": "Tcl Community",
      "license": "MIT"
    }
  ],
  "tags": ["official", "library", "core"],
  "description": "Standard Tcl library"
}
```

> [!NOTE]  
> The `web` field is optional and points to documentation if different from the repository `url`.  
> The `method` field is optional, used only if the `url` is a GitHub repository or a Fossil repository.

## My Package is incorrectly listed

Please open an issue at [registry/issues](https://github.com/tcltk-pkgs/registry/issues)

## Auto-Update

This repository uses GitHub Actions to:
- Validate packages.json on every PR.
- Generate packages-meta.json daily (metadata, stats, validation).

## Acknowledgments

The registry format draws inspiration from modern package registries 
(npm, Cargo, Nim) while being specifically adapted for the Tcl/Tk ecosystem.

## See Also

**[Tcl-Related-Link](https://github.com/ray2501/Tcl-Related-Link)** — An exhaustive, well-organized collection of Tcl/Tk links including books, tools, extensions, and language bindings. A must-bookmark for any Tcl developer.

## License

This registry is dedicated to the public domain under [CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/).