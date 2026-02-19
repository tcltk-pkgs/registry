# Tcl/Tk Packages Registry

Central registry of third-party packages and extensions for `Tcl/Tk`.

## Browse Packages

Visit the web interface: **[tcltk-pkgs.pages.dev](https://tcltk-pkgs.pages.dev)**

Search, filter and explore all available packages with an easy-to-use interface.
- Full-text search
- Filter by tags
- Sort by popularity, recent updates, or name
- Direct links to repositories and documentation

## Adding a Package

Submit a PR adding your package to packages.json. The registry is automatically rebuilt daily.

| Field               | Type   | Description                         |
| ------------------- | ------ | ----------------------------------- |
| `name`              | string | Package name (no spaces)            |
| `sources`           | array  | Array of source objects             |
| `sources[].url`     | string | Repository URL                      |
| `sources[].method`  | string | `git` or `fossil` (optional)        |
| `sources[].web`     | string | Documentation URL (optional)        |
| `sources[].author`  | string | Package author/maintainer           |
| `sources[].license` | string | SPDX license identifier             |
| `tags`              | array  | Keywords for categorization         |
| `description`       | string | Short description                   |

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
      "license": "BSD-3-Clause"
    }
  ],
  "tags": ["official", "library", "core"],
  "description": "Standard Tcl library"
}
```

> [!NOTE]  
> `method` can be `git` or `fossil` for now. The `web` field is optional and points to documentation if different from the repository `URL`.

## Auto-Update

This repository uses GitHub Actions to:
- Validate packages.json on every PR.
- Generate packages-meta.json daily (metadata, stats, validation).

## License

This registry is dedicated to the public domain under [CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/).