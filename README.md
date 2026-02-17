# Tcl/Tk Packages registry

Central registry of third-party packages and extensions for `Tcl/Tk`

## Adding a package :

Submit a PR with your package information. Simply add an entry to the `packages.json` file following this format:

```json
{
  "name": "mypackage",
  "sources": [
    {
      "url": "https://github.com/user/mypackage",
      "method": "git",
      "web": "https://github.com/user/mypackage",
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

If the package name already exists, add another source like this:

```json
{
  "name": "mypackage",
  "sources": [
    {
      "url": "https://github.com/user/mypackage",
      "method": "git",
      "web": "https://github.com/user/mypackage",
      "author": "user",
      "license": "MIT"
    },
    {
      "url": "https://github.com/user1/mypackage",
      "method": "git",
      "web": "https://github.com/user1/mypackage",
      "author": "user1",
      "license": "Apache 2.0"
    }
  ],
  "tags": ["tcl", "module", "category"],
  "description": "Description here"
}
```

## License

This registry is dedicated to the public domain under [CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/).