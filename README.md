# Setup MSSQL Action

This GitHub action automatically installs a SQL server and `sqlcmd` on Windows and Linux.

On Windows, we install an Express edition of the container. On Linux, a Docker container is started. `sqlcmd` is actually preinstalled on all Windows images as well as Ubuntu 22.04. Essentially, it only has an effect on Ubuntu 24.04.

## Usage

### Inputs

* `components`: Specify the components you want to install. Can be `sqlengine` and `sqlcmd`. The list of components needs be a comma-separated list like `sqlengine,sqlcmd`. [GitHub Actions does not support passing YAML lists to composite actions](https://github.com/actions/runner/issues/2238).
* `force-encryption`: When you request to install `sqlengine`, you can set this input to `true` in order to encrypt all connections to the SQL server. The action will generate a self-signed certificate for that. Default is `false`.
* `sa-password`: The sa password for the SQL instances. Default is `bHuZH81%cGC6`.
* `version`: Version of the SQL server you want to install (2019 or 2022).

### Example

```yaml
name: Continuous Integration

on:
  pull_request:
  push:
  schedule:
    - cron: "30 8 * * 1"

jobs:
  test:
    name: Tests
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup MSSQL
        uses: rails-sqlserver/setup-mssql@v1
        with:
          components: sqlcmd,sqlengine
          force-encryption: true
          sa-password: "iamastrongpassword1234!"
          version: 2022
```

## License

The scripts and documentation in this project are released under the MIT License.

## Credits

Inspiration for the action came from https://github.com/marketplace/actions/mssql-suite.
