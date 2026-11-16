SSO and 2FA gateway for the services behind Traefik, backed by a lightweight LDAP user directory.

Services:
  authelia  :9091  login portal + Traefik's forwardAuth endpoint (/api/authz/forward-auth)
  lldap     :17170 web UI for users and groups (admin / LLDAP_ADMIN_PASSWORD)

Data: AUTHELIA_DATA (sessions, TOTP and WebAuthn registrations, encrypted with
AUTHELIA_STORAGE_ENCRYPTION_KEY) and LLDAP_DATA (users, groups, password hashes): folders on a
backed-up dataset. Keep the generated secrets in the password manager: a restore needs the same
storage key to read the second factors. PUID:PGID: the user that runs labber (Authelia's
entrypoint gives /config to them and runs as them; unset, it gave /config to root).

Before deployment:
  .env — AUTHELIA_SESSION_DOMAIN: the domain the protected apps share (home.<domain>);
         AUTHELIA_URL: the portal inside it (https://auth.home.<domain>)
  config/authelia/configuration.yml — access_control: default two_factor; add rules per app
         or group (e.g. one_factor for a low-risk app, a group for family accounts)

Traefik (lan mode): a route for the portal, and one middleware the protected routes name:
  http:
    middlewares:
      authelia:
        forwardAuth:
          address: http://<authelia-host>:9091/api/authz/forward-auth
          trustForwardHeader: true
          authResponseHeaders: [Remote-User, Remote-Groups, Remote-Email, Remote-Name]
    routers:
      auth:    {rule: "Host(`auth.home.<domain>`)", service: authelia, ...}
      termix:  {..., middlewares: [authelia, secure-headers]}
Firewall: the authelia host takes 9091 from Traefik only; 17170 (LLDAP's UI) from admins.
Tested end to end (Traefik selfsigned + a test app): no session → 302 to the portal; a login
through LLDAP; a one_factor app gets Remote-User / Remote-Groups; a two_factor app still asks
for the second factor.

First users: LLDAP's UI → create users and groups (e.g. admins); each user registers a TOTP or a
passkey at the first two_factor login. Notifications (password reset, device registration)
go to /data/notification.txt until an SMTP notifier is configured.

Validate before starting:
  docker compose run --rm --no-deps authelia authelia config validate --config /config/configuration.yml
