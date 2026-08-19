# Basic configuration
The RESTful API and web interface are enabled by installing the `oxidized-web`
gem and configuring the `extensions.oxidized-web:` section in the configuration
file:
```yaml
extensions:
  oxidized-web:
    load: true
    # enter your configuration here
```

You can set the following parameter:
- `load`: `true`/`false`: Enables or disables the `oxidized-web` extension
  (default: `false`)
- `listen`: Specifies the interface to bind to (default: `127.0.0.1`). Valid
  options:
  - `127.0.0.1`: Allows IPv4 connections from localhost only
  - `'[::1]'`: Allows IPv6 connections from localhost only
  - `<IPv4-Address>` or `'[<IPv6-Address>]'`: Binds to a specific interface
  - `0.0.0.0`: Binds to any IPv4 interface
  - `'[::]'`:  Binds to any IPv4 and IPv6 interface
- `port`: Specifies the TCP port to listen to (default: `8888`)
- `url_prefix`: Defines a URL prefix (default: no prefix)
- `vhosts`: A list of virtual hosts to listen to. If not specified, it will
  respond to any virtual host.
- `max_failures`: How many recent failures to keep and show per host on the
  node detail page (default: `10`). See
  [Host credentials and failure history](#host-credentials-and-failure-history).
- `hide_credentials`: `true`/`false`: Hides the resolved username and password
  on the node detail page and omits the password from its JSON representation
  (default: `false`).

## Examples

```yaml
# Listen on http://[::1]:8888/
extensions:
  oxidized-web:
    load: true
    listen: '[::1]'
    port: 8888
```

```yaml
# Listen on http://127.0.0.1:8888/
extensions:
  oxidized-web:
    load: true
    listen: 127.0.0.1
    port: 8888
```

```yaml
# Listen on http://[2001:db8:0:face:b001:0:dead:beaf]:8888/oxidized/
extensions:
  oxidized-web:
    load: true
    listen: '[2001:db8:0:face:b001:0:dead:beaf]'
    port: 8888
    url_prefix: oxidized
```

```yaml
# Listen on http://10.0.0.1:8000/oxidized/
extensions:
  oxidized-web:
    load: true
    listen: 10.0.0.1
    port: 8000
    url_prefix: oxidized
```

```yaml
# Listen on any interface to http://oxidized.rocks:8888 and
# http://oxidized:8888
extensions:
  oxidized-web:
    load: true
    listen: '[::]'
    url_prefix: oxidized
    vhosts:
     - oxidized.rocks
     - oxidized
```

# Hide node vars
Some node vars (enable, password) can contain sensible data. You can list the
vars to be hidden under `hide_node_vars`:
```yaml
extensions:
  oxidized-web:
    load: true
    hide_node_vars:
     - enable
     - password
```

# Host credentials and failure history
The node detail page (`/node/show/<node>`) shows, in addition to the serialized
node metadata:

- **Host credentials**: the username and password Oxidized resolved for the
  host (from the node, group, model and global configuration). The password is
  masked in the UI and revealed with a click. Note that the mask is only
  cosmetic — the password value is delivered in the page (and in the JSON
  representation), so anyone who can load the page can read it. Use
  `hide_credentials` to suppress it entirely.
- **Recent failures**: a short history of the last failed backup attempts, one
  entry per connection method. Oxidized tries each configured input in turn
  (for example SSH and then Telnet), and the core keeps only the *last* error;
  `oxidized-web` records each attempt so a host that fails SSH and then Telnet
  shows one entry for each, with the timestamp, protocol, error type and error
  message. The history is built in memory from the first failed poll after the
  extension has loaded and resets when the node list is reloaded or Oxidized
  restarts. Until a host has failed with the extension running, the list falls
  back to the single last error the core still holds for that host (with the
  protocol filled in when the host has exactly one configured input), so a
  currently-failing host always shows *why* rather than an empty list.

The number of failures retained per host is controlled by `max_failures`
(default `10`). To keep credentials out of the web UI and API entirely, set
`hide_credentials: true`:

```yaml
extensions:
  oxidized-web:
    load: true
    # keep up to 20 recent failures per host on the detail page
    max_failures: 20
    # do not expose the resolved username/password in the web UI or JSON
    hide_credentials: true
```

> **Note**: `oxidized-web` has no authentication of its own. When credentials
> are displayed, make sure the interface is only reachable by trusted operators
> (bind it to localhost, or place it behind an authenticating reverse proxy).