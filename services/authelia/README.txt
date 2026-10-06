SSO and 2FA gateway for all services, backed by a lightweight LDAP user directory.

Services:
  authelia  :9091  Single sign-on + 2FA portal
  lldap     :17170 Web UI for managing users and groups

Before deployment:
  .env
  config/authelia/configuration.yml
