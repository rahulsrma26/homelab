SSO and 2FA gateway for all services, backed by a lightweight LDAP user directory.

Services:
  authelia  :9091  Single sign-on + 2FA portal
  lldap     :17170 Web UI for managing users and groups

Authelia waits for LLDAP's built-in health check before starting, including on a
fresh directory database, so its LDAP startup check does not race initialization.

Before deployment:
  .env — AUTHELIA_SESSION_DOMAIN is the cookie domain; AUTHELIA_URL is the full
         HTTPS address of the authentication portal (default https://auth.<domain>)
  config/authelia/configuration.yml — uses Authelia's template filter

Existing installations: merge the new configuration template and Compose environment
entries together. labber preserves edited config files and saves the repo's version
as .labber-new. Remove the old session.domain setting when using session.cookies.

Validate before starting:
  docker compose run --rm --no-deps authelia authelia config validate --config /config/configuration.yml
