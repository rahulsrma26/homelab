Forgejo — local Git hosting, private repositories, Actions and GitHub publishing.

Deploy with labber forgejo install. SQLite and repositories live in FORGEJO_DATA
(default ./data); back up this entire directory and .env. The server never mounts a Docker socket.

Before deployment:
  .env — data directory, HTTPS domain, guest's direct SSH hostname/address, Traefik's source IP,
         HTTP/SSH ports, and the data owner's UID/GID

Storage mode (COMPOSE_FILE in .env):
  local  Actions artifacts and packages in FORGEJO_DATA (the default)
  s3     artifacts and packages in an S3 bucket, e.g. services/garage; Actions logs
         stay local. Forgejo refuses to start while the bucket is unreachable and
         retries until it is back; a running Forgejo keeps serving Git. Put the S3
         server on the same host, or switch to local to start without it.
Packages are off by default (PACKAGES_ENABLED); artifacts are kept 7 days and
Actions logs 90 days.

The HTTPS name resolves to Traefik; the SSH name resolves directly to this guest.
Allow HTTP only from Traefik (and a local readiness check), SSH from trusted Git
clients. This service uses Forgejo login; do not put a browser-only login in front
of Git, API, runner or registry endpoints. Registration is disabled; create the
first administrator with the CLI as described in guides/forgejo-setup.md.

CI/CD also needs a runner. One VM can host both Forgejo and the native runner.
The runner's Docker access then gives trusted workflows control of that entire
VM, including Forgejo data. Separate Forgejo LXC + runner VM provides a stronger
boundary. The full labber tests require the runner VM; a server-only LXC works.

runner/ contains native runner and systemd templates. examples/ contains workflows
to copy into a repository after reviewing labels and deployment targets. They do
not run automatically from this service directory. Deployment uses labber.
Full setup, CI/CD, backups and recovery: guides/forgejo-setup.md.
