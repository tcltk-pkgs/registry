# Tcl/Tk Packages registry

Central registry of third-party packages and extensions for `Tcl/Tk`

## Adding a package :

Submit a PR with your package information. Simply add an entry to the `packages.json` file following this format:

```json
{
  "name": "monpackage",
  "sources": [
    {
      "url": "https://github.com/user/monpackage",
      "method": "git",
      "web": "https://github.com/user/monpackage",
      "author": "user",
      "license": "MIT"
    }
  ],
  "tags": ["tcllib", "module", "category"],
  "description": "Description here"
}
```
> [!NOTE]  
> `method` can be `git` or `fossil` for now. The `web` field is optional and points to documentation if different from the repository `URL`.

## License

This registry is dedicated to the public domain under [CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/).